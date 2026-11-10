import CoreData
import ImageIO
import XCTest

@testable import RecipeCore

final class ImageTests: XCTestCase {
  static func photograph(type: String = "public.jpeg") throws -> Data {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 1200, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  func testThumbnailImportAndExistingStoreBackfill() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try Self.photograph()
    try original.write(to: root.appendingPathComponent("photo.jpg"))
    let file = root.appendingPathComponent("Soup.md")
    try "# Soup\n![Photo](photo.jpg)".write(to: file, atomically: true, encoding: .utf8)
    let directory = root.appendingPathComponent("Library")
    var store: LibraryStore? = try LibraryStore(directory: directory)
    XCTAssertEqual(try store!.importURLs([file]).imported, 1)
    try store!.backfillThumbnails()
    let recipe = try XCTUnwrap(store!.recipes().first)
    let path = try XCTUnwrap(recipe.thumbnailPath)
    let thumbnail = store!.assetsDirectory.appendingPathComponent(path)
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(thumbnail as CFURL, nil))
    XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertEqual(image.width, 400)
    XCTAssertEqual(image.height, 200)
    XCTAssertEqual(
      try Data(contentsOf: store!.assetsDirectory.appendingPathComponent(recipe.assetPaths[0])),
      original)
    store = nil
    // Simulate the immediately preceding model, which already had the nullable thumbnail field.
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: LibraryModel.current())
    let persistent = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil,
      at: directory.appendingPathComponent("Store-v2/Library.sqlite"))
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    try context.performAndWait {
      let object = try XCTUnwrap(RecipePersistence.object(id: recipe.id, in: context))
      object.setValue(nil, forKey: "thumbnailPath")
      try context.save()
    }
    try coordinator.remove(persistent)
    try FileManager.default.removeItem(at: thumbnail)
    let reopened = try LibraryStore(directory: directory)
    try reopened.backfillThumbnails()
    XCTAssertEqual(try reopened.recipe(id: recipe.id)?.thumbnailPath, path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnail.path))
  }

  func testAsyncLoadingDownsamplesAndReusesCacheAcrossThousandRequests() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".jpg")
    try Self.photograph().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let loader = RecipeImageLoader()
    let loaded = await loader.image(at: url, maximumPixels: 400)
    let first = try XCTUnwrap(loaded)
    XCTAssertEqual(first.size.width, 400)
    for _ in 0..<1000 {
      let cached = await loader.image(at: url, maximumPixels: 400)
      XCTAssertTrue(first === cached)
    }
    let missing = await loader.image(at: url.appendingPathExtension("missing"))
    XCTAssertNil(missing)
  }
}
