import XCTest

@testable import RecipeCore

final class LibraryTests: XCTestCase {
  func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  func testArchiveRoundTripAndReimport() throws {
    let root = try fixture()
    let source = root.appendingPathComponent("Asian Cooking")
    let assets = source.appendingPathComponent("_resources")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: assets.appendingPathComponent("photo%20one.jpg"))
    let original =
      "---\nCreated at: 17-04-2025\nSource URL: https://example.com/recipe\n---\n# Tofu 김치\n### Ingredients\n* ½ cup soy sauce\n![[./_resources/photo%2520one.jpg\\|300x200]]\n### Instructions\n1. Stir."
    try original.write(
      to: source.appendingPathComponent("recipe.md"), atomically: true, encoding: .utf8)
    var store: LibraryStore? = try LibraryStore(directory: root.appendingPathComponent("Library"))
    XCTAssertEqual(try store!.importURLs([source]).imported, 1)
    XCTAssertEqual(try store!.importURLs([source]).skipped, 1)
    let recipe = try XCTUnwrap(store!.recipes().first)
    XCTAssertEqual(recipe.title, "Tofu 김치")
    XCTAssertEqual(recipe.markdown, original)
    XCTAssertEqual(recipe.sourceURL, "https://example.com/recipe")
    XCTAssertTrue(recipe.warnings.isEmpty)
    XCTAssertEqual(recipe.assetPaths.count, 1)
    let savedAsset = store!.assetsDirectory.appendingPathComponent(recipe.assetPaths[0])
    try FileManager.default.removeItem(at: source)
    store = nil
    let reopened = try LibraryStore(directory: root.appendingPathComponent("Library"))
    XCTAssertEqual(try reopened.recipes().first, recipe)
    XCTAssertEqual(try Data(contentsOf: savedAsset), Data([1, 2, 3]))
  }
  func testTraversalAndMissingImagesAreReported() throws {
    let root = try fixture()
    let source = root.appendingPathComponent("Import")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data([9]).write(to: root.appendingPathComponent("private.jpg"))
    let markdown = "# Test\n![[../private.jpg]]\n![[missing.jpg]]"
    try markdown.write(
      to: source.appendingPathComponent("test.md"), atomically: true, encoding: .utf8)
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let report = try store.importURLs([source])
    XCTAssertEqual(report.imported, 1)
    XCTAssertEqual(report.issues.count, 2)
    XCTAssertTrue(try store.recipes()[0].assetPaths.isEmpty)
  }
  func testChangedContentIsPreservedAndInvalidFileAccountedFor() throws {
    let root = try fixture()
    let source = root.appendingPathComponent("Import")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let file = source.appendingPathComponent("test.md")
    try "# Soup\n* salt".write(to: file, atomically: true, encoding: .utf8)
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    _ = try store.importURLs([source])
    try "# Soup\n* pepper".write(to: file, atomically: true, encoding: .utf8)
    try Data([0xff, 0xfe, 0xff]).write(to: source.appendingPathComponent("bad.md"))
    let report = try store.importURLs([source])
    XCTAssertEqual(report.fileCount, 2)
    XCTAssertEqual(report.imported, 1)
    XCTAssertEqual(report.issues.count, 1)
    XCTAssertEqual(try store.recipes().count, 2)
  }
  func testAdjacentImagesAndParenthesizedPaths() throws {
    let root = try fixture()
    let source = root.appendingPathComponent("Import")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data([1]).write(to: source.appendingPathComponent("photo(1).jpg"))
    try Data([2]).write(to: source.appendingPathComponent("photo2.jpg"))
    try "# Recipe\n![first](photo(1).jpg)![second](photo2.jpg)[Caption](https://example.com)".write(
      to: source.appendingPathComponent("test.md"), atomically: true, encoding: .utf8)
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    XCTAssertTrue(try store.importURLs([source]).issues.isEmpty)
    let recipe = try XCTUnwrap(store.recipes().first)
    XCTAssertEqual(recipe.assetPaths.count, 2)
    XCTAssertTrue(recipe.blocks.contains { $0.text.contains("Caption") })
  }
  func testDeleteRestoreAndLegacyRecords() throws {
    let root = try fixture()
    let source = root.appendingPathComponent("Import")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try "# Soup\n* salt".write(
      to: source.appendingPathComponent("soup.md"), atomically: true, encoding: .utf8)
    try "# Soup\n* pepper".write(
      to: source.appendingPathComponent("duplicate.md"), atomically: true, encoding: .utf8)
    var store: LibraryStore? = try LibraryStore(directory: root.appendingPathComponent("Library"))
    _ = try store!.importURLs([source])
    let recipe = try XCTUnwrap(store!.recipes().first)
    let legacyData = try JSONEncoder().encode(recipe)
    XCTAssertNil(try JSONDecoder().decode(Recipe.self, from: legacyData).deletedAt)
    try store!.setDeleted(recipe.id, deleted: true)
    XCTAssertEqual(try store!.recipes().count, 1)
    XCTAssertEqual(try store!.recipes(includeDeleted: true).count, 2)
    XCTAssertEqual(try store!.importURLs([source]).skipped, 2)
    store = nil
    let reopened = try LibraryStore(directory: root.appendingPathComponent("Library"))
    XCTAssertEqual(try reopened.recipes().count, 1)
    try reopened.setDeleted(recipe.id, deleted: false)
    XCTAssertEqual(try reopened.recipes().count, 2)
    XCTAssertEqual(try reopened.recipes().first(where: { $0.id == recipe.id }), recipe)
  }
  func testEditingPreservesOriginalAndCopiesImagesOnSave() throws {
    let root = try fixture()
    let file = root.appendingPathComponent("recipe.md")
    let source = "# Original\n* Ingredient\nExtra clipping text"
    try source.write(to: file, atomically: true, encoding: .utf8)
    var store: LibraryStore? = try LibraryStore(directory: root.appendingPathComponent("Library"))
    _ = try store!.importURLs([file])
    let original = try XCTUnwrap(store!.recipes().first)
    var draft = original
    draft.title = "Clean recipe"
    draft.blocks = [
      RecipeBlock(id: 8, kind: .text, text: "My own note"),
      RecipeBlock(id: 20, kind: .image, text: "My photograph", assetPath: "staged:photo"),
    ]
    XCTAssertEqual(try store!.recipes().first, original)  // A discarded draft never changes storage.
    let bytes = try ImageTests.photograph(type: "public.png")
    try store!.saveEdits(draft, newImages: ["staged:photo": bytes])
    let saved = try XCTUnwrap(store!.recipes().first)
    XCTAssertEqual(saved.markdown, source)
    XCTAssertEqual(saved.fingerprint, original.fingerprint)
    XCTAssertEqual(saved.title, "Clean recipe")
    XCTAssertEqual(saved.blocks.map(\.id), [0, 1])
    XCTAssertEqual(
      try Data(contentsOf: store!.assetsDirectory.appendingPathComponent(saved.assetPaths[0])),
      bytes)
    XCTAssertEqual(try store!.importURLs([file]).skipped, 1)
    store = nil
    let reopened = try LibraryStore(directory: root.appendingPathComponent("Library"))
    XCTAssertEqual(try reopened.recipes().first, saved)
    var failed = saved
    failed.title = "Must not save"
    failed.blocks.append(
      RecipeBlock(id: 2, kind: .image, text: "missing", assetPath: "staged:missing"))
    XCTAssertThrowsError(try reopened.saveEdits(failed, newImages: [:]))
    XCTAssertEqual(try reopened.recipes().first, saved)
    var removed = saved
    removed.blocks.removeAll { $0.kind == .image }
    try reopened.saveEdits(removed, newImages: [:])
    XCTAssertTrue(try reopened.recipes()[0].assetPaths.isEmpty)
    XCTAssertEqual(try reopened.recipes()[0].markdown, source)
  }
  func testUserArchiveIfProvided() throws {
    guard let path = ProcessInfo.processInfo.environment["RECIPEAPP_TEST_ARCHIVE"] else {
      throw XCTSkip("Set RECIPEAPP_TEST_ARCHIVE to validate a real archive")
    }
    let root = try fixture()
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let report = try store.importURLs([URL(fileURLWithPath: path)])
    print("ARCHIVE: \(report.summary); warnings: \(report.issues.count)")
    XCTAssertEqual(report.fileCount, 97)
    XCTAssertFalse(report.issues.contains(where: { $0.hasPrefix("Failed:") }))
    XCTAssertEqual(
      report.imported + report.skipped + report.likelyDuplicates.count, report.fileCount)
    for candidate in report.likelyDuplicates {
      XCTAssertTrue(try store.resolveDuplicate(candidate, importCopy: true))
    }
    let second = try store.importURLs([URL(fileURLWithPath: path)])
    XCTAssertEqual(second.imported, 0)
    XCTAssertEqual(second.skipped, report.fileCount)
    for recipe in try store.recipes() {
      for asset in recipe.assetPaths {
        XCTAssertTrue(
          FileManager.default.fileExists(
            atPath: store.assetsDirectory.appendingPathComponent(asset).path))
      }
    }
  }
}
