import AppKit
import RecipeCore
import SwiftUI

@main
struct RecipeApplication: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var library = LibraryModel()
  var body: some Scene {
    WindowGroup("RecipeApp") {
      LibraryView().environmentObject(library).frame(minWidth: 700, minHeight: 500)
        .background(BrowserWindowSizing())
    }
    .windowResizability(.automatic)
    // A recipe opened from the list gets its own window; opening the same recipe again
    // brings its existing window forward rather than duplicating it.
    WindowGroup("Recipe", for: UUID.self) { $recipeID in
      RecipeWindow(recipeID: recipeID).environmentObject(library).frame(minWidth: 480, minHeight: 400)
    }
    .windowResizability(.automatic)
    Settings { LibrarySettingsView().environmentObject(library) }
    .commands {
      // Replace the default New menu (and its ⌘N "New Window") with our own items.
      CommandGroup(replacing: .newItem) {
        Button("New recipe") { library.newItemRequest = NewItemRequest(note: false, token: UUID()) }
          .keyboardShortcut("n", modifiers: .command)
          .disabled(library.busy || library.store == nil)
        Button("New note") { library.newItemRequest = NewItemRequest(note: true, token: UUID()) }
          .keyboardShortcut("n", modifiers: [.command, .shift])
          .disabled(library.busy || library.store == nil)
        Divider()
        Button("Import recipes…") { library.chooseImport() }
          .keyboardShortcut("i", modifiers: [.command, .shift])
          .disabled(library.busy || library.store == nil)
        Button("Import notes…") { library.chooseImport(asNotes: true) }
          .disabled(library.busy || library.store == nil)
        Divider()
        Button("Export/backup…", action: library.exportLibrary)
          .disabled(library.busy || library.store == nil)
        Button("Restore backup…", action: library.restoreBackup)
          .disabled(library.busy)
        Divider()
        Button("Sync with iPhone…") { library.showSync = true }
          .disabled(library.store == nil)
      }
    }
  }
}

/// When SwiftPM builds the Mac app as a bare executable (how Xcode runs it from
/// `Package.swift`), it launches without a regular activation policy, so no Dock
/// icon appears and the window stays behind other apps. Promoting to `.regular`
/// and activating on launch gives a normal foreground window with a Dock icon.
/// A signed `.app` bundle is already `.regular`, so this is harmless there.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct LibrarySettingsView: View {
  @EnvironmentObject var library: LibraryModel
  var body: some View {
    Form {
      Section("Importing") {
        Toggle("Review catalogue before importing", isOn: $library.reviewCatalogue)
          .help("Marked approved sets are accepted directly. Unmarked folders retain duplicate safeguards.")
        if library.report != nil {
          Button("Open import report") {
            NSApp.keyWindow?.close()
            library.reportVersion = UUID()
          }
        }
        Text("Import, export and restore are in the File menu.").font(.caption).foregroundStyle(.secondary)
      }
      if library.busy { ProgressView(library.progress) }
      else if !library.progress.isEmpty { Text(library.progress).font(.caption) }
    }.formStyle(.grouped).padding().frame(width: 440)
      .disabled(library.busy || library.store == nil)
  }
}

struct NewItemRequest: Equatable { let note: Bool; let token: UUID }

/// A filter in the search field: a category or a tag, combined with the free text.
enum SearchToken: Identifiable, Hashable {
  case category(id: String, name: String)
  case tag(String)
  var id: String { switch self { case .category(let id, _): return "c:" + id; case .tag(let name): return "t:" + name } }
  var label: String { switch self { case .category(_, let name): return name; case .tag(let name): return "#" + name } }
  var icon: String { switch self { case .category: return "square.grid.2x2"; case .tag: return "tag" } }
}

/// A stable 6-digit pairing code for this Mac, generated once and reused, so the
/// iPhone keeps syncing without re-entering it every time.
enum SyncPairing {
  static let defaultsKey = "syncPairingCode"
  static func code() -> String {
    let defaults = UserDefaults.standard
    if let existing = defaults.string(forKey: defaultsKey), existing.count == 6 { return existing }
    let code = String(format: "%06d", Int.random(in: 0...999999))
    defaults.set(code, forKey: defaultsKey)
    return code
  }
}

/// The Sync window just shows the pairing code and status. The Mac shares
/// automatically while the app is open (see `LibraryModel.startSharing`).
struct SyncHostView: View {
  @ObservedObject var library: LibraryModel
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Sync with iPhone").font(.title2.bold())
      Text("Your iPhone syncs recipes from this Mac and sends back favourites, cooked notes and views. This Mac shares while the app is open, over your local network.")
        .font(.callout).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        Text("Pairing code").font(.caption).foregroundStyle(.secondary)
        Text(library.pairingCode).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit().textSelection(.enabled)
        Text("Enter this on your iPhone once. It is remembered, so later syncs are a single tap.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Text(library.syncStatus).font(.callout)
      HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
    }.padding(24).frame(width: 420)
  }
}

