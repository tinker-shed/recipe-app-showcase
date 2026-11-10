import XCTest
@testable import RecipeCore
final class SearchTests: XCTestCase {
  func testAllTidyNotebooksHaveDeliberateDefaults() {
    XCTAssertEqual(CatalogueVocabulary.notebookDefaults.count, 16)
    XCTAssertEqual(CatalogueVocabulary.defaults("Vegetarian Recipes"), ["vegetarian"])
    XCTAssertEqual(CatalogueVocabulary.defaults("Pumpkin Recipes"), [])
    for ids in CatalogueVocabulary.notebookDefaults.values {
      XCTAssertTrue(Set(ids).isSubset(of: Set(CatalogueVocabulary.all.map(\.id))))
    }
  }
  func testSidecarPersistenceSearchSyntaxAndRanking() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("recipe.md")
    try "# Old title\nClementine curry with lemons".write(to: file, atomically: true, encoding: .utf8)
    try ##"{"cleanTitle":"Clementine curry","categories":["thai","fish"],"cuisine":"thai","mainIngredient":"salmon","ingredients":["salmon","lemon","dill","aubergine"],"tags":["#weeknight","one-pan"]}"##.write(to: root.appendingPathComponent("recipe.catalogue.json"), atomically: true, encoding: .utf8)
    var store: LibraryStore? = try LibraryStore(directory: root.appendingPathComponent("Library"))
    XCTAssertEqual(try store!.importURLs([file]).imported, 1)
    store = nil
    let reopened = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let r = try XCTUnwrap(reopened.recipes().first)
    XCTAssertEqual(r.title, "Clementine curry")
    for q in ["salmon lemon dill", "#weeknight", "#one-pan", "\"clementine curry\"", "cuisine:thai", "category:fish", "category:asian", "eggplants", "fish", "lémon -coriander"] {
      XCTAssertNotNil(RecipeSearch.score(r, query: q), q)
    }
    XCTAssertNil(RecipeSearch.score(r, query: "salmon -dill"))
    XCTAssertNil(RecipeSearch.score(r, query: "salmon broccoli"))
    XCTAssertNotNil(RecipeSearch.score(r, query: "salmon broccoli", pantry: true))
    var textMatch = r; textMatch.id = UUID(); textMatch.ingredients = []; textMatch.mainIngredient = nil
    textMatch.blocks = [RecipeBlock(id: 0, kind: .text, text: "salmon")]
    XCTAssertEqual(RecipeSearch.results([textMatch, r], query: "salmon").first?.id, r.id)
    XCTAssertEqual(try reopened.importURLs([file]).skipped, 1)
    XCTAssertEqual(try reopened.recipe(id: r.id)?.tags, ["one-pot", "weeknight"])
  }
}
