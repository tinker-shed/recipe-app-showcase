import Foundation

public enum ImportPolicy {
  case standard, approvedTidy

  public static func forSelection(_ urls: [URL]) -> ImportPolicy {
    !urls.isEmpty && urls.allSatisfy { url in
      let directory = url.pathExtension.lowercased() == "md" ? url.deletingLastPathComponent() : url
      return ApprovedRecipeSet.load(at: directory) != nil
    } ? .approvedTidy : .standard
  }
}

struct ApprovedRecipeSet {
  struct Marker: Codable {
    let schemaVersion: Int
    let setId: UUID
    let name: String
    let createdAt: String
    let fileCount: Int
  }
  let marker: Marker
  let root: URL

  static func load(at directory: URL) -> Self? {
    let root = directory.resolvingSymlinksInPath().standardizedFileURL
    let file = root.appendingPathComponent(".recipeapp-set.json")
    guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
      values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 65536,
      let data = try? Data(contentsOf: file), let marker = try? JSONDecoder().decode(Marker.self, from: data),
      marker.schemaVersion == 1, marker.fileCount >= 0,
      !marker.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let date = DateFormatter()
    date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
    date.dateFormat = "yyyy-MM-dd"; date.isLenient = false
    guard let created = date.date(from: marker.createdAt), date.string(from: created) == marker.createdAt else { return nil }
    return Self(marker: marker, root: root)
  }

  /// Never discover approval outside the folder the user selected.
  static func containing(_ file: URL, within selection: URL) -> Self? {
    let boundary = selection.resolvingSymlinksInPath().standardizedFileURL
    var directory = file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
    while directory == boundary || directory.path.hasPrefix(boundary.path + "/") {
      let marker = directory.appendingPathComponent(".recipeapp-set.json")
      // An invalid nested marker is a boundary, not permission to inherit another set's approval.
      if FileManager.default.fileExists(atPath: marker.path) { return load(at: directory) }
      if directory == boundary { break }
      directory.deleteLastPathComponent()
    }
    return nil
  }

  func relativePath(_ file: URL) -> String? {
    let path = file.standardizedFileURL.path
    let prefix = root.path + "/"
    guard path.hasPrefix(prefix) else { return nil }
    return String(path.dropFirst(prefix.count))
  }
}

struct ApprovedRecipeIdentity: Hashable {
  let setId: UUID
  let relativePath: String
}
