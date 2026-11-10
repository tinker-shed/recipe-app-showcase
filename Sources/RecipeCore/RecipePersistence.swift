import CoreData
import CryptoKit
import UniformTypeIdentifiers

/// All functions here run on the owning Core Data context's queue.
enum RecipePersistence {
  static func object(id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
    let request = NSFetchRequest<NSManagedObject>(entityName: "Recipe")
    request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
    request.fetchLimit = 1
    return try context.fetch(request).first
  }

  static func read(_ object: NSManagedObject) throws -> Recipe {
    guard let id = object.value(forKey: "id") as? UUID,
      let title = object.value(forKey: "title") as? String,
      let notebook = object.value(forKey: "notebook") as? String,
      let markdown = object.value(forKey: "markdown") as? String,
      let blocks = object.value(forKey: "blocksData") as? Data,
      let warnings = object.value(forKey: "warningsData") as? Data,
      let fingerprint = object.value(forKey: "fingerprint") as? String,
      let importedAt = object.value(forKey: "importedAt") as? Date
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let assets = (object.value(forKey: "assets") as? Set<NSManagedObject> ?? []).sorted {
      ($0.value(forKey: "position") as? Int64 ?? 0) < ($1.value(forKey: "position") as? Int64 ?? 0)
    }
    let paths = try assets.map { asset -> String in
      guard let path = asset.value(forKey: "relativePath") as? String else {
        throw CocoaError(.fileReadCorruptFile)
      }
      return path
    }
    return Recipe(
      id: id,
      title: title,
      collection: notebook,
      sourceURL: object.value(forKey: "sourceURL") as? String,
      markdown: markdown,
      blocks: try JSONDecoder().decode([RecipeBlock].self, from: blocks),
      assetPaths: paths,
      warnings: try JSONDecoder().decode([String].self, from: warnings),
      fingerprint: fingerprint,
      importedAt: importedAt,
      deletedAt: object.value(forKey: "deletedAt") as? Date,
      favourite: object.value(forKey: "isFavourite") as? Bool ?? false,
      favouriteChangedAt: object.value(forKey: "favouriteChangedAt") as? Date,
      createdText: object.value(forKey: "createdText") as? String,
      updatedText: object.value(forKey: "updatedText") as? String,
      thumbnailPath: object.value(forKey: "thumbnailPath") as? String,
      sourceFile: object.value(forKey: "sourceFile") as? String,
      setId: object.value(forKey: "setId") as? UUID,
      setRelativePath: object.value(forKey: "setRelativePath") as? String,
      origin: object.value(forKey: "origin") as? String,
      parentRecipeID: object.value(forKey: "parentRecipeID") as? UUID,
      isRecipe: object.value(forKey: "isRecipe") as? Bool,
      personalNotes: object.value(forKey: "personalNotes") as? String,
      viewCount: (object.value(forKey: "viewCount") as? Int ?? 0) == 0 ? nil : object.value(forKey: "viewCount") as? Int,
      lastViewedAt: object.value(forKey: "lastViewedAt") as? Date,
      cookHistory: history(object),
      categories: names(object, "categories", key: "id"),
      tags: names(object, "tags"), ingredients: names(object, "ingredients"),
      cuisine: object.value(forKey: "cuisine") as? String,
      mainIngredient: object.value(forKey: "mainIngredient") as? String,
      catalogueConfidence: object.value(forKey: "catalogueConfidence") as? Double,
      reviewedAt: object.value(forKey: "reviewedAt") as? Date
    )
  }

