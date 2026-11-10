import XCTest
@testable import RecipeCore
final class NotesTests: XCTestCase {
  func testTidyNotesFolderWithoutSidecarIsNotARecipeCollection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Notes")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "---\nTitle: Conversion Tables\nOriginal notebook: Useful Notes\n---\n# Conversion Tables\nOne cup is not a fixed weight.".write(to: folder.appendingPathComponent("Conversion Tables.md"), atomically: true, encoding: .utf8)
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let report = try store.importURLs([folder])
    XCTAssertEqual(report.notesImported, 1)
    let records = try store.recipes()
    XCTAssertTrue(try XCTUnwrap(records.first).isNote)
    XCTAssertTrue(LibraryBrowse.collections(records).isEmpty)
  }
  func testNotesAndPersonalNotesPersistAndAreSearchable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Note.md")
    try "# Pickle journal\nRemember the cabbage".write(to: file, atomically: true, encoding: .utf8)
    try #"{"isRecipe":false}"#.write(to: root.appendingPathComponent("Note.catalogue.json"), atomically: true, encoding: .utf8)
    var store: LibraryStore? = try LibraryStore(directory: root.appendingPathComponent("Library"))
    _ = try store!.importURLs([file])
    var note = try XCTUnwrap(store!.recipes().first)
    XCTAssertTrue(note.isNote)
    XCTAssertTrue(LibraryBrowse.matches(note, section: .notes))
    XCTAssertFalse(LibraryBrowse.matches(note, section: .all))
    XCTAssertTrue(LibraryBrowse.collections([note]).isEmpty)
    note.personalNotes = "Next time add juniper"
    try store!.saveEdits(note, newImages: [:])
    _ = try store!.importURLs([file]); store = nil
    let reopened = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let saved = try XCTUnwrap(reopened.recipes().first)
    XCTAssertNotNil(RecipeSearch.score(saved, query: "juniper"))
    XCTAssertNotNil(RecipeSearch.score(saved, query: "cabbage"))
    XCTAssertEqual(saved.markdown, note.markdown)
    XCTAssertEqual(saved.personalNotes, note.personalNotes)
  }
}
