import Foundation

/// What one device sends to the other during a sync.
/// The Mac (source of truth for content) fills `recipes`; the phone leaves it empty. Both fill
/// `activity`, one entry per recipe they know about.
public struct SyncSnapshot: Codable, Equatable, Sendable {
  public var recipes: [Recipe]
  public var activity: [RecipeActivity]
  public init(recipes: [Recipe] = [], activity: [RecipeActivity] = []) {
    self.recipes = recipes
    self.activity = activity
  }
}

/// The two-way-merged part of a recipe: favourite (with its change time for tie-breaking), the cook
/// log including tombstones, and the new views this device recorded since the last sync.
public struct RecipeActivity: Codable, Equatable, Sendable {
  public var recipeID: UUID
  public var favourite: Bool
  public var favouriteChangedAt: Date?
  public var cookEntries: [CookEntry]
  public var viewDelta: Int
  public init(recipeID: UUID, favourite: Bool, favouriteChangedAt: Date?, cookEntries: [CookEntry], viewDelta: Int) {
    self.recipeID = recipeID
    self.favourite = favourite
    self.favouriteChangedAt = favouriteChangedAt
    self.cookEntries = cookEntries
    self.viewDelta = viewDelta
  }
}

/// A device's current state, read locally before merging.
public struct RecipeLocalState: Equatable, Sendable {
  public var recipe: Recipe
  public var cookEntries: [CookEntry]  // includes tombstones
  public init(recipe: Recipe, cookEntries: [CookEntry]) {
    self.recipe = recipe
    self.cookEntries = cookEntries
  }
}

/// The result of a merge: what to change locally.
public struct MergePlan: Equatable, Sendable {
  public var upsertRecipes: [Recipe]            // content to mirror (phone only)
  public var removeRecipeIDs: [UUID]            // recipes the Mac no longer has (phone only)
  public var resolvedActivity: [ResolvedActivity]
  public init(upsertRecipes: [Recipe] = [], removeRecipeIDs: [UUID] = [], resolvedActivity: [ResolvedActivity] = []) {
    self.upsertRecipes = upsertRecipes
    self.removeRecipeIDs = removeRecipeIDs
    self.resolvedActivity = resolvedActivity
  }
}

public struct ResolvedActivity: Equatable, Sendable {
  public var recipeID: UUID
  public var favourite: Bool
  public var favouriteChangedAt: Date?
  public var cookEntries: [CookEntry]  // merged set to write (includes tombstones)
  public var viewCount: Int            // new local view count (old + peer delta)
  public init(recipeID: UUID, favourite: Bool, favouriteChangedAt: Date?, cookEntries: [CookEntry], viewCount: Int) {
    self.recipeID = recipeID
    self.favourite = favourite
    self.favouriteChangedAt = favouriteChangedAt
    self.cookEntries = cookEntries
    self.viewCount = viewCount
  }
}