  static func write(_ recipe: Recipe, in context: NSManagedObjectContext, assetsDirectory: URL, vocabulary: RecipeVocabularyCache? = nil)
    throws
  {
    let existing = try object(id: recipe.id, in: context)
    let object =
      existing ?? NSEntityDescription.insertNewObject(forEntityName: "Recipe", into: context)
    if existing == nil {
      object.setValue(recipe.id, forKey: "id")
      object.setValue(recipe.viewCount ?? 0, forKey: "viewCount")
      object.setValue(recipe.lastViewedAt, forKey: "lastViewedAt")
      object.setValue(recipe.collection, forKey: "notebook")
      object.setValue(recipe.collection, forKey: "category")
      object.setValue(recipe.markdown, forKey: "markdown")
      object.setValue(recipe.fingerprint, forKey: "fingerprint")
      object.setValue(recipe.contentFingerprint, forKey: "contentFingerprint")
      object.setValue(recipe.sourceFile, forKey: "sourceFile")
      object.setValue(recipe.setId, forKey: "setId")
      object.setValue(recipe.setRelativePath, forKey: "setRelativePath")
      object.setValue(recipe.importedAt, forKey: "importedAt")
    }
    if let categories = recipe.categories { try setNames(categories, relationship: "categories", entity: "Category", key: "id", object: object, context: context, vocabulary: vocabulary) }
    if let tags = recipe.tags { try setNames(tags.map(CatalogueVocabulary.tag), relationship: "tags", entity: "Tag", object: object, context: context, vocabulary: vocabulary) }
    if let ingredients = recipe.ingredients { try setNames(ingredients, relationship: "ingredients", entity: "Ingredient", object: object, context: context, vocabulary: vocabulary) }
    object.setValue(recipe.origin, forKey: "origin")
    object.setValue(recipe.parentRecipeID, forKey: "parentRecipeID")
    object.setValue(recipe.isRecipe, forKey: "isRecipe")
    object.setValue(recipe.personalNotes, forKey: "personalNotes")
    object.setValue(recipe.cuisine, forKey: "cuisine")
    object.setValue(recipe.mainIngredient, forKey: "mainIngredient")
    object.setValue(recipe.catalogueConfidence, forKey: "catalogueConfidence")
    object.setValue(recipe.reviewedAt, forKey: "reviewedAt")
    object.setValue(recipe.title, forKey: "title")
    object.setValue(recipe.sourceURL, forKey: "sourceURL")
    object.setValue(try JSONEncoder().encode(recipe.blocks), forKey: "blocksData")
    object.setValue(try JSONEncoder().encode(recipe.warnings), forKey: "warningsData")
    object.setValue(recipe.createdText, forKey: "createdText")
    object.setValue(recipe.updatedText, forKey: "updatedText")
    object.setValue(recipe.deletedAt, forKey: "deletedAt")
    object.setValue(recipe.favourite, forKey: "isFavourite")
    object.setValue(recipe.favouriteChangedAt, forKey: "favouriteChangedAt")
    object.setValue(
      normaliseText(
        recipe.title + " " + (recipe.personalNotes ?? "") + " "
          + recipe.blocks.filter { $0.kind != .image && $0.kind != .missingImage }.map(\.text)
          .joined(separator: " ")), forKey: "searchText")
    object.setValue(recipe.heroImagePath, forKey: "heroAssetPath")
    if existing != nil, object.changedValues().keys.contains("heroAssetPath") {
      object.setValue(nil, forKey: "thumbnailPath")
    }
    if object.value(forKey: "thumbnailPath") == nil {
      object.setValue(
        RecipeImages.makeThumbnail(
          heroPath: recipe.heroImagePath, assetsDirectory: assetsDirectory),
        forKey: "thumbnailPath")
    }
    // Preserve catalogue fields, relationships and activity history on normal content saves.
    try updateAssets(
      recipe.assetPaths, recipe: object, context: context, directory: assetsDirectory)
  }

