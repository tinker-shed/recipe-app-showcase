import AppKit
import SwiftUI
import RecipeCore

struct CookHistoryView: View {
  @EnvironmentObject var library: LibraryModel
  @Environment(\.dismiss) var dismiss
  let recipeID: UUID
  @State private var entry: CookEntry
  @State private var images: [String: Data] = [:]
  @State private var error: String?
  init(recipeID: UUID, entry: CookEntry = CookEntry()) {
    self.recipeID = recipeID
    _entry = State(initialValue: entry)
  }
  var history: [CookEntry] { library.recipes.first { $0.id == recipeID }?.cookHistory ?? [] }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Cooking and batch log").font(.title2)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          DatePicker("Cooked / started", selection: $entry.date, displayedComponents: .date)
          Toggle("Record a finish date", isOn: Binding(get: { entry.finishedAt != nil }, set: { entry.finishedAt = $0 ? max(Date(), entry.date) : nil }))
          if entry.finishedAt != nil {
            DatePicker("Finished", selection: Binding(get: { entry.finishedAt ?? entry.date }, set: { entry.finishedAt = $0 }), displayedComponents: .date)
          }
          Text("Notes")
          TextEditor(text: Binding(get: { entry.note ?? "" }, set: { entry.note = $0 })).frame(height: 80)
          HStack {
            TextField("Ingredient weight (g)", value: $entry.ingredientWeightGrams, format: .number)
            TextField("Salt (g)", value: $entry.saltGrams, format: .number)
          }
          HStack {
            TextField("Override salt %", value: $entry.saltPercent, format: .number)
            TextField("pH", value: $entry.pH, format: .number)
            Picker("Rating", selection: $entry.rating) {
              Text("None").tag(Optional<Int>.none)
              ForEach(1...5, id: \.self) { Text("\($0)").tag(Optional($0)) }
            }
          }
          if let percent = entry.effectiveSaltPercent { Text("Salt: \(percent, specifier: "%.1f")%") }
          Button("Add batch photos…", action: addPhotos)
          ForEach(entry.photoPaths ?? [], id: \.self) { path in
            HStack {
              if let bytes = images[path], let image = NSImage(data: bytes) { Image(nsImage: image).resizable().scaledToFit().frame(height: 100) }
              else { RecipeImage(path: path, height: 100) }
              Button("Remove photo") { entry.photoPaths?.removeAll { $0 == path } }
            }
          }
          Button("Save log entry") {
            do {
              try library.store?.saveCookEntry(entry, recipeID: recipeID, newImages: images)
              library.refreshRecipe(recipeID); entry = CookEntry(); images = [:]
            } catch { self.error = error.localizedDescription }
          }.buttonStyle(.borderedProminent)
          Divider()
          ForEach(history) { item in
            HStack {
              VStack(alignment: .leading) {
                Text(item.date.formatted(date: .abbreviated, time: .omitted)).font(.headline)
                if let finish = item.finishedAt { Text("Finished " + finish.formatted(date: .abbreviated, time: .omitted)) }
                if let salt = item.effectiveSaltPercent { Text("\(salt, specifier: "%.1f")% salt") }
                if let pH = item.pH { Text("pH \(pH, specifier: "%.1f")") }
                if let note = item.note { Text(note).foregroundStyle(.secondary) }
              }
              Spacer()
              Button("Edit") { entry = item; images = [:] }
              Button("Remove", role: .destructive) {
                do { try library.store?.deleteCookEntry(item.id); library.refreshRecipe(recipeID) }
                catch { self.error = error.localizedDescription }
              }
            }.padding(.vertical, 8)
          }
        }
      }
      HStack { Spacer(); Button("Done") { dismiss() } }
    }.padding(24).frame(width: 620, height: 650)
      .alert("Could not save log", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
  }
  private func addPhotos() {
    let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    do {
      for url in panel.urls {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let bytes = try Data(contentsOf: url)
        _ = try RecipeImages.fileExtension(for: bytes)
        let key = "staged:" + UUID().uuidString
        images[key] = bytes
        entry.photoPaths = (entry.photoPaths ?? []) + [key]
      }
    } catch { self.error = error.localizedDescription }
  }
}

struct BatchLogView: View {
  @EnvironmentObject var library: LibraryModel
  let query: String
  @State private var year = ""
  @State private var category = ""
  @State private var editing: BatchRow?
  struct BatchRow: Identifiable {
    let recipe: Recipe
    let entry: CookEntry
    var id: UUID { entry.id }
  }
  var entries: [BatchRow] {
    library.recipes.filter { $0.deletedAt == nil }.flatMap { recipe in
      (recipe.cookHistory ?? []).map { BatchRow(recipe: recipe, entry: $0) }
    }.filter {
      (year.isEmpty || String(Calendar.current.component(.year, from: $0.entry.date)) == year)
        && (category.isEmpty || CatalogueVocabulary.hasCategory($0.recipe, category))
        && (query.isEmpty || ($0.recipe.title + " " + ($0.entry.note ?? "")).localizedCaseInsensitiveContains(query))
    }.sorted { $0.entry.date > $1.entry.date }
  }
  var body: some View {
    VStack {
      TextField("Filter by year", text: $year).padding(.horizontal)
      Picker("Category", selection: $category) {
        Text("All categories").tag("")
        ForEach(CatalogueVocabulary.all) { Text($0.name).tag($0.id) }
      }.padding(.horizontal)
      List(entries) { row in
        Button {
          editing = row
        } label: {
          VStack(alignment: .leading) {
            Text(row.recipe.title).font(.headline)
            Text(row.entry.date.formatted(date: .abbreviated, time: .omitted))
            Text(row.entry.note ?? "").lineLimit(3)
          }
        }.buttonStyle(.plain)
      }
    }.sheet(item: $editing) { row in CookHistoryView(recipeID: row.recipe.id, entry: row.entry).environmentObject(library) }
  }
}
