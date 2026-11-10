import CoreData
import Foundation

// Thread-safe: all access goes through the serial Core Data context queue (context.performAndWait).
public final class LibraryStore: @unchecked Sendable {
  public let directory: URL
  public var assetsDirectory: URL { directory.appendingPathComponent("Assets", isDirectory: true) }
  private var recordedOpenings = Set<UUID>()
  private let context: NSManagedObjectContext
  private let coordinator: NSPersistentStoreCoordinator
  public init(directory: URL) throws {
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("Assets"), withIntermediateDirectories: true)
    let storeURL = try LibraryMigration.storeURL(in: directory)
    coordinator = NSPersistentStoreCoordinator(managedObjectModel: LibraryModel.current())
    try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL)
    context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    try context.performAndWait {
      // Only the cheap fingerprint backfill runs at open. Thumbnail generation is
      // heavy for a large library (it decodes every hero), so it is no longer done
      // here - it froze launch after a big sync. Callers run backfillThumbnails()
      // off the main thread instead.
      let missing = NSFetchRequest<NSManagedObject>(entityName: "Recipe")
      missing.predicate = NSPredicate(format: "contentFingerprint == nil")
      for object in try context.fetch(missing) {
        object.setValue(
          DuplicateDetection.fingerprint(object.value(forKey: "markdown") as? String ?? ""),
          forKey: "contentFingerprint")
      }
      if context.hasChanges { try context.save() }
    }
    // Best-effort housekeeping must never prevent a library from opening.
    _ = try? removeOldOrphanAssets()
  }

  /// Generate thumbnails for recipes that have a hero photo but no thumbnail yet.
  /// Decodes each hero, so it is heavy for a large library; run it off the main
  /// thread. Safe to call repeatedly: it only touches recipes still missing one.
  public func backfillThumbnails() throws {
    try context.performAndWait {
      let request = NSFetchRequest<NSManagedObject>(entityName: "Recipe")
      request.predicate = NSPredicate(format: "thumbnailPath == nil AND heroAssetPath != nil")
      for object in try context.fetch(request) {
        object.setValue(
          RecipeImages.makeThumbnail(
            heroPath: object.value(forKey: "heroAssetPath") as? String,
            assetsDirectory: assetsDirectory), forKey: "thumbnailPath")
      }
      if context.hasChanges { try context.save() }
    }
  }

  /// Protect recipe IDs, shared assets, thumbnails and cook photographs, including deleted recipes.
  @discardableResult
  func removeOldOrphanAssets(now: Date = Date()) throws -> [String] {
    try context.performAndWait {
      let fm = FileManager.default
      let assets = assetsDirectory.standardizedFileURL
      guard assets.resolvingSymlinksInPath() == assets else { return [] }
      var protected = Set<String>()
      func protect(_ path: String?) {
        if let first = path?.split(separator: "/").first { protected.insert(String(first)) }
      }
      let recipes = NSFetchRequest<NSDictionary>(entityName: "Recipe")
      recipes.resultType = .dictionaryResultType
      recipes.propertiesToFetch = ["id", "heroAssetPath", "thumbnailPath"]
      for row in try context.fetch(recipes) {
        if let id = row["id"] as? UUID { protected.insert(id.uuidString) }
        protect(row["heroAssetPath"] as? String); protect(row["thumbnailPath"] as? String)
      }
      let paths = NSFetchRequest<NSDictionary>(entityName: "Asset")
      paths.resultType = .dictionaryResultType; paths.propertiesToFetch = ["relativePath"]
      for row in try context.fetch(paths) { protect(row["relativePath"] as? String) }
      let events = NSFetchRequest<NSDictionary>(entityName: "CookEvent")
      events.resultType = .dictionaryResultType; events.propertiesToFetch = ["photoPathsData"]
      for row in try context.fetch(events) {
        if let data = row["photoPathsData"] as? Data {
          for path in try JSONDecoder().decode([String].self, from: data) { protect(path) }
        }
      }
      let cutoff = now.addingTimeInterval(-86400)
      let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
      var removed: [String] = []
      for folder in try fm.contentsOfDirectory(at: assets, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
        guard UUID(uuidString: folder.lastPathComponent) != nil, !protected.contains(folder.lastPathComponent) else { continue }
        let values = try folder.resourceValues(forKeys: keys)
        guard values.isDirectory == true, values.isSymbolicLink != true,
          let modified = values.contentModificationDate, modified < cutoff else { continue }
        // Editing a contained file need not change the directory's date. Retain recent or uncertain contents.
        var old = true
        let children = fm.enumerator(at: folder, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in old = false; return false })
        while let child = children?.nextObject() as? URL {
          let childValues = try child.resourceValues(forKeys: keys)
          if childValues.isSymbolicLink == true || childValues.contentModificationDate.map({ $0 >= cutoff }) ?? true { old = false; break }
        }
        guard old else { continue }
        try fm.removeItem(at: folder)
        removed.append(folder.lastPathComponent)
      }
      return removed
    }
  }

  public func recipes(includeDeleted: Bool = false) throws -> [Recipe] {
    try context.performAndWait {
      let request = NSFetchRequest<NSManagedObject>(entityName: "Recipe")
      if !includeDeleted {
        request.predicate = NSPredicate(format: "deletedAt == nil")
      }
      request.sortDescriptors = [
        NSSortDescriptor(
          key: "title", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
      ]
      request.relationshipKeyPathsForPrefetching = ["assets"]
      return try context.fetch(request).map(RecipePersistence.read)
    }
  }

  public func recipe(id: UUID) throws -> Recipe? {
    try context.performAndWait {
      guard let object = try RecipePersistence.object(id: id, in: context) else { return nil }
      return try RecipePersistence.read(object)
    }
  }

  public func save(_ recipe: Recipe) throws { try save(recipe, vocabulary: nil) }

  private func save(_ recipe: Recipe, vocabulary: RecipeVocabularyCache?) throws {
    try context.performAndWait {
      do {
        try RecipePersistence.write(recipe, in: context, assetsDirectory: assetsDirectory, vocabulary: vocabulary)
        try context.save()
      } catch {
        context.rollback()
        vocabulary?.invalidateAfterRollback()
        throw error
      }
    }
  }

  public func setFavourite(_ id: UUID, favourite: Bool) throws {
    try context.performAndWait {
      do {
        guard let object = try RecipePersistence.object(id: id, in: context) else { return }
        object.setValue(favourite, forKey: "isFavourite")
        object.setValue(Date(), forKey: "favouriteChangedAt")
        try context.save()
      } catch { context.rollback(); throw error }
    }
  }

  /// A view lifecycle token prevents SwiftUI redraws from counting as new openings.
  public func recordView(_ id: UUID, opening: UUID, at date: Date = Date()) throws {
    try context.performAndWait {
      guard !recordedOpenings.contains(opening), let object = try RecipePersistence.object(id: id, in: context), object.value(forKey: "deletedAt") == nil else { return }
      do {
        object.setValue((object.value(forKey: "viewCount") as? Int64 ?? 0) + 1, forKey: "viewCount")
        object.setValue(date, forKey: "lastViewedAt")
        try context.save()
        recordedOpenings.insert(opening)
      } catch { context.rollback(); throw error }
    }
  }
  public func recordCooked(_ recipeID: UUID, on date: Date = Date()) throws {
    try saveCookEntry(CookEntry(date: date), recipeID: recipeID)
  }

  public func saveCookEntry(_ draft: CookEntry, recipeID: UUID, newImages: [String: Data] = [:]) throws {
    try draft.validate()
    var entry = draft
    var written: [URL] = []
    do {
      entry.photoPaths = try draft.photoPaths?.map { path in
        if path.hasPrefix("staged:") {
          guard let bytes = newImages[path] else { throw CocoaError(.fileReadNoSuchFile) }
          let ext = try RecipeImages.fileExtension(for: bytes)
          let relative = recipeID.uuidString + "/" + UUID().uuidString + "." + ext
          let url = assetsDirectory.appendingPathComponent(relative)
          try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
          try bytes.write(to: url, options: .atomic)
          written.append(url)
          return relative
        }
        guard RecipeAttachments.url(for: RecipeBlock(id: 0, kind: .image, text: "", assetPath: path), assetsDirectory: assetsDirectory) != nil else { throw CocoaError(.fileReadNoSuchFile) }
        return path
      }
      try persistCookEntry(entry, recipeID: recipeID)
    } catch {
      for url in written { try? FileManager.default.removeItem(at: url) }
      throw error
    }
  }
  private func persistCookEntry(_ entry: CookEntry, recipeID: UUID) throws {
    try context.performAndWait {
      do {
        guard let recipe = try RecipePersistence.object(id: recipeID, in: context) else { throw CocoaError(.fileNoSuchFile) }
        let request = NSFetchRequest<NSManagedObject>(entityName: "CookEvent")
        request.predicate = NSPredicate(format: "id == %@", entry.id as NSUUID)
        let event = try context.fetch(request).first ?? NSEntityDescription.insertNewObject(forEntityName: "CookEvent", into: context)
        if let owner = event.value(forKey: "recipe") as? NSManagedObject, owner != recipe { throw CocoaError(.validationRelationshipDeniedDelete) }
        event.setValue(entry.id, forKey: "id")
        event.setValue(entry.date, forKey: "date")
        event.setValue(entry.note, forKey: "note")
        event.setValue(entry.deletedAt, forKey: "deletedAt")
        event.setValue(entry.finishedAt, forKey: "finishedAt")
        event.setValue(entry.ingredientWeightGrams, forKey: "ingredientWeightGrams")
        event.setValue(entry.saltGrams, forKey: "saltGrams")
        event.setValue(entry.saltPercent, forKey: "saltPercent")
        event.setValue(entry.pH, forKey: "pH")
        event.setValue(entry.rating, forKey: "rating")
        event.setValue(try entry.photoPaths.map { try JSONEncoder().encode($0) }, forKey: "photoPathsData")
        event.setValue(recipe, forKey: "recipe")
        try context.save()
      } catch { context.rollback(); throw error }
    }
  }
  /// Soft-deletes the entry (a tombstone), so the deletion can propagate to the other device on sync.
  public func deleteCookEntry(_ id: UUID) throws {
    try context.performAndWait {
      do {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CookEvent")
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        for event in try context.fetch(request) { event.setValue(Date(), forKey: "deletedAt") }
        try context.save()
      } catch { context.rollback(); throw error }
    }
  }

  /// Permanently removes a record. Used to discard a brand-new item the user cancelled before saving.
  public func discardRecipe(_ id: UUID) throws {
    try context.performAndWait {
      do {
        if let object = try RecipePersistence.object(id: id, in: context) { context.delete(object) }
        try context.save()
      } catch { context.rollback(); throw error }
    }
  }

  // MARK: - Sync support

  /// Cook entries for a recipe, optionally including soft-deleted tombstones (needed for sync).
  public func cookEntries(_ recipeID: UUID, includingDeleted: Bool) throws -> [CookEntry] {
    try context.performAndWait {
      let request = NSFetchRequest<NSManagedObject>(entityName: "CookEvent")
      request.predicate = NSPredicate(format: "recipe.id == %@", recipeID as NSUUID)
      return try context.fetch(request).compactMap { event -> CookEntry? in
        guard let id = event.value(forKey: "id") as? UUID, let date = event.value(forKey: "date") as? Date else { return nil }
        if !includingDeleted, event.value(forKey: "deletedAt") != nil { return nil }
        var entry = CookEntry(id: id, date: date, note: event.value(forKey: "note") as? String)
        entry.deletedAt = event.value(forKey: "deletedAt") as? Date
        entry.finishedAt = event.value(forKey: "finishedAt") as? Date
        entry.ingredientWeightGrams = event.value(forKey: "ingredientWeightGrams") as? Double
        entry.saltGrams = event.value(forKey: "saltGrams") as? Double
        entry.saltPercent = event.value(forKey: "saltPercent") as? Double
        entry.pH = event.value(forKey: "pH") as? Double
        entry.rating = event.value(forKey: "rating") as? Int
        if let data = event.value(forKey: "photoPathsData") as? Data { entry.photoPaths = try? JSONDecoder().decode([String].self, from: data) }
        return entry
      }
    }
  }

  /// This device's current recipes with their full cook logs (tombstones included), for merging.
  public func localStates() throws -> [RecipeLocalState] {
    try recipes().map { RecipeLocalState(recipe: $0, cookEntries: try cookEntries($0.id, includingDeleted: true)) }
  }

  /// Build the snapshot this device sends to the other. The Mac includes recipe content; both include activity.
  public func buildSnapshot(isMac: Bool, syncState: SyncState) throws -> SyncSnapshot {
    let states = try localStates()
    let activity = states.map { state in
      RecipeActivity(
        recipeID: state.recipe.id, favourite: state.recipe.favourite,
        favouriteChangedAt: state.recipe.favouriteChangedAt, cookEntries: state.cookEntries,
        viewDelta: max(0, (state.recipe.viewCount ?? 0) - syncState.reportedViews(state.recipe.id)))
    }
    return SyncSnapshot(recipes: isMac ? states.map(\.recipe) : [], activity: activity)
  }

  /// Apply a merge plan to this device and update the sync state (reported view counts, last sync time).
  public func apply(_ plan: MergePlan, syncState: inout SyncState) throws {
    for recipe in plan.upsertRecipes { try save(recipe) }
    for id in plan.removeRecipeIDs { try discardRecipe(id) }
    for resolved in plan.resolvedActivity {
      try applyFavourite(resolved.recipeID, favourite: resolved.favourite, changedAt: resolved.favouriteChangedAt)
      try updateAttribute(resolved.recipeID, key: "viewCount", value: Int64(resolved.viewCount))
      for entry in resolved.cookEntries { try upsertCookEntry(entry, recipeID: resolved.recipeID) }
      syncState.setReportedViews(resolved.recipeID, resolved.viewCount)
    }
    syncState.lastSyncAt = Date()
  }

  /// Sets favourite and its change time directly, without re-stamping (used when applying a merge).
  public func applyFavourite(_ id: UUID, favourite: Bool, changedAt: Date?) throws {
    try context.performAndWait {
      do {
        guard let object = try RecipePersistence.object(id: id, in: context) else { return }
        object.setValue(favourite, forKey: "isFavourite")
        object.setValue(changedAt, forKey: "favouriteChangedAt")
        try context.save()
      } catch { context.rollback(); throw error }
    }
  }

  /// Writes a cook entry by id (including its tombstone), without the photo-staging validation, for sync apply.
  private func upsertCookEntry(_ entry: CookEntry, recipeID: UUID) throws {
    try context.performAndWait {
      do {
        guard let recipe = try RecipePersistence.object(id: recipeID, in: context) else { return }
        let request = NSFetchRequest<NSManagedObject>(entityName: "CookEvent")
        request.predicate = NSPredicate(format: "id == %@", entry.id as NSUUID)
        let event = try context.fetch(request).first ?? NSEntityDescription.insertNewObject(forEntityName: "CookEvent", into: context)
        event.setValue(entry.id, forKey: "id")
        event.setValue(entry.date, forKey: "date")
        event.setValue(entry.note, forKey: "note")
        event.setValue(entry.deletedAt, forKey: "deletedAt")
        event.setValue(entry.finishedAt, forKey: "finishedAt")
        event.setValue(entry.ingredientWeightGrams, forKey: "ingredientWeightGrams")
        event.setValue(entry.saltGrams, forKey: "saltGrams")
        event.setValue(entry.saltPercent, forKey: "saltPercent")
        event.setValue(entry.pH, forKey: "pH")
        event.setValue(entry.rating, forKey: "rating")
        event.setValue(try entry.photoPaths.map { try JSONEncoder().encode($0) }, forKey: "photoPathsData")
        event.setValue(recipe, forKey: "recipe")
        try context.save()
      } catch { context.rollback(); throw error }
    }
  }

  private func updateAttribute(_ id: UUID, key: String, value: Any?) throws {
    try context.performAndWait {
      do {
        guard let object = try RecipePersistence.object(id: id, in: context) else { return }
        object.setValue(value, forKey: key)
        try context.save()
      } catch {
        context.rollback()
        throw error
      }
    }
  }

  private func fingerprints() throws -> Set<String> {
    try context.performAndWait {
      let request = NSFetchRequest<NSDictionary>(entityName: "Recipe")
      request.resultType = .dictionaryResultType
      request.propertiesToFetch = ["fingerprint"]
      return Set(try context.fetch(request).compactMap { $0["fingerprint"] as? String })
    }
  }
  private func duplicateIndex() throws -> DuplicateIndex {
    try context.performAndWait {
      let request = NSFetchRequest<NSDictionary>(entityName: "Recipe")
      request.resultType = .dictionaryResultType
      request.propertiesToFetch = ["contentFingerprint", "sourceFile", "title"]
      var index = DuplicateIndex()
      for row in try context.fetch(request) {
        guard let fingerprint = row["contentFingerprint"] as? String,
          let title = row["title"] as? String
        else { continue }
        index.insert(
          DuplicateRecord(
            fingerprint: fingerprint, sourceFile: row["sourceFile"] as? String, title: title))
      }
      return index
    }
  }

  /// Pending copies are already self-contained, but are not recipes until explicitly accepted.
  /// Returns false when declined or when another import has already saved the exact copy.
  public func resolveDuplicate(_ candidate: LikelyDuplicate, importCopy: Bool) throws -> Bool {
    guard try recipe(id: candidate.id) == nil else { return false }
    if importCopy, try !fingerprints().contains(candidate.recipe.fingerprint) {
      try save(candidate.recipe)
      return true
    }
    let folder = assetsDirectory.appendingPathComponent(candidate.id.uuidString)
    if FileManager.default.fileExists(atPath: folder.path) {
      try FileManager.default.removeItem(at: folder)
    }
    return false
  }

  public func resolveCatalogue(_ recipe: Recipe, accept: Bool) throws -> Bool {
    guard !accept || !recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
    let candidate = LikelyDuplicate(recipe: recipe, matchingTitle: "", reason: "Catalogue review")
    return try resolveDuplicate(candidate, importCopy: accept)
  }

  public func createOwn(title: String, note: Bool = false, copying source: Recipe? = nil) throws -> Recipe {
    let id = UUID()
    var recipe = Recipe(id: id, title: title, collection: note ? "My notes" : "My recipes", sourceURL: source?.sourceURL,
      markdown: source?.markdown ?? "", blocks: source?.blocks ?? [RecipeBlock(id: 0, kind: .text, text: "")],
      assetPaths: source?.assetPaths ?? [], warnings: source?.warnings ?? [], fingerprint: "own:" + id.uuidString,
      importedAt: Date(), favourite: false, origin: "own", parentRecipeID: source?.id, isRecipe: !note)
    recipe.categories = source?.categories
    recipe.tags = source?.tags
    recipe.ingredients = source?.ingredients
    recipe.cuisine = source?.cuisine
    recipe.mainIngredient = source?.mainIngredient
    try save(recipe)
    return recipe
  }

  /// Copies staged images only when Save is chosen; the imported source stays immutable.
  public func saveEdits(_ draft: Recipe, newImages: [String: Data]) throws {
    guard let original = try recipe(id: draft.id) else { throw CocoaError(.fileNoSuchFile) }
    var edited = draft
    edited.markdown = original.markdown
    edited.fingerprint = original.fingerprint
    edited.deletedAt = original.deletedAt
    edited.favourite = original.favourite
    edited.origin = original.origin
    edited.parentRecipeID = original.parentRecipeID
    if let titleIndex = edited.blocks.firstIndex(where: { $0.kind == .heading && $0.text == original.title }) {
      edited.blocks[titleIndex].text = edited.title
    }
    edited.tags = Array(Set((edited.tags ?? []).map(CatalogueVocabulary.tag).filter { !$0.isEmpty })).sorted()
    var written: [URL] = []
    do {
      let folder = assetsDirectory.appendingPathComponent(draft.id.uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      var mapped: [String: String] = [:]
      for index in edited.blocks.indices {
        guard let path = edited.blocks[index].assetPath, path.hasPrefix("staged:") else { continue }
        if let replacement = mapped[path] {
          edited.blocks[index].assetPath = replacement
          continue
        }
        guard let data = newImages[path] else { throw CocoaError(.fileReadNoSuchFile) }
        let extensionName = try RecipeImages.fileExtension(for: data)
        let relative = "\(draft.id.uuidString)/\(UUID().uuidString).\(extensionName)"
        let destination = assetsDirectory.appendingPathComponent(relative)
        try data.write(to: destination, options: .atomic)
        written.append(destination)
        mapped[path] = relative
        edited.blocks[index].assetPath = relative
      }
      edited.blocks = edited.blocks.enumerated().map { index, block in
        var result = block
        result.id = index
        return result
      }
      edited.assetPaths =
        Array(NSOrderedSet(array: edited.blocks.compactMap(\.assetPath))) as? [String] ?? []
      // Original warning details remain in the import report. Current view reflects retained missing-image blocks.
      edited.warnings = edited.blocks.filter { $0.kind == .missingImage || $0.kind == .missingAttachment }.map(\.text)
      try save(edited)
    } catch {
      for url in written { try? FileManager.default.removeItem(at: url) }
      throw error
    }
  }
  /// Soft deletion preserves the original and its assets for recovery.
  public func setDeleted(_ id: UUID, deleted: Bool) throws {
    try updateAttribute(id, key: "deletedAt", value: deleted ? Date() : nil)
  }
  /// Records that the user has checked a flagged recipe, so it leaves the Needs review list.
  public func markReviewed(_ id: UUID, reviewed: Bool = true) throws {
    try updateAttribute(id, key: "reviewedAt", value: reviewed ? Date() : nil)
  }

  private func approvedIdentities(backfilling sets: [ApprovedRecipeSet]) throws -> [ApprovedRecipeIdentity: Set<String>] {
    try context.performAndWait {
      var roots: [String: ApprovedRecipeSet] = [:]
      for set in sets { roots[set.root.path] = set }
      let ordered = roots.values.sorted { $0.root.path.count > $1.root.path.count }
      do {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Recipe")
        request.predicate = NSPredicate(format: "setId == nil AND sourceFile != nil")
        for object in try context.fetch(request) {
          guard let source = object.value(forKey: "sourceFile") as? String, source.hasPrefix("/") else { continue }
          let file = URL(fileURLWithPath: source).resolvingSymlinksInPath()
          for set in ordered {
            guard let relative = set.relativePath(file),
              ApprovedRecipeSet.containing(file, within: set.root)?.marker.setId == set.marker.setId else { continue }
            object.setValue(set.marker.setId, forKey: "setId")
            object.setValue(relative, forKey: "setRelativePath")
            break
          }
        }
        if context.hasChanges { try context.save() }
      } catch { context.rollback(); throw error }
      let request = NSFetchRequest<NSDictionary>(entityName: "Recipe")
      request.resultType = .dictionaryResultType
      request.propertiesToFetch = ["setId", "setRelativePath", "fingerprint"]
      var result: [ApprovedRecipeIdentity: Set<String>] = [:]
      for row in try context.fetch(request) {
        guard let id = row["setId"] as? UUID, let path = row["setRelativePath"] as? String,
          let fingerprint = row["fingerprint"] as? String else { continue }
        result[ApprovedRecipeIdentity(setId: id, relativePath: path), default: []].insert(fingerprint)
      }
      return result
    }
  }

  public func importURLs(_ urls: [URL], asNotes: Bool = false, reviewCatalogue: Bool = false, policy: ImportPolicy = .standard, progress: @escaping (Int, Int) -> Void = { _, _ in }) throws
    -> ImportReport
  {
    var report = ImportReport()
    var files: [(URL, URL)] = []
    var seen = Set<String>()
    for url in urls {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        report.failed += 1
        report.issues.append("Missing import location: " + url.lastPathComponent)
        continue
      }
      if isDirectory.boolValue {
        let enumerator = FileManager.default.enumerator(
          at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        while let child = enumerator?.nextObject() as? URL {
          if child.lastPathComponent == "_resources" {
            enumerator?.skipDescendants()
            continue
          }
          if child.pathExtension.lowercased() == "md",
            seen.insert(child.standardizedFileURL.path).inserted
          {
            files.append((child, url))
          }
        }
      } else if url.pathExtension.lowercased() == "md",
        seen.insert(url.standardizedFileURL.path).inserted
      {
        files.append((url, url.deletingLastPathComponent()))
      }
    }
    let vocabulary = try context.performAndWait { try RecipeVocabularyCache(context: context) }
    var fingerprints = try fingerprints()
    // A caller's policy hint cannot grant approval: each file must have a valid bounded marker.
    var duplicateIndex = try duplicateIndex()
    let sets = files.map { ApprovedRecipeSet.containing($0.0, within: $0.1) }
    var importedSources = try approvedIdentities(backfilling: sets.compactMap { $0 })
    report.fileCount = files.count
    // Process unsuffixed names first so exact aliases cannot hide numbered siblings.
    let orderedFiles = files.sorted {
      let leftNumbered =
        $0.0.deletingPathExtension().path != DuplicateDetection.filenameFamily($0.0.path)
      let rightNumbered =
        $1.0.deletingPathExtension().path != DuplicateDetection.filenameFamily($1.0.path)
      if leftNumbered != rightNumbered { return !leftNumbered }
      return $0.0.path < $1.0.path
    }
    for (index, pair) in orderedFiles.enumerated() {
      let (file, root) = pair
      do {
        let approvedSet = ApprovedRecipeSet.containing(file, within: root)
        let policy: ImportPolicy = approvedSet == nil ? .standard : .approvedTidy
        if policy == .standard, let metadata = try CatalogueMetadata.load(for: file, allowedRoot: root),
          try metadata.keeper(for: file, allowedRoot: root) != nil {
          report.skipped += 1
          report.catalogueSkipped += 1
          progress(index + 1, files.count)
          continue
        }
        var recipe = try MarkdownImporter.parse(
          file: file, allowedRoot: root, assetsDirectory: assetsDirectory)
        if asNotes { recipe.isRecipe = false }
        let assetFolder = assetsDirectory.appendingPathComponent(recipe.id.uuidString)
        let identity = approvedSet.flatMap { set in set.relativePath(file.resolvingSymlinksInPath()).map {
          ApprovedRecipeIdentity(setId: set.marker.setId, relativePath: $0)
        } }
        recipe.setId = identity?.setId
        recipe.setRelativePath = identity?.relativePath
        if let identity, let previous = importedSources[identity] {
          try? FileManager.default.removeItem(at: assetFolder)
          report.skipped += 1
          if !previous.contains(recipe.fingerprint) {
            report.changedSinceImport += 1
            report.issues.append("\(identity.relativePath): changed since import; existing recipe left untouched")
          }
        } else if policy == .standard && fingerprints.contains(recipe.fingerprint) {
          duplicateIndex.insert(
            DuplicateRecord(
              fingerprint: recipe.contentFingerprint, sourceFile: recipe.sourceFile,
              title: recipe.title))
          try? FileManager.default.removeItem(at: assetFolder)
          report.skipped += 1
        } else if policy == .standard, let match = duplicateIndex.match(recipe) {
          report.likelyDuplicates.append(
            LikelyDuplicate(recipe: recipe, matchingTitle: match.title, reason: match.reason))
          fingerprints.insert(recipe.fingerprint)
          duplicateIndex.insert(
            DuplicateRecord(
              fingerprint: recipe.contentFingerprint, sourceFile: recipe.sourceFile,
              title: recipe.title))
          report.issues.append(
            contentsOf: recipe.warnings.map { "\(file.lastPathComponent): \($0)" })
        } else {
          let needsCatalogueReview = try policy == .standard && reviewCatalogue && CatalogueMetadata.load(for: file, allowedRoot: root) != nil
          if needsCatalogueReview {
            report.catalogueReview.append(recipe)
          } else {
            do { try save(recipe, vocabulary: vocabulary) } catch {
              try? FileManager.default.removeItem(at: assetFolder)
              throw error
            }
            if let identity { importedSources[identity, default: []].insert(recipe.fingerprint) }
            report.imported += 1
            if recipe.isNote { report.notesImported += 1 }
          }
          fingerprints.insert(recipe.fingerprint)
          duplicateIndex.insert(
            DuplicateRecord(
              fingerprint: recipe.contentFingerprint, sourceFile: recipe.sourceFile,
              title: recipe.title))
          report.issues.append(
            contentsOf: recipe.warnings.map { "\(file.lastPathComponent): \($0)" })
        }
      } catch {
        report.failed += 1
        report.issues.append("Failed: \(file.lastPathComponent): \(error.localizedDescription)")
      }
      progress(index + 1, files.count)
    }
    report.vocabularyFetches = context.performAndWait { vocabulary.fetchCount }
    report.catalogueReview.sort { ($0.catalogueConfidence ?? 1) < ($1.catalogueConfidence ?? 1) }
    return report
  }
}
