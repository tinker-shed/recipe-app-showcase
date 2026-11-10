import Foundation

/// Sidecars are optional. Suggestions are never treated as approved duplicate decisions.
struct CatalogueMetadata: Decodable {
  var cleanTitle: String?
  var categories: [String]?
  var tags: [String]?
  var ingredients: [String]?
  var cuisine: String?
  var mainIngredient: String?
  var isRecipe: Bool?
  var sourceFile: String?
  var likelyDuplicateOf: String?
  var duplicateStatus: String?
  var notes: String?
  var confidence: Double?

  var confirmedDuplicate: String? {
    guard let target = likelyDuplicateOf, !target.isEmpty else { return nil }
    let legacyApproval = (notes ?? "").contains("Catalogue review 2026-10-25: Confirmed duplicate of ")
      || (notes ?? "").contains("Catalogue review 2026-10-25: Confirmed identical duplicate of ")
    return duplicateStatus == "confirmed" || legacyApproval ? target : nil
  }

  static func displayLabel(for file: URL, allowedRoot: URL) throws -> String {
    let identifier = file.deletingLastPathComponent().lastPathComponent
    let root = allowedRoot.resolvingSymlinksInPath().standardizedFileURL
    var directory = file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
    while directory == root || directory.path.hasPrefix(root.path + "/") {
      let mapping = directory.appendingPathComponent("notebook-labels.json")
      if FileManager.default.fileExists(atPath: mapping.path) {
        guard mapping.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
          throw CatalogueError.invalid("Notebook labels are outside the import folder")
        }
        let labels = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: mapping))
        if let label = labels[identifier], !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          return label
        }
        return identifier
      }
      if directory == root { break }
      directory.deleteLastPathComponent()
    }
    // When a single notebook is selected, its parent's JSON may be outside the granted scope.
    // Preserve the two approved labels without reading outside that scope.
    return ["Deserts": "Desserts", "Vegaterian Recipes": "Vegetarian Recipes"][identifier] ?? identifier
  }

  static func load(for file: URL, allowedRoot: URL) throws -> CatalogueMetadata? {
    let sidecar = file.deletingPathExtension().appendingPathExtension("catalogue.json")
    guard FileManager.default.fileExists(atPath: sidecar.path) else { return nil }
    let root = allowedRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
    guard sidecar.resolvingSymlinksInPath().path.hasPrefix(root) else {
      throw CatalogueError.invalid("Sidecar is outside the import folder")
    }
    let data = try JSONDecoder().decode(Self.self, from: Data(contentsOf: sidecar))
    if let confidence = data.confidence, !confidence.isFinite || !(0...1).contains(confidence) {
      throw CatalogueError.invalid("Catalogue confidence must be between zero and one")
    }
    if let source = data.sourceFile {
      guard !source.hasPrefix("/"), !source.split(separator: "/").contains(".."),
        file.standardizedFileURL.path.hasSuffix("/" + source) else {
        throw CatalogueError.invalid("Sidecar sourceFile does not match the note")
      }
    }
    return data
  }

  /// A missing, cyclic or out-of-folder keeper must not silently discard a recipe.
  func keeper(for file: URL, allowedRoot: URL) throws -> URL? {
    guard let target = confirmedDuplicate else { return nil }
    guard let source = sourceFile, !target.hasPrefix("/"),
      !target.contains("://"), !target.split(separator: "/").contains(".."),
      target.lowercased().hasSuffix(".md") else {
      throw CatalogueError.invalid("Invalid confirmed duplicate target")
    }
    var base = file.standardizedFileURL
    for _ in source.split(separator: "/") { base.deleteLastPathComponent() }
    let keeper = base.appendingPathComponent(target).resolvingSymlinksInPath().standardizedFileURL
    let root = allowedRoot.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    guard keeper.path.hasPrefix(root), keeper != file.resolvingSymlinksInPath().standardizedFileURL,
      (try? keeper.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
      throw CatalogueError.invalid("Confirmed duplicate keeper is missing or outside the import folder")
    }
    if try Self.load(for: keeper, allowedRoot: allowedRoot)?.confirmedDuplicate != nil {
      throw CatalogueError.invalid("Confirmed duplicate chain or cycle needs review")
    }
    return keeper
  }
}

enum CatalogueError: LocalizedError {
  case invalid(String)
  var errorDescription: String? {
    switch self { case .invalid(let message): return message }
  }
}
