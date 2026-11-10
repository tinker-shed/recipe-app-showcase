import Foundation

/// Moves one sync message (a `Data` blob) at a time. The networking layer provides a real one; tests
/// provide an in-memory one.
public protocol SyncTransport {
  func send(_ data: Data) throws
  func receive() throws -> Data
}

/// Runs the three-step file-exchange over a transport, archiving each bundle to a single blob.
/// Transport-agnostic, so the same logic serves the in-memory tests and the real network connection.
public enum SyncConductor {
  private static func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sync-" + UUID().uuidString)
  }

  /// Mac side of a connection: send our bundle, then receive and apply the phone's return.
  public static func runMacSide(store: LibraryStore, transport: SyncTransport) throws {
    let bundle = tempDir(); defer { try? FileManager.default.removeItem(at: bundle) }
    try SyncFileExchange.exportMacBundle(from: store, to: bundle)
    try transport.send(SyncArchive.archive(bundle))
    let returnDir = tempDir(); defer { try? FileManager.default.removeItem(at: returnDir) }
    try SyncArchive.extract(try transport.receive(), to: returnDir)
    try SyncFileExchange.importPhoneBundle(into: store, from: returnDir)
  }

  /// Phone side: receive and apply the Mac bundle, then send our return.
  public static func runPhoneSide(store: LibraryStore, transport: SyncTransport) throws {
    let macDir = tempDir(); defer { try? FileManager.default.removeItem(at: macDir) }
    try SyncArchive.extract(try transport.receive(), to: macDir)
    let returnDir = tempDir(); defer { try? FileManager.default.removeItem(at: returnDir) }
    try SyncFileExchange.importMacBundle(into: store, from: macDir, writingReturnTo: returnDir)
    try transport.send(SyncArchive.archive(returnDir))
  }
}
