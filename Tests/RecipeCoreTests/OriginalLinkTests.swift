import XCTest
@testable import RecipeCore
final class OriginalLinkTests: XCTestCase {
  func testRemoteLinksStayLinksAndOriginalImagesAreNotHeroesAcrossExport() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try ImageTests.photograph().write(to: source.appendingPathComponent("page.jpg"))
    let text = """
    # Scanned recipe
    [Remote](https://example.com/photo.jpg)
    [PDF](https://example.com/file.pdf)
    ![External](https://example.com/image.png)
    [Protocol relative](//example.com/other.jpg)
    ## Original page
    [Original](page.jpg)
    ## Tips
    Keep the page for reference.
    """
    try text.write(to: source.appendingPathComponent("Scan.md"), atomically: true, encoding: .utf8)
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let report = try store.importURLs([source])
    XCTAssertTrue(report.issues.isEmpty)
    let recipe = try XCTUnwrap(store.recipes().first)
    XCTAssertNil(recipe.heroImagePath); XCTAssertNil(recipe.thumbnailPath)
    XCTAssertEqual(recipe.blocks.filter { $0.kind == .originalImage }.count, 1)
    XCTAssertEqual(recipe.blocks.filter { $0.kind == .text && $0.text.contains("example.com") }.count, 4)
    let view = RecipePresentation(recipe)
    XCTAssertNil(view.hero); XCTAssertEqual(view.originals.count, 1)
    XCTAssertNotNil(RecipeAttachments.url(for: view.originals[0], assetsDirectory: store.assetsDirectory))
    let output = root.appendingPathComponent("Export")
    try LibraryBackup.export(store, to: output)
    let second = try LibraryStore(directory: root.appendingPathComponent("Reimport"))
    _ = try second.importURLs([output.appendingPathComponent("Recipes")])
    let restored = try XCTUnwrap(second.recipes().first)
    XCTAssertNil(restored.heroImagePath)
    XCTAssertEqual(RecipePresentation(restored).originals.count, 1)
  }
  func testMethodPhotographDoesNotBecomeAMainPhotoOrThumbnail() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try ImageTests.photograph().write(to: root.appendingPathComponent("step.jpg"))
    let file = root.appendingPathComponent("Pizza Beans.md")
    try "# Pizza Beans\n## Ingredients\n- Beans\n## Method\n1. Cook.\n![Step](step.jpg)".write(to: file, atomically: true, encoding: .utf8)
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    _ = try store.importURLs([file])
    let recipe = try XCTUnwrap(store.recipes().first)
    XCTAssertNil(recipe.heroImagePath)
    XCTAssertNil(recipe.thumbnailPath)
    XCTAssertNil(RecipePresentation(recipe).hero)
    XCTAssertEqual(RecipePresentation(recipe).body.filter { $0.kind == .image }.count, 1)
  }
  func testLocalLinksBecomeImagesAndOriginalSectionEndsAtNextSection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try ImageTests.photograph().write(to: root.appendingPathComponent("photo.jpg"))
    let file = root.appendingPathComponent("Recipe.md")
    try "# Soup\n[Photo](photo.jpg)\n## Original PDF\n[Scan](photo.jpg)\n## Method\n![Step](photo.jpg)".write(to: file, atomically: true, encoding: .utf8)
    let recipe = try MarkdownImporter.parse(file: file, allowedRoot: root, assetsDirectory: root.appendingPathComponent("Assets"))
    XCTAssertEqual(recipe.blocks.filter { $0.kind == .image }.count, 2)
    XCTAssertEqual(recipe.blocks.filter { $0.kind == .originalImage }.count, 1)
  }
}
