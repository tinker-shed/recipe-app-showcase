import CoreData
import XCTest
@testable import RecipeCore

final class ApprovedSetTests: XCTestCase {
  static func marker(_ root: URL, id: UUID = UUID()) throws -> UUID {
    let data = ApprovedRecipeSet.Marker(schemaVersion: 1, setId: id, name: "Test set", createdAt: "2026-10-26", fileCount: 2)
    try JSONEncoder().encode(data).write(to: root.appendingPathComponent(".recipeapp-set.json"))
    return id
  }
  func fixture() throws -> (URL, URL, LibraryStore) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("tidy")
    try FileManager.default.createDirectory(at: source.appendingPathComponent("Soups"), withIntermediateDirectories: true)
    for name in ["Soup", "Soup.1"] {
      try "---\nCreated at: \(name)\n---\n# Soup\n- Peas\n1. Simmer.".write(to: source.appendingPathComponent("Soups/\(name).md"), atomically: true, encoding: .utf8)
    }
    return (root, source, try LibraryStore(directory: root.appendingPathComponent("Library")))
  }
  func testMovedRenamedSetAndChangedFileNeverCreateAnotherCopy() throws {
    let (root, source, store) = try fixture()
    let id = try Self.marker(source)
    XCTAssertEqual(try store.importURLs([source]).imported, 2)
    let originals = try store.recipes()
    XCTAssertTrue(originals.allSatisfy { $0.setId == id && $0.setRelativePath?.hasPrefix("Soups/") == true })
    let moved = root.appendingPathComponent("Elsewhere/Renamed recipes")
    try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: source, to: moved)
    let reopened = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let repeated = try reopened.importURLs([moved])
    XCTAssertEqual(repeated.imported, 0); XCTAssertEqual(repeated.skipped, 2)
    XCTAssertEqual(ImportPolicy.forSelection([moved]), .approvedTidy)
    try "# Changed soup\nUse beans instead.".write(to: moved.appendingPathComponent("Soups/Soup.md"), atomically: true, encoding: .utf8)
    let changed = try reopened.importURLs([moved])
    XCTAssertEqual(changed.imported, 0); XCTAssertEqual(changed.skipped, 2)
    XCTAssertEqual(changed.changedSinceImport, 1)
    XCTAssertTrue(changed.issues.first?.contains("changed since import") == true)
    XCTAssertEqual(try reopened.recipes(), originals)
  }
  func testNameOrInvalidMarkerCannotGrantApprovalEvenWithCallerHint() throws {
    let (_, source, store) = try fixture()
    XCTAssertEqual(ImportPolicy.forSelection([source]), .standard)
    let report = try store.importURLs([source], policy: .approvedTidy)
    XCTAssertEqual(report.imported, 1); XCTAssertEqual(report.likelyDuplicates.count, 1)
    for invalid in ["{}", #"{"schemaVersion":2,"setId":"bad"}"#, "not JSON"] {
      try invalid.write(to: source.appendingPathComponent(".recipeapp-set.json"), atomically: true, encoding: .utf8)
      XCTAssertEqual(ImportPolicy.forSelection([source]), .standard)
    }
    _ = try Self.marker(source)
    // Selecting only the notebook does not authorise reading its parent's marker.
    XCTAssertNil(ApprovedRecipeSet.containing(source.appendingPathComponent("Soups/Soup.md"), within: source.appendingPathComponent("Soups")))
  }
  func testLegacyRecordsBackfillWithoutReplacingContentOrActivity() throws {
    let (root, source, store) = try fixture()
    let report = try store.importURLs([source])
    for item in report.likelyDuplicates { _ = try store.resolveDuplicate(item, importCopy: true) }
    let records = try store.recipes()
    XCTAssertTrue(records.allSatisfy { $0.setId == nil })
    try store.setFavourite(records[0].id, favourite: true)
    let id = try Self.marker(source)
    try "# Changed after original import".write(to: source.appendingPathComponent("Soups/Soup.md"), atomically: true, encoding: .utf8)
    let next = try store.importURLs([source])
    XCTAssertEqual(next.imported, 0); XCTAssertEqual(next.skipped, 2); XCTAssertEqual(next.changedSinceImport, 1)
    let saved = try store.recipes()
    XCTAssertEqual(saved.map(\.id), records.map(\.id))
    XCTAssertTrue(saved.allSatisfy { $0.setId == id })
    XCTAssertEqual(saved[0].markdown, records[0].markdown)
    XCTAssertTrue(saved[0].favourite)
    let renamed = root.appendingPathComponent("Renamed")
    try FileManager.default.moveItem(at: source, to: renamed)
    XCTAssertEqual(try store.importURLs([renamed]).imported, 0)
  }
  func testNestedSetsAndUnmarkedNeighboursUseIndependentPolicies() throws {
    let (root, source, store) = try fixture()
    _ = try Self.marker(source)
    let other = root.appendingPathComponent("Unapproved")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try "# Soup\n- Peas\n1. Simmer.".write(to: other.appendingPathComponent("Another.md"), atomically: true, encoding: .utf8)
    _ = try store.importURLs([source])
    let report = try store.importURLs([root])
    XCTAssertEqual(report.imported, 0)
    XCTAssertEqual(report.likelyDuplicates.count, 1)
    XCTAssertEqual(report.skipped, 2)
  }
  func testVersion8MigrationPreservesRecordAndAddsOptionalIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Store-v2")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: LibraryModel.version8())
    let persistent = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: folder.appendingPathComponent("Library.sqlite"))
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    let id = UUID()
    try context.performAndWait {
      let object = NSEntityDescription.insertNewObject(forEntityName: "Recipe", into: context)
      for (key, value): (String, Any) in ["id": id, "title": "Old soup", "notebook": "Soups", "markdown": "# Old soup", "blocksData": Data("[]".utf8), "warningsData": Data("[]".utf8), "fingerprint": "old", "importedAt": Date(), "isFavourite": true] { object.setValue(value, forKey: key) }
      try context.save()
    }
    try coordinator.remove(persistent)
    let store = try LibraryStore(directory: root)
    let saved = try XCTUnwrap(store.recipe(id: id))
    XCTAssertEqual(saved.title, "Old soup"); XCTAssertTrue(saved.favourite)
    XCTAssertNil(saved.setId); XCTAssertNil(saved.setRelativePath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("MigrationBackups").path))
  }
}
