import Foundation

public struct RecipeCategory: Identifiable {
  public let id: String
  public let name: String
  public let section: String
  public let parentId: String?
}
public enum CatalogueVocabulary {
  static func json(_ name: String) -> [String: Any] {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
      let data = try? Data(contentsOf: url) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
  }
  public static let all: [RecipeCategory] = {
    var result: [RecipeCategory] = []
    for section in json("categories")["sections"] as? [[String: Any]] ?? [] {
      for value in section["categories"] as? [[String: Any]] ?? [] {
        guard let id = value["id"] as? String, let name = value["name"] as? String else { continue }
        result.append(RecipeCategory(id: id, name: name, section: section["name"] as? String ?? "Other", parentId: nil))
        for child in value["children"] as? [[String: Any]] ?? [] {
          if let cid = child["id"] as? String, let cname = child["name"] as? String {
            result.append(RecipeCategory(id: cid, name: cname, section: section["name"] as? String ?? "Other", parentId: id))
          }
        }
      }
    }
    return result
  }()
  public static func categories(_ values: [String]) -> [String]? {
    let values = Array(Set(values).intersection(all.map(\.id))).sorted()
    return values.isEmpty ? nil : values
  }
  public static func defaults(_ notebook: String) -> [String] {
    notebookDefaults[notebook] ?? []
  }
  // Every tidy folder is listed. Pumpkin has no single dish type or diet;
  // Pasta does not imply Italian, and the mixed Notes section has no cuisine.
  public static let notebookDefaults: [String: [String]] = [
    "Asian Cooking": ["asian"], "Bread Baking": ["bread-baking"], "Cooking": ["meat"],
    "Desserts": ["desserts"], "Ferment Preserves and Pickles": ["ferments-pickles"],
    "Fish Recipes": ["fish"], "Jams and Chutney": ["jams-chutneys"],
    "Lunches": ["lunches-light-meals"], "Mexican Dishes": ["mexican"],
    "Notes": ["notes-logs"], "Pasta Dishes": ["pasta-noodles"], "Pumpkin Recipes": [],
    "Salads": ["salads"], "Snacks and Dips": ["starters-snacks", "sauces-dips-condiments"],
    "Soups": ["soups"], "Vegetarian Recipes": ["vegetarian"]
  ]
  static let tagAliases: [String: String] = {
    var result: [String: String] = [:]
    for group in json("tags")["groups"] as? [[String: Any]] ?? [] {
      for value in group["tags"] as? [[String: Any]] ?? [] {
        guard let tag = value["tag"] as? String else { continue }
        result[tag] = tag
        for alias in value["aliases"] as? [String] ?? [] { result[alias] = tag }
      }
    }
    return result
  }()
  public static var knownTags: [String] { Array(Set(tagAliases.values)).sorted() }
  public static func tag(_ text: String) -> String {
    let name = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# \n\t"))
      .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: "-")
    return tagAliases[name] ?? name
  }
  public static func hasCategory(_ recipe: Recipe, _ id: String) -> Bool {
    let values = recipe.categories ?? []
    return values.contains(id) || all.contains { $0.parentId == id && values.contains($0.id) }
  }
}

