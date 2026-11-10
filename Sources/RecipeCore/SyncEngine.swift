import Foundation

/// The pure two-way merge. No store or network: it takes the local state and the peer's snapshot
/// and returns the changes to apply locally. The Mac owns content (mirrored to the phone); the three
/// activity fields merge both ways.
public enum SyncEngine {
  /// Later change wins; a side that never changed its favourite does not override one that did.
  public static func mergeFavourite(_ local: (Bool, Date?), _ remote: (Bool, Date?)) -> (Bool, Date?) {
    switch (local.1, remote.1) {
    case (nil, nil): return local
    case (_, nil): return local
    case (nil, _): return remote
    case let (localAt?, remoteAt?): return remoteAt > localAt ? remote : local
    }
  }

  /// Union of both logs by entry id. A deletion (tombstone) wins; if both deleted, the earlier time stands.
  public static func mergeCookEntries(_ local: [CookEntry], _ remote: [CookEntry]) -> [CookEntry] {
    var byID: [UUID: CookEntry] = [:]
    for entry in local { byID[entry.id] = entry }
    for entry in remote {
      guard var existing = byID[entry.id] else { byID[entry.id] = entry; continue }
      switch (existing.deletedAt, entry.deletedAt) {
      case (nil, let other?): existing.deletedAt = other
      case (let mine?, let other?) where other < mine: existing.deletedAt = other
      default: break
      }
      byID[entry.id] = existing
    }
    return Array(byID.values)
  }

  /// Build the plan to apply locally. `isPhone` mirrors the Mac's content; the Mac side changes only activity.
  public static func merge(local: [RecipeLocalState], remote: SyncSnapshot, isPhone: Bool) -> MergePlan {
    var plan = MergePlan()
    let localByID = Dictionary(local.map { ($0.recipe.id, $0) }, uniquingKeysWith: { first, _ in first })
    let remoteActivity = Dictionary(remote.activity.map { ($0.recipeID, $0) }, uniquingKeysWith: { first, _ in first })

    var ids = Set(localByID.keys).union(remoteActivity.keys)
    if isPhone {
      let remoteIDs = Set(remote.recipes.map(\.id))
      plan.upsertRecipes = remote.recipes
      plan.removeRecipeIDs = localByID.keys.filter { !remoteIDs.contains($0) }
      ids.formUnion(remoteIDs)
      // A recipe removed on the Mac has no activity to resolve.
      ids.subtract(plan.removeRecipeIDs)
    }

    for id in ids {
      let localState = localByID[id]
      let localFav = localState.map { ($0.recipe.favourite, $0.recipe.favouriteChangedAt) } ?? (false, nil)
      let localCook = localState?.cookEntries ?? []
      let localViews = localState?.recipe.viewCount ?? 0
      let peer = remoteActivity[id]
      let favourite = peer.map { mergeFavourite(localFav, ($0.favourite, $0.favouriteChangedAt)) } ?? localFav
      let cook = peer.map { mergeCookEntries(localCook, $0.cookEntries) } ?? localCook
      let views = localViews + (peer?.viewDelta ?? 0)
      plan.resolvedActivity.append(
        ResolvedActivity(recipeID: id, favourite: favourite.0, favouriteChangedAt: favourite.1, cookEntries: cook, viewCount: views))
    }
    return plan
  }
}
