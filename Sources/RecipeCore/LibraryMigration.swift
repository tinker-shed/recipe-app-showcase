import CoreData

/// Builds a new store beside the old one, publishing it only after every record verifies.
/// The original database and managed assets are never overwritten by migration.
enum LibraryMigration {
  static func storeURL(in directory: URL) throws -> URL {
    let fileManager = FileManager.default
    let finalDirectory = directory.appendingPathComponent("Store-v2", isDirectory: true)
    let finalURL = finalDirectory.appendingPathComponent("Library.sqlite")
    if fileManager.fileExists(atPath: finalDirectory.path) {
      guard fileManager.fileExists(atPath: finalURL.path) else {
        throw CocoaError(.fileReadCorruptFile)
      }
      try upgradeDuplicateFields(at: finalURL, in: directory)
      return finalURL
    }
    let legacyURL = directory.appendingPathComponent("Library.sqlite")
    let staging = directory.appendingPathComponent(
      ".migration-" + UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    do {
      let coordinator = NSPersistentStoreCoordinator(managedObjectModel: LibraryModel.current())
      let store = try coordinator.addPersistentStore(
        ofType: NSSQLiteStoreType, configurationName: nil,
        at: staging.appendingPathComponent("Library.sqlite"))
      do {
        if fileManager.fileExists(atPath: legacyURL.path) {
          let backup = try backupLegacyStore(in: directory)
          try migrate(
            from: backup.appendingPathComponent("Library.sqlite"), to: coordinator,
            assets: directory.appendingPathComponent("Assets"))
        }
        // Closing checkpoints the new store before the entire directory is atomically published.
        try coordinator.remove(store)
      } catch {
        try? coordinator.remove(store)
        throw error
      }
      try fileManager.moveItem(at: staging, to: finalDirectory)
      return finalURL
    } catch {
      try? fileManager.removeItem(at: staging)
      throw error
    }
  }

  private static func upgradeDuplicateFields(at url: URL, in directory: URL) throws {
    let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
      ofType: NSSQLiteStoreType, at: url)
    let destination = LibraryModel.current()
    if destination.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) { return }
    guard let source = [LibraryModel.version10(), LibraryModel.version9(), LibraryModel.version8(), LibraryModel.version7(), LibraryModel.version6(), LibraryModel.version5(), LibraryModel.version4(), LibraryModel.version3(), LibraryModel.version2()].first(where: {
      $0.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
    }) else {
      throw CocoaError(.persistentStoreIncompatibleVersionHash)
    }
    let backup = directory.appendingPathComponent("MigrationBackups/v2-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
    for suffix in ["", "-wal", "-shm"] {
      let file = URL(fileURLWithPath: url.path + suffix)
      if FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.copyItem(
          at: file, to: backup.appendingPathComponent("Library.sqlite" + suffix))
      }
    }
    let staging = directory.appendingPathComponent(".schema-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    let migrated = staging.appendingPathComponent("Library.sqlite")
    let mapping = try NSMappingModel.inferredMappingModel(
      forSourceModel: source, destinationModel: destination)
    let manager = NSMigrationManager(sourceModel: source, destinationModel: destination)
    try manager.migrateStore(
      from: backup.appendingPathComponent("Library.sqlite"), sourceType: NSSQLiteStoreType,
      options: nil, with: mapping, toDestinationURL: migrated, destinationType: NSSQLiteStoreType,
      destinationOptions: nil)
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: destination)
    try coordinator.replacePersistentStore(
      at: url, destinationOptions: nil, withPersistentStoreFrom: migrated, sourceOptions: nil,
      ofType: NSSQLiteStoreType)
  }

  private static func backupLegacyStore(in directory: URL) throws -> URL {
    let backup = directory.appendingPathComponent("MigrationBackups", isDirectory: true)
      .appendingPathComponent("v1-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
    // Copy the whole SQLite file family before opening it; the WAL may contain recent edits.
    for name in ["Library.sqlite", "Library.sqlite-wal", "Library.sqlite-shm"] {
      let original = directory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: original.path) {
        try FileManager.default.copyItem(at: original, to: backup.appendingPathComponent(name))
      }
    }
    try
      "Legacy recipe store backed up before model migration. Keep these SQLite files together. Managed images remain unchanged in ../../Assets.\n"
      .write(to: backup.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    return backup
  }

  private static func originalFields(_ recipe: Recipe) -> Recipe {
    var original = recipe
    original.thumbnailPath = nil
    return original
  }

  private static func migrate(
    from backup: URL, to destination: NSPersistentStoreCoordinator, assets: URL
  ) throws {
    let legacyCoordinator = NSPersistentStoreCoordinator(managedObjectModel: LibraryModel.legacy())
    let legacyStore = try legacyCoordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil, at: backup,
      options: [NSReadOnlyPersistentStoreOption: true])
    defer { try? legacyCoordinator.remove(legacyStore) }
    let legacyContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    legacyContext.persistentStoreCoordinator = legacyCoordinator
    let recipes: [Recipe] = try legacyContext.performAndWait {
      let request = NSFetchRequest<NSManagedObject>(entityName: "StoredRecipe")
      return try legacyContext.fetch(request).map { record in
        guard let data = record.value(forKey: "payload") as? Data,
          let id = record.value(forKey: "id") as? UUID
        else { throw CocoaError(.fileReadCorruptFile) }
        let recipe = try JSONDecoder().decode(Recipe.self, from: data)
        guard recipe.id == id else { throw CocoaError(.fileReadCorruptFile) }
        return recipe
      }
    }
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = destination
    try context.performAndWait {
      for recipe in recipes {
        try RecipePersistence.write(recipe, in: context, assetsDirectory: assets)
      }
      try context.save()
      context.reset()
      let count = try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Recipe"))
      guard count == recipes.count else { throw CocoaError(.fileReadCorruptFile) }
      for expected in recipes {
        guard let object = try RecipePersistence.object(id: expected.id, in: context),
          try originalFields(RecipePersistence.read(object)) == originalFields(expected)
        else { throw CocoaError(.fileReadCorruptFile) }
      }
    }
  }
}
