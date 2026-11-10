import XCTest
@testable import RecipeCore
final class PendingReviewTests: XCTestCase {
  func testSecondImportCannotDiscardThreeQueuedItemsAndBulkReviewKeepsLowConfidence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("Source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<3 {
      try "# Recipe \(index)\nContent \(index)".write(to: source.appendingPathComponent("\(index).md"), atomically: true, encoding: .utf8)
      try JSONSerialization.data(withJSONObject: ["confidence": index == 0 ? 0.7 : 0.8]).write(to: source.appendingPathComponent("\(index).catalogue.json"))
    }
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    var report = try store.importURLs([source], reviewCatalogue: true)
    let ids = report.catalogueReview.map(\.id)
    XCTAssertEqual(ids.count, 3)
    XCTAssertThrowsError(try ImportReview.requireFinished(report))
    XCTAssertEqual(report.catalogueReview.map(\.id), ids)
    for id in ids { XCTAssertTrue(FileManager.default.fileExists(atPath: store.assetsDirectory.appendingPathComponent(id.uuidString).path)) }
    try ImportReview.resolve(&report, action: .acceptConfidentCatalogue, store: store)
    XCTAssertEqual(report.imported, 2); XCTAssertEqual(report.catalogueReview.count, 1)
    XCTAssertThrowsError(try ImportReview.requireFinished(report))
    try ImportReview.resolve(&report, action: .acceptAll, store: store)
    XCTAssertNoThrow(try ImportReview.requireFinished(report))
    XCTAssertEqual(try store.recipes().count, 3)
  }
}
