import XCTest
@testable import RecipeCore

final class ResourcePathTests: XCTestCase {
  func testMovedCataloguePathsResolveOnlyBesideNote() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("Vegetarian Recipes")
    // Exact path spellings from the real catalogue, with small synthetic file contents.
    let paths = [
      "_resources/Spiced_Vegetarian_Cottage_Pie.resources/Spiced Veg Sheps Pie.pdf",
      "_resources/PDF_-_cookieandkate.com.resources/cookie-and-kate-welcome-guide-5.pdf",
      "_resources/Beetroot_tatted_tatin_-_Sunday_Telegraph-_10-09-17.resources/Scannable Document on 10 Sep 2017, 17_47_21.png"
    ]
    for path in paths {
      let file = note.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data([1,2,3]).write(to: file)
      for ref in ["./" + path, "Vegaterian Recipes/" + path, "/old/export/Vegaterian Recipes/" + path, "file:///old/export/" + path] {
        XCTAssertEqual(MarkdownImporter.resource(ref, relativeTo: note, allowedRoot: root), file)
      }
    }
    let encoded = paths[0].replacingOccurrences(of: " ", with: "%2520")
    XCTAssertEqual(MarkdownImporter.resource(encoded, relativeTo: note, allowedRoot: root), note.appendingPathComponent(paths[0]))
    XCTAssertNil(MarkdownImporter.resource("https://example.com/" + paths[0], relativeTo: note, allowedRoot: root))
    XCTAssertNil(MarkdownImporter.resource("en-cache://" + paths[0], relativeTo: note, allowedRoot: root))
    XCTAssertNil(MarkdownImporter.resource("old/_resources/../private.pdf", relativeTo: note, allowedRoot: root))
    XCTAssertNil(MarkdownImporter.resource("old/_resources/other.resources/Spiced Veg Sheps Pie.pdf", relativeTo: note, allowedRoot: root))
    let outside = root.appendingPathComponent("outside.pdf")
    try Data([9]).write(to: outside)
    try FileManager.default.createSymbolicLink(at: note.appendingPathComponent("_resources/link.pdf"), withDestinationURL: outside)
    XCTAssertNil(MarkdownImporter.resource("_resources/link.pdf", relativeTo: note, allowedRoot: note))
  }
}
