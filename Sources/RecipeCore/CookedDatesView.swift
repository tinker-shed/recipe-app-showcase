import SwiftUI

public enum CookedPresentation {
  public static func date(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_GB")
    formatter.dateFormat = "d MMM yyyy"
    return formatter.string(from: date)
  }
  public static func summary(_ recipe: Recipe) -> String {
    let count = recipe.cookCount
    return "Cooked \(count) \(count == 1 ? "time" : "times")"
      + (recipe.lastCookedAt.map { " · last on " + date($0) } ?? "")
  }
}

public struct CookedDatesView: View {
  let entries: [CookEntry]
  let remove: (UUID) -> Void
  @Environment(\.dismiss) private var dismiss
  public init(entries: [CookEntry], remove: @escaping (UUID) -> Void) {
    self.entries = entries
    self.remove = remove
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Cooked log").font(.title2)
        Spacer()
        Button("Done") { dismiss() }
      }
      if entries.isEmpty { Text("You haven’t recorded cooking this recipe yet.").foregroundStyle(.secondary) }
      List(entries.sorted { $0.date > $1.date }) { entry in
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 3) {
            Text(CookedPresentation.date(entry.date))
            if let note = entry.note, !note.isEmpty {
              Text(note).font(.callout).foregroundStyle(.secondary)
            }
          }
          Spacer()
          Button("Remove", role: .destructive) { remove(entry.id) }
            .accessibilityLabel("Remove cooked entry for " + CookedPresentation.date(entry.date))
        }
      }
    }.padding(24).frame(minWidth: 280, minHeight: 300)
  }
}
