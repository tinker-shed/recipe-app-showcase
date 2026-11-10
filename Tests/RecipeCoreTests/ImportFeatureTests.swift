import XCTest
@testable import RecipeCore
final class ImportFeatureTests: XCTestCase {
  func testSeparateNotesImportIsRepeatableAndAccountsForFailures() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("Notes to import")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "# My journal\nRemember this".write(to: source.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
    try Data([255]).write(to: source.appendingPathComponent("broken.md"))
    let outside = root.appendingPathComponent("outside.md")
    try "# Private".write(to: outside, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("escape.md"), withDestinationURL: outside)
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let report = try store.importURLs([source], asNotes: true)
    XCTAssertEqual(report.imported, 1); XCTAssertEqual(report.notesImported, 1)
    XCTAssertEqual(report.failed, 2); XCTAssertEqual(report.fileCount, 3)
    XCTAssertTrue(try XCTUnwrap(store.recipes().first).isNote)
    let repeated = try store.importURLs([source], asNotes: true)
    XCTAssertEqual(repeated.imported, 0); XCTAssertEqual(repeated.skipped, 1)
    XCTAssertEqual(try store.importURLs([root.appendingPathComponent("absent")]).failed, 1)
  }
}
