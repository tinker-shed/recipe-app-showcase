import Foundation
import Network

public enum SyncNetworkError: LocalizedError {
  case connectionClosed, pairingRejected, timedOut
  public var errorDescription: String? {
    switch self {
    case .pairingRejected:
      return "That pairing code did not match. On the Mac, open File ▸ Sync with iPhone to see the code, then enter it again."
    case .connectionClosed:
      return "The connection to the Mac dropped. Make sure the Mac app is open on the same Wi-Fi, then try again."
    case .timedOut:
      return "The Mac did not respond. Make sure the Mac app is open on the same Wi-Fi, then try again."
    }
  }
}

/// The Bonjour service type both sides use to find each other on the local network.
public let recipeSyncServiceType = "_recipesync._tcp"

/// A blocking `SyncTransport` over an NWConnection, framing each message with a 4-byte length prefix.
/// The conductor runs synchronously on a background thread, so send/receive block via semaphores.
public final class ConnectionTransport: SyncTransport {
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "recipe.sync.connection")
  public init(_ connection: NWConnection) { self.connection = connection }

  /// Starts the connection and waits until it is ready (or fails).
  public func start(timeout: TimeInterval = 20) throws {
    let semaphore = DispatchSemaphore(value: 0)
    var failure: Error?
    connection.stateUpdateHandler = { state in
      switch state {
      case .ready: semaphore.signal()
      case .failed(let error): failure = error; semaphore.signal()
      case .cancelled: failure = failure ?? SyncNetworkError.connectionClosed; semaphore.signal()
      default: break
      }
    }
    connection.start(queue: queue)
    guard semaphore.wait(timeout: .now() + timeout) == .success else { connection.cancel(); throw SyncNetworkError.timedOut }
    if let failure { throw failure }
  }

  public func cancel() { connection.cancel() }

  public func send(_ data: Data) throws {
    var frame = Data()
    frame.appendUInt32(UInt32(data.count))
    frame.append(data)
    let semaphore = DispatchSemaphore(value: 0)
    var failure: Error?
    connection.send(content: frame, completion: .contentProcessed { error in failure = error; semaphore.signal() })
    semaphore.wait()
    if let failure { throw failure }
  }

  public func receive() throws -> Data {
    let length = try receiveExactly(4).readUInt32()
    return try receiveExactly(Int(length))
  }

  private func receiveExactly(_ count: Int) throws -> Data {
    var buffer = Data()
    while buffer.count < count {
      let semaphore = DispatchSemaphore(value: 0)
      var chunk: Data?
      var failure: Error?
      var finished = false
      connection.receive(minimumIncompleteLength: 1, maximumLength: count - buffer.count) { data, _, isComplete, error in
        chunk = data; failure = error; finished = isComplete; semaphore.signal()
      }
      semaphore.wait()
      if let failure { throw failure }
      if let chunk, !chunk.isEmpty { buffer.append(chunk) }
      else if finished { throw SyncNetworkError.connectionClosed }
    }
    return buffer
  }
}

/// The Mac side: advertises a Bonjour service and, on each accepted connection, checks the pairing
/// code then runs the Mac side of a sync. A plain TCP connection on the local network for now;
/// wrapping it in TLS with a pre-shared key derived from the pairing code is a planned hardening step.
public final class SyncServer {
  private let store: LibraryStore
  private let pairingCode: String
  private let displayName: String
  private var listener: NWListener?
  public var onSyncComplete: ((Error?) -> Void)?

  public init(store: LibraryStore, pairingCode: String, displayName: String = "Recipe Mac") {
    self.store = store
    self.pairingCode = pairingCode
    self.displayName = displayName
  }

  /// Starts listening. `port` is for tests (localhost); in the app it is omitted and the OS assigns one.
  @discardableResult
  public func start(port: NWEndpoint.Port? = nil, advertise: Bool = true) throws -> NWEndpoint.Port? {
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    let listener: NWListener = try port.map { try NWListener(using: parameters, on: $0) } ?? NWListener(using: parameters)
    if advertise { listener.service = NWListener.Service(name: displayName, type: recipeSyncServiceType) }
    listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.start(queue: .global())
    self.listener = listener
    _ = ready.wait(timeout: .now() + 10)
    return listener.port
  }

  public func stop() { listener?.cancel(); listener = nil }

  private func handle(_ connection: NWConnection) {
    DispatchQueue.global().async { [store, pairingCode, onSyncComplete] in
      let transport = ConnectionTransport(connection)
      var result: Error?
      do {
        try transport.start()
        let offered = String(data: try transport.receive(), encoding: .utf8)
        guard offered == pairingCode else {
          try? transport.send(Data("no".utf8)); transport.cancel()
          onSyncComplete?(SyncNetworkError.pairingRejected); return
        }
        try transport.send(Data("ok".utf8))
        try SyncConductor.runMacSide(store: store, transport: transport)
        try transport.send(Data("done".utf8))  // let the phone close only once we have applied its return
      } catch { result = error }
      transport.cancel()
      onSyncComplete?(result)
    }
  }
}

/// A Mac found on the local network, offered to the phone for syncing.
public struct DiscoveredMac: Identifiable, Equatable, Sendable {
  public let name: String
  public let endpoint: NWEndpoint
  public var id: String { name }
}

/// Finds Macs advertising the sync service on the local network. Results arrive on the main queue.
public final class SyncBrowser {
  private var browser: NWBrowser?
  public init() {}
  public func start(_ onChange: @escaping ([DiscoveredMac]) -> Void) {
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    let browser = NWBrowser(for: .bonjour(type: recipeSyncServiceType, domain: nil), using: parameters)
    browser.browseResultsChangedHandler = { results, _ in
      // The same Mac can appear on more than one interface (Wi-Fi and peer-to-peer),
      // so keep one entry per name.
      var seen = Set<String>()
      let macs: [DiscoveredMac] = results.compactMap { result in
        guard case let .service(name, _, _, _) = result.endpoint, seen.insert(name).inserted else { return nil }
        return DiscoveredMac(name: name, endpoint: result.endpoint)
      }
      DispatchQueue.main.async { onChange(macs.sorted { $0.name < $1.name }) }
    }
    browser.start(queue: .global())
    self.browser = browser
  }
  public func stop() { browser?.cancel(); browser = nil }
}

/// The phone side: connect to a discovered endpoint, prove the pairing code, then run the phone side.
public enum SyncClient {
  public static func sync(store: LibraryStore, to endpoint: NWEndpoint, pairingCode: String) throws {
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    let connection = NWConnection(to: endpoint, using: parameters)
    let transport = ConnectionTransport(connection)
    defer { transport.cancel() }
    try transport.start()
    try transport.send(Data(pairingCode.utf8))
    guard String(data: try transport.receive(), encoding: .utf8) == "ok" else { throw SyncNetworkError.pairingRejected }
    try SyncConductor.runPhoneSide(store: store, transport: transport)
    _ = try? transport.receive()  // wait for the Mac's "done" so it finishes applying before we close
  }
}
