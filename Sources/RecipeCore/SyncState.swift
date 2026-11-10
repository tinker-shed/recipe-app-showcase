import Foundation

/// Per-device sync bookkeeping, kept beside the library (not in Core Data).
/// Holds this device's stable id, the last successful sync time, and, per recipe, the view count
/// already reported to the other device, so view counts can be summed across devices without
/// double counting.
public struct SyncState: Codable, Equatable, Sendable {
  public var deviceID: UUID
  public var lastSyncAt: Date?
  /// recipe id (as a string) -> this device's viewCount at the last sync.
  public var reportedViewCounts: [String: Int]
  public init(deviceID: UUID = UUID(), lastSyncAt: Date? = nil, reportedViewCounts: [String: Int] = [:]) {
    self.deviceID = deviceID
    self.lastSyncAt = lastSyncAt
    self.reportedViewCounts = reportedViewCounts
  }
  public func reportedViews(_ recipeID: UUID) -> Int { reportedViewCounts[recipeID.uuidString] ?? 0 }
  public mutating func setReportedViews(_ recipeID: UUID, _ value: Int) {
    reportedViewCounts[recipeID.uuidString] = value
  }
}

/// Loads and saves the SyncState file in a library directory. A missing or unreadable file yields a
/// fresh state with a new device id, so a first run just works.
public enum SyncStateStore {
  static func fileURL(in directory: URL) -> URL { directory.appendingPathComponent("sync-state.json") }
  public static func load(in directory: URL) -> SyncState {
    let url = fileURL(in: directory)
    guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(SyncState.self, from: data)
    else { return SyncState() }
    return state
  }
  public static func save(_ state: SyncState, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(state)
    try data.write(to: fileURL(in: directory), options: .atomic)
  }
}
