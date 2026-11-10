import XCTest
@testable import RecipeCore
final class BackupTests: XCTestCase {
  func testPortableExportCompleteRestoreAndTamperRejection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    var recipe = try store.createOwn(title: "My soup")
    recipe.blocks = [RecipeBlock(id: 0, kind: .image, text: "Photo", assetPath: "staged:one"), RecipeBlock(id: 1, kind: .bullet, text: "½ tsp salt")]
    recipe.personalNotes = "Lovely with bread"
    let photo = try ImageTests.photograph(type: "public.jpeg")
    try store.saveEdits(recipe, newImages: ["staged:one": photo])
    try store.setFavourite(recipe.id, favourite: true)
    try store.recordView(recipe.id, opening: UUID())
    try store.saveCookEntry(CookEntry(note: "First batch"), recipeID: recipe.id)
    let note = try store.createOwn(title: "Journal", note: true)
    try store.setDeleted(note.id, deleted: true)
    let expected = try store.recipes(includeDeleted: true)
    let output = root.appendingPathComponent("Export")
    XCTAssertThrowsError(try LibraryBackup.export(store, to: store.assetsDirectory.appendingPathComponent("Nested")))
    try LibraryBackup.export(store, to: output)
    XCTAssertThrowsError(try LibraryBackup.export(store, to: output))
    let portable = try LibraryStore(directory: root.appendingPathComponent("Portable"))
    XCTAssertEqual(try portable.importURLs([output.appendingPathComponent("Recipes")]).imported, 1)
    XCTAssertEqual(try portable.recipes().first?.collection, "My recipes")
    XCTAssertTrue(try portable.recipes().first?.blocks.contains { $0.text == "½ tsp salt" } == true)
    XCTAssertThrowsError(try LibraryBackup.restore(from: output, to: output.appendingPathComponent("Nested")))
    let restoredURL = root.appendingPathComponent("Restored")
    try LibraryBackup.restore(from: output, to: restoredURL)
    let restored = try LibraryStore(directory: restoredURL)
    XCTAssertEqual(try restored.recipes(includeDeleted: true), expected)
    XCTAssertThrowsError(try LibraryBackup.restore(from: output, to: restoredURL))
    let image = try XCTUnwrap(expected.first { $0.id == recipe.id }?.assetPaths.first)
    try Data([0]).write(to: output.appendingPathComponent("Assets/" + image))
    let rejected = root.appendingPathComponent("Rejected")
    XCTAssertThrowsError(try LibraryBackup.restore(from: output, to: rejected))
    XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
  }
}
