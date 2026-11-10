import CoreData
import XCTest

@testable import RecipeCore

final class DuplicateTests: XCTestCase {
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  func testChangedMetadataAndWhitespaceRequireExplicitAcceptance() throws {
    let root = try fixture()
    let file = root.appendingPathComponent("Soup.md")
    try "---\nLast updated at: yesterday\n---\n# Soup\n* salt".write(
      to: file, atomically: true, encoding: .utf8)
    var store: LibraryStore? = try LibraryStore(directory: root.appendingPathComponent("Library"))
    XCTAssertEqual(try store!.importURLs([file]).imported, 1)
    store = nil
    store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    try "---\nLast updated at: today\n---\n# Soup\n\n*   salt  ".write(
      to: file, atomically: true, encoding: .utf8)
    let report = try store!.importURLs([file])
    XCTAssertEqual(report.imported, 0)
    let candidate = try XCTUnwrap(report.likelyDuplicates.first)
    XCTAssertTrue(candidate.reason.contains("body"))
    XCTAssertEqual(try store!.recipes().count, 1)
    XCTAssertTrue(try store!.resolveDuplicate(candidate, importCopy: true))
    XCTAssertEqual(try store!.recipes().count, 2)
    XCTAssertEqual(try store!.importURLs([file]).skipped, 1)
  }

  func testNumberedFilesReviewAndSkipRemovesCopiedAssets() throws {
    let root = try fixture()
    let first = root.appendingPathComponent("Soup.md")
    let second = root.appendingPathComponent("Soup.1.md")
    try ImageTests.photograph().write(to: root.appendingPathComponent("photo.jpg"))
    try "# Soup\n* salt".write(to: first, atomically: true, encoding: .utf8)
    try "# Soup\n* pepper\n![Photo](photo.jpg)".write(to: second, atomically: true, encoding: .utf8)
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    XCTAssertEqual(try store.importURLs([first]).imported, 1)
    let report = try store.importURLs([second])
    let candidate = try XCTUnwrap(report.likelyDuplicates.first)
    XCTAssertTrue(candidate.reason.contains("filename"))
    let folder = store.assetsDirectory.appendingPathComponent(candidate.id.uuidString)
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    XCTAssertFalse(try store.resolveDuplicate(candidate, importCopy: false))
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    XCTAssertEqual(try store.recipes().count, 1)
    XCTAssertEqual(try store.importURLs([second]).likelyDuplicates.count, 1)
  }

  func testSameTitleDifferentRecipesAndDifferentFoldersAreNotDuplicates() throws {
    let root = try fixture()
    let other = root.appendingPathComponent("Other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let files = [
      root.appendingPathComponent("Soup.md"), root.appendingPathComponent("Another.md"),
      other.appendingPathComponent("Soup.1.md"),
    ]
    for (index, file) in files.enumerated() {
      try "# Soup\n* ingredient \(index)".write(to: file, atomically: true, encoding: .utf8)
    }
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let report = try store.importURLs(files)
    XCTAssertEqual(report.imported, 3)
    XCTAssertTrue(report.likelyDuplicates.isEmpty)
  }

  func testSameBatchFlagsNumberedCopiesAndExactCopiesStillSkip() throws {
    let root = try fixture()
    let first = root.appendingPathComponent("Soup.md")
    let second = root.appendingPathComponent("Soup.1.md")
    let exact = root.appendingPathComponent("Exact.md")
    try "# Soup\n* salt".write(to: first, atomically: true, encoding: .utf8)
    try "# Soup\n* pepper".write(to: second, atomically: true, encoding: .utf8)
    try FileManager.default.copyItem(at: first, to: exact)
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let report = try store.importURLs([first, second, exact])
    // The exact copy's different filename must not hide the Soup.md family from detection.
    XCTAssertEqual(report.imported + report.skipped + report.likelyDuplicates.count, 3)
    XCTAssertEqual(report.skipped, 1)
    XCTAssertEqual(report.likelyDuplicates.count, 1)
  }

  func testVersion2UpgradePreservesRecipeAndBackfillsContentFingerprint() throws {
    let root = try fixture()
    let directory = root.appendingPathComponent("Store-v2")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: LibraryModel.version2())
    let persistent = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil,
      at: directory.appendingPathComponent("Library.sqlite"))
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    let id = UUID()
    try context.performAndWait {
      let record = NSEntityDescription.insertNewObject(forEntityName: "Recipe", into: context)
      let values: [String: Any] = [
        "id": id, "title": "Soup", "notebook": "Cooking", "markdown": "# Soup\n* salt",
        "blocksData": Data("[]".utf8), "warningsData": Data("[]".utf8), "fingerprint": "old-exact",
        "importedAt": Date(), "isFavourite": true,
      ]
      for (key, value) in values { record.setValue(value, forKey: key) }
      try context.save()
    }
    try coordinator.remove(persistent)
    let library = try LibraryStore(directory: root)
    XCTAssertTrue(try XCTUnwrap(library.recipe(id: id)).favourite)
    let file = root.appendingPathComponent("New export.md")
    try "---\nUpdated: today\n---\n# Soup\n* salt".write(
      to: file, atomically: true, encoding: .utf8)
    XCTAssertEqual(try library.importURLs([file]).likelyDuplicates.count, 1)
    let backups = try FileManager.default.contentsOfDirectory(
      atPath: root.appendingPathComponent("MigrationBackups").path)
    XCTAssertEqual(backups.filter { $0.hasPrefix("v2-") }.count, 1)
  }
}
