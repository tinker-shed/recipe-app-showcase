import XCTest
@testable import RecipeCore
final class SearchPerformanceTests: XCTestCase {
  func testCachedThousandRecipeThreeTermSearch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let base = try store.createOwn(title: "Salmon")
    var recipes = (0..<1000).map { number -> Recipe in
      var recipe = base
      recipe.id = UUID(); recipe.title = "Salmon \(number)"; recipe.fingerprint = String(number)
      recipe.ingredients = ["salmon", "lemon", "dill"]
      recipe.blocks = [RecipeBlock(id: 0, kind: .text, text: String(repeating: "Simmer gently and serve with rice. ", count: 50))]
      return recipe
    }
    let index = RecipeSearchIndex(); index.update(recipes)
    let start = Date()
    XCTAssertEqual(index.results(recipes, query: "salmon lemon dill").count, 1000)
    let seconds = Date().timeIntervalSince(start)
    print("SEARCH BENCHMARK: 1000 recipes, 3 terms: \(seconds * 1000) ms")
    #if !DEBUG
    XCTAssertLessThan(seconds, 0.050)
    #endif
    recipes[0].favourite = true; recipes[0].viewCount = 1
    index.update(recipes); XCTAssertEqual(index.normalisationCount, 1000)
    recipes[0].personalNotes = "Juniper berries"
    index.update(recipes); XCTAssertEqual(index.normalisationCount, 1001)
    XCTAssertEqual(index.results(recipes, query: "juniper").map(\.id), [recipes[0].id])
    recipes[0].blocks = [RecipeBlock(id: 0, kind: .text, text: "Coriander")]
    index.update(recipes)
    XCTAssertEqual(index.results(recipes, query: "salmon -coriander").count, 999)
  }
}
