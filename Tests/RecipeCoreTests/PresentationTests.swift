import XCTest
@testable import RecipeCore
final class PresentationTests: XCTestCase {
  func testFactsSectionsAndOriginalPageRemainFaithful() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("reference"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([1]).write(to: root.appendingPathComponent("photo.jpg"))
    try Data([2]).write(to: root.appendingPathComponent("reference/page.jpg"))
    let file = root.appendingPathComponent("recipe.md")
    try "# Soup\nServes 4\nPrep time: 10 minutes\n![Photo](photo.jpg)\n## Ingredients\n- ½ tsp salt\n## Method\n1. Simmer\n## Notes\nKeep cool\n[Original page](reference/page.jpg)".write(to: file, atomically: true, encoding: .utf8)
    let r = try MarkdownImporter.parse(file: file, allowedRoot: root, assetsDirectory: root.appendingPathComponent("Assets"))
    let view = RecipePresentation(r)
    XCTAssertEqual(view.facts, ["Serves 4", "Prep time: 10 minutes"])
    XCTAssertNotNil(view.hero)
    XCTAssertEqual(view.originals.count, 1)
    XCTAssertTrue(view.body.contains { $0.text == "½ tsp salt" })
    XCTAssertTrue(view.body.contains { $0.text == "Keep cool" })
    XCTAssertEqual(RecipePresentation.ingredientIDs(r).count, 1)
    XCTAssertNotNil(RecipeAttachments.url(for: view.originals[0], assetsDirectory: root.appendingPathComponent("Assets")))
  }
}
