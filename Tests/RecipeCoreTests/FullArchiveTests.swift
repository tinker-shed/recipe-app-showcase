import XCTest
import CryptoKit
@testable import RecipeCore

final class FullArchiveTests: XCTestCase {
  func testTidyArchiveHasCompleteAccountingAndSafeRepeatImport() throws {
    guard let path = ProcessInfo.processInfo.environment["RECIPEAPP_FULL_ARCHIVE"] else {
      throw XCTSkip("Set RECIPEAPP_FULL_ARCHIVE to validate the tidy archive")
    }
    let source = URL(fileURLWithPath: path)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey])!
    var markdownHashes: [URL: SHA256.Digest] = [:]
    while let url = files.nextObject() as? URL {
      if url.pathExtension == "md" { markdownHashes[url] = SHA256.hash(data: try Data(contentsOf: url)) }
    }
    XCTAssertGreaterThan(markdownHashes.count, 0)
    var store: LibraryStore? = try LibraryStore(directory: root.appendingPathComponent("Library"))
    let report = try store!.importURLs([source], policy: .approvedTidy)
    XCTAssertEqual(report.fileCount, markdownHashes.count)
    XCTAssertEqual(report.fileCount, report.imported + report.skipped + report.failed + report.likelyDuplicates.count)
    XCTAssertEqual(report.failed, 0, report.issues.filter { $0.hasPrefix("Failed:") }.joined(separator: "\n"))
    for candidate in report.likelyDuplicates { _ = try store!.resolveDuplicate(candidate, importCopy: true) }
    XCTAssertTrue(report.catalogueReview.isEmpty)
    XCTAssertTrue(report.likelyDuplicates.isEmpty)
    let records = try store!.recipes()
    let noPhoto = records.filter { !$0.isNote && RecipePresentation($0).hero == nil }.map { $0.collection + "/" + $0.title }.sorted()
    if let output = ProcessInfo.processInfo.environment["RECIPEAPP_TRIAL_REPORT"] {
      let figures: [String: Any] = ["files": report.fileCount, "recipes": records.filter { !$0.isNote }.count,
        "notes": records.filter(\.isNote).count, "failures": report.failed, "warnings": report.issues,
        "noMainPhotoCount": noPhoto.count, "noMainPhoto": noPhoto,
        "notebooks": LibraryBrowse.collections(records).count]
      try JSONSerialization.data(withJSONObject: figures, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
    print("TIDY PHOTOS: \(noPhoto.count) recipes without a main photograph")
    for recipe in records {
      for path in recipe.assetPaths { XCTAssertTrue(FileManager.default.fileExists(atPath: store!.assetsDirectory.appendingPathComponent(path).path)) }
    }
    let repeated = try store!.importURLs([source], policy: .approvedTidy)
    XCTAssertEqual(repeated.imported, 0)
    XCTAssertEqual(repeated.failed, 0)
    XCTAssertEqual(repeated.skipped, report.fileCount)
    store = nil
    let reopened = try LibraryStore(directory: root.appendingPathComponent("Library"))
    XCTAssertEqual(try reopened.recipes().count, records.count)
    for (url, checksum) in markdownHashes { XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: url)), checksum) }
    print("FULL CATALOGUE: \(report.summary); confirmed duplicates skipped: \(report.catalogueSkipped); retained after scratch review: \(records.count); notes: \(records.filter(\.isNote).count); attachment warnings: \(report.issues.count). Repeat: \(repeated.summary)")
  }
}
