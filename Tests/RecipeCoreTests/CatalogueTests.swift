import XCTest
@testable import RecipeCore

final class CatalogueTests: XCTestCase {
  func folder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Notebook"), withIntermediateDirectories:true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  func note(_ root: URL, _ name: String, _ text: String) throws -> URL {
    let file = root.appendingPathComponent("Notebook/" + name + ".md")
    try text.write(to:file,atomically:true,encoding:.utf8)
    return file
  }
  func metadata(_ file: URL, _ values: [String:Any]) throws {
    try JSONSerialization.data(withJSONObject:values).write(to:file.deletingPathExtension().appendingPathExtension("catalogue.json"))
  }
  func testConfirmedDuplicateSkippedBeforeAssetsAndSuggestionsRetained() throws {
    let root = try folder()
    _ = try note(root,"Keep","# Keep\n- beans")
    let duplicate = try note(root,"Copy","# Copy\n![[missing.jpg]]")
    try metadata(duplicate,["sourceFile":"Notebook/Copy.md","likelyDuplicateOf":"Notebook/Keep.md","duplicateStatus":"confirmed"])
    let suggested = try note(root,"Suggestion","# Different curry\n- tomatoes")
    try metadata(suggested,["sourceFile":"Notebook/Suggestion.md","likelyDuplicateOf":"Notebook/Keep.md","notes":"Possible duplicate only"])
    let store = try LibraryStore(directory:root.appendingPathComponent("Library"))
    let report = try store.importURLs([root.appendingPathComponent("Notebook")])
    XCTAssertEqual(report.fileCount,3)
    XCTAssertEqual(report.imported,2)
    XCTAssertEqual(report.catalogueSkipped,1)
    XCTAssertTrue(report.issues.isEmpty)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:store.assetsDirectory.path).count,2)
  }
  func testBadDecisionsProduceErrorsRatherThanSilentSkips() throws {
    for target in ["Notebook/Absent.md","../private.md","Notebook/Copy.md"] {
      let root = try folder()
      let copy = try note(root,"Copy","# Copy")
      try metadata(copy,["sourceFile":"Notebook/Copy.md","likelyDuplicateOf":target,"duplicateStatus":"confirmed"])
      let store = try LibraryStore(directory:root.appendingPathComponent("Library"))
      let report = try store.importURLs([copy])
      XCTAssertEqual(report.catalogueSkipped,0)
      XCTAssertEqual(report.imported,0)
      XCTAssertEqual(report.issues.count,1)
    }
  }
  func testLegacyApprovalAndCycleDetection() throws {
    let root = try folder()
    let a = try note(root,"A","# A")
    let b = try note(root,"B","# B")
    try metadata(a,["sourceFile":"Notebook/A.md","likelyDuplicateOf":"Notebook/B.md","notes":"Catalogue review 2026-10-25: Confirmed duplicate of Notebook/B.md."])
    XCTAssertEqual(try CatalogueMetadata.load(for:a,allowedRoot:root)?.keeper(for:a,allowedRoot:root),b)
    try metadata(b,["sourceFile":"Notebook/B.md","likelyDuplicateOf":"Notebook/A.md","duplicateStatus":"confirmed"])
    XCTAssertThrowsError(try CatalogueMetadata.load(for:a,allowedRoot:root)?.keeper(for:a,allowedRoot:root))
    try "{broken".write(to:a.deletingPathExtension().appendingPathExtension("catalogue.json"),atomically:true,encoding:.utf8)
    XCTAssertThrowsError(try CatalogueMetadata.load(for:a,allowedRoot:root))
  }
  func testNotebookLabelsPersistWithoutChangingSourceIdentifier() throws {
    let root = try folder()
    let file = try note(root,"Soup","# Soup")
    try JSONSerialization.data(withJSONObject:["Notebook":"My display label"]).write(to:root.appendingPathComponent("notebook-labels.json"))
    var store: LibraryStore? = try LibraryStore(directory:root.appendingPathComponent("Library"))
    XCTAssertEqual(try store!.importURLs([root]).imported,1)
    let recipe = try XCTUnwrap(store!.recipes().first)
    XCTAssertEqual(recipe.collection,"My display label")
    XCTAssertEqual(recipe.sourceFile,file.path)
    store = nil
    let reopened = try LibraryStore(directory:root.appendingPathComponent("Library"))
    XCTAssertEqual(try reopened.recipe(id:recipe.id)?.collection,"My display label")
    XCTAssertEqual(try CatalogueMetadata.displayLabel(for: root.appendingPathComponent("Deserts/Cake.md"),allowedRoot:root.appendingPathComponent("Deserts")),"Desserts")
    XCTAssertEqual(try CatalogueMetadata.displayLabel(for: root.appendingPathComponent("Vegaterian Recipes/Curry.md"),allowedRoot:root.appendingPathComponent("Vegaterian Recipes")),"Vegetarian Recipes")
    XCTAssertEqual(try CatalogueMetadata.displayLabel(for:file,allowedRoot:file.deletingLastPathComponent()),"Notebook")
  }
}
