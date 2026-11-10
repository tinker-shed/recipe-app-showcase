import Foundation

/// Preview selection is separate from opening a reading session.
public struct RecipeReadingSession {
  public private(set) var recipeID: UUID?
  public init() {}
  public mutating func open(_ id: UUID) -> UUID? {
    guard recipeID != id else { return nil }
    recipeID = id
    return UUID()
  }
  public mutating func close() { recipeID = nil }
}
