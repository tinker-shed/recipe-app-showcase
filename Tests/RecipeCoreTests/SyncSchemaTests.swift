import CoreData
import XCTest
@testable import RecipeCore

final class SyncSchemaTests: XCTestCase {
  private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  func testSchema11MigratesAndActivityFieldsWork() throws {
    let root = try root()
    let folder = root.appendingPathComponent("Store-v2")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: LibraryModel.version10())
    let persistent = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil, at: folder.appendingPathComponent("Library.sqlite"))
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    let id = UUID()
    try context.performAndWait {
      let object = NSEntityDescription.insertNewObject(forEntityName: "Recipe", into: context)
      object.setValue(id, forKey: "id"); object.setValue("Soup", forKey: "title"); object.setValue("Soups", forKey: "notebook")
      object.setValue("# Soup", forKey: "markdown")
      object.setValue(try JSONEncoder().encode([RecipeBlock]()), forKey: "blocksData")
      object.setValue(try JSONEncoder().encode([String]()), forKey: "warningsData")
      object.setValue("fp", forKey: "fingerprint"); object.setValue(Date(), forKey: "importedAt")
      try context.save()
    }
    try coordinator.remove(persistent)

    let store = try LibraryStore(directory: root)
    XCTAssertNil(try XCTUnwrap(store.recipe(id: id)).favouriteChangedAt)
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("MigrationBackups").path).isEmpty)

    // Favourite now stamps the change time, for sync tie-breaking.
    try store.setFavourite(id, favourite: true)
    let favourited = try XCTUnwrap(store.recipe(id: id))
    XCTAssertTrue(favourited.favourite)
    XCTAssertNotNil(favourited.favouriteChangedAt)

    // A cook entry shows in the history; deleting it leaves a tombstone, so the history is empty but recoverable for sync.
    let entry = CookEntry(date: Date(), note: "too much salt")
    try store.saveCookEntry(entry, recipeID: id)
    XCTAssertEqual(try XCTUnwrap(store.recipe(id: id)).cookHistory?.count, 1)
    try store.deleteCookEntry(entry.id)
    XCTAssertNil(try XCTUnwrap(store.recipe(id: id)).cookHistory)
  }
}
