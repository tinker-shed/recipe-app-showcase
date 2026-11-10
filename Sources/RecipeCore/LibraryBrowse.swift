import Foundation

public enum LibrarySection: Hashable {
  case all, favourites, review, deleted, notes, own, batch
  case collection(String)
  public var title: String {
    switch self {
    case .all: return "All recipes"
    case .favourites: return "Favourites"
    case .review: return "Needs review"
    case .deleted: return "Recently deleted"
    case .notes: return "Notes"
    case .own: return "My recipes"
    case .batch: return "Batch log"
    case .collection(let name): return name
    }
  }
}

public struct CollectionCount: Identifiable, Equatable {
  public var id: String { name }
  public let name: String
  public let count: Int
}

public struct CategoryCount: Identifiable, Equatable {
  public let id: String
  public let name: String
  public let count: Int
}

public enum LibraryBrowse {
  public static func categories(_ recipes: [Recipe]) -> [CategoryCount] {
    let available = recipes.filter { $0.deletedAt == nil && !$0.isNote }
    return CatalogueVocabulary.all.compactMap { category in
      let count = available.filter { CatalogueVocabulary.hasCategory($0, category.id) }.count
      return count == 0 ? nil : CategoryCount(id: category.id, name: category.name, count: count)
    }
  }

  public static func collections(_ recipes: [Recipe]) -> [CollectionCount] {
    Dictionary(grouping: recipes.filter { $0.deletedAt == nil && !$0.isNote }, by: \.collection)
      .map { CollectionCount(name: $0.key, count: $0.value.count) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  public static func matches(_ recipe: Recipe, section: LibrarySection) -> Bool {
    if section == .deleted { return recipe.deletedAt != nil }
    guard recipe.deletedAt == nil else { return false }
    if section == .notes { return recipe.isNote }
    guard !recipe.isNote else { return false }
    switch section {
    case .own: return recipe.origin == "own"
    case .all: return true
    case .favourites: return recipe.favourite
    case .review: return recipe.needsReview
    case .collection(let name): return recipe.collection == name
    default: return false
    }
  }
}