  private static func history(_ object: NSManagedObject) -> [CookEntry]? {
    let events = (object.value(forKey: "cookEvents") as? Set<NSManagedObject> ?? []).compactMap { event -> CookEntry? in
      guard let id = event.value(forKey: "id") as? UUID, let date = event.value(forKey: "date") as? Date,
        event.value(forKey: "deletedAt") == nil else { return nil }
      var entry = CookEntry(id: id, date: date, note: event.value(forKey: "note") as? String)
      entry.finishedAt = event.value(forKey: "finishedAt") as? Date
      entry.ingredientWeightGrams = event.value(forKey: "ingredientWeightGrams") as? Double
      entry.saltGrams = event.value(forKey: "saltGrams") as? Double
      entry.saltPercent = event.value(forKey: "saltPercent") as? Double
      entry.pH = event.value(forKey: "pH") as? Double
      entry.rating = event.value(forKey: "rating") as? Int
      if let data = event.value(forKey: "photoPathsData") as? Data { entry.photoPaths = try? JSONDecoder().decode([String].self, from: data) }
      return entry
    }.sorted { $0.date > $1.date }
    return events.isEmpty ? nil : events
  }
  private static func names(_ object: NSManagedObject, _ relationship: String, key: String = "name") -> [String]? {
    let values = (object.value(forKey: relationship) as? Set<NSManagedObject> ?? []).compactMap { $0.value(forKey: key) as? String }.sorted()
    return values.isEmpty ? nil : values
  }
  private static func setNames(_ names: [String], relationship: String, entity: String, key: String = "name", object: NSManagedObject, context: NSManagedObjectContext, vocabulary: RecipeVocabularyCache?) throws {
    var records = Set<NSManagedObject>()
    for name in Set(names).filter({ !$0.isEmpty }) {
      let record: NSManagedObject
      if let vocabulary {
        record = try vocabulary.record(entity: entity, key: key, name: name, context: context)
      } else {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "%K == %@", key, name)
        record = try context.fetch(request).first ?? NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
      }
      record.setValue(name, forKey: key)
      if entity == "Category", let category = CatalogueVocabulary.all.first(where: { $0.id == name }) {
        record.setValue(category.name, forKey: "name")
        record.setValue(category.section, forKey: "section")
        record.setValue(category.parentId, forKey: "parentId")
      }
      records.insert(record)
    }
    object.setValue(records, forKey: relationship)
  }

  static func normaliseText(_ text: String) -> String {
    let unlinked = text.replacingOccurrences(
      of: #"\[([^\]]+)\]\([^\n]*?\)"#, with: "$1", options: .regularExpression)
    let plain = unlinked.replacingOccurrences(
      of: #"[*_`#>]"#, with: "", options: .regularExpression)
    return plain.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_GB")
    )
    .components(separatedBy: .whitespacesAndNewlines)
    .filter { !$0.isEmpty }
    .joined(separator: " ")
  }

  private static func mediaType(for extensionName: String) -> String {
    // Known formats must not depend on Launch Services being available (for example in tests).
    let known = [
      "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
      "pdf": "application/pdf", "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml",
      "heic": "image/heic", "heif": "image/heif", "tif": "image/tiff", "tiff": "image/tiff",
    ]
    return known[extensionName.lowercased()]
      ?? UTType(filenameExtension: extensionName)?.preferredMIMEType
      ?? "application/octet-stream"
  }

  private static func updateAssets(
    _ paths: [String], recipe: NSManagedObject, context: NSManagedObjectContext, directory: URL
  ) throws {
    let existing = recipe.value(forKey: "assets") as? Set<NSManagedObject> ?? []
    var available = Array(existing)
    for (position, path) in paths.enumerated() {
      let asset: NSManagedObject
      if let index = available.firstIndex(where: {
        $0.value(forKey: "relativePath") as? String == path
      }) {
        asset = available.remove(at: index)
      } else {
        asset = NSEntityDescription.insertNewObject(forEntityName: "Asset", into: context)
        asset.setValue(UUID(), forKey: "id")
        asset.setValue(path, forKey: "relativePath")
        asset.setValue(recipe, forKey: "recipe")
        let url = directory.appendingPathComponent(path).standardizedFileURL
          .resolvingSymlinksInPath()
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(root) else { throw CocoaError(.fileReadInvalidFileName) }
        let mediaType = mediaType(for: url.pathExtension)
        asset.setValue(mediaType, forKey: "mediaType")
        // Missing legacy files stay represented; do not invent a checksum or fail the whole migration.
        let checksum: String
        if FileManager.default.fileExists(atPath: url.path) {
          checksum = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map {
            String(format: "%02x", $0)
          }.joined()
        } else {
          checksum = ""
        }
        asset.setValue(checksum, forKey: "checksum")
      }
      asset.setValue(Int64(position), forKey: "position")
    }
    for asset in available {
      context.delete(asset)
    }
  }
}
