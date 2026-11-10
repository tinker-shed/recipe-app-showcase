import XCTest
@testable import RecipeCore
final class TidyPolicyTests: XCTestCase {
  func testApprovedSetDoesNotMergeDistinctFilesOrQueueReviewButRepeatIsSafe() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("tidy/Soups")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    _ = try ApprovedSetTests.marker(source)
    for name in ["Soup", "Soup.1"] {
      try "# Soup\n- Peas\n1. Simmer.".write(to: source.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8)
      try #"{"isRecipe":true,"confidence":0.7}"#.write(to: source.appendingPathComponent(name + ".catalogue.json"), atomically: true, encoding: .utf8)
    }
    XCTAssertEqual(ImportPolicy.forSelection([source]), .approvedTidy)
    XCTAssertEqual(ImportPolicy.forSelection([root]), .standard)
    let store = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let first = try store.importURLs([source], reviewCatalogue: true, policy: .approvedTidy)
    XCTAssertEqual(first.imported, 2)
    XCTAssertFalse(first.hasPendingReview)
    let repeatRun = try store.importURLs([source], policy: .approvedTidy)
    XCTAssertEqual(repeatRun.skipped, 2)
    XCTAssertEqual(try store.recipes().count, 2)
  }
}
