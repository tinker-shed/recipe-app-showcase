import XCTest
@testable import RecipeCore
final class BatchSuggestionTests: XCTestCase {
  func testAcceptedSuggestionKeepsStableIdentityAndTextWithoutDuplicateLogs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let recipe = try store.createOwn(title: "Ferment")
    let file = root.appendingPathComponent("suggestions.json")
    let id = UUID()
    try JSONSerialization.data(withJSONObject: ["version": 1, "candidates": [["id": id.uuidString, "sourceFile": "2023.md", "startDate": "2023-09-28", "text": "Cabbage 1250g; salt 25g", "reason": "Review"]]]).write(to: file)
    let suggestion = try XCTUnwrap(BatchSuggestion.load(file).first)
    XCTAssertNotNil(suggestion.date)
    let entry = suggestion.entry(date: try XCTUnwrap(suggestion.date), text: suggestion.text)
    try store.saveCookEntry(entry, recipeID: recipe.id)
    try store.saveCookEntry(entry, recipeID: recipe.id)
    XCTAssertEqual(try store.recipe(id: recipe.id)?.cookCount, 1)
    XCTAssertEqual(try store.recipe(id: recipe.id)?.cookHistory?.first?.note, suggestion.text)
    XCTAssertNil(entry.saltGrams)
  }
}
