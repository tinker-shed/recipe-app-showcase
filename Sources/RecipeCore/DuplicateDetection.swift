import Foundation

public enum DuplicateDetection {
  public static func fingerprint(_ markdown: String) -> String {
    var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
      let end = lines.dropFirst().firstIndex(where: {
        ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces))
      })
    {
      lines.removeFirst(end + 1)
    }
    let normalised = lines.joined(separator: "\n").components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }.joined(separator: " ")
    return MarkdownImporter.digest(Data(normalised.utf8))
  }

  static func filenameFamily(_ path: String) -> String {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let stem = url.deletingPathExtension().lastPathComponent.replacingOccurrences(
      of: #"\.\d+$"#, with: "", options: .regularExpression)
    return url.deletingLastPathComponent().appendingPathComponent(stem).path
  }
}

struct DuplicateRecord {
  let fingerprint: String
  let sourceFile: String?
  let title: String
}

struct DuplicateIndex {
  private var bodies: [String: String] = [:]
  private var filenames: [String: (path: String, title: String)] = [:]

  mutating func insert(_ record: DuplicateRecord) {
    bodies[record.fingerprint] = bodies[record.fingerprint] ?? record.title
    if let path = record.sourceFile {
      let family = DuplicateDetection.filenameFamily(path)
      filenames[family] = filenames[family] ?? (path, record.title)
    }
  }

  func match(_ recipe: Recipe) -> (title: String, reason: String)? {
    if let title = bodies[recipe.contentFingerprint] {
      return (title, "Same recipe body after ignoring front matter and whitespace.")
    }
    if let path = recipe.sourceFile,
      let existing = filenames[DuplicateDetection.filenameFamily(path)], existing.path != path
    {
      return (existing.title, "Numbered copies of the same filename in the same folder.")
    }
    return nil
  }
}