@MainActor final class LibraryModel: ObservableObject {
  let searchIndex = RecipeSearchIndex()
  @Published var recipes: [Recipe] = [] { willSet { searchIndex.update(newValue) } }
  @Published var selected: UUID?
  @Published var busy = false
  @Published var reviewCatalogue = false
  @Published var progress = ""
  @Published var report: ImportReport?
  @Published var reportVersion = UUID()
  @Published var error: String?
  // Set by the New recipe / New note menu commands; LibraryView acts on it and clears it.
  @Published var newItemRequest: NewItemRequest?
  // Set by the "Sync with iPhone" command; LibraryView presents the sync host sheet.
  @Published var showSync = false
  var store: LibraryStore?
  // Sync: a stable pairing code and a server that shares while the app is open.
  let pairingCode = SyncPairing.code()
  @Published var sharing = false
  @Published var syncStatus = "Not sharing yet."
  private var syncServer: SyncServer?
  /// Reload all recipes from the store, e.g. after a sync has changed them underneath us.
  func reload() {
    do { recipes = try store?.recipes(includeDeleted: true) ?? [] }
    catch { self.error = error.localizedDescription }
  }
  init() {
    do {
      let defaultLocation = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(
          "RecipeApp/Library", isDirectory: true)
      let location: URL
      if let override = ProcessInfo.processInfo.environment["RECIPEAPP_LIBRARY_PATH"] {
        guard override.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
        location = URL(fileURLWithPath: override, isDirectory: true)
      } else { location = defaultLocation }
      store = try LibraryStore(directory: location)
      recipes = try store!.recipes(includeDeleted: true)
      searchIndex.update(recipes)
      startSharing()
      backfillThumbnails()
    } catch { self.error = error.localizedDescription }
  }
  /// Generate any missing thumbnails off the main thread, then reload. Done here
  /// rather than at store open so a large library (or a fresh sync) opens quickly.
  func backfillThumbnails() {
    guard let store else { return }
    DispatchQueue.global(qos: .utility).async {
      try? store.backfillThumbnails()
      DispatchQueue.main.async { self.reload() }
    }
  }
  /// Share with the iPhone while the app is open, using the stable pairing code.
  /// The iPhone initiates each sync; this just keeps the Mac discoverable.
  func startSharing() {
    guard let store, syncServer == nil else { return }
    let server = SyncServer(store: store, pairingCode: pairingCode, displayName: Host.current().localizedName ?? "Recipe Mac")
    server.onSyncComplete = { [weak self] error in
      DispatchQueue.main.async {
        guard let self else { return }
        if let error { self.syncStatus = "Last sync failed: \(error.localizedDescription)" }
        else {
          self.syncStatus = "Synced with iPhone at " + Date().formatted(date: .omitted, time: .shortened)
          self.reload()
          self.backfillThumbnails()
        }
      }
    }
    do {
      _ = try server.start()
      syncServer = server
      sharing = true
      syncStatus = "Sharing. On your iPhone, open Sync and tap this Mac."
    } catch {
      syncStatus = "Could not start sharing: \(error.localizedDescription)"
    }
  }
  func chooseImport() { chooseImport(asNotes: false) }
  func chooseImport(asNotes: Bool) {
    do { try ImportReview.requireFinished(report) } catch { self.error = error.localizedDescription; return }
    guard !busy else { return }
    let panel = NSOpenPanel()
    panel.title = asNotes ? "Import notes folder" : "Import recipes and their photographs"
    panel.message =
      "Choose Markdown files or their containing folder. Include the _resources folder beside your recipes. Originals will be copied, not moved."
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK, let store else { return }
    let urls = panel.urls
    let reviewCatalogue = self.reviewCatalogue
    busy = true
    progress = "Preparing import…"
    let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
    Task {
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          try store.importURLs(urls, asNotes: asNotes, reviewCatalogue: reviewCatalogue, policy: ImportPolicy.forSelection(urls)) { done, total in
            Task { @MainActor in self.progress = "Importing \(done) of \(total)…" }
          }
        }.value
        recipes = try store.recipes(includeDeleted: true)
        report = result
        reportVersion = UUID()
        if selected == nil { selected = recipes.first?.id }
        backfillThumbnails()
      } catch { self.error = error.localizedDescription }
      accessed.forEach { $0.stopAccessingSecurityScopedResource() }
      busy = false
    }
  }
  func resolveDuplicate(_ candidate: LikelyDuplicate, importCopy: Bool) {
    guard let store else { return }
    do {
      let imported = try store.resolveDuplicate(candidate, importCopy: importCopy)
      report?.likelyDuplicates.removeAll { $0.id == candidate.id }
      if imported { report?.imported += 1; if candidate.recipe.isNote { report?.notesImported += 1 } } else { report?.skipped += 1 }
      refreshRecipe(candidate.id)
    } catch { self.error = error.localizedDescription }
  }

  func resolveCatalogue(_ recipe: Recipe, accept: Bool) {
    do {
      let imported = try store?.resolveCatalogue(recipe, accept: accept) ?? false
      report?.catalogueReview.removeAll { $0.id == recipe.id }
      if imported {
        report?.imported += 1
        if recipe.isNote { report?.notesImported += 1 }
      } else { report?.skipped += 1 }
      refreshRecipe(recipe.id)
    } catch { self.error = error.localizedDescription }
  }
  func resolveReview(_ action: ReviewAction) {
    guard let store, var pending = report else { return }
    let ids = pending.catalogueReview.map(\.id) + pending.likelyDuplicates.map(\.id)
    defer { report = pending; refreshRecipes(ids) }
    do { try ImportReview.resolve(&pending, action: action, store: store) }
    catch { self.error = error.localizedDescription }
  }

  func setDeleted(_ recipe: Recipe, deleted: Bool) {
    guard let store, !busy else { return }
    do {
      try store.setDeleted(recipe.id, deleted: deleted)
      if let updated = try store.recipe(id: recipe.id),
        let index = recipes.firstIndex(where: { $0.id == recipe.id })
      {
        recipes[index] = updated
      }
      if selected == recipe.id { selected = nil }
    } catch { self.error = error.localizedDescription }
  }
  /// Marks a flagged recipe as checked so it leaves the Needs review list.
  func markReviewed(_ recipe: Recipe, reviewed: Bool = true) {
    guard let store, !busy else { return }
    do {
      try store.markReviewed(recipe.id, reviewed: reviewed)
      if let updated = try store.recipe(id: recipe.id),
        let index = recipes.firstIndex(where: { $0.id == recipe.id })
      {
        recipes[index] = updated
      }
    } catch { self.error = error.localizedDescription }
  }
  /// Permanently removes a record and drops it from the list. Used to discard a cancelled brand-new item.
  func discard(_ id: UUID) {
    guard let store else { return }
    do {
      try store.discardRecipe(id)
      recipes.removeAll { $0.id == id }
      if selected == id { selected = nil }
    } catch { self.error = error.localizedDescription }
  }
  func restoreBackup() {
    guard !busy else { return }
    let sourcePanel = NSOpenPanel()
    sourcePanel.title = "Choose a RecipeApp backup folder"
    sourcePanel.canChooseDirectories = true
    sourcePanel.canChooseFiles = false
    guard sourcePanel.runModal() == .OK, let source = sourcePanel.url else { return }
    let destinationPanel = NSOpenPanel()
    destinationPanel.title = "Restore to a new folder — your current library stays unchanged"
    destinationPanel.canChooseDirectories = true
    destinationPanel.canChooseFiles = false
    guard destinationPanel.runModal() == .OK, let parent = destinationPanel.url else { return }
    let sourceAccess = source.startAccessingSecurityScopedResource()
    let destinationAccess = parent.startAccessingSecurityScopedResource()
    let destination = parent.appendingPathComponent("Restored-RecipeApp-" + UUID().uuidString)
    busy = true
    progress = "Verifying and restoring backup…"
    Task {
      do {
        try await Task.detached { try LibraryBackup.restore(from: source, to: destination) }.value
        NSWorkspace.shared.activateFileViewerSelecting([destination])
        progress = "Restored to " + destination.lastPathComponent
      } catch { self.error = error.localizedDescription }
      if sourceAccess { source.stopAccessingSecurityScopedResource() }
      if destinationAccess { parent.stopAccessingSecurityScopedResource() }
      busy = false
    }
  }
  func exportLibrary() {
    guard let store, !busy else { return }
    let panel = NSOpenPanel()
    panel.title = "Choose a folder for your library backup"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    guard panel.runModal() == .OK, let parent = panel.url else { return }
    let accessed = parent.startAccessingSecurityScopedResource()
    let destination = parent.appendingPathComponent("RecipeApp-Backup-" + UUID().uuidString)
    busy = true
    progress = "Exporting library…"
    Task {
      do {
        try await Task.detached { try LibraryBackup.export(store, to: destination) }.value
        progress = "Backup saved: " + destination.lastPathComponent
        NSWorkspace.shared.activateFileViewerSelecting([destination])
      } catch { self.error = error.localizedDescription }
      if accessed { parent.stopAccessingSecurityScopedResource() }
      busy = false
    }
  }
  func refreshRecipe(_ id: UUID) { refreshRecipes([id]) }
  func refreshRecipes(_ ids: [UUID]) {
    do {
      guard let store else { return }
      let updates = try ids.compactMap { try store.recipe(id: $0) }
      recipes = RecipeMemory.updating(recipes, with: updates)
    } catch { self.error = error.localizedDescription }
  }
  func opened(_ id: UUID, token: UUID) {
    do { try store?.recordView(id, opening: token); refreshRecipe(id) }
    catch { self.error = error.localizedDescription }
  }
  func toggleFavourite(_ recipe: Recipe) {
    do {
      guard let store else { return }
      try store.setFavourite(recipe.id, favourite: !recipe.favourite)
      if let updated = try store.recipe(id: recipe.id),
        let index = recipes.firstIndex(where: { $0.id == recipe.id })
      {
        recipes[index] = updated
      }
    } catch { self.error = error.localizedDescription }
  }
}

