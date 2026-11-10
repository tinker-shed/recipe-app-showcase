import XCTest
@testable import RecipeCore

final class UsabilityTests: XCTestCase {
  func testImportedCategoryIDsCountsAndCachedSearchAfterRestart() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for (title, categories) in [("Pea soup", ["soups", "vegetarian"]), ("Korean rice", ["korean", "vegetarian"]), ("Fish pie", ["fish"])] {
      try "# \(title)\n## Ingredients\n- A pinch of salt".write(to: root.appendingPathComponent(title + ".md"), atomically: true, encoding: .utf8)
      try JSONSerialization.data(withJSONObject: ["categories": categories]).write(to: root.appendingPathComponent(title + ".catalogue.json"))
    }
    let directory = root.appendingPathComponent("Library")
    XCTAssertEqual(try LibraryStore(directory: directory).importURLs([root]).imported, 3)
    let store = try LibraryStore(directory: directory)
    let recipes = try store.recipes()
    XCTAssertEqual(recipes.first { $0.title == "Korean rice" }?.categories, ["korean", "vegetarian"])
    let counts = Dictionary(uniqueKeysWithValues: LibraryBrowse.categories(recipes).map { ($0.id, $0.count) })
    XCTAssertEqual(counts["vegetarian"], 2); XCTAssertEqual(counts["soups"], 1)
    XCTAssertEqual(counts["korean"], 1); XCTAssertEqual(counts["asian"], 1)
    XCTAssertNil(counts["desserts"])
    let selected = recipes.filter { CatalogueVocabulary.hasCategory($0, "vegetarian") }
    let index = RecipeSearchIndex()
    // No pre-warming required: newly published records are searchable immediately.
    XCTAssertEqual(index.results(selected, query: "").count, 2)
    XCTAssertEqual(index.results(selected, query: "pea").map(\.title), ["Pea soup"])
    XCTAssertEqual(index.results(recipes, query: "category:korean").map(\.title), ["Korean rice"])
    var edited = try XCTUnwrap(selected.first)
    edited.title = "Fresh courgette dish"
    XCTAssertEqual(index.results([edited], query: "courgette").count, 1)
    var deleted = edited; deleted.deletedAt = Date()
    XCTAssertTrue(LibraryBrowse.categories([deleted]).isEmpty)
  }
  func testEverySortWithAndWithoutSearchAndStableZeroViews() {
    func recipe(_ title: String, views: Int?, days: [Double]) -> Recipe {
      var r = Recipe(id: UUID(), title: title, collection: "Soups", sourceURL: nil, markdown: "", blocks: [], assetPaths: [], warnings: [], fingerprint: title, importedAt: Date(), favourite: false)
      r.viewCount = views
      r.cookHistory = days.map { CookEntry(date: Date(timeIntervalSince1970: $0 * 86400)) }
      return r
    }
    let recipes = [recipe("Z soup", views: 0, days: []), recipe("B soup", views: 10, days: [2]), recipe("A soup", views: nil, days: []), recipe("C soup", views: 2, days: [1, 3])]
    let expected: [RecipeSort: [String]] = [
      .title: ["A soup", "B soup", "C soup", "Z soup"],
      .mostCooked: ["C soup", "B soup", "A soup", "Z soup"],
      .recentlyCooked: ["C soup", "B soup", "A soup", "Z soup"],
      .mostViewed: ["B soup", "C soup", "A soup", "Z soup"],
      .neverCooked: ["A soup", "Z soup"]
    ]
    let index = RecipeSearchIndex()
    for query in ["", "soup"] {
      for sort in RecipeSort.allCases {
        XCTAssertEqual(sort.apply(index.results(recipes, query: query)).map(\.title), expected[sort], "\(sort), \(query)")
      }
    }
  }
  func testReadingSessionCountsOpeningsNotPreviewsOrRedraws() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let recipe = try store.createOwn(title: "Soup")
    var session = RecipeReadingSession()
    XCTAssertNil(session.recipeID)
    XCTAssertEqual(try store.recipe(id: recipe.id)?.viewCount ?? 0, 0)
    let token = try XCTUnwrap(session.open(recipe.id))
    try store.recordView(recipe.id, opening: token)
    try store.recordView(recipe.id, opening: token)
    XCTAssertNil(session.open(recipe.id))
    XCTAssertEqual(try store.recipe(id: recipe.id)?.viewCount, 1)
    session.close()
    let next = try XCTUnwrap(session.open(recipe.id))
    try store.recordView(recipe.id, opening: next)
    XCTAssertEqual(try store.recipe(id: recipe.id)?.viewCount, 2)
  }
  func testKeepScreenOnIsOptInAndCancelledOnLeaving() {
    var state = ScreenAwakeState()
    XCTAssertFalse(state.enabled)
    state.toggle(); XCTAssertTrue(state.enabled)
    state.toggle(); XCTAssertFalse(state.enabled)
    state.toggle(); state.deactivate(); XCTAssertFalse(state.enabled)
    state.deactivate(); XCTAssertFalse(state.enabled)
  }
  func testOneTapCookedDatesPersistAndRemainSearchable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let recipe = try store.createOwn(title: "Soup")
    let old = Calendar.current.date(byAdding: .month, value: -7, to: Date())!
    var legacy = CookEntry(date: old, note: "Preserve this batch")
    legacy.pH = 4; legacy.saltPercent = 2
    try store.saveCookEntry(legacy, recipeID: recipe.id)
    XCTAssertNotNil(RecipeSearch.score(try XCTUnwrap(store.recipe(id: recipe.id)), query: "cooked:>6m"))
    try store.recordCooked(recipe.id)
    let reopened = try LibraryStore(directory: root)
    let saved = try XCTUnwrap(reopened.recipe(id: recipe.id))
    XCTAssertEqual(saved.cookCount, 2)
    XCTAssertTrue(CookedPresentation.summary(saved).hasPrefix("Cooked 2 times · last on "))
    XCTAssertNil(RecipeSearch.score(saved, query: "cooked:never"))
    XCTAssertNil(RecipeSearch.score(saved, query: "cooked:>6m"))
    XCTAssertEqual(saved.cookHistory?.first?.date.timeIntervalSinceNow ?? -100, 0, accuracy: 5)
    XCTAssertNil(saved.cookHistory?.first?.note)
    XCTAssertEqual(saved.cookHistory?.last?.note, legacy.note)
    XCTAssertEqual(saved.cookHistory?.last?.pH, 4)
    try reopened.deleteCookEntry(try XCTUnwrap(saved.cookHistory?.first?.id))
    XCTAssertEqual(try reopened.recipe(id: recipe.id)?.cookCount, 1)
    try reopened.deleteCookEntry(legacy.id)
    XCTAssertNotNil(RecipeSearch.score(try XCTUnwrap(reopened.recipe(id: recipe.id)), query: "cooked:never"))
  }
  func testEditingDraftCancelSavePhotoRemovalAndRestart() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(directory: root)
    let original = try store.createOwn(title: "Soup")
    let photo = try ImageTests.photograph(type: "public.png")
    var draft = original
    draft.title = "Pea soup"; draft.tags = ["family"]; draft.categories = ["soups", "vegetarian"]
    draft.blocks = [RecipeBlock(id: 0, kind: .heading, text: "Soup", level: 1),
      RecipeBlock(id: 1, kind: .image, text: "Dish", assetPath: "staged:main"),
      RecipeBlock(id: 2, kind: .heading, text: "Ingredients", level: 2),
      RecipeBlock(id: 3, kind: .bullet, text: "200 g peas"),
      RecipeBlock(id: 4, kind: .heading, text: "Method", level: 2),
      RecipeBlock(id: 5, kind: .step, text: "Simmer for 10 minutes")]
    // Cancelling a value-type draft does not save text or staged image bytes.
    XCTAssertEqual(try store.recipe(id: original.id), original)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.assetsDirectory.path).isEmpty)
    try store.saveEdits(draft, newImages: ["staged:main": photo])
    let reopened = try LibraryStore(directory: root)
    var saved = try XCTUnwrap(reopened.recipe(id: original.id))
    XCTAssertEqual(saved.title, "Pea soup"); XCTAssertEqual(saved.categories, ["soups", "vegetarian"])
    XCTAssertEqual(saved.tags, ["family"])
    XCTAssertTrue(saved.blocks.contains { $0.text == "200 g peas" })
    XCTAssertTrue(saved.blocks.contains { $0.text == "Simmer for 10 minutes" })
    let oldPhoto = try XCTUnwrap(saved.heroImagePath)
    saved.blocks.removeAll { $0.kind == .image }
    saved.categories = []; saved.tags = []
    try reopened.saveEdits(saved, newImages: [:])
    let final = try XCTUnwrap(LibraryStore(directory: root).recipe(id: original.id))
    XCTAssertNil(final.heroImagePath); XCTAssertNil(final.thumbnailPath)
    XCTAssertTrue((final.categories ?? []).isEmpty); XCTAssertTrue((final.tags ?? []).isEmpty)
    XCTAssertEqual(try Data(contentsOf: reopened.assetsDirectory.appendingPathComponent(oldPhoto)), photo)
    XCTAssertEqual(final.markdown, original.markdown)
  }
  func testPhotolessTilesHaveStableNotebookColoursAndInitials() {
    let soup = RecipeTileAppearance(title: "  Pea soup", notebook: "Soups")
    XCTAssertEqual(soup.initial, "P")
    XCTAssertEqual(soup.paletteIndex, RecipeTileAppearance(title: "Carrot soup", notebook: "Soups").paletteIndex)
    XCTAssertEqual(soup, RecipeTileAppearance(title: "  Pea soup", notebook: "Soups"))
    XCTAssertEqual(RecipeTileAppearance(title: "Éclair", notebook: "Desserts").initial, "É")
    XCTAssertEqual(RecipeTileAppearance(title: "", notebook: "").initial, "?")
    XCTAssertTrue((0..<6).contains(soup.paletteIndex))
  }
}
