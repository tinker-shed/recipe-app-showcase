import Foundation

public struct Recipe: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var title: String
  public var collection: String
  public var sourceURL: String?
  public var markdown: String
  public var blocks: [RecipeBlock]
  public var assetPaths: [String]
  public var warnings: [String]
  public var fingerprint: String
  public var importedAt: Date
  public var deletedAt: Date? = nil
  public var favourite: Bool
  /// When the favourite flag was last changed, so two-device sync can break ties (later wins).
  public var favouriteChangedAt: Date? = nil
  public var createdText: String?
  public var updatedText: String?
  public var thumbnailPath: String? = nil
  public var sourceFile: String? = nil
  public var setId: UUID? = nil
  public var setRelativePath: String? = nil
  public var heroImagePath: String? {
    for block in blocks {
      // A photograph first appearing in the method illustrates a step, not the finished dish.
      if block.kind == .heading, block.level <= 2,
        ["method", "instruction", "direction"].contains(where: block.text.lowercased().hasPrefix) { return nil }
      if block.kind == .image && !RecipePresentation.isReference(block) { return block.assetPath }
    }
    return nil
  }
  public var origin: String? = nil
  public var parentRecipeID: UUID? = nil
  public var isRecipe: Bool? = nil
  public var personalNotes: String? = nil
  public var isNote: Bool { isRecipe == false || (isRecipe == nil && ["Useful Notes", "Ferment Log", "Notes"].contains(collection)) }
  public var viewCount: Int? = nil
  public var lastViewedAt: Date? = nil
  public var cookHistory: [CookEntry]? = nil
  public var cookCount: Int { cookHistory?.count ?? 0 }
  public var lastCookedAt: Date? { cookHistory?.map(\.date).max() }
  public var categories: [String]? = nil
  public var tags: [String]? = nil
  public var ingredients: [String]? = nil
  public var cuisine: String? = nil
  public var mainIngredient: String? = nil
  public var catalogueConfidence: Double? = nil
  /// Set when the user has checked a flagged recipe; once set, it no longer needs review.
  public var reviewedAt: Date? = nil
  public var needsReview: Bool {
    if reviewedAt != nil { return false }
    return (catalogueConfidence.map { $0 < 0.8 } ?? false)
      || markdown.localizedCaseInsensitiveContains("[check]")
      || blocks.contains { $0.text.localizedCaseInsensitiveContains("[check]") }
  }
  public var contentFingerprint: String { DuplicateDetection.fingerprint(markdown) }
}

public enum BlockKind: String, Codable, CaseIterable, Sendable {
  case heading
  case text
  case bullet
  case step
  case image
  case pdf
  case originalImage
  case missingAttachment
  case missingImage
}

public struct RecipeBlock: Codable, Identifiable, Equatable, Sendable {
  public var id: Int
  public var kind: BlockKind
  public var text: String
  public var level: Int
  public var assetPath: String?
  public init(id: Int, kind: BlockKind, text: String, level: Int = 0, assetPath: String? = nil) {
    self.id = id
    self.kind = kind
    self.text = text
    self.level = level
    self.assetPath = assetPath
  }
}

public struct ImportReport: Sendable {
  var vocabularyFetches = 0 // Regression instrumentation, not part of the displayed summary.
  public var imported = 0
  public var notesImported = 0
  public var failed = 0
  public var skipped = 0
  public var catalogueSkipped = 0
  public var changedSinceImport = 0
  public var issues: [String] = []
  public var fileCount = 0
  public var catalogueReview: [Recipe] = []
  public var likelyDuplicates: [LikelyDuplicate] = []
  public var hasPendingReview: Bool { !catalogueReview.isEmpty || !likelyDuplicates.isEmpty }
  public var summary: String {
    "\(imported) imported · \(skipped) skipped · \(likelyDuplicates.count + catalogueReview.count) awaiting review · \(fileCount) files checked · \(notesImported) notes · \(failed) failed" + (changedSinceImport > 0 ? " · \(changedSinceImport) changed since import" : "")
  }
  public init() {}
}

public struct LikelyDuplicate: Identifiable, Sendable {
  public var id: UUID { recipe.id }
  public let recipe: Recipe
  public let matchingTitle: String
  public let reason: String
}

public struct CookEntry: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var date: Date
  public var note: String?
  /// Tombstone for sync: a removed entry is kept with this set so the deletion propagates to the other device.
  public var deletedAt: Date? = nil
  public var finishedAt: Date? = nil
  public var ingredientWeightGrams: Double? = nil
  public var saltGrams: Double? = nil
  public var saltPercent: Double? = nil
  public var pH: Double? = nil
  public var rating: Int? = nil
  public var photoPaths: [String]? = nil
  public var effectiveSaltPercent: Double? {
    if let saltPercent { return saltPercent }
    guard let weight = ingredientWeightGrams, weight > 0, let salt = saltGrams else { return nil }
    return (salt / weight * 1000).rounded() / 10
  }
  public func validate() throws {
    let values = [ingredientWeightGrams, saltGrams, saltPercent, pH].compactMap { $0 }
    guard values.allSatisfy({ $0.isFinite && $0 >= 0 }),
      pH.map({ $0 <= 14 }) ?? true, saltPercent.map({ $0 <= 100 }) ?? true,
      rating.map({ (1...5).contains($0) }) ?? true,
      finishedAt.map({ $0 >= date }) ?? true else { throw CocoaError(.validationNumberTooLarge) }
  }
  public init(id: UUID = UUID(), date: Date = Date(), note: String? = nil) {
    self.id = id
    self.date = date
    self.note = note
  }
}
public enum RecipeSort: String, CaseIterable {
  case title = "Title", mostCooked = "Most cooked", recentlyCooked = "Recently cooked", mostViewed = "Most viewed", neverCooked = "Never cooked"
  public func apply(_ recipes: [Recipe]) -> [Recipe] {
    let candidates = self == .neverCooked ? recipes.filter { $0.cookCount == 0 } : recipes
    return candidates.sorted {
      switch self {
      case .mostCooked: if $0.cookCount != $1.cookCount { return $0.cookCount > $1.cookCount }
      case .recentlyCooked: if $0.lastCookedAt != $1.lastCookedAt { return ($0.lastCookedAt ?? .distantPast) > ($1.lastCookedAt ?? .distantPast) }
      case .mostViewed: if ($0.viewCount ?? 0) != ($1.viewCount ?? 0) { return ($0.viewCount ?? 0) > ($1.viewCount ?? 0) }
      default: break
      }
      let order = $0.title.localizedStandardCompare($1.title)
      return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
    }
  }
}
