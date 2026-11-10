import Foundation

public enum ReviewAction { case acceptAll, acceptConfidentCatalogue, rejectAll }
public enum ImportReview {
  public static func requireFinished(_ report: ImportReport?) throws {
    if report?.hasPendingReview == true { throw ReviewError.pending }
  }
  public static func resolve(_ report: inout ImportReport, action: ReviewAction, store: LibraryStore) throws {
    for recipe in report.catalogueReview {
      if case .acceptConfidentCatalogue = action, (recipe.catalogueConfidence ?? 0) < 0.8 { continue }
      let imported = try store.resolveCatalogue(recipe, accept: action != .rejectAll)
      report.catalogueReview.removeAll { $0.id == recipe.id }
      if imported { report.imported += 1; if recipe.isNote { report.notesImported += 1 } }
      else { report.skipped += 1 }
    }
    // Confidence is catalogue confidence, not evidence that a duplicate is a distinct recipe.
    if case .acceptConfidentCatalogue = action { return }
    for candidate in report.likelyDuplicates {
      let imported = try store.resolveDuplicate(candidate, importCopy: action != .rejectAll)
      report.likelyDuplicates.removeAll { $0.id == candidate.id }
      if imported { report.imported += 1; if candidate.recipe.isNote { report.notesImported += 1 } }
      else { report.skipped += 1 }
    }
  }
}
public enum ReviewError: LocalizedError {
  case pending
  public var errorDescription: String? { "Finish or cancel the current review first. Pending items have been kept." }
}
