import XCTest
@testable import RecipeCore
final class RecipeMemoryTests: XCTestCase {
  func testSingleRecordActivityUpdateLeavesOtherRecordsUnchanged() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let first = try store.createOwn(title: "First")
    let other = try store.createOwn(title: "Other")
    try store.recordView(first.id, opening: UUID())
    try store.setFavourite(first.id, favourite: true)
    try store.saveCookEntry(CookEntry(), recipeID: first.id)
    let updated = try XCTUnwrap(store.recipe(id: first.id))
    let memory = RecipeMemory.updating([first, other], with: [updated])
    XCTAssertEqual(memory.count, 2)
    XCTAssertEqual(memory[1], other)
    XCTAssertEqual(memory[0].viewCount, 1)
    XCTAssertEqual(memory[0].cookCount, 1)
    XCTAssertTrue(memory[0].favourite)
    XCTAssertEqual(RecipeMemory.updating(memory, with: [updated]), memory)
  }
}
