import CryptoKit
import CoreGraphics
import Foundation

public enum MarkdownImporter {
  static func match(_ pattern: String, _ text: String) -> [String]? {
    guard let r = try? NSRegularExpression(pattern: pattern),
      let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    return (0..<m.numberOfRanges).map {
      Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? ""
    }
  }
  static func isRemote(_ reference: String) -> Bool {
    var value = reference.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    for _ in 0..<4 {
      if value.hasPrefix("//") { return true }
      if let scheme = URL(string: value)?.scheme, scheme.lowercased() != "file" { return true }
      guard let decoded = value.removingPercentEncoding, decoded != value else { break }
      value = decoded
    }
    return false
  }
  // Split embeds with balanced parentheses, retaining adjacent text and multiple images.
  static func imageSegments(_ line: String) -> [String] {
    let chars = Array(line)
    var segments: [String] = []
    var cursor = 0
    var start = 0
    while cursor + 1 < chars.count {
      guard chars[cursor] == "!", chars[cursor + 1] == "[" else {
        cursor += 1
        continue
      }
      let begin = cursor
      if cursor + 2 < chars.count, chars[cursor + 2] == "[" {
        var end = cursor + 3
        while end + 1 < chars.count && !(chars[end] == "]" && chars[end + 1] == "]") { end += 1 }
        guard end + 1 < chars.count else {
          cursor += 2
          continue
        }
        if begin > start { segments.append(String(chars[start..<begin])) }
        segments.append(String(chars[begin..<(end + 2)]))
        cursor = end + 2
        start = cursor
      } else {
        var close = cursor + 2
        while close < chars.count && chars[close] != "]" { close += 1 }
        guard close + 1 < chars.count, chars[close + 1] == "(" else {
          cursor += 2
          continue
        }
        var end = close + 2
        var depth = 1
        while end < chars.count {
          if chars[end] == "\\" {
            end += 2
            continue
          }
          if chars[end] == "(" { depth += 1 }
          if chars[end] == ")" {
            depth -= 1
            if depth == 0 { break }
          }
          end += 1
        }
        guard depth == 0 else {
          cursor += 2
          continue
        }
        if begin > start { segments.append(String(chars[start..<begin])) }
        let reference = String(chars[(close + 2)..<end])
        // Remote embeds remain clickable text; views never fetch external image bytes.
        segments.append(isRemote(reference) ? String(chars[(begin + 1)..<(end + 1)]) : "![[" + reference + "]]")
        cursor = end + 1
        start = cursor
      }
    }
    if start < chars.count { segments.append(String(chars[start...])) }
    return segments.isEmpty ? [line] : segments
  }
  /// Normal Markdown and wiki PDF links become attachment segments, retaining surrounding text.
  static func attachmentSegments(_ line: String) -> [String] {
    var converted = line
    for pattern in [#"(?<!!)\[\[([^\n]*?\.(?:pdf|jpg|jpeg|png|heic))\]\]"#, #"(?<!!)\[([^\]\n]*)\]\(((?:[^()\n]|\([^()\n]*\))*\.(?:pdf|jpg|jpeg|png|heic))\)"#] {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
      for match in regex.matches(in: converted, range: NSRange(converted.startIndex..., in: converted)).reversed() {
        guard let range = Range(match.range, in: converted),
          let target = Range(match.range(at: match.numberOfRanges - 1), in: converted),
          !isRemote(String(converted[target])) else { continue }
        converted.insert("!", at: range.lowerBound)
      }
    }
    return imageSegments(converted)
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  // Resolve the exact resource suffix beside the note, never a same-named file in another notebook.
  // Exported links can retain an old absolute/notebook prefix after the export is moved.
  static func resource(_ reference: String, relativeTo directory: URL, allowedRoot: URL) -> URL? {
    var path = reference.replacingOccurrences(of: "\\|", with: "|").components(separatedBy: "|")[0]
    if path.hasPrefix("<"), path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
    let root = allowedRoot.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    func existing(_ candidate: URL) -> URL? {
      let url = candidate.resolvingSymlinksInPath().standardizedFileURL
      guard url.path.hasPrefix(root),
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      else { return nil }
      return url
    }
    for _ in 0..<4 {
      // Never reinterpret remote web links or Evernote authentication/cache URLs as local files.
      let local = !path.contains("://") || path.hasPrefix("file://")
      if local {
        if !path.hasPrefix("/"), !path.contains("://"),
          let result = existing(directory.appendingPathComponent(path)) { return result }
        let components = path.components(separatedBy: "/")
        if let anchor = components.firstIndex(of: "_resources") {
          let suffix = Array(components.dropFirst(anchor + 1))
          if !suffix.isEmpty, !suffix.contains(".."), !suffix.contains("."), !suffix.contains("") {
            let resources = directory.appendingPathComponent("_resources", isDirectory: true)
            if let result = existing(resources.appendingPathComponent(suffix.joined(separator: "/"))) {
              return result
            }
          }
        }
      }
      guard let decoded = path.removingPercentEncoding, decoded != path else { break }
      path = decoded
    }
    return nil
  }
  public static func parse(file: URL, allowedRoot: URL, assetsDirectory: URL) throws -> Recipe {
    let resolved = file.resolvingSymlinksInPath().standardizedFileURL
    let rootPath = allowedRoot.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    guard resolved.path.hasPrefix(rootPath) else { throw CocoaError(.fileReadNoPermission) }
    let data = try Data(contentsOf: file)
    guard let markdown = String(data: data, encoding: .utf8) else {
      throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    var metadata: [String: String] = [:]
    var lines = markdown.components(separatedBy: .newlines)
    if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
      let end = lines.dropFirst().firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces) == "---"
      })
    {
      for line in lines[1..<end] {
        if let colon = line.firstIndex(of: ":") {
          metadata[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        }
      }
      lines.removeFirst(end + 1)
    }
    let catalogue = try CatalogueMetadata.load(for: file, allowedRoot: allowedRoot)
    let collection = try CatalogueMetadata.displayLabel(for: file, allowedRoot: allowedRoot)
    let id = UUID()
    let directory = assetsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var blocks: [RecipeBlock] = []
    var assets: [String] = []
    var warnings: [String] = []
    var title = file.deletingPathExtension().lastPathComponent
    var foundTitle = false
    var originalSection = false
    var fingerprintData = data
    var copied: [String: String] = [:]
    do {
      for raw in lines.flatMap(attachmentSegments) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { continue }
        let image =
          match(#"!\[\[(.*?)\]\]"#, line).map { $0[1] }
          ?? match(#"!\[[^\]]*\]\((.*)\)"#, line).map { $0[1] }
        if let reference = image, !isRemote(reference) {
          let referencePath = reference.replacingOccurrences(of: "\\|", with: "|").components(separatedBy: "|")[0]
          let isPDF = referencePath.lowercased().hasSuffix(".pdf")
          if let source = resource(
            reference, relativeTo: file.deletingLastPathComponent(), allowedRoot: allowedRoot)
          {
            if isPDF, CGPDFDocument(source as CFURL)?.numberOfPages ?? 0 == 0 {
              warnings.append("PDF unreadable: \(reference)")
              blocks.append(RecipeBlock(id: blocks.count, kind: .missingAttachment, text: "PDF unreadable"))
              continue
            }
            let bytes = try Data(contentsOf: source)
            let hash = digest(bytes)
            fingerprintData.append(Data(hash.utf8))
            let relative: String
            if let previous = copied[source.path] {
              relative = previous
            } else {
              let ext = source.pathExtension.lowercased()
              let name = "\(hash).\(ext.isEmpty ? "bin" : ext)"
              relative = "\(id.uuidString)/\(name)"
              try bytes.write(to: directory.appendingPathComponent(name), options: .atomic)
              copied[source.path] = relative
              assets.append(relative)
            }
            blocks.append(
              RecipeBlock(id: blocks.count, kind: isPDF ? .pdf : originalSection ? .originalImage : .image, text: reference, assetPath: relative))
          } else {
            warnings.append("\(isPDF ? "PDF" : "Image") unavailable: \(reference)")
            blocks.append(
              RecipeBlock(id: blocks.count, kind: isPDF ? .missingAttachment : .missingImage,
                text: isPDF ? "PDF unavailable" : "Image unavailable"))
          }
          // Keep captions or inline text in the original; nothing is discarded from the archived Markdown.
        } else if let h = match(#"^(#{1,6})\s+(.+)$"#, line) {
          if h[1].count <= 2 {
            originalSection = ["original page", "original pdf"].contains(h[2].lowercased().trimmingCharacters(in: .whitespaces))
          }
          if !foundTitle {
            title = h[2].replacingOccurrences(of: "**", with: "")
            foundTitle = true
          }
          blocks.append(
            RecipeBlock(id: blocks.count, kind: .heading, text: h[2], level: h[1].count))
        } else if let bullet = match(#"^[-*+]\s+(.*)$"#, line) {
          blocks.append(RecipeBlock(id: blocks.count, kind: .bullet, text: bullet[1]))
        } else if let step = match(#"^\d+[.)]\s+(.*)$"#, line) {
          blocks.append(RecipeBlock(id: blocks.count, kind: .step, text: step[1]))
        } else if line != "---" && line != "* * *" {
          blocks.append(RecipeBlock(id: blocks.count, kind: .text, text: line))
        }
      }
      return Recipe(
        id: id, title: catalogue?.cleanTitle?.isEmpty == false ? catalogue!.cleanTitle! : title, collection: collection,
        sourceURL: metadata["source url"], markdown: markdown, blocks: blocks, assetPaths: assets,
        warnings: warnings, fingerprint: digest(fingerprintData), importedAt: Date(),
        favourite: false, createdText: metadata["created at"],
        updatedText: metadata["last updated at"],
        sourceFile: file.standardizedFileURL.path,
        isRecipe: catalogue?.isRecipe,
        categories: CatalogueVocabulary.categories(catalogue?.categories ?? CatalogueVocabulary.defaults(collection)),
        tags: catalogue?.tags.map { Array(Set($0.map(CatalogueVocabulary.tag))).sorted() },
        ingredients: catalogue?.ingredients.map { $0.map(RecipeSearch.normalise) },
        cuisine: catalogue?.cuisine, mainIngredient: catalogue?.mainIngredient,
        catalogueConfidence: catalogue?.confidence)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }
}