public enum RecipeSearch {
  static let aliases = CatalogueVocabulary.json("ingredient-synonyms")["aliases"] as? [String: String] ?? [:]
  static let groups = CatalogueVocabulary.json("ingredient-synonyms")["groups"] as? [String: [String]] ?? [:]
  public static func normalise(_ text: String) -> String {
    var value = RecipePersistence.normaliseText(text)
    value = value.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.map {
      $0.count > 3 && $0.hasSuffix("s") && !$0.hasSuffix("ss") ? String($0.dropLast()) : $0
    }.joined(separator: " ")
    for (alias, canonical) in aliases.sorted(by: { $0.key.count > $1.key.count }) {
      value = (" " + value + " ").replacingOccurrences(of: " " + alias + " ", with: " " + canonical + " ").trimmingCharacters(in: .whitespaces)
    }
    return value
  }
  static let tokenExpression = try! NSRegularExpression(pattern: #"-?"[^"]+"|\S+"#)
  public static func score(_ recipe: Recipe, query: String, pantry: Bool = false) -> Int? {
    SearchQuery(query).score(recipe, document: SearchDocument(recipe), pantry: pantry)
  }
  public static func results(_ recipes: [Recipe], query: String, pantry: Bool = false) -> [Recipe] {
    let index = RecipeSearchIndex()
    index.update(recipes)
    return index.results(recipes, query: query, pantry: pantry)
  }
}

struct SearchDocument {
  let fingerprint: String
  let original: Recipe
  let ingredients: String
  let title: String
  let body: String
  init(_ recipe: Recipe) {
    fingerprint = recipe.fingerprint
    original = recipe
    ingredients = " " + RecipeSearch.normalise((recipe.ingredients ?? []).joined(separator: " ") + " " + (recipe.mainIngredient ?? "")) + " "
    title = " " + RecipeSearch.normalise(recipe.title) + " "
    body = " " + RecipeSearch.normalise(recipe.blocks.map(\.text).joined(separator: " ") + " " + (recipe.personalNotes ?? "") + " " + (recipe.cookHistory ?? []).compactMap(\.note).joined(separator: " ")) + " "
  }
  func isCurrent(_ recipe: Recipe) -> Bool {
    fingerprint == recipe.fingerprint && original.title == recipe.title
      && original.ingredients == recipe.ingredients && original.mainIngredient == recipe.mainIngredient
      && original.blocks == recipe.blocks && original.personalNotes == recipe.personalNotes
      && (original.cookHistory ?? []).compactMap(\.note) == (recipe.cookHistory ?? []).compactMap(\.note)
  }
}

struct SearchQuery {
  enum Kind { case text([String]), tag(String), category(String), cuisine(String), never, before(Date) }
  struct Token { let negative: Bool; let kind: Kind }
  let tokens: [Token]
  init(_ query: String) {
    tokens = RecipeSearch.tokenExpression.matches(in: query, range: NSRange(query.startIndex..., in: query)).compactMap { match in
      guard let range = Range(match.range, in: query) else { return nil }
      let token = String(query[range])
      let negative = token.hasPrefix("-")
      let raw = (negative ? String(token.dropFirst()) : token).trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
      let kind: Kind
      if raw.hasPrefix("#") { kind = .tag(CatalogueVocabulary.tag(raw)) }
      else if raw.hasPrefix("category:") { kind = .category(String(raw.dropFirst(9))) }
      else if raw.hasPrefix("cuisine:") { kind = .cuisine(String(raw.dropFirst(8))) }
      else if raw == "cooked:never" { kind = .never }
      else if raw == "cooked:>6m" { kind = .before(Calendar.current.date(byAdding: .month, value: -6, to: Date())!) }
      else {
        let term = RecipeSearch.normalise(raw)
        kind = .text(([term] + (RecipeSearch.groups[term] ?? [])).map { " " + RecipeSearch.normalise($0) + " " })
      }
      return Token(negative: negative, kind: kind)
    }
  }
  func score(_ recipe: Recipe, document: SearchDocument, pantry: Bool) -> Int? {
    var score = 0
    var textMatches = 0
    var positiveTextTerms = 0
    for token in tokens {
      let matched: Bool
      var weight = 1
      switch token.kind {
      case .tag(let tag): matched = (recipe.tags ?? []).contains(tag)
      case .category(let category): matched = CatalogueVocabulary.hasCategory(recipe, category)
      case .cuisine(let cuisine): matched = recipe.cuisine == cuisine
      case .never: matched = recipe.cookCount == 0
      case .before(let date): matched = recipe.lastCookedAt.map { $0 < date } ?? true
      case .text(let variants):
        weight = variants.contains(where: document.ingredients.contains) ? 30 : variants.contains(where: document.title.contains) ? 20 : variants.contains(where: document.body.contains) ? 10 : 0
        matched = weight > 0
        if !token.negative {
          positiveTextTerms += 1
          if matched { textMatches += 1 }
          if pantry { score += weight; continue }
        }
      }
      if token.negative ? matched : !matched { return nil }
      if !token.negative { score += weight }
    }
    if pantry && positiveTextTerms > 0 && textMatches == 0 { return nil }
    return score
  }
}

public final class RecipeSearchIndex {
  private var documents: [UUID: SearchDocument] = [:]
  public private(set) var normalisationCount = 0
  public init() {}
  public func update(_ recipes: [Recipe]) {
    let ids = Set(recipes.map(\.id))
    documents = documents.filter { ids.contains($0.key) }
    for recipe in recipes where documents[recipe.id]?.isCurrent(recipe) != true {
      documents[recipe.id] = SearchDocument(recipe)
      normalisationCount += 1
    }
  }
  public func results(_ recipes: [Recipe], query: String, pantry: Bool = false) -> [Recipe] {
    // Publishing recipes and updating the cache must not leave a transient empty list.
    // Also supports newly imported/edited records before a caller's explicit cache update.
    for recipe in recipes where documents[recipe.id]?.isCurrent(recipe) != true {
      documents[recipe.id] = SearchDocument(recipe)
      normalisationCount += 1
    }
    let parsed = SearchQuery(query)
    return recipes.compactMap { recipe -> (Recipe, Int)? in
      guard let document = documents[recipe.id], let score = parsed.score(recipe, document: document, pantry: pantry) else { return nil }
      return (recipe, score)
    }.sorted {
      // Best text match first, then alphabetical. Favourites are not pinned to the
      // top; they are browsed via the Favourites section. (The Mac re-sorts anyway.)
      if $0.1 != $1.1 { return $0.1 > $1.1 }
      let order = $0.0.title.localizedStandardCompare($1.0.title)
      return order == .orderedSame ? $0.0.id.uuidString < $1.0.id.uuidString : order == .orderedAscending
    }.map(\.0)
  }
}
