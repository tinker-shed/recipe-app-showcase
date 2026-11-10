import Foundation

public struct BatchSuggestion: Decodable, Identifiable {
  public let id: UUID
  public let sourceFile: String
  public let startDate: String?
  public let text: String
  public let reason: String
  public var ingredientWeightGrams: Double?
  public var saltGrams: Double?
  public var saltPercent: Double?
  public var pH: Double?
  public var date: Date? {
    guard let startDate else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    return formatter.date(from: startDate)
  }
  public static func load(_ url: URL) throws -> [BatchSuggestion] {
    struct Envelope: Decodable { let version: Int; let candidates: [BatchSuggestion] }
    let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
    guard envelope.version == 1, Set(envelope.candidates.map(\.id)).count == envelope.candidates.count else { throw CocoaError(.fileReadCorruptFile) }
    return envelope.candidates
  }
  public func entry(date: Date, text: String) -> CookEntry {
    var entry = CookEntry(id: id, date: date, note: text)
    entry.ingredientWeightGrams = ingredientWeightGrams
    entry.saltGrams = saltGrams
    entry.saltPercent = saltPercent
    entry.pH = pH
    return entry
  }
}
