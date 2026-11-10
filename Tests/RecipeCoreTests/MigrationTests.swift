import CoreData
import CryptoKit
import XCTest

@testable import RecipeCore

final class MigrationTests: XCTestCase {
  private func temporaryLibrary() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  // Independent fixture matches the actual shipped v0.1.4 programmatic model.
  private func legacyModel() -> NSManagedObjectModel {
    let model = NSManagedObjectModel()
    let entity = NSEntityDescription()
    entity.name = "StoredRecipe"
    entity.managedObjectClassName = "NSManagedObject"
    let id = NSAttributeDescription()
    id.name = "id"
    id.attributeType = .UUIDAttributeType
    id.isOptional = false
    let payload = NSAttributeDescription()
    payload.name = "payload"
    payload.attributeType = .binaryDataAttributeType
    payload.isOptional = false
    entity.properties = [id, payload]
    entity.uniquenessConstraints = [["id"]]
    model.entities = [entity]
    return model
  }

  @discardableResult
  private func createLegacy(_ directory: URL, payloads: [(UUID, Data)], keepOpen: Bool = false)
    throws -> NSPersistentStoreCoordinator?
  {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: legacyModel())
    let store = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil,
      at: directory.appendingPathComponent("Library.sqlite"))
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    try context.performAndWait {
      for (id, data) in payloads {
        let object = NSEntityDescription.insertNewObject(
          forEntityName: "StoredRecipe", into: context)
        object.setValue(id, forKey: "id")
        object.setValue(data, forKey: "payload")
      }
      try context.save()
      context.reset()
    }
    if keepOpen { return coordinator }
    try coordinator.remove(store)
    return nil
  }

  private func legacyRecipe(_ id: UUID, title: String, favourite: Bool, deleted: Bool, path: String)
    throws -> Data
  {
    var object: [String: Any] = [
      "id": id.uuidString,
      "title": title,
      "collection": "Asian Cooking",
      "sourceURL": "https://example.com/recipe",
      "markdown": "# Original title\n* Original ingredient\n",
      "blocks": [
        ["id": 7, "kind": "text", "text": "My edited instructions — ½ cup", "level": 0],
        ["id": 13, "kind": "image", "text": "Photograph", "level": 0, "assetPath": path],
      ],
      "assetPaths": [path],
      "warnings": ["An original image was unavailable"],
      "fingerprint": "source-" + id.uuidString,
      "importedAt": 720000000.0,
      "favourite": favourite,
      "createdText": "17-04-2025",
      "updatedText": "18-04-2025",
    ]
    if deleted { object["deletedAt"] = 720000100.0 }
    return try JSONSerialization.data(withJSONObject: object)
  }

  func testMigratesEveryLegacyFieldAndLeavesBackupAndAssetsIntact() throws {
    let directory = try temporaryLibrary()
    let ids = [UUID(), UUID(), UUID()]
    var payloads: [(UUID, Data)] = []
    let bytes = Data([1, 2, 3, 4])
    for (index, id) in ids.enumerated() {
      let path = id.uuidString + "/photo.jpg"
      let asset = directory.appendingPathComponent("Assets/" + path)
      try FileManager.default.createDirectory(
        at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
      try bytes.write(to: asset)
      payloads.append(
        (
          id,
          try legacyRecipe(
            id, title: "Edited recipe \(index)", favourite: index == 1, deleted: index == 2,
            path: path)
        ))
    }
    try createLegacy(directory, payloads: payloads)
    let originalDatabase = try Data(contentsOf: directory.appendingPathComponent("Library.sqlite"))
    var store: LibraryStore? = try LibraryStore(directory: directory)
    let expected = try payloads.map { try JSONDecoder().decode(Recipe.self, from: $0.1) }
    XCTAssertEqual(try store!.recipes(includeDeleted: true).count, 3)
    XCTAssertEqual(try store!.recipes().count, 2)
    for recipe in expected {
      XCTAssertEqual(try store!.recipe(id: recipe.id), recipe)
      XCTAssertEqual(
        try Data(contentsOf: store!.assetsDirectory.appendingPathComponent(recipe.assetPaths[0])),
        bytes)
    }
    XCTAssertNil(try store!.recipe(id: UUID()))
    XCTAssertEqual(
      try Data(contentsOf: directory.appendingPathComponent("Library.sqlite")), originalDatabase)
    let backups = try FileManager.default.contentsOfDirectory(
      at: directory.appendingPathComponent("MigrationBackups"), includingPropertiesForKeys: nil)
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(
      try Data(contentsOf: backups[0].appendingPathComponent("Library.sqlite")), originalDatabase)
    store = nil
    let reopened = try LibraryStore(directory: directory)
    for recipe in expected { XCTAssertEqual(try reopened.recipe(id: recipe.id), recipe) }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: directory.appendingPathComponent("MigrationBackups").path
      ).count, 1)
    try reopened.setFavourite(ids[0], favourite: true)
    try reopened.setDeleted(ids[1], deleted: true)
    XCTAssertTrue(try XCTUnwrap(reopened.recipe(id: ids[0])).favourite)
    XCTAssertNotNil(try XCTUnwrap(reopened.recipe(id: ids[1])).deletedAt)
    XCTAssertEqual(try reopened.recipe(id: ids[2]), expected[2])
  }

  func testLegacyMigrationCreatesHeroThumbnail() throws {
    let directory = try temporaryLibrary()
    let id = UUID()
    let path = id.uuidString + "/photo.jpg"
    let asset = directory.appendingPathComponent("Assets/" + path)
    try FileManager.default.createDirectory(
      at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ImageTests.photograph().write(to: asset)
    let payload = try legacyRecipe(id, title: "Soup", favourite: true, deleted: false, path: path)
    try createLegacy(directory, payloads: [(id, payload)])
    let store = try LibraryStore(directory: directory)
    var migrated = try XCTUnwrap(store.recipe(id: id))
    let thumbnail = try XCTUnwrap(migrated.thumbnailPath)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: store.assetsDirectory.appendingPathComponent(thumbnail).path))
    migrated.thumbnailPath = nil
    XCTAssertEqual(migrated, try JSONDecoder().decode(Recipe.self, from: payload))
  }

  func testMigrationIncludesUncheckpointedWAL() throws {
    let directory = try temporaryLibrary()
    let id = UUID()
    let payload = try legacyRecipe(
      id, title: "Latest WAL edit", favourite: true, deleted: true,
      path: id.uuidString + "/missing.jpg")
    let coordinator = try XCTUnwrap(
      createLegacy(directory, payloads: [(id, payload)], keepOpen: true))
    defer { for store in coordinator.persistentStores { try? coordinator.remove(store) } }
    let wal = directory.appendingPathComponent("Library.sqlite-wal")
    XCTAssertGreaterThan(try Data(contentsOf: wal).count, 0)
    let library = try LibraryStore(directory: directory)
    XCTAssertEqual(try library.recipe(id: id), try JSONDecoder().decode(Recipe.self, from: payload))
    let backups = try FileManager.default.contentsOfDirectory(
      at: directory.appendingPathComponent("MigrationBackups"), includingPropertiesForKeys: nil)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: backups[0].appendingPathComponent("Library.sqlite-wal").path))
  }

  func testMalformedLegacyRecordDoesNotPublishPartialMigration() throws {
    let directory = try temporaryLibrary()
    let id = UUID()
    let valid = try legacyRecipe(
      id, title: "Valid", favourite: true, deleted: false, path: id.uuidString + "/missing.jpg")
    try createLegacy(directory, payloads: [(id, valid), (UUID(), Data("broken payload".utf8))])
    let original = try Data(contentsOf: directory.appendingPathComponent("Library.sqlite"))
    XCTAssertThrowsError(try LibraryStore(directory: directory))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("Store-v2").path))
    XCTAssertEqual(
      try Data(contentsOf: directory.appendingPathComponent("Library.sqlite")), original)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: directory.appendingPathComponent("MigrationBackups").path
      ).count, 1)
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
        $0.hasPrefix(".migration-")
      })
  }

  func testNewStoreHasQueryableFieldsAndInverseRelationships() throws {
    let directory = try temporaryLibrary()
    let id = UUID()
    let data = try legacyRecipe(
      id, title: "Café Curry", favourite: true, deleted: false, path: id.uuidString + "/missing.jpg"
    )
    try createLegacy(directory, payloads: [(id, data)])
    var library: LibraryStore? = try LibraryStore(directory: directory)
    let migrated = try XCTUnwrap(library!.recipe(id: id))
    library = nil
    let model = LibraryModel.current()
    XCTAssertEqual(
      Set(model.entities.compactMap(\.name)), ["Recipe", "Asset", "CookEvent", "Ingredient", "Tag", "Category"])
    XCTAssertNil(model.entitiesByName["Recipe"]?.attributesByName["payload"])
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    let store = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil,
      at: directory.appendingPathComponent("Store-v2/Library.sqlite"))
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    try context.performAndWait {
      let request = NSFetchRequest<NSManagedObject>(entityName: "Recipe")
      request.predicate = NSPredicate(
        format: "title == %@ AND isFavourite == YES AND searchText CONTAINS %@", "Café Curry",
        "cafe curry")
      let recipe = try XCTUnwrap(context.fetch(request).first)
      XCTAssertEqual(recipe.value(forKey: "category") as? String, "Asian Cooking")
      XCTAssertEqual(recipe.value(forKey: "viewCount") as? Int64, 0)
      XCTAssertNil(recipe.value(forKey: "thumbnailPath"))
      let asset = try XCTUnwrap((recipe.value(forKey: "assets") as? Set<NSManagedObject>)?.first)
      XCTAssertEqual(asset.value(forKey: "mediaType") as? String, "image/jpeg")
      XCTAssertEqual(asset.value(forKey: "checksum") as? String, "")
      let tag = NSEntityDescription.insertNewObject(forEntityName: "Tag", into: context)
      tag.setValue(" #Week Night ", forKey: "name")
      recipe.mutableSetValue(forKey: "tags").add(tag)
      XCTAssertTrue(tag.mutableSetValue(forKey: "recipes").contains(recipe))
      let ingredient = NSEntityDescription.insertNewObject(
        forEntityName: "Ingredient", into: context)
      ingredient.setValue(" Aubergine ", forKey: "name")
      recipe.mutableSetValue(forKey: "ingredients").add(ingredient)
      let event = NSEntityDescription.insertNewObject(forEntityName: "CookEvent", into: context)
      event.setValue(UUID(), forKey: "id")
      event.setValue(Date(timeIntervalSince1970: 100), forKey: "date")
      event.setValue(recipe, forKey: "recipe")
      recipe.setValue("Vegetarian", forKey: "category")
      recipe.setValue(Int64(4), forKey: "viewCount")
      try context.save()
      context.reset()
    }
    try coordinator.remove(store)
    let reopened = try LibraryStore(directory: directory)
    var edited = migrated
    edited.title = "Updated title"
    edited.markdown = "Must never replace source"
    try reopened.save(edited)
    XCTAssertEqual(try reopened.recipe(id: id)?.markdown, migrated.markdown)
    // Check relationships/history survive a content save, without adding any user-facing feature.
    let inspectStore = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil,
      at: directory.appendingPathComponent("Store-v2/Library.sqlite"))
    try context.performAndWait {
      let recipe = try XCTUnwrap(RecipePersistence.object(id: id, in: context))
      XCTAssertEqual(recipe.value(forKey: "viewCount") as? Int64, 4)
      XCTAssertEqual(recipe.value(forKey: "category") as? String, "Vegetarian")
      XCTAssertEqual(recipe.mutableSetValue(forKey: "tags").count, 1)
      let tag = try XCTUnwrap((recipe.value(forKey: "tags") as? Set<NSManagedObject>)?.first)
      XCTAssertEqual(tag.value(forKey: "name") as? String, "week-night")
      let ingredient = try XCTUnwrap(
        (recipe.value(forKey: "ingredients") as? Set<NSManagedObject>)?.first)
      XCTAssertEqual(ingredient.value(forKey: "name") as? String, "aubergine")
      XCTAssertEqual(recipe.mutableSetValue(forKey: "ingredients").count, 1)
      XCTAssertEqual(recipe.mutableSetValue(forKey: "cookEvents").count, 1)
    }
    try coordinator.remove(inspectStore)
  }
}
