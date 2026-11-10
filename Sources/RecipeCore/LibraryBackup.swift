import Foundation

public struct LibraryBackupManifest: Codable {
  public var version: Int
  public var recipes: [Recipe]
  public var assets: [String: String]
}

public enum LibraryBackup {
  private static func safe(_ relative: String, root: URL) throws -> URL {
    guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."), !relative.isEmpty else { throw CocoaError(.fileReadInvalidFileName) }
    let url = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
    guard url.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else { throw CocoaError(.fileReadNoPermission) }
    return url
  }
  /// Publishes only a complete new directory, never overwrites an existing export.
  public static func export(_ store: LibraryStore, to destination: URL) throws {
    let fm = FileManager.default
    let destinationPath = destination.standardizedFileURL.resolvingSymlinksInPath().path
    let libraryPath = store.directory.standardizedFileURL.resolvingSymlinksInPath().path
    guard destinationPath != libraryPath, !destinationPath.hasPrefix(libraryPath + "/") else { throw CocoaError(.fileWriteInvalidFileName) }
    guard !fm.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
    let staging = destination.deletingLastPathComponent().appendingPathComponent(".export-" + UUID().uuidString)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }
    let recipes = try store.recipes(includeDeleted: true)
    let assets = staging.appendingPathComponent("Assets")
    try fm.createDirectory(at: assets, withIntermediateDirectories: true)
    var hashes: [String: String] = [:]
    // Compare resolved paths: the enumerator may report /private/var where the store says /var.
    let assetsRoot = store.assetsDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
    let enumerator = fm.enumerator(at: store.assetsDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    while let file = enumerator?.nextObject() as? URL {
      let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard properties.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
      guard properties.isRegularFile == true else { continue }
      let filePath = file.standardizedFileURL.resolvingSymlinksInPath().path
      guard filePath.hasPrefix(assetsRoot) else { throw CocoaError(.fileReadNoPermission) }
      let relative = String(filePath.dropFirst(assetsRoot.count))
      let output = try safe(relative, root: assets)
      try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
      let bytes = try Data(contentsOf: file)
      try bytes.write(to: output)
      hashes[relative] = MarkdownImporter.digest(bytes)
    }
    for recipe in recipes {
      for path in recipe.assetPaths + (recipe.cookHistory ?? []).flatMap({ $0.photoPaths ?? [] }) where hashes[path] == nil { throw BackupError.missing(path) }
      let kind = recipe.deletedAt != nil ? "Recently deleted" : recipe.isNote ? "Notes" : "Recipes"
      let folder = staging.appendingPathComponent(kind).appendingPathComponent(recipe.id.uuidString)
      try fm.createDirectory(at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
      var links: [String: String] = [:]
      for (index, path) in recipe.assetPaths.enumerated() {
        let source = try safe(path, root: assets)
        let name = "\(index)." + source.pathExtension
        try fm.copyItem(at: source, to: folder.appendingPathComponent("images/" + name))
        links[path] = "images/" + name
      }
      var lines = ["---", "Source URL: " + (recipe.sourceURL ?? "").replacingOccurrences(of: "\n", with: " "), "---", "# " + recipe.title]
      for block in recipe.blocks {
        if block.kind == .heading && block.text == recipe.title { continue }
        switch block.kind {
        case .originalImage: break // Reference images are exported together at the end.
        case .image, .pdf:
          if let path = block.assetPath, let link = links[path] {
            lines.append(block.kind == .image ? "![Photograph](\(link))" : "[View original PDF](\(link))")
          }
        case .heading: lines.append(String(repeating: "#", count: max(2, min(6, block.level))) + " " + block.text)
        case .bullet: lines.append("- " + block.text)
        case .step: lines.append("1. " + block.text)
        default: lines.append(block.text)
        }
      }
      if let notes = recipe.personalNotes, !notes.isEmpty { lines += ["## My notes", notes] }
      let originals = recipe.blocks.filter { $0.kind == .originalImage }
      if !originals.isEmpty {
        lines.append("## Original page")
        for block in originals {
          if let path = block.assetPath, let link = links[path] { lines.append("[View original](\(link))") }
        }
      }
      try lines.joined(separator: "\n\n").write(to: folder.appendingPathComponent("Recipe.md"), atomically: true, encoding: .utf8)
      // Exact provenance is archived as text so ordinary folder import won't duplicate it.
      try recipe.markdown.write(to: folder.appendingPathComponent("Original-Markdown.txt"), atomically: true, encoding: .utf8)
      let sidecar: [String: Any] = ["cleanTitle": recipe.title, "isRecipe": !recipe.isNote,
        "categories": recipe.categories ?? [], "ingredients": recipe.ingredients ?? [], "tags": recipe.tags ?? [],
        "confidence": recipe.catalogueConfidence as Any? ?? NSNull(), "cuisine": recipe.cuisine as Any? ?? NSNull(),
        "mainIngredient": recipe.mainIngredient as Any? ?? NSNull()]
      try JSONSerialization.data(withJSONObject: sidecar, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("Recipe.catalogue.json"))
      try JSONSerialization.data(withJSONObject: [recipe.id.uuidString: recipe.collection]).write(to: folder.appendingPathComponent("notebook-labels.json"))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(LibraryBackupManifest(version: 1, recipes: recipes, assets: hashes)).write(to: staging.appendingPathComponent("Library-Backup.json"))
    try "RecipeApp backup\nRecipes/ and Notes/ contain portable Markdown and attachments. Recently deleted/ is kept separately. Library-Backup.json plus Assets/ is the complete restorable library, including activity, original Markdown, edited blocks and removed photos. Keep the whole folder together. Original-Markdown.txt preserves source spelling; its old source paths are provenance, not portable links.\n".write(to: staging.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    try fm.moveItem(at: staging, to: destination)
  }

  /// Restore to a new library only. Validate hashes and paths before creating any store.
  public static func restore(from backup: URL, to destination: URL) throws {
    let fm = FileManager.default
    let destinationPath = destination.standardizedFileURL.resolvingSymlinksInPath().path
    let backupPath = backup.standardizedFileURL.resolvingSymlinksInPath().path
    guard destinationPath != backupPath, !destinationPath.hasPrefix(backupPath + "/") else { throw CocoaError(.fileWriteInvalidFileName) }
    guard !fm.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
    let manifest = try JSONDecoder().decode(LibraryBackupManifest.self, from: Data(contentsOf: safe("Library-Backup.json", root: backup)))
    guard manifest.version == 1, Set(manifest.recipes.map(\.id)).count == manifest.recipes.count else { throw CocoaError(.fileReadCorruptFile) }
    let inputAssets = try safe("Assets", root: backup)
    for (path, checksum) in manifest.assets {
      let data = try Data(contentsOf: safe(path, root: inputAssets))
      guard MarkdownImporter.digest(data) == checksum else { throw CocoaError(.fileReadCorruptFile) }
    }
    for recipe in manifest.recipes {
      for path in recipe.assetPaths + recipe.blocks.compactMap(\.assetPath) + (recipe.cookHistory ?? []).flatMap({ $0.photoPaths ?? [] }) {
        guard manifest.assets[path] != nil else { throw BackupError.missing(path) }
      }
    }
    let staging = destination.deletingLastPathComponent().appendingPathComponent(".restore-" + UUID().uuidString)
    try fm.createDirectory(at: staging.appendingPathComponent("Assets"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }
    for path in manifest.assets.keys {
      let output = try safe(path, root: staging.appendingPathComponent("Assets"))
      try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.copyItem(at: safe(path, root: inputAssets), to: output)
    }
    try autoreleasepool {
      let restored = try LibraryStore(directory: staging)
      for recipe in manifest.recipes {
        try restored.save(recipe)
        for event in recipe.cookHistory ?? [] { try restored.saveCookEntry(event, recipeID: recipe.id) }
      }
      guard try restored.recipes(includeDeleted: true).count == manifest.recipes.count else { throw CocoaError(.fileReadCorruptFile) }
    }
    try fm.moveItem(at: staging, to: destination)
  }
}
public enum BackupError: LocalizedError {
  case missing(String)
  public var errorDescription: String? {
    switch self { case .missing(let path): return "Backup cannot be completed: missing attachment \(path)" }
  }
}
