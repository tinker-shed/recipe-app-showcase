import XCTest
@testable import RecipeCore
final class ActivityTests: XCTestCase {
  func testFavouriteViewsAndEditableCookingHistoryPersistWithoutReimportReset() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Soup.md")
    try "# Soup\nSalt".write(to: file, atomically: true, encoding: .utf8)
    var store: LibraryStore? = try LibraryStore(directory: root.appendingPathComponent("Library"))
    _ = try store!.importURLs([file])
    let r = try XCTUnwrap(store!.recipes().first)
    XCTAssertNotNil(RecipeSearch.score(r, query: "cooked:never"))
    let opening = UUID()
    try store!.recordView(r.id, opening: opening)
    try store!.recordView(r.id, opening: opening)
    try store!.recordView(r.id, opening: UUID())
    try store!.setFavourite(r.id, favourite: true)
    var entry = CookEntry(date: Date(timeIntervalSince1970: 0), note: "Old batch")
    try store!.saveCookEntry(entry, recipeID: r.id)
    entry.note = "Corrected"
    try store!.saveCookEntry(entry, recipeID: r.id)
    XCTAssertEqual(try store!.recipe(id: r.id)?.cookCount, 1)
    _ = try store!.importURLs([file]); store = nil
    let reopened = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let saved = try XCTUnwrap(reopened.recipe(id: r.id))
    XCTAssertEqual(saved.viewCount, 2)
    XCTAssertTrue(saved.favourite)
    XCTAssertEqual(saved.cookHistory?.first?.note, "Corrected")
    XCTAssertNil(RecipeSearch.score(saved, query: "cooked:never"))
    XCTAssertNotNil(RecipeSearch.score(saved, query: "cooked:>6m"))
    var stale = r; stale.title = "New title"
    try reopened.saveEdits(stale, newImages: [:])
    XCTAssertEqual(try reopened.recipe(id: r.id)?.viewCount, 2)
    XCTAssertEqual(try reopened.recipe(id: r.id)?.cookCount, 1)
    try reopened.deleteCookEntry(entry.id)
    XCTAssertEqual(try reopened.recipe(id: r.id)?.cookCount, 0)
  }
}
