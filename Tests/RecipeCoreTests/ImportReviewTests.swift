import XCTest
@testable import RecipeCore
final class ImportReviewTests: XCTestCase {
  func testCatalogueReviewIsOrderedAndDoesNotSaveBeforeAcceptance() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("Source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for (title, confidence) in [("A", 0.95), ("B", 0.6)] {
      try "# \(title)\nIngredients for \(title)".write(to: source.appendingPathComponent(title + ".md"), atomically: true, encoding: .utf8)
      try JSONSerialization.data(withJSONObject: ["confidence": confidence]).write(to: source.appendingPathComponent(title + ".catalogue.json"))
    }
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let report = try store.importURLs([source], reviewCatalogue: true)
    XCTAssertEqual(report.imported, 0)
    XCTAssertEqual(report.catalogueReview.map(\.title), ["B", "A"])
    XCTAssertTrue(try store.recipes().isEmpty)
    var accepted = report.catalogueReview[0]
    accepted.title = "Reviewed B"; accepted.tags = ["family"]
    XCTAssertTrue(try store.resolveCatalogue(accepted, accept: true))
    XCTAssertFalse(try store.resolveCatalogue(report.catalogueReview[1], accept: false))
    XCTAssertEqual(try store.recipes().first?.title, "Reviewed B")
    XCTAssertEqual(try store.recipes().first?.tags, ["family"])
    let second = try store.importURLs([source], reviewCatalogue: true)
    XCTAssertEqual(second.skipped, 1)
    XCTAssertEqual(second.catalogueReview.count, 1)
  }
}
