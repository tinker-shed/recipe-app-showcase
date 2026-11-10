import XCTest
@testable import RecipeCore
final class OwnRecipeTests: XCTestCase {
  func testOwnRecipePhotoReplacementMetadataAndIndependentVersion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var store: LibraryStore? = try LibraryStore(directory: root)
    var own = try store!.createOwn(title: "My curry")
    own.blocks = [RecipeBlock(id: 0, kind: .text, text: "My method"), RecipeBlock(id: 1, kind: .image, text: "Photo", assetPath: "staged:one")]
    own.tags = ["#One-pan", "#Family Favourite"]
    own.categories = ["indian"]
    let original = try ImageTests.photograph(type: "public.png")
    try store!.saveEdits(own, newImages: ["staged:one": original])
    var saved = try XCTUnwrap(store!.recipe(id: own.id))
    let oldPath = saved.assetPaths[0]
    saved.blocks[1].assetPath = "staged:two"
    let replacement = try ImageTests.photograph(type: "public.jpeg")
    try store!.saveEdits(saved, newImages: ["staged:two": replacement])
    saved = try XCTUnwrap(store!.recipe(id: own.id))
    XCTAssertEqual(try Data(contentsOf: store!.assetsDirectory.appendingPathComponent(saved.assetPaths[0])), replacement)
    XCTAssertEqual(try Data(contentsOf: store!.assetsDirectory.appendingPathComponent(oldPath)), original)
    let version = try store!.createOwn(title: "Variation", copying: saved)
    XCTAssertEqual(version.parentRecipeID, saved.id)
    XCTAssertNotEqual(version.fingerprint, saved.fingerprint)
    XCTAssertTrue(LibraryBrowse.matches(saved, section: .own))
    store = nil
    let reopened = try LibraryStore(directory: root)
    XCTAssertEqual(try reopened.recipe(id: own.id)?.tags, ["family-favourite", "one-pot"])
    XCTAssertEqual(try reopened.recipe(id: own.id)?.categories, ["indian"])
    let note = try reopened.createOwn(title: "Ferment diary", note: true)
    XCTAssertTrue(note.isNote)
  }
}
