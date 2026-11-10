import XCTest
@testable import RecipeCore

final class SyncTransportTests: XCTestCase {
  func testSyncErrorsReadFriendly() {
    // The alert shows localizedDescription; it must be plain English, not "error 1".
    XCTAssertTrue(SyncNetworkError.pairingRejected.localizedDescription.localizedCaseInsensitiveContains("pairing code"))
    for error in [SyncNetworkError.connectionClosed, .pairingRejected, .timedOut] {
      XCTAssertFalse(error.localizedDescription.contains("SyncNetworkError"))
    }
  }
  private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }
  private func store() throws -> LibraryStore { try LibraryStore(directory: tempDir()) }

  func testArchiveRoundTrip() throws {
    let source = tempDir()
    try "manifest".data(using: .utf8)!.write(to: source.appendingPathComponent("manifest.json"))
    let nested = source.appendingPathComponent("assets/abc")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let photo = Data((0..<2048).map { UInt8($0 % 251) })
    try photo.write(to: nested.appendingPathComponent("photo.jpg"))

    let blob = try SyncArchive.archive(source)
    let restored = tempDir().appendingPathComponent("out")
    try SyncArchive.extract(blob, to: restored)

    XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("manifest.json")), "manifest".data(using: .utf8))
    XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("assets/abc/photo.jpg")), photo)
    // A truncated blob is rejected rather than crashing.
    XCTAssertThrowsError(try SyncArchive.extract(blob.prefix(10), to: tempDir().appendingPathComponent("bad")))
  }

  func testLoopbackSyncConvergesOverTheWire() throws {
    let mac = try store(), phone = try store()
    let id = UUID()
    try mac.save(Recipe(id: id, title: "Soup", collection: "Soups", sourceURL: nil, markdown: "# Soup",
      blocks: [], assetPaths: [], warnings: [], fingerprint: "fp", importedAt: Date(),
      favourite: false, createdText: nil, updatedText: nil))
    try mac.setFavourite(id, favourite: true)
    try mac.saveCookEntry(CookEntry(date: Date(timeIntervalSince1970: 1), note: "mac note"), recipeID: id)
    for _ in 0..<2 { try mac.recordView(id, opening: UUID()) }

    let macToPhone = BlockingQueue(), phoneToMac = BlockingQueue()
    let macTransport = LoopbackTransport(outbound: macToPhone, inbound: phoneToMac)
    let phoneTransport = LoopbackTransport(outbound: phoneToMac, inbound: macToPhone)

    let group = DispatchGroup()
    var macError: Error?, phoneError: Error?
    DispatchQueue.global().async(group: group) { do { try SyncConductor.runMacSide(store: mac, transport: macTransport) } catch { macError = error } }
    DispatchQueue.global().async(group: group) { do { try SyncConductor.runPhoneSide(store: phone, transport: phoneTransport) } catch { phoneError = error } }
    XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
    XCTAssertNil(macError); XCTAssertNil(phoneError)

    let onPhone = try XCTUnwrap(phone.recipe(id: id))
    XCTAssertEqual(onPhone.title, "Soup")
    XCTAssertTrue(onPhone.favourite)
    XCTAssertEqual(onPhone.cookHistory?.count, 1)
    XCTAssertEqual(onPhone.viewCount, 2)
  }

  func testNetworkSyncOverLocalhost() throws {
    let mac = try store(), phone = try store()
    let id = UUID()
    try mac.save(Recipe(id: id, title: "Dal", collection: "Asian Cooking", sourceURL: nil, markdown: "# Dal",
      blocks: [], assetPaths: [], warnings: [], fingerprint: "fp", importedAt: Date(),
      favourite: false, createdText: nil, updatedText: nil))
    try mac.setFavourite(id, favourite: true)
    try mac.saveCookEntry(CookEntry(date: Date(timeIntervalSince1970: 1), note: "mac note"), recipeID: id)
    for _ in 0..<2 { try mac.recordView(id, opening: UUID()) }

    let server = SyncServer(store: mac, pairingCode: "123456")
    let macDone = expectation(description: "mac side complete")
    var macError: Error?
    server.onSyncComplete = { error in macError = error; macDone.fulfill() }
    let port = try XCTUnwrap(server.start(advertise: false))  // localhost, no Bonjour
    addTeardownBlock { server.stop() }

    try SyncClient.sync(store: phone, to: .hostPort(host: "127.0.0.1", port: port), pairingCode: "123456")
    wait(for: [macDone], timeout: 15)
    XCTAssertNil(macError)

    let onPhone = try XCTUnwrap(phone.recipe(id: id))
    XCTAssertTrue(onPhone.favourite)
    XCTAssertEqual(onPhone.cookHistory?.count, 1)
    XCTAssertEqual(onPhone.viewCount, 2)
  }

  func testNetworkSyncRejectsWrongPairingCode() throws {
    let mac = try store(), phone = try store()
    let server = SyncServer(store: mac, pairingCode: "111111")
    let port = try XCTUnwrap(server.start(advertise: false))
    addTeardownBlock { server.stop() }
    XCTAssertThrowsError(try SyncClient.sync(store: phone, to: .hostPort(host: "127.0.0.1", port: port), pairingCode: "999999"))
  }
}

/// A thread-safe one-item-at-a-time queue, to pair two transports in-process.
final class BlockingQueue {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var items: [Data] = []
  func put(_ data: Data) { lock.lock(); items.append(data); lock.unlock(); semaphore.signal() }
  func take() -> Data { semaphore.wait(); lock.lock(); defer { lock.unlock() }; return items.removeFirst() }
}

struct LoopbackTransport: SyncTransport {
  let outbound: BlockingQueue
  let inbound: BlockingQueue
  func send(_ data: Data) throws { outbound.put(data) }
  func receive() throws -> Data { inbound.take() }
}
