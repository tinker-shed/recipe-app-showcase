import XCTest
@testable import RecipeCore
final class BrowseTests: XCTestCase {
  func testCountsExcludeDeletedAndNamesCannotCollideWithSections() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("one.md")
    try "# Soup".write(to: file, atomically: true, encoding: .utf8)
    var r = try MarkdownImporter.parse(file: file, allowedRoot: root, assetsDirectory: root.appendingPathComponent("Assets"))
    r.collection = "Favourites"
    XCTAssertTrue(LibraryBrowse.matches(r, section: .collection("Favourites")))
    XCTAssertFalse(LibraryBrowse.matches(r, section: .favourites))
    var deleted = r; deleted.id = UUID(); deleted.deletedAt = Date()
    XCTAssertEqual(LibraryBrowse.collections([r, deleted]).first?.count, 1)
    XCTAssertTrue(LibraryBrowse.matches(deleted, section: .deleted))
  }
}