private enum LibrarySheet: Identifiable {
  case report
  case batchSuggestions([BatchSuggestion])
  case editor(Recipe, isNew: Bool = false)
  var id: String {
    switch self {
    case .report: return "report"
    case .batchSuggestions: return "batchSuggestions"
    case .editor(let recipe, _): return recipe.id.uuidString
    }
  }
}

/// A single recipe shown in its own window. Opening the window counts as a view, matching
/// the previous full-window reading mode; the split view's detail pane remains an uncounted preview.
struct RecipeWindow: View {
  @EnvironmentObject var library: LibraryModel
  let recipeID: UUID?
  @State private var showOriginal = false
  private var recipe: Recipe? { library.recipes.first { $0.id == recipeID } }
  var body: some View {
    Group {
      if let recipe {
        RecipeDetail(recipe: recipe, showOriginal: showOriginal)
          .navigationTitle(recipe.title)
          .toolbar {
            ToolbarItem {
              Button { showOriginal.toggle() } label: {
                Label(showOriginal ? "Catalogued view" : "Original Markdown", systemImage: "doc.plaintext")
              }.help(showOriginal ? "Show the tidied recipe" : "Show the original clipping")
            }
          }
      } else {
        VStack(spacing: 12) {
          Image(systemName: "fork.knife").font(.largeTitle).accessibilityHidden(true)
          Text("This recipe is no longer available").font(.title2)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear { if let recipeID { library.opened(recipeID, token: UUID()) } }
  }
}

struct LibraryView: View {
  @EnvironmentObject var library: LibraryModel
  @Environment(\.openWindow) private var openWindow
  @State private var query = ""
  @State private var settledQuery = ""
  @State private var tokens: [SearchToken] = []
  @State private var pantry = false
  @State private var sort = RecipeSort.title
  @State private var collection = LibrarySection.all
  @State private var activeSheet: LibrarySheet?
  @State private var showOriginal = false
  @State private var pendingDeletion: Recipe?
  @AppStorage("libraryGridLayout") private var gridLayout = false
  @State private var gridColumns = 1
  // Follow the user's system accent colour rather than forcing a brand colour.
  private let sage = Color.accentColor
  private func moveSelection(by offset: Int) {
    let ids = filtered.map(\.id)
    guard !ids.isEmpty else { return }
    guard let current = library.selected, let index = ids.firstIndex(of: current) else { library.selected = ids[0]; return }
    library.selected = ids[min(max(index + offset, 0), ids.count - 1)]
  }
  private func openSelected() {
    if let id = library.selected, filtered.contains(where: { $0.id == id }) { openRecipe(id) }
  }
  private func gridColumnCount(for width: CGFloat) -> Int {
    let item: CGFloat = 180, spacing: CGFloat = 14, outer: CGFloat = 28
    return max(1, Int((width - outer + spacing) / (item + spacing)))
  }
  @ViewBuilder private func recipeContextMenu(_ recipe: Recipe) -> some View {
    Button("Original Markdown") { library.selected = recipe.id; showOriginal = true }
    Button("Make my version") { createOwn(note: recipe.isNote, copying: recipe) }
    if recipe.deletedAt != nil {
      Button("Restore recipe") { library.setDeleted(recipe, deleted: false) }.disabled(library.busy)
    } else {
      Button("Delete recipe…", role: .destructive) { pendingDeletion = recipe }.disabled(library.busy)
    }
  }
  private var openOnReturn: RecipeListKeyboard {
    RecipeListKeyboard { openSelected() }
  }
  private var recipeList: some View {
    List(selection: $library.selected) {
      ForEach(filtered) { recipe in
        VStack(alignment: .leading, spacing: 8) {
          RecipeImage(path: recipe.thumbnailPath ?? recipe.heroImagePath, height: 125, placeholderTitle: recipe.title, placeholderCollection: recipe.collection)
          Text(recipe.title).font(.headline).lineLimit(3).frame(height: 48, alignment: .topLeading)
          HStack {
            Text(recipe.collection).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if recipe.favourite { Image(systemName: "heart.fill").foregroundStyle(sage).accessibilityLabel("Favourite") }
          }
        }.padding(.vertical, 8).tag(recipe.id)
          // List(selection:) handles single-click selection and arrow-key navigation; we add
          // only double-click to open (no native primary action on macOS 13) and Return below.
          .onTapGesture(count: 2) { openRecipe(recipe.id) }
          .contextMenu { recipeContextMenu(recipe) }
      }
    }.listStyle(.inset).background(openOnReturn)
  }
  private var recipeGrid: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
          ForEach(filtered) { recipe in
            VStack(alignment: .leading, spacing: 6) {
              RecipeImage(path: recipe.thumbnailPath ?? recipe.heroImagePath, height: 120, placeholderTitle: recipe.title, placeholderCollection: recipe.collection)
              Text(recipe.title).font(.subheadline.weight(.semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
              HStack {
                Text(recipe.collection).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if recipe.favourite { Image(systemName: "heart.fill").foregroundStyle(sage).accessibilityLabel("Favourite") }
              }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(library.selected == recipe.id ? sage.opacity(0.18) : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { openRecipe(recipe.id) }
            .onTapGesture(count: 1) { library.selected = recipe.id }
            .contextMenu { recipeContextMenu(recipe) }
            .id(recipe.id)
          }
        }.padding(14)
          .background(GeometryReader { geo in
            Color.clear
              .onAppear { gridColumns = gridColumnCount(for: geo.size.width) }
              .onChange(of: geo.size.width) { gridColumns = gridColumnCount(for: $0) }
          })
      }
      .background(RecipeGridKeyboard(columns: gridColumns, move: moveSelection, open: openSelected))
      .onChange(of: library.selected) { id in
        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
      }
    }
  }
  var filtered: [Recipe] {
    // Faceted: a recipe must be in ANY selected category AND have ANY selected tag AND match the text.
    let categoryIDs = tokens.compactMap { token -> String? in if case .category(let id, _) = token { return id } else { return nil } }
    let tagNames = tokens.compactMap { token -> String? in if case .tag(let name) = token { return name } else { return nil } }
    let results = library.searchIndex.results(library.recipes.filter { recipe in
      LibraryBrowse.matches(recipe, section: collection)
        && (categoryIDs.isEmpty || categoryIDs.contains { CatalogueVocabulary.hasCategory(recipe, $0) })
        && (tagNames.isEmpty || tagNames.contains { (recipe.tags ?? []).contains($0) })
    }, query: settledQuery, pantry: pantry)
    return sort.apply(results)
  }
  private var allTags: [String] { Array(Set(library.recipes.flatMap { $0.tags ?? [] })).sorted() }
  private var searchSuggestions: Binding<[SearchToken]> {
    Binding(get: {
      let q = query.trimmingCharacters(in: .whitespaces).lowercased()
      guard !q.isEmpty else { return [] }
      let selected = Set(tokens.map(\.id))
      let cats = LibraryBrowse.categories(library.recipes)
        .filter { $0.name.lowercased().contains(q) }
        .map { SearchToken.category(id: $0.id, name: $0.name) }
      let tags = allTags.filter { $0.lowercased().contains(q) }.map { SearchToken.tag($0) }
      return Array((cats + tags).filter { !selected.contains($0.id) }.prefix(10))
    }, set: { _ in })
  }
  private func toggleToken(_ token: SearchToken) {
    if let index = tokens.firstIndex(of: token) { tokens.remove(at: index) } else { tokens.append(token) }
  }
  private func createOwn(note: Bool, copying source: Recipe? = nil) {
    do {
      guard var recipe = try library.store?.createOwn(title: source.map { $0.title + " — my version" } ?? (note ? "New note" : "New recipe"), note: note, copying: source) else { return }
      // A brand-new item opens with four empty text boxes ready to fill, saving repeated Add text clicks.
      if source == nil { recipe.blocks = (0..<4).map { RecipeBlock(id: $0, kind: .text, text: "") } }
      library.refreshRecipe(recipe.id)
      collection = note ? .notes : .own
      library.selected = recipe.id
      activeSheet = .editor(recipe, isNew: source == nil)
    } catch { library.error = error.localizedDescription }
  }
  private func openRecipe(_ id: UUID) {
    library.selected = id
    openWindow(value: id)
  }
  private var browser: some View {
    NavigationSplitView {
      List(selection: $collection) {
        Label("All recipes", systemImage: "books.vertical").tag(LibrarySection.all)
        Label("My recipes", systemImage: "person.crop.square").tag(LibrarySection.own)
        Label("Notes", systemImage: "note.text").tag(LibrarySection.notes)
        Label("Favourites", systemImage: "heart").tag(LibrarySection.favourites)
        Label("Needs review", systemImage: "exclamationmark.bubble").tag(LibrarySection.review)
        Label("Recently deleted", systemImage: "trash").tag(LibrarySection.deleted)
        Section("Collections") {
          ForEach(LibraryBrowse.collections(library.recipes)) { item in
            HStack {
              Label(item.name, systemImage: "folder")
              Spacer()
              Text("\(item.count)").foregroundStyle(.secondary)
            }.tag(LibrarySection.collection(item.name))
          }
        }
      }.navigationTitle("RecipeApp").navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 260)
    } content: {
      VStack(spacing: 0) {
        if library.busy { ProgressView(library.progress).padding() }
        if filtered.isEmpty {
          VStack(spacing: 14) {
            Image(systemName: "book.closed").font(.system(size: 42)).foregroundStyle(sage).accessibilityHidden(true)
            Text(library.recipes.isEmpty ? "Your cookbook starts here" : "No matching recipes")
              .font(.title3)
            Text(
              library.recipes.isEmpty
                ? "Choose File › Import recipes… to keep recipes and photographs together."
                : "Try another search or collection."
            ).foregroundStyle(.secondary).multilineTextAlignment(.center)
          }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if gridLayout {
          recipeGrid
        } else {
          recipeList
        }
        Text("\(filtered.count) \(collection == .notes ? "notes" : "recipes") · Stored on this Mac").font(.caption).foregroundStyle(
          .secondary
        ).padding(10)
      }.navigationTitle(collection.title).navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
    } detail: {
      if let recipe = library.recipes.first(where: { $0.id == library.selected }) {
        RecipeDetail(recipe: recipe, showOriginal: showOriginal).id(recipe.id)
      } else {
        VStack(spacing: 12) {
          Image(systemName: "fork.knife").font(.largeTitle).accessibilityHidden(true)
          Text("Choose a recipe").font(.title2)
          Text("Your own cookbook, ready offline.").foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
  var body: some View {
    browser
    .task(id: query) {
      do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
      if !Task.isCancelled { settledQuery = query }
    }
    .searchable(text: $query, tokens: $tokens, suggestedTokens: searchSuggestions, prompt: "Search, or add a category or tag") { token in
      Label(token.label, systemImage: token.icon)
    }
    .confirmationDialog(
      "Delete recipe?",
      isPresented: Binding(
        get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
      titleVisibility: .visible
    ) {
      Button("Move to Recently deleted", role: .destructive) {
        if let recipe = pendingDeletion { library.setDeleted(recipe, deleted: true) }
        pendingDeletion = nil
      }
      Button("Cancel", role: .cancel) { pendingDeletion = nil }
    } message: {
      Text(
        "“\(pendingDeletion?.title ?? "")” will be removed from your library. You can restore it from Recently deleted."
      )
    }
     .onChange(of: library.selected) { id in
      showOriginal = false

    }
    .toolbar {
      ToolbarItem {
        Menu {
          Button("New recipe") { createOwn(note: false) }
          Button("New note") { createOwn(note: true) }
        } label: {
          Label("New", systemImage: "square.and.pencil")
        }
        .help("Create a new recipe (⌘N) or note (⇧⌘N)")
        .disabled(library.busy || library.store == nil)
      }
      ToolbarItem {
        Menu {
          Menu("Category") {
            ForEach(LibraryBrowse.categories(library.recipes)) { category in
              let token = SearchToken.category(id: category.id, name: category.name)
              Button { toggleToken(token) } label: {
                if tokens.contains(token) { Label("\(category.name) (\(category.count))", systemImage: "checkmark") }
                else { Text("\(category.name) (\(category.count))") }
              }
            }
          }
          Menu("Tag") {
            ForEach(allTags, id: \.self) { tag in
              let token = SearchToken.tag(tag)
              Button { toggleToken(token) } label: {
                if tokens.contains(token) { Label("#" + tag, systemImage: "checkmark") } else { Text("#" + tag) }
              }
            }
          }
          if !tokens.isEmpty { Divider(); Button("Clear filters") { tokens = [] } }
        } label: {
          Label("Filter", systemImage: tokens.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help("Filter by category or tag")
      }
      ToolbarItem {
        Picker("Layout", selection: $gridLayout) {
          Image(systemName: "list.bullet").tag(false)
          Image(systemName: "square.grid.2x2").tag(true)
        }.pickerStyle(.segmented).help("Show recipes as a list or a grid")
      }
      ToolbarItem {
        Picker("Sort", selection: $sort) {
          ForEach(RecipeSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.menu).help("Change how recipes are sorted")
      }
      ToolbarItem {
        if let recipe = library.recipes.first(where: { $0.id == library.selected }) {
          Button { activeSheet = .editor(recipe) } label: { Label("Edit", systemImage: "pencil") }
            .labelStyle(.titleAndIcon).keyboardShortcut("e", modifiers: .command)
            .help(recipe.isNote ? "Edit note (⌘E)" : "Edit recipe (⌘E)")
            .disabled(library.busy || recipe.deletedAt != nil)
        }
      }
    }
    .onChange(of: collection) { _ in library.selected = nil; tokens = [] }
    .onChange(of: library.newItemRequest) { req in
      guard let req else { return }
      createOwn(note: req.note)
      library.newItemRequest = nil
    }
    .onChange(of: library.reportVersion) { _ in if library.report != nil { activeSheet = .report } }
    .sheet(isPresented: Binding(get: { library.showSync }, set: { library.showSync = $0 })) {
      SyncHostView(library: library)
    }
    .sheet(item: $activeSheet) { sheet in
      switch sheet {
      case .batchSuggestions(let candidates): BatchSuggestionView(candidates: candidates).environmentObject(library)
      case .editor(let recipe, let isNew): RecipeEditor(recipe: recipe, isNew: isNew).environmentObject(library)
      case .report:
        VStack(alignment: .leading, spacing: 16) {
          Text("Import review").font(.title2)
          if let report = library.report {
            Text(report.summary)
            if report.hasPendingReview {
              HStack {
                Button("Accept all") { library.resolveReview(.acceptAll) }
                Button("Accept all with confidence ≥ 0.8") { library.resolveReview(.acceptConfidentCatalogue) }
              }
              Text("Accept all includes duplicate copies. The confidence action accepts catalogue items only.").font(.caption)
              Button("Cancel review and skip all pending items", role: .destructive) { library.resolveReview(.rejectAll) }
            }
            Text(
              report.issues.isEmpty
                ? "Review catalogue suggestions and likely duplicates below. Closing keeps pending items. Use the review actions to accept or explicitly skip them."
                : "Some items need attention. Their original text is preserved."
            ).foregroundStyle(.secondary)
            ScrollView {
              VStack(alignment: .leading, spacing: 18) {
                ForEach(report.catalogueReview) { recipe in
                  CatalogueReviewCard(recipe: recipe) { draft, accept in library.resolveCatalogue(draft, accept: accept) }
                  Divider()
                }
                ForEach(report.likelyDuplicates) { candidate in
                  VStack(alignment: .leading, spacing: 8) {
                    Text("Likely duplicate: " + candidate.recipe.title).font(.headline)
                    Text("Matches: " + candidate.matchingTitle)
                    Text(candidate.reason).font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Show incoming recipe") {
                      Text(candidate.recipe.markdown).font(.caption).textSelection(.enabled)
                    }
                    HStack {
                      Button("Import another copy") {
                        library.resolveDuplicate(candidate, importCopy: true)
                      }
                      Button("Skip") { library.resolveDuplicate(candidate, importCopy: false) }
                    }
                  }
                  Divider()
                }
                Text(report.issues.joined(separator: "\n\n")).font(.caption).textSelection(.enabled)
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          HStack {
            Spacer()
            Button(library.report?.hasPendingReview == true ? "Close — keep pending" : "Done") {
              activeSheet = nil
            }.keyboardShortcut(.defaultAction)
          }
        }.padding(24).frame(width: 580, height: 400)
      }
    }
    .alert(
      "RecipeApp needs attention",
      isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })
    ) {
      Button("OK") { library.error = nil }
    } message: {
      Text(library.error ?? "")
    }
  }
}

struct RecipeImage: View {
  @EnvironmentObject var library: LibraryModel
  let path: String?
  let height: CGFloat
  var placeholderTitle: String? = nil
  var placeholderCollection = ""
  @State private var loadedImage: PlatformRecipeImage?
  private var imageURL: URL? {
    path.flatMap { library.store?.assetsDirectory.appendingPathComponent($0) }
  }
  var body: some View {
    Group {
      if let image = loadedImage {
        Image(nsImage: image).resizable().aspectRatio(contentMode: height > 180 ? .fit : .fill)
      } else if let title = placeholderTitle {
        RecipeInitialTile(title: title, notebook: placeholderCollection)
      } else { Color.clear }
    }.frame(maxWidth: .infinity).frame(height: height).clipped().clipShape(
      RoundedRectangle(cornerRadius: 12)
    ).contentShape(Rectangle()).allowsHitTesting(false).accessibilityLabel("Recipe photograph")
      .task(id: imageURL) {
        loadedImage = nil
        guard let url = imageURL else { return }
        let image = await RecipeImageLoader.shared.image(
          at: url, maximumPixels: height <= 180 ? 400 : 1600)
        guard !Task.isCancelled else { return }
        loadedImage = image
      }
  }
}

struct RecipeDetail: View {
  @EnvironmentObject var library: LibraryModel
  let recipe: Recipe
  let showOriginal: Bool
  @State private var historyShown = false
  @State private var cookedConfirmation: UUID?
  @State private var addingCookNote = false
  @State private var cookNote = ""
  private func logCook() {
    do {
      guard let store = library.store else { return }
      let trimmed = cookNote.trimmingCharacters(in: .whitespacesAndNewlines)
      try store.saveCookEntry(CookEntry(date: Date(), note: trimmed.isEmpty ? nil : trimmed), recipeID: recipe.id)
      library.refreshRecipe(recipe.id)
      cookedConfirmation = UUID()
    } catch { library.error = error.localizedDescription }
  }
  func rich(_ text: String) -> Text {
    Text(
      (try? AttributedString(
        markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text))
  }
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        if !showOriginal, let hero = RecipePresentation(recipe).hero {
          RecipeImage(path: hero.assetPath, height: 320)
        }
        HStack(alignment: .top, spacing: 12) {
          Text(recipe.title).font(.largeTitle.bold()).textSelection(.enabled)
          Spacer(minLength: 12)
          Button { library.toggleFavourite(recipe) } label: {
            Image(systemName: recipe.favourite ? "heart.fill" : "heart").font(.title2)
              .accessibilityLabel(recipe.favourite ? "Remove favourite" : "Add favourite")
          }.buttonStyle(.plain)
            .help(recipe.favourite ? "Remove from favourites" : "Add to favourites")
        }
        CookingModeToggle()
        VStack(alignment: .leading, spacing: 8) {
          // Collection, ownership and tags on one line.
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(recipe.collection.uppercased()).font(.caption).foregroundStyle(.secondary)
            if recipe.origin == "own" {
              Text("· " + (recipe.isNote ? "My note" : "My recipe")).font(.caption).foregroundStyle(.secondary)
            }
            if let tags = recipe.tags, !tags.isEmpty {
              Text(tags.map { "#" + $0 }.joined(separator: "  ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
          }
          // Categories, mapped from stored ids to readable names, so multiple categories are all visible.
          let categoryNames = (recipe.categories ?? []).compactMap { id in CatalogueVocabulary.all.first { $0.id == id }?.name }
          if !categoryNames.isEmpty {
            Label(categoryNames.joined(separator: " · "), systemImage: "square.grid.2x2")
              .font(.caption).foregroundStyle(.secondary)
          }
          // Cook action plus view and cook counts on one line; the counts open the dates.
          if !recipe.isNote {
            HStack(spacing: 12) {
              Button("Cooked this") { cookNote = ""; addingCookNote = true }
              Button { historyShown = true } label: {
                Text("Viewed \(recipe.viewCount ?? 0) times · " + CookedPresentation.summary(recipe))
                  .font(.caption).foregroundStyle(.secondary)
              }.buttonStyle(.plain).help("See cooked dates")
              if cookedConfirmation != nil { Text("· Added").font(.caption).foregroundStyle(.secondary) }
              Spacer(minLength: 8)
            }
          }
          // Offline status and the original website on one line.
          HStack(spacing: 10) {
            Label(
              recipe.warnings.isEmpty ? "Available offline" : "Text saved offline · Some attachments unavailable",
              systemImage: "internaldrive"
            ).font(.caption).foregroundStyle(.secondary)
            if let source = recipe.sourceURL, let url = URL(string: source),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
              Text("·").font(.caption).foregroundStyle(.secondary)
              Link("Original website ↗", destination: url).font(.caption)
            }
            Spacer(minLength: 8)
          }
          if recipe.needsReview {
            HStack(spacing: 8) {
              Label("Needs review", systemImage: "exclamationmark.bubble").font(.caption).foregroundStyle(.orange)
              Button("Mark as reviewed") { library.markReviewed(recipe) }.font(.caption).buttonStyle(.link)
            }
          }
          if !recipe.warnings.isEmpty {
            Label("\(recipe.warnings.count) attachment warnings — see import report", systemImage: "exclamationmark.triangle")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        if let notes = recipe.personalNotes, !notes.isEmpty {
          Text("My notes").font(.headline)
          rich(notes)
        }
        if !showOriginal {
          ForEach(RecipePresentation(recipe).facts, id: \.self) { rich($0).font(.headline) }
          ForEach(RecipePresentation(recipe).originals) { original in
            if let directory = library.store?.assetsDirectory,
              let url = RecipeAttachments.url(for: original, assetsDirectory: directory) {
              Button("View original — " + (original.kind == .pdf ? "PDF" : "page image")) {
                if !NSWorkspace.shared.open(url) { library.error = "The reference could not be opened." }
              }
            } else { Text("Original reference unavailable").foregroundStyle(.secondary) }
          }
        }
        Divider()
        if showOriginal {
          Text("Original imported Markdown").font(.headline)
          Text(recipe.markdown).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          ForEach(RecipePresentation(recipe).body) { block in
            switch block.kind {
            case .heading:
              rich(block.text).font(block.level <= 2 ? .title2.bold() : .headline).padding(.top, 12)
            case .pdf, .originalImage:
              if let directory = library.store?.assetsDirectory,
                let url = RecipeAttachments.url(for: block, assetsDirectory: directory) {
                Button {
                  if !NSWorkspace.shared.open(url) { library.error = "The PDF could not be opened." }
                } label: { Label("Open PDF attachment", systemImage: "doc.richtext") }
              } else {
                Label("PDF attachment unavailable", systemImage: "doc.badge.ellipsis")
              }
            case .missingAttachment:
              Label(block.text, systemImage: "doc.badge.ellipsis").foregroundStyle(.secondary)
            case .image: RecipeImage(path: block.assetPath, height: 320)
            case .missingImage:
              Label("Photograph not available in export", systemImage: "photo").foregroundStyle(
                .secondary)
            case .bullet:
              HStack(alignment: .top, spacing: 12) {
                Text("•").foregroundStyle(.primary).accessibilityHidden(true)
                rich(block.text)
              }
            case .step:
              HStack(alignment: .top) {
                Image(systemName: "arrow.right.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                rich(block.text)
              }
            default: rich(block.text)
            }
          }.font(.system(size: 17)).textSelection(.enabled)
        }
        if !showOriginal {
          let cookNotes = (recipe.cookHistory ?? []).filter { !($0.note ?? "").isEmpty }.sorted { $0.date > $1.date }
          if !cookNotes.isEmpty {
            Divider()
            Text("Cooking notes").font(.title2.bold()).padding(.top, 12)
            ForEach(cookNotes) { entry in
              VStack(alignment: .leading, spacing: 2) {
                Text(CookedPresentation.date(entry.date)).font(.caption).foregroundStyle(.secondary)
                rich(entry.note ?? "")
              }.frame(maxWidth: .infinity, alignment: .leading)
            }.textSelection(.enabled)
          }
        }
      }.padding(32).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity)
    }
    .task(id: cookedConfirmation) {
      guard cookedConfirmation != nil else { return }
      do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
      cookedConfirmation = nil
    }
    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    .sheet(isPresented: $historyShown) {
      CookedDatesView(entries: library.recipes.first { $0.id == recipe.id }?.cookHistory ?? []) { id in
        do { try library.store?.deleteCookEntry(id); library.refreshRecipe(recipe.id) }
        catch { library.error = error.localizedDescription }
      }
    }
    .sheet(isPresented: $addingCookNote) {
      VStack(alignment: .leading, spacing: 16) {
        Text("Cooked this").font(.title2)
        Text("Add an optional note about this time you cooked it. Leave it blank to just record the date.")
          .font(.caption).foregroundStyle(.secondary)
        TextEditor(text: $cookNote).font(.body).frame(minHeight: 120)
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4)))
        HStack {
          Spacer()
          Button("Cancel") { addingCookNote = false }.keyboardShortcut(.cancelAction)
          Button("Save") { logCook(); addingCookNote = false }.keyboardShortcut(.defaultAction)
        }
      }.padding(24).frame(width: 440)
    }
    .background(
      Color(
        nsColor: NSColor(name: nil) { appearance in
          appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.098, green: 0.137, blue: 0.114, alpha: 1)
            : NSColor(red: 0.973, green: 0.969, blue: 0.949, alpha: 1)
        }))
  }
}
