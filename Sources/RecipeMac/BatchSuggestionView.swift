import SwiftUI
import RecipeCore

struct BatchSuggestionView: View {
  @EnvironmentObject var library: LibraryModel
  @Environment(\.dismiss) var dismiss
  @State var candidates: [BatchSuggestion]
  @State private var recipeID: UUID?
  @State private var date = Date()
  @State private var confirmedDate = false
  @State private var text = ""
  @State private var error: String?
  var candidate: BatchSuggestion? { candidates.first }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Review batch suggestions").font(.title2)
      if let candidate {
        Text(candidate.sourceFile).font(.headline)
        Text(candidate.reason).foregroundStyle(.secondary)
        Text("\(candidates.count) awaiting review")
        Picker("Link to recipe", selection: $recipeID) {
          Text("Choose a recipe").tag(Optional<UUID>.none)
          ForEach(library.recipes.filter { !$0.isNote && $0.deletedAt == nil }) { Text($0.title).tag(Optional($0.id)) }
        }
        DatePicker("Started / cooked", selection: $date, displayedComponents: .date)
        Toggle("I have checked the date and batch boundaries", isOn: $confirmedDate)
        HStack {
          TextField("Weight (g)", value: $candidates[0].ingredientWeightGrams, format: .number)
          TextField("Salt (g)", value: $candidates[0].saltGrams, format: .number)
          TextField("Salt %", value: $candidates[0].saltPercent, format: .number)
          TextField("pH", value: $candidates[0].pH, format: .number)
        }
        TextEditor(text: $text)
        HStack {
          Button("Reject suggestion") { candidates.removeFirst(); loadNext() }
          Button("Accept and add to log") {
            guard let recipeID else { return }
            do {
              try library.store?.saveCookEntry(candidate.entry(date: date, text: text), recipeID: recipeID)
              library.refreshRecipe(recipeID); candidates.removeFirst(); loadNext()
            } catch { self.error = error.localizedDescription }
          }.disabled(recipeID == nil || !confirmedDate)
        }
      } else { Text("Review complete. Original notes are unchanged.") }
      HStack { Spacer(); Button("Close") { dismiss() } }
    }.padding(24).frame(width: 650, height: 600)
      .onAppear {
        let accepted = Set(library.recipes.flatMap { ($0.cookHistory ?? []).map(\.id) })
        candidates.removeAll { accepted.contains($0.id) }
        loadNext()
      }
      .alert("Could not add batch", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
  }
  private func loadNext() {
    text = candidate?.text ?? ""
    date = candidate?.date ?? Date()
    confirmedDate = false
    recipeID = nil
  }
}
