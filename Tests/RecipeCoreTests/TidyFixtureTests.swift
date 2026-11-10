import CoreGraphics
import XCTest
@testable import RecipeCore

final class TidyFixtureTests: XCTestCase {
  func testTidyRecipePhotosPDFAndNote() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let tidy = root.appendingPathComponent("tidy")
    let resources = tidy.appendingPathComponent("Desserts/_resources/Pecan_Pie")
    let notes = tidy.appendingPathComponent("Notes")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    let main = try ImageTests.photograph()
    try main.write(to: resources.appendingPathComponent("main.jpg"))
    try ImageTests.photograph(type: "public.png").write(to: resources.appendingPathComponent("step.png"))
    var box = CGRect(x: 0, y: 0, width: 100, height: 100)
    let pdf = try XCTUnwrap(CGContext(resources.appendingPathComponent("original.pdf") as CFURL, mediaBox: &box, nil))
    pdf.beginPDFPage(nil); pdf.endPDFPage(); pdf.closePDF()
    let text = """
    ---
    Title: Pecan Pie
    Notebook: Desserts
    Created at: 09-11-2020
    Last updated at: 09-11-2020
    Source URL: https://example.com/pie
    ---
    # Pecan Pie
    ![Pecan Pie](./_resources/Pecan_Pie/main.jpg)
    **Serves:** 8 · **Prep:** 20 mins · **Cook:** 45 mins
    ## Ingredients
    ### Crust
    - 155 g plain flour
    ### Filling
    - 100 g pecans
    ## Method
    1. Make the pastry.
       ![](./_resources/Pecan_Pie/step.png)
    2. Fill and bake.
    ## Tips
    - Leave to cool.
    ## Original PDF
    [Original](./_resources/Pecan_Pie/original.pdf)
    """
    try text.write(to: tidy.appendingPathComponent("Desserts/Pecan Pie.md"), atomically: true, encoding: .utf8)
    try "---\nTitle: Conversion Tables\nOriginal notebook: Useful Notes\n---\n# Conversion Tables\nUseful measures".write(to: notes.appendingPathComponent("Conversion Tables.md"), atomically: true, encoding: .utf8)
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let report = try store.importURLs([tidy])
    XCTAssertEqual(report.imported, 2); XCTAssertEqual(report.notesImported, 1)
    XCTAssertEqual(report.failed, 0); XCTAssertTrue(report.issues.isEmpty)
    let records = try store.recipes()
    let recipe = try XCTUnwrap(records.first { !$0.isNote })
    XCTAssertEqual(recipe.blocks.filter { $0.kind == .image }.count, 2)
    XCTAssertEqual(recipe.blocks.filter { $0.kind == .pdf }.count, 1)
    XCTAssertEqual(recipe.blocks.filter { $0.kind == .step }.count, 2)
    XCTAssertEqual(RecipePresentation.ingredientIDs(recipe).count, 2)
    let mainPath = try XCTUnwrap(recipe.heroImagePath)
    XCTAssertEqual(try Data(contentsOf: store.assetsDirectory.appendingPathComponent(mainPath)), main)
    let presentation = RecipePresentation(recipe)
    XCTAssertEqual(presentation.hero?.assetPath, mainPath)
    XCTAssertEqual(presentation.originals.count, 1)
    XCTAssertEqual(presentation.facts.count, 1)
    let stepIndex = try XCTUnwrap(presentation.body.firstIndex { $0.kind == .step })
    XCTAssertEqual(presentation.body[stepIndex + 1].kind, .image)
    let original = try XCTUnwrap(presentation.originals.first)
    XCTAssertNotNil(RecipeAttachments.url(for: original, assetsDirectory: store.assetsDirectory))
    XCTAssertEqual(recipe.createdText, "09-11-2020")
    XCTAssertEqual(recipe.sourceURL, "https://example.com/pie")
    XCTAssertEqual(records.filter(\.isNote).count, 1)
    XCTAssertEqual(LibraryBrowse.collections(records).count, 1)
  }
}
