import Foundation

/// Packs a bundle directory into a single `Data` blob and back, so a transport can move it as one
/// message. A tiny length-framed format (no dependencies), symmetric across macOS and iOS.
///
///   magic "RSYA" (4) | version (1) | entryCount (UInt32 LE)
///   per entry: pathLength (UInt32 LE) | path (UTF-8) | dataLength (UInt64 LE) | data
public enum SyncArchive {
  enum ArchiveError: Error { case malformed }
  static let magic = Data("RSYA".utf8)
  static let version: UInt8 = 1

  public static func archive(_ directory: URL) throws -> Data {
    let fileManager = FileManager.default
    let base = directory.standardizedFileURL.resolvingSymlinksInPath()
    var files: [(path: String, url: URL)] = []
    let enumerator = fileManager.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = enumerator?.nextObject() as? URL {
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
      let components = Array(url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.dropFirst(base.pathComponents.count))
      files.append((components.joined(separator: "/"), url))
    }
    files.sort { $0.path < $1.path }  // stable order so archives are reproducible

    var out = Data()
    out.append(magic)
    out.append(version)
    out.appendUInt32(UInt32(files.count))
    for file in files {
      let path = Data(file.path.utf8)
      out.appendUInt32(UInt32(path.count))
      out.append(path)
      let bytes = try Data(contentsOf: file.url)
      out.appendUInt64(UInt64(bytes.count))
      out.append(bytes)
    }
    return out
  }

  public static func extract(_ data: Data, to directory: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    var cursor = data.startIndex
    func take(_ count: Int) throws -> Data {
      guard count >= 0, data.index(cursor, offsetBy: count, limitedBy: data.endIndex) != nil, cursor + count <= data.endIndex else { throw ArchiveError.malformed }
      let slice = data.subdata(in: cursor..<(cursor + count))
      cursor += count
      return slice
    }
    guard try take(4) == magic, try take(1).first == version else { throw ArchiveError.malformed }
    let count = try take(4).readUInt32()
    for _ in 0..<count {
      let pathLength = Int(try take(4).readUInt32())
      guard let path = String(data: try take(pathLength), encoding: .utf8), !path.hasPrefix("/"), !path.contains("..") else { throw ArchiveError.malformed }
      let dataLength = Int(try take(8).readUInt64())
      let bytes = try take(dataLength)
      let destination = path.split(separator: "/").reduce(directory) { $0.appendingPathComponent(String($1)) }
      try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try bytes.write(to: destination, options: .atomic)
    }
  }
}

extension Data {
  mutating func appendUInt32(_ value: UInt32) { for i in 0..<4 { append(UInt8((value >> (8 * UInt32(i))) & 0xFF)) } }
  mutating func appendUInt64(_ value: UInt64) { for i in 0..<8 { append(UInt8((value >> (8 * UInt64(i))) & 0xFF)) } }
  func readUInt32() -> UInt32 {
    var value: UInt32 = 0
    for (i, byte) in enumerated() where i < 4 { value |= UInt32(byte) << (8 * UInt32(i)) }
    return value
  }
  func readUInt64() -> UInt64 {
    var value: UInt64 = 0
    for (i, byte) in enumerated() where i < 8 { value |= UInt64(byte) << (8 * UInt64(i)) }
    return value
  }
}
