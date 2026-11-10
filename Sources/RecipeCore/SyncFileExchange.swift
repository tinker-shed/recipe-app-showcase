import Foundation

/// Drives a full sync as three file steps, no networking. Each step persists the device's SyncState
/// beside its library. Order matters for the view-count deltas: the phone snapshots its own activity
/// before it applies the Mac's, so each device only ever reports its own new views.
///
///   1. Mac:   exportMacBundle   -> a Mac bundle (content + assets + Mac activity)
///   2. Phone: importMacBundle   -> applies it, returns a phone bundle (activity only)
///   3. Mac:   importPhoneBundle -> applies the phone's activity
public enum SyncFileExchange {
  /// Step 1 (Mac): write the bundle the phone will import. Does not change the Mac yet.
  public static func exportMacBundle(from store: LibraryStore, to directory: URL) throws {
    let state = SyncStateStore.load(in: store.directory)
    let snapshot = try store.buildSnapshot(isMac: true, syncState: state)
    try SyncBundle.write(snapshot, isMac: true, assetsDirectory: store.assetsDirectory, to: directory)
  }

  /// Step 2 (phone): apply the Mac bundle and write the phone's activity bundle for the Mac to import.
  public static func importMacBundle(into store: LibraryStore, from macBundle: URL, writingReturnTo returnBundle: URL) throws {
    var state = SyncStateStore.load(in: store.directory)
    // Snapshot the phone's own activity BEFORE applying the Mac's, so view deltas are not double counted.
    let outgoing = try store.buildSnapshot(isMac: false, syncState: state)
    let incoming = try SyncBundle.read(macBundle).snapshot
    try SyncBundle.copyAssets(from: macBundle, into: store.assetsDirectory)
    var plan = SyncEngine.merge(local: try store.localStates(), remote: incoming, isPhone: true)
    // Thumbnails are regenerated locally from the copied hero photo.
    plan.upsertRecipes = plan.upsertRecipes.map { var recipe = $0; recipe.thumbnailPath = nil; return recipe }
    try store.apply(plan, syncState: &state)
    try SyncStateStore.save(state, in: store.directory)
    try SyncBundle.write(outgoing, isMac: false, assetsDirectory: store.assetsDirectory, to: returnBundle)
  }

  /// Step 3 (Mac): apply the phone's activity bundle.
  public static func importPhoneBundle(into store: LibraryStore, from returnBundle: URL) throws {
    var state = SyncStateStore.load(in: store.directory)
    let incoming = try SyncBundle.read(returnBundle).snapshot
    var plan = SyncEngine.merge(local: try store.localStates(), remote: incoming, isPhone: false)
    plan.upsertRecipes = []  // the Mac owns content; a phone bundle never changes it
    try store.apply(plan, syncState: &state)
    try SyncStateStore.save(state, in: store.directory)
  }
}
