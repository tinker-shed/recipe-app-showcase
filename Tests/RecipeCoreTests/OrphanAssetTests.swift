import XCTest
@testable import RecipeCore
final class OrphanAssetTests: XCTestCase {
  func testLaunchRemovesOnlyOldUnreferencedUUIDFolders() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    var store: LibraryStore? = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let assets = store!.assetsDirectory
    let old = Date().addingTimeInterval(-172800)
    func folder(_ name: String = UUID().uuidString, recentChild: Bool = false) throws -> URL {
      let url = assets.appendingPathComponent(name)
      try fm.createDirectory(at: url, withIntermediateDirectories: true)
      let image = url.appendingPathComponent("photo.jpg")
      try ImageTests.photograph().write(to: image)
      if !recentChild { try fm.setAttributes([.modificationDate: old], ofItemAtPath: image.path) }
      try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
      return url
    }
    let abandoned = try folder()
    let fresh = try folder(recentChild: true)
    let nonUUID = try folder("Do not remove")
    var recipe = try store!.createOwn(title: "Retained")
    let shared = try folder()
    let relative = shared.lastPathComponent + "/photo.jpg"
    recipe.assetPaths = [relative]
    recipe.blocks = [RecipeBlock(id: 0, kind: .image, text: "Shared", assetPath: relative)]
    try store!.save(recipe)
    let own = try folder(recipe.id.uuidString)
    let cook = try folder()
    var entry = CookEntry()
    entry.photoPaths = [cook.lastPathComponent + "/photo.jpg"]
    try store!.saveCookEntry(entry, recipeID: recipe.id)
    try store!.setDeleted(recipe.id, deleted: true)
    let link = assets.appendingPathComponent(UUID().uuidString)
    try fm.createSymbolicLink(at: link, withDestinationURL: nonUUID)
    store = nil
    let reopened = try LibraryStore(directory: root.appendingPathComponent("Library"))
    XCTAssertFalse(fm.fileExists(atPath: abandoned.path))
    for retained in [fresh, nonUUID, shared, own, cook, link] { XCTAssertTrue(fm.fileExists(atPath: retained.path), retained.path) }
    XCTAssertTrue(try reopened.removeOldOrphanAssets().isEmpty)
  }
}
