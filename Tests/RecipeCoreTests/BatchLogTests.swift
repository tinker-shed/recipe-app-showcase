import XCTest
@testable import RecipeCore
final class BatchLogTests: XCTestCase {
  func testSaltValidationPhotosAndBackupRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let recipe = try store.createOwn(title: "Sauerkraut")
    var entry = CookEntry(date: Date(timeIntervalSince1970: 1000), note: "Cabbage batch")
    entry.ingredientWeightGrams = 1250; entry.saltGrams = 25; entry.pH = 3.6
    entry.finishedAt = Date(timeIntervalSince1970: 2000); entry.rating = 4
    XCTAssertEqual(entry.effectiveSaltPercent, 2)
    entry.saltPercent = 2.5; XCTAssertEqual(entry.effectiveSaltPercent, 2.5)
    entry.photoPaths = ["staged:photo"]
    try store.saveCookEntry(entry, recipeID: recipe.id, newImages: ["staged:photo": ImageTests.photograph(type: "public.jpeg")])
    let reopened = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let saved = try XCTUnwrap(reopened.recipe(id: recipe.id)?.cookHistory?.first)
    XCTAssertEqual(saved.pH, 3.6); XCTAssertEqual(saved.rating, 4)
    XCTAssertFalse(saved.photoPaths!.first!.hasPrefix("staged:"))
    var invalid = saved; invalid.pH = 19
    XCTAssertThrowsError(try reopened.saveCookEntry(invalid, recipeID: recipe.id))
    invalid = saved; invalid.finishedAt = .distantPast
    XCTAssertThrowsError(try invalid.validate())
    let backup = root.appendingPathComponent("Backup")
    try LibraryBackup.export(reopened, to: backup)
    try LibraryBackup.restore(from: backup, to: root.appendingPathComponent("Restored"))
    let restored = try LibraryStore(directory: root.appendingPathComponent("Restored"))
    XCTAssertEqual(try restored.recipe(id: recipe.id)?.cookHistory, [saved])
    XCTAssertNotNil(RecipeSearch.score(try XCTUnwrap(restored.recipe(id: recipe.id)), query: "cabbage"))
  }
}
