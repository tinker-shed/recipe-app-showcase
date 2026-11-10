import CoreGraphics
import XCTest
@testable import RecipeCore

final class PDFTests: XCTestCase {
  func testPDFOnlyNoteSurvivesReopenWithManagedAttachment() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("Notebook")
    let pdf = source.appendingPathComponent("_resources/Spiced_Vegetarian_Cottage_Pie.resources/Spiced Veg Sheps Pie.pdf")
    try FileManager.default.createDirectory(at:pdf.deletingLastPathComponent(),withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    var box = CGRect(x:0,y:0,width:100,height:100)
    let context = try XCTUnwrap(CGContext(pdf as CFURL,mediaBox:&box,nil))
    context.beginPDFPage(nil);context.endPDFPage();context.closePDF()
    let original = try Data(contentsOf:pdf)
    let note = source.appendingPathComponent("Pie.md")
    try "# Pie\nBefore [Original PDF](./_resources/Spiced_Vegetarian_Cottage_Pie.resources/Spiced Veg Sheps Pie.pdf) after\n![[./_resources/Spiced_Vegetarian_Cottage_Pie.resources/Spiced Veg Sheps Pie.pdf]]".write(to:note,atomically:true,encoding:.utf8)
    var store: LibraryStore? = try LibraryStore(directory:root.appendingPathComponent("Library"))
    let report = try store!.importURLs([source]);XCTAssertEqual(report.imported,1);XCTAssertTrue(report.issues.isEmpty)
    let recipe = try XCTUnwrap(store!.recipes().first)
    XCTAssertEqual(recipe.blocks.filter{$0.kind == .pdf}.count,2)
    XCTAssertEqual(recipe.assetPaths.count,1)
    XCTAssertNil(recipe.heroImagePath);XCTAssertNil(recipe.thumbnailPath)
    XCTAssertTrue(recipe.blocks.contains{$0.text == "Before"});XCTAssertTrue(recipe.blocks.contains{$0.text == "after"})
    let block = try XCTUnwrap(recipe.blocks.first{$0.kind == .pdf})
    let saved = try XCTUnwrap(RecipeAttachments.url(for:block,assetsDirectory:store!.assetsDirectory))
    XCTAssertEqual(try Data(contentsOf:saved),original)
    try FileManager.default.removeItem(at:source)
    store = nil
    let reopened = try LibraryStore(directory:root.appendingPathComponent("Library"))
    XCTAssertEqual(try reopened.recipe(id:recipe.id),recipe)
    XCTAssertEqual(CGPDFDocument(saved as CFURL)?.numberOfPages,1)
    XCTAssertNil(RecipeAttachments.url(for:RecipeBlock(id:1,kind:.pdf,text:"bad",assetPath:"../outside.pdf"),assetsDirectory:reopened.assetsDirectory))
  }
  func testMissingAndCorruptPDFsAreReported() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    try Data("not PDF".utf8).write(to:root.appendingPathComponent("bad.pdf"))
    let file = root.appendingPathComponent("Note.md")
    try "# Note\n[[missing.pdf]]\n[bad](bad.pdf)".write(to:file,atomically:true,encoding:.utf8)
    let recipe = try MarkdownImporter.parse(file:file,allowedRoot:root,assetsDirectory:root.appendingPathComponent("Assets"))
    XCTAssertEqual(recipe.warnings.count,2)
    XCTAssertEqual(recipe.blocks.filter{$0.kind == .missingAttachment}.count,2)
    XCTAssertTrue(recipe.assetPaths.isEmpty)
  }
}
