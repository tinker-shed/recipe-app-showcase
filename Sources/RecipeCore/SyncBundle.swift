import Foundation

/// A sync payload on disk: a directory holding a JSON manifest and, for a Mac content bundle, the
/// referenced photo/PDF files under `assets/`. One device writes it, the other reads it. Packaging
/// the directory into a single file to transfer (zip) belongs with the share UI, later.
public enum SyncBundle {
  public static let version = 1

  public struct Manifest: Codable, Equatable, Sendable {
    public var version: Int
    public var isMac: Bool
    public var snapshot: SyncSnapshot
  }

  static func manifestURL(in directory: URL) -> URL { directory.appendingPathComponent("manifest.json") }
  static func assetsURL(in directory: URL) -> URL { directory.appendingPathComponent("assets", isDirectory: true) }

  /// Writes a bundle directory. For a Mac bundle, copies the assets the recipes reference so the
  /// phone can show photos; a phone (activity-only) bundle carries no assets.
  public static func write(_ snapshot: SyncSnapshot, isMac: Bool, assetsDirectory: URL, to directory: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifest = Manifest(version: version, isMac: isMac, snapshot: snapshot)
    try JSONEncoder().encode(manifest).write(to: manifestURL(in: directory), options: .atomic)
    guard isMac else { return }
    let assets = assetsURL(in: directory)
    for path in Set(snapshot.recipes.flatMap(\.assetPaths)) {
      let source = assetsDirectory.appendingPathComponent(path)
      guard fileManager.fileExists(atPath: source.path) else { continue }
      let destination = assets.appendingPathComponent(path)
      try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fileManager.copyItem(at: source, to: destination)
    }
  }

  /// Reads a bundle's manifest.
  public static func read(_ directory: URL) throws -> Manifest {
    try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL(in: directory)))
  }

  /// Copies a bundle's asset files into the importing store, skipping any already present.
  public static func copyAssets(from directory: URL, into assetsDirectory: URL) throws {
    let fileManager = FileManager.default
    let assets = assetsURL(in: directory).standardizedFileURL.resolvingSymlinksInPath()
    guard fileManager.fileExists(atPath: assets.path) else { return }
    let baseComponents = assets.pathComponents
    let enumerator = fileManager.enumerator(at: assets, includingPropertiesForKeys: [.isRegularFileKey])
    while let file = enumerator?.nextObject() as? URL {
      guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
      // Compute the path relative to the bundle's assets root via path components, which is robust to
      // /var vs /private/var symlink differences on macOS.
      let relativeComponents = Array(file.standardizedFileURL.resolvingSymlinksInPath().pathComponents.dropFirst(baseComponents.count))
      guard !relativeComponents.isEmpty else { continue }
      let destination = relativeComponents.reduce(assetsDirectory) { $0.appendingPathComponent($1) }
      guard !fileManager.fileExists(atPath: destination.path) else { continue }
      try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fileManager.copyItem(at: file, to: destination)
    }
  }
}
