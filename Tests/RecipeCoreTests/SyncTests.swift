import XCTest
@testable import RecipeCore

final class SyncTests: XCTestCase {
  // MARK: helpers
  private func store() throws -> LibraryStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return try LibraryStore(directory: dir)
  }
  private func recipe(_ id: UUID = UUID(), _ title: String = "Soup", fingerprint: String = "fp") -> Recipe {
    Recipe(id: id, title: title, collection: "Soups", sourceURL: nil, markdown: "# " + title,
      blocks: [], assetPaths: [], warnings: [], fingerprint: fingerprint, importedAt: Date(),
      favourite: false, createdText: nil, updatedText: nil)
  }
  private func date(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

  // MARK: pure merge

  func testFavouriteTieBreak() {
    let t1 = date(100), t2 = date(200)
    // Only one side changed: that change wins.
    XCTAssertEqual(SyncEngine.mergeFavourite((false, nil), (true, t1)).0, true)
    XCTAssertEqual(SyncEngine.mergeFavourite((true, t1), (false, nil)).0, true)
    // Later change wins, both directions.
    XCTAssertEqual(SyncEngine.mergeFavourite((true, t1), (false, t2)).0, false)
    XCTAssertEqual(SyncEngine.mergeFavourite((false, t2), (true, t1)).0, false)
    // Neither changed: keep local.
    XCTAssertEqual(SyncEngine.mergeFavourite((false, nil), (false, nil)).1, nil)
  }

  func testCookUnionAndTombstone() {
    let a = CookEntry(id: UUID(), date: date(1), note: "a")
    let b = CookEntry(id: UUID(), date: date(2), note: "b")
    // Union keeps both.
    XCTAssertEqual(Set(SyncEngine.mergeCookEntries([a], [b]).map(\.id)), [a.id, b.id])
    // A tombstone on either side deletes the entry everywhere.
    var aDeleted = a; aDeleted.deletedAt = date(5)
    XCTAssertNotNil(SyncEngine.mergeCookEntries([a], [aDeleted]).first { $0.id == a.id }?.deletedAt)
    XCTAssertNotNil(SyncEngine.mergeCookEntries([aDeleted], [a]).first { $0.id == a.id }?.deletedAt)
    // Earlier deletion time stands.
    var aDeletedLater = a; aDeletedLater.deletedAt = date(9)
    XCTAssertEqual(SyncEngine.mergeCookEntries([aDeletedLater], [aDeleted]).first { $0.id == a.id }?.deletedAt, date(5))
  }

  func testPhoneMergeMirrorsContentAndSumsViews() {
    let keep = UUID(), gone = UUID(), fresh = UUID()
    var kept = recipe(keep, "Keep"); kept.viewCount = 2
    let local = [RecipeLocalState(recipe: kept, cookEntries: []),
                 RecipeLocalState(recipe: recipe(gone, "Gone"), cookEntries: [])]
    let remote = SyncSnapshot(
      recipes: [recipe(keep, "Keep"), recipe(fresh, "Fresh")],
      activity: [RecipeActivity(recipeID: keep, favourite: true, favouriteChangedAt: date(10), cookEntries: [], viewDelta: 5),
                 RecipeActivity(recipeID: fresh, favourite: false, favouriteChangedAt: nil, cookEntries: [], viewDelta: 3)])
    let plan = SyncEngine.merge(local: local, remote: remote, isPhone: true)
    XCTAssertEqual(Set(plan.upsertRecipes.map(\.id)), [keep, fresh])
    XCTAssertEqual(plan.removeRecipeIDs, [gone])
    XCTAssertEqual(Set(plan.resolvedActivity.map(\.recipeID)), [keep, fresh])
    XCTAssertEqual(plan.resolvedActivity.first { $0.recipeID == keep }?.viewCount, 7)   // 2 local + 5 delta
    XCTAssertEqual(plan.resolvedActivity.first { $0.recipeID == fresh }?.viewCount, 3)  // new recipe
    XCTAssertEqual(plan.resolvedActivity.first { $0.recipeID == keep }?.favourite, true)
  }

  // MARK: end to end, two stores

  func testTwoStoreRoundTripConvergesAndIsIdempotent() throws {
    let mac = try store(), phone = try store()
    let id = UUID()
    try mac.save(recipe(id, "Tomato Pasta"))
    try mac.setFavourite(id, favourite: true)
    try mac.saveCookEntry(CookEntry(date: date(1), note: "mac note"), recipeID: id)
    for _ in 0..<3 { try mac.recordView(id, opening: UUID()) }  // mac viewed 3 times

    var macState = SyncState(), phoneState = SyncState()
    try syncOnce(mac: mac, phone: phone, macState: &macState, phoneState: &phoneState)

    // Phone received content, the favourite, the cook note and the views.
    let onPhone = try XCTUnwrap(phone.recipe(id: id))
    XCTAssertEqual(onPhone.title, "Tomato Pasta")
    XCTAssertTrue(onPhone.favourite)
    XCTAssertEqual(onPhone.cookHistory?.count, 1)
    XCTAssertEqual(onPhone.viewCount, 3)

    // Phone adds its own cook note and views; both converge on the next sync.
    try phone.saveCookEntry(CookEntry(date: date(2), note: "phone note"), recipeID: id)
    for _ in 0..<2 { try phone.recordView(id, opening: UUID()) }  // phone viewed twice
    try mac.recordView(id, opening: UUID())                        // mac viewed once more
    try syncOnce(mac: mac, phone: phone, macState: &macState, phoneState: &phoneState)

    XCTAssertEqual(try XCTUnwrap(mac.recipe(id: id)).cookHistory?.count, 2)
    XCTAssertEqual(try XCTUnwrap(phone.recipe(id: id)).cookHistory?.count, 2)
    XCTAssertEqual(try XCTUnwrap(mac.recipe(id: id)).viewCount, 6)    // 3 + 1 + 2
    XCTAssertEqual(try XCTUnwrap(phone.recipe(id: id)).viewCount, 6)

    // Deleting on the phone propagates to the Mac.
    let phoneEntry = try XCTUnwrap(phone.recipe(id: id)?.cookHistory?.first { $0.note == "phone note" })
    try phone.deleteCookEntry(phoneEntry.id)
    try syncOnce(mac: mac, phone: phone, macState: &macState, phoneState: &phoneState)
    XCTAssertEqual(try XCTUnwrap(mac.recipe(id: id)).cookHistory?.count, 1)
    XCTAssertNil(try XCTUnwrap(mac.recipe(id: id)).cookHistory?.first { $0.note == "phone note" })

    // Idempotent: a further sync with no changes leaves view counts and logs unchanged.
    try syncOnce(mac: mac, phone: phone, macState: &macState, phoneState: &phoneState)
    XCTAssertEqual(try XCTUnwrap(mac.recipe(id: id)).viewCount, 6)
    XCTAssertEqual(try XCTUnwrap(phone.recipe(id: id)).viewCount, 6)
    XCTAssertEqual(try XCTUnwrap(phone.recipe(id: id)).cookHistory?.count, 1)
  }

  /// One sync: both build their snapshot, then both apply the other's.
  private func syncOnce(mac: LibraryStore, phone: LibraryStore, macState: inout SyncState, phoneState: inout SyncState) throws {
    let macSnap = try mac.buildSnapshot(isMac: true, syncState: macState)
    let phoneSnap = try phone.buildSnapshot(isMac: false, syncState: phoneState)
    let phonePlan = SyncEngine.merge(local: try phone.localStates(), remote: macSnap, isPhone: true)
    let macPlan = SyncEngine.merge(local: try mac.localStates(), remote: phoneSnap, isPhone: false)
    try phone.apply(phonePlan, syncState: &phoneState)
    try mac.apply(macPlan, syncState: &macState)
  }
}
