import CoreData
import XCTest

@testable import RecipeCore

final class EditorImageTests: XCTestCase {
  func testEditorKeepsRealFormatsBytesAndMetadataAfterRestart() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Soup.md")
    try "# Soup\n* salt".write(to: file, atomically: true, encoding: .utf8)
    let directory = root.appendingPathComponent("Library")
    var store: LibraryStore? = try LibraryStore(directory: directory)
    _ = try store!.importURLs([file])
    let original = try XCTUnwrap(store!.recipes().first)
    var draft = original
    let formats = [
      ("public.jpeg", "jpg", "image/jpeg"), ("public.png", "png", "image/png"),
      ("com.compuserve.gif", "gif", "image/gif"), ("public.tiff", "tiff", "image/tiff"),
    ]
    var bytes: [String: Data] = [:]
    for (index, format) in formats.enumerated() {
      let key = "staged:\(index)"
      bytes[key] = try ImageTests.photograph(type: format.0)
      draft.blocks.append(
        RecipeBlock(id: index + 10, kind: .image, text: "Misleading filename.png", assetPath: key))
    }
    try store!.saveEdits(draft, newImages: bytes)
    store = nil
    let reopened = try LibraryStore(directory: directory)
    let saved = try XCTUnwrap(reopened.recipe(id: original.id))
    XCTAssertEqual(saved.markdown, original.markdown)
    XCTAssertEqual(saved.assetPaths.count, formats.count)
    for (index, path) in saved.assetPaths.enumerated() {
      XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, formats[index].1)
      XCTAssertEqual(
        try Data(contentsOf: reopened.assetsDirectory.appendingPathComponent(path)),
        bytes["staged:\(index)"])
    }
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: LibraryModel.current())
    let persistent = try coordinator.addPersistentStore(
      ofType: NSSQLiteStoreType, configurationName: nil,
      at: directory.appendingPathComponent("Store-v2/Library.sqlite"))
    defer { try? coordinator.remove(persistent) }
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    try context.performAndWait {
      let request = NSFetchRequest<NSManagedObject>(entityName: "Asset")
      request.sortDescriptors = [NSSortDescriptor(key: "position", ascending: true)]
      let assets = try context.fetch(request)
      for (index, asset) in assets.enumerated() {
        XCTAssertEqual(asset.value(forKey: "mediaType") as? String, formats[index].2)
        XCTAssertEqual(
          asset.value(forKey: "checksum") as? String,
          MarkdownImporter.digest(bytes["staged:\(index)"]!))
      }
    }
    var invalid = saved
    invalid.blocks.append(
      RecipeBlock(id: 99, kind: .image, text: "Broken", assetPath: "staged:broken"))
    XCTAssertThrowsError(
      try reopened.saveEdits(invalid, newImages: ["staged:broken": Data("not an image".utf8)]))
    XCTAssertEqual(try reopened.recipe(id: saved.id), saved)
  }
}
