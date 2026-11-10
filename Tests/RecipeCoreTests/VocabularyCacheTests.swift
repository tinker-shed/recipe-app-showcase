import CoreData
import XCTest
@testable import RecipeCore
final class VocabularyCacheTests: XCTestCase {
  func testImportFetchesThreeVocabulariesOnceAndReusesNames() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    _ = try ApprovedSetTests.marker(source)
    for index in 0..<30 {
      try "# Soup \(index)\n- Peas".write(to: source.appendingPathComponent("\(index).md"), atomically: true, encoding: .utf8)
      try #"{"categories":["vegetarian","soups"],"tags":["easy","one-pan"],"ingredients":["pea","salt"]}"#.write(to: source.appendingPathComponent("\(index).catalogue.json"), atomically: true, encoding: .utf8)
    }
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let report = try store.importURLs([source], policy: .approvedTidy)
    XCTAssertEqual(report.imported, 30); XCTAssertEqual(report.vocabularyFetches, 3)
    for recipe in try store.recipes() {
      XCTAssertEqual(recipe.categories, ["soups", "vegetarian"])
      XCTAssertEqual(recipe.tags, ["easy", "one-pot"])
      XCTAssertEqual(recipe.ingredients, ["pea", "salt"])
    }
    XCTAssertEqual(try store.importURLs([source], policy: .approvedTidy).vocabularyFetches, 3)
  }
  func testRolledBackInsertCannotPoisonNextCachedWrite() throws {
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: LibraryModel.current())
    try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    try context.performAndWait {
      let cache = try RecipeVocabularyCache(context: context)
      let first = try cache.record(entity: "Tag", key: "name", name: "easy", context: context)
      context.rollback(); cache.invalidateAfterRollback()
      let second = try cache.record(entity: "Tag", key: "name", name: "easy", context: context)
      XCTAssertFalse(first === second)
      try context.save()
      let again = try cache.record(entity: "Tag", key: "name", name: "easy", context: context)
      XCTAssertTrue(second === again)
      XCTAssertEqual(cache.fetchCount, 6)
      XCTAssertEqual(try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Tag")), 1)
    }
  }
}
