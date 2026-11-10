import XCTest
@testable import RecipeCore

final class SyncBundleTests: XCTestCase {
  private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }
  private func store() throws -> LibraryStore { try LibraryStore(directory: tempDir()) }

  func testFileExchangeRoundTripWithPhotoConvergesAndIsIdempotent() throws {
    let mac = try store(), phone = try store()
    let id = UUID()
    let assetPath = id.uuidString + "/photo.jpg"

    // A Mac recipe with a hero photo on disk.
    let heroURL = mac.assetsDirectory.appendingPathComponent(assetPath)
    try FileManager.default.createDirectory(at: heroURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ImageTests.photograph().write(to: heroURL)
    let recipe = Recipe(
      id: id, title: "Tomato Pasta", collection: "Pasta Dishes", sourceURL: nil, markdown: "# Tomato Pasta",
      blocks: [RecipeBlock(id: 0, kind: .image, text: "photo.jpg", assetPath: assetPath)],
      assetPaths: [assetPath], warnings: [], fingerprint: "fp", importedAt: Date(),
      favourite: false, createdText: nil, updatedText: nil)
    try mac.save(recipe)
    try mac.setFavourite(id, favourite: true)
    try mac.saveCookEntry(CookEntry(date: Date(timeIntervalSince1970: 1), note: "mac note"), recipeID: id)
    for _ in 0..<2 { try mac.recordView(id, opening: UUID()) }

    // Sync 1: Mac -> phone, phone -> Mac.
    try exchange(mac: mac, phone: phone)

    let onPhone = try XCTUnwrap(phone.recipe(id: id))
    XCTAssertEqual(onPhone.title, "Tomato Pasta")
    XCTAssertTrue(onPhone.favourite)
    XCTAssertEqual(onPhone.cookHistory?.count, 1)
    XCTAssertEqual(onPhone.viewCount, 2)
    // The photo was carried over and the thumbnail regenerated.
    XCTAssertTrue(FileManager.default.fileExists(atPath: phone.assetsDirectory.appendingPathComponent(assetPath).path))
    XCTAssertNotNil(onPhone.thumbnailPath)

    // Phone adds activity; sync 2 converges.
    try phone.saveCookEntry(CookEntry(date: Date(timeIntervalSince1970: 2), note: "phone note"), recipeID: id)
    try phone.recordView(id, opening: UUID())
    try exchange(mac: mac, phone: phone)

    XCTAssertEqual(try XCTUnwrap(mac.recipe(id: id)).cookHistory?.count, 2)
    XCTAssertEqual(try XCTUnwrap(phone.recipe(id: id)).cookHistory?.count, 2)
    XCTAssertEqual(try XCTUnwrap(mac.recipe(id: id)).viewCount, 3)   // 2 mac + 1 phone
    XCTAssertEqual(try XCTUnwrap(phone.recipe(id: id)).viewCount, 3)

    // Idempotent: another exchange with no changes leaves counts and logs alone.
    try exchange(mac: mac, phone: phone)
    XCTAssertEqual(try XCTUnwrap(mac.recipe(id: id)).viewCount, 3)
    XCTAssertEqual(try XCTUnwrap(phone.recipe(id: id)).viewCount, 3)
    XCTAssertEqual(try XCTUnwrap(mac.recipe(id: id)).cookHistory?.count, 2)
  }

  private func exchange(mac: LibraryStore, phone: LibraryStore) throws {
    let macBundle = tempDir().appendingPathComponent("mac-bundle")
    let returnBundle = tempDir().appendingPathComponent("phone-bundle")
    try SyncFileExchange.exportMacBundle(from: mac, to: macBundle)
    try SyncFileExchange.importMacBundle(into: phone, from: macBundle, writingReturnTo: returnBundle)
    try SyncFileExchange.importPhoneBundle(into: mac, from: returnBundle)
  }
}
