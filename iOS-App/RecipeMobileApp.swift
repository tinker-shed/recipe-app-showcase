import SwiftUI
import RecipeCore
import UIKit
import UniformTypeIdentifiers
import QuickLook

/// iPadOS 15 has no NavigationSplitView visibility API, so collapse the sidebar
/// by nudging the underlying split view controller. The system keeps the toggle
/// button to reopen it.
enum SidebarControl {
  static func collapse() {
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows {
        if let split = window.rootViewController?.firstSplitViewController {
          split.preferredDisplayMode = .secondaryOnly
          return
        }
      }
    }
  }
}

private extension UIViewController {
  var firstSplitViewController: UISplitViewController? {
    if let split = self as? UISplitViewController { return split }
    for child in children { if let found = child.firstSplitViewController { return found } }
    return presentedViewController?.firstSplitViewController
  }
}

@main
struct RecipeMobileApp: App {
  @StateObject private var library = MobileLibrary()
  var body: some Scene {
    WindowGroup { MobileLibraryView().environmentObject(library).tint(Color(red: 0.27, green: 0.40, blue: 0.31)) }
  }
}

@MainActor final class MobileLibrary: ObservableObject {
  let searchIndex = RecipeSearchIndex()
  @Published var recipes: [Recipe] = [] { willSet { searchIndex.update(newValue) } }
  @Published var error: String?
  var store: LibraryStore?
  init() {
    do {
      let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RecipeApp/Library")
      store = try LibraryStore(directory: directory)
      refresh()
      #if DEBUG
      seedTestLibraryIfEmpty()
      #endif
      backfillThumbnails()
    } catch { self.error = error.localizedDescription }
  }
  func refresh() {
    do { recipes = try store?.recipes() ?? [] }
    catch { self.error = error.localizedDescription }
  }
  /// Generate any missing thumbnails off the main thread, then refresh so the grid
  /// shows the small images instead of decoding full-size hero photos.
  func backfillThumbnails() {
    guard let store else { return }
    DispatchQueue.global(qos: .utility).async {
      try? store.backfillThumbnails()
      DispatchQueue.main.async { self.refresh() }
    }
  }
  func refreshRecipe(_ id: UUID) {
    do {
      guard let updated = try store?.recipe(id: id) else { return }
      recipes = RecipeMemory.updating(recipes, with: [updated])
    } catch { self.error = error.localizedDescription }
  }
  func favourite(_ recipe: Recipe) {
    do { try store?.setFavourite(recipe.id, favourite: !recipe.favourite); refreshRecipe(recipe.id) }
    catch { self.error = error.localizedDescription }
  }
  func opened(_ id: UUID, token: UUID) {
    do { try store?.recordView(id, opening: token); refreshRecipe(id) }
    catch { self.error = error.localizedDescription }
  }
  #if DEBUG
  /// Seeds a few sample recipes on first launch so the Simulator shows content before sync exists.
  /// Debug only: this never ships, and the real library will arrive by syncing from the Mac.
  func seedTestLibraryIfEmpty() {
    guard let store, recipes.isEmpty else { return }
    let samples: [(collection: String, file: String, markdown: String)] = [
      ("Pasta Dishes", "tomato-pasta.md", "# Simple Tomato Pasta\n\nServes 2\n\n## Ingredients\n- 200g spaghetti\n- 400g tinned tomatoes\n- 2 cloves garlic\n- Olive oil\n- Salt and pepper\n\n## Method\n1. Boil the spaghetti until al dente.\n2. Soften the garlic in olive oil.\n3. Add the tomatoes and simmer for 10 minutes.\n4. Toss the drained pasta through the sauce.\n"),
      ("Soups", "carrot-coriander-soup.md", "# Carrot and Coriander Soup\n\nServes 4\n\n## Ingredients\n- 500g carrots\n- 1 onion\n- 1 litre vegetable stock\n- Fresh coriander\n\n## Method\n1. Soften the onion in a little oil.\n2. Add the chopped carrots and the stock.\n3. Simmer until tender, then blend.\n4. Stir through the chopped coriander.\n"),
      ("Bread Baking", "quick-soda-bread.md", "# Quick Soda Bread\n\nMakes 1 loaf\n\n## Ingredients\n- 500g plain flour\n- 1 tsp bicarbonate of soda\n- 1 tsp salt\n- 400ml buttermilk\n\n## Method\n1. Heat the oven to 200C.\n2. Mix the dry ingredients, then stir in the buttermilk.\n3. Shape into a round and score a cross on top.\n4. Bake for 40 minutes until it sounds hollow.\n"),
      ("Asian Cooking", "egg-fried-rice.md", "# Egg Fried Rice\n\nServes 2\n\n## Ingredients\n- 2 cups cooked, cooled rice\n- 2 eggs\n- 2 spring onions\n- Soy sauce\n\n## Method\n1. Scramble the eggs and set aside.\n2. Fry the rice over a high heat.\n3. Add the eggs, spring onions and a splash of soy sauce.\n"),
      ("Notes", "kitchen-notes.md", "# Kitchen Notes\n\nThe oven runs about 10C hot, so reduce baking temperatures accordingly.\n"),
    ]
    do {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SampleRecipes-" + UUID().uuidString)
      for sample in samples {
        let folder = dir.appendingPathComponent(sample.collection)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try sample.markdown.write(to: folder.appendingPathComponent(sample.file), atomically: true, encoding: .utf8)
      }
      _ = try store.importURLs([dir], policy: ImportPolicy.forSelection([dir]))
      try? FileManager.default.removeItem(at: dir)
      refresh()
    } catch { self.error = error.localizedDescription }
  }
  #endif
  func logCook(_ id: UUID, note: String) {
    do {
      let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
      try store?.saveCookEntry(CookEntry(date: Date(), note: trimmed.isEmpty ? nil : trimmed), recipeID: id)
      refreshRecipe(id)
    } catch { self.error = error.localizedDescription }
  }

  // MARK: Sync
  @Published var discoveredMacs: [DiscoveredMac] = []
  @Published var syncing = false
  @Published var lastSyncAt: Date?
  private let browser = SyncBrowser()
  func startBrowsing() {
    loadLastSync()
    browser.start { [weak self] macs in self?.discoveredMacs = macs }
  }
  func stopBrowsing() { browser.stop() }
  func loadLastSync() { lastSyncAt = store.map { SyncStateStore.load(in: $0.directory).lastSyncAt } ?? nil }
  func sync(with mac: DiscoveredMac, pairingCode: String) {
    guard let store, !syncing else { return }
    syncing = true
    DispatchQueue.global().async {
      do {
        try SyncClient.sync(store: store, to: mac.endpoint, pairingCode: pairingCode)
        DispatchQueue.main.async { self.refresh(); self.loadLastSync(); self.syncing = false; self.backfillThumbnails() }
      } catch {
        DispatchQueue.main.async { self.error = error.localizedDescription; self.syncing = false }
      }
    }
  }
}

/// NavigationStack on iOS 16+, with a stack-styled NavigationView fallback for iOS 15.
struct AdaptiveNavigation<Content: View>: View {
  @ViewBuilder var content: () -> Content
  var body: some View {
    if #available(iOS 16, *) { NavigationStack { content() } }
    else { NavigationView { content() }.navigationViewStyle(.stack) }
  }
}

/// A filter in the search field: a category or a tag, combined with the free text.
enum SearchToken: Identifiable, Hashable {
  case category(id: String, name: String)
  case tag(String)
  var id: String { switch self { case .category(let id, _): return "c:" + id; case .tag(let name): return "t:" + name } }
  var label: String { switch self { case .category(_, let name): return name; case .tag(let name): return "#" + name } }
  var icon: String { switch self { case .category: return "square.grid.2x2"; case .tag: return "tag" } }
}

/// Token search where available (iOS 16+), with a plain-text fallback on iOS 15 (the Filter menu
/// still adds category/tag tokens there).
struct TokenSearchable: ViewModifier {
  @Binding var query: String
  @Binding var tokens: [SearchToken]
  var suggestions: [SearchToken]
  func body(content: Content) -> some View {
    if #available(iOS 16, *) {
      content.searchable(text: $query, tokens: $tokens, suggestedTokens: .constant(suggestions), prompt: "Search, or add a category or tag") { token in
        Label(token.label, systemImage: token.icon)
      }
    } else {
      content.searchable(text: $query, prompt: "Recipes and ingredients")
    }
  }
}

struct MobileLibraryView: View {
  @EnvironmentObject var library: MobileLibrary
  @State private var section = LibrarySection.all
  @State private var query = ""
  @State private var settledQuery = ""
  @State private var tokens: [SearchToken] = []
  @State private var showingSync = false
  @Environment(\.horizontalSizeClass) private var hSize
  @AppStorage("gridColumns") private var gridColumns = 4
  var results: [Recipe] {
    let categoryIDs = tokens.compactMap { token -> String? in if case .category(let id, _) = token { return id } else { return nil } }
    let tagNames = tokens.compactMap { token -> String? in if case .tag(let name) = token { return name } else { return nil } }
    return library.searchIndex.results(library.recipes.filter { recipe in
      LibraryBrowse.matches(recipe, section: section)
        && (categoryIDs.isEmpty || categoryIDs.contains { CatalogueVocabulary.hasCategory(recipe, $0) })
        && (tagNames.isEmpty || tagNames.contains { (recipe.tags ?? []).contains($0) })
    }, query: settledQuery)
  }
  private var sectionName: String {
    switch section {
    case .favourites: return "Favourites"
    case .notes: return "Notes"
    case .review: return "Needs review"
    case .collection(let name): return name
    default: return "All recipes"
    }
  }
  // iPad (regular width) uses a fixed number of columns the user picks; iPhone
  // (compact) keeps the adaptive two-ish columns.
  private var gridItems: [GridItem] {
    if hSize == .regular {
      return Array(repeating: GridItem(.flexible(), spacing: 14), count: gridColumns)
    }
    return [GridItem(.adaptive(minimum: 160), spacing: 14)]
  }
  private var allTags: [String] { Array(Set(library.recipes.flatMap { $0.tags ?? [] })).sorted() }
  private var searchSuggestions: [SearchToken] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return [] }
    let selected = Set(tokens.map(\.id))
    let cats = LibraryBrowse.categories(library.recipes)
      .filter { $0.name.lowercased().contains(q) }
      .map { SearchToken.category(id: $0.id, name: $0.name) }
    let tags = allTags.filter { $0.lowercased().contains(q) }.map { SearchToken.tag($0) }
    return Array((cats + tags).filter { !selected.contains($0.id) }.prefix(10))
  }
  private func toggleToken(_ token: SearchToken) {
    if let index = tokens.firstIndex(of: token) { tokens.remove(at: index) } else { tokens.append(token) }
  }
  private var selectionBinding: Binding<LibrarySection?> {
    Binding(get: { section }, set: { if let value = $0 { section = value } })
  }
  // iPad sidebar: the same sections the iPhone offers, plus the notebooks.
  private var sidebar: some View {
    List(selection: selectionBinding) {
      Section {
        Label("All recipes", systemImage: "books.vertical").tag(LibrarySection.all)
        Label("Favourites", systemImage: "heart").tag(LibrarySection.favourites)
        Label("Notes", systemImage: "note.text").tag(LibrarySection.notes)
      }
      let collections = LibraryBrowse.collections(library.recipes)
      if !collections.isEmpty {
        Section("Collections") {
          ForEach(collections) { collection in
            HStack {
              Label(collection.name, systemImage: "folder")
              Spacer(minLength: 8)
              Text("\(collection.count)").foregroundStyle(.secondary)
            }.tag(LibrarySection.collection(collection.name))
          }
        }
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("Library")
  }
  private var libraryMenu: some View {
    Menu {
      Picker("Library", selection: $section) {
        Text("All recipes").tag(LibrarySection.all)
        Text("Favourites").tag(LibrarySection.favourites)
        Text("Notes").tag(LibrarySection.notes)
      }
      if !LibraryBrowse.collections(library.recipes).isEmpty {
        Picker("Collection", selection: $section) {
          ForEach(LibraryBrowse.collections(library.recipes)) { collection in
            Text("\(collection.name) (\(collection.count))").tag(LibrarySection.collection(collection.name))
          }
        }
      }
    } label: { Label("Library", systemImage: "books.vertical") }
      .help("Browse by section or notebook")
  }
  private var filterMenu: some View {
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
  private var columnsMenu: some View {
    Menu {
      Picker("Recipes across", selection: $gridColumns) {
        Text("2 across").tag(2)
        Text("3 across").tag(3)
        Text("4 across").tag(4)
      }
    } label: { Label("Grid size", systemImage: "square.grid.2x2") }
      .help("How many recipes across, and how big the images are")
  }
  private var syncButton: some View {
    Button { showingSync = true } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
      .help("Sync with the Mac over your local network")
  }
  // Conditionals live inside the groups' view builders, not at the toolbar level,
  // because conditional ToolbarContent needs iOS 16 (the iPad runs iPadOS 15).
  @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .navigationBarLeading) {
      if hSize != .regular { libraryMenu }
    }
    ToolbarItemGroup(placement: .navigationBarTrailing) {
      filterMenu
      if hSize == .regular { columnsMenu }
      syncButton
    }
  }
  // Always reserve two lines for the title (an invisible two-line placeholder
  // sized to the current text), so one- and two-line cards are the same height
  // and the images line up in a clean grid.
  private func cardTitle(_ title: String) -> some View {
    Text("M\nM")
      .font(.subheadline.weight(.semibold)).lineLimit(2).hidden()
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .topLeading) {
        Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
          .multilineTextAlignment(.leading).foregroundStyle(.primary)
      }
  }
  @ViewBuilder private var gridContent: some View {
    ScrollView {
      if results.isEmpty {
        Text(library.recipes.isEmpty ? "No recipes yet. Sync from the Mac to add recipes." : "No matching recipes.")
          .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 48).padding(.horizontal, 24)
      } else {
        LazyVGrid(columns: gridItems, spacing: 14) {
          ForEach(results) { recipe in
            NavigationLink(destination: MobileRecipeView(recipeID: recipe.id)) {
              VStack(alignment: .leading, spacing: 6) {
                // A Color.clear box fixes the 4:3 ratio to the column width, so every
                // card is the same height; the photo fills and is clipped to it.
                Color.clear
                  .aspectRatio(4.0 / 3.0, contentMode: .fit)
                  .overlay(
                    MobileRecipeImage(path: recipe.thumbnailPath ?? recipe.heroImagePath, thumbnail: true, fill: true, placeholderTitle: recipe.title, placeholderCollection: recipe.collection)
                  )
                  .clipShape(RoundedRectangle(cornerRadius: 12))
                cardTitle(recipe.title)
                HStack(spacing: 4) {
                  Text(recipe.collection).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  Spacer(minLength: 2)
                  if recipe.favourite { Image(systemName: "heart.fill").font(.caption).foregroundStyle(.tint).accessibilityLabel("Favourite") }
                }
              }
            }.buttonStyle(.plain)
          }
        }.padding(16)
        Text("\(results.count) items · Stored on this device").font(.caption).foregroundStyle(.secondary).padding(.bottom, 20)
      }
    }
    .navigationTitle(sectionName)
    .task(id: query) {
      do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
      if !Task.isCancelled { settledQuery = query }
    }
    .modifier(TokenSearchable(query: $query, tokens: $tokens, suggestions: searchSuggestions))
    .toolbar { libraryToolbar }
  }
  var body: some View {
    Group {
      if hSize == .regular {
        // iPad: a Mac-style sidebar beside the grid (classic split, works on iPadOS 15).
        // .id(section) gives the detail a fresh identity per section so its scroll
        // view is rebuilt at the top rather than keeping the previous offset.
        NavigationView {
          sidebar
          gridContent.id(section)
        }
      } else {
        // iPhone: the compact stack with the Library menu.
        AdaptiveNavigation { gridContent.id(section) }
      }
    }
    .sheet(isPresented: $showingSync) { SyncView().environmentObject(library) }
    .onChange(of: section) { _ in
      tokens = []
      // On iPad, dismiss the sidebar after a selection so the grid gets full width.
      if hSize == .regular { SidebarControl.collapse() }
    }
    .alert("RecipeApp needs attention", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
      Button("OK") { library.error = nil }
    } message: { Text(library.error ?? "") }
  }
}

struct SyncView: View {
  @EnvironmentObject var library: MobileLibrary
  @Environment(\.dismiss) private var dismiss
  @AppStorage("syncPairingCode") private var pairingCode = ""
  var body: some View {
    AdaptiveNavigation {
      Form {
        Section("Pairing code") {
          TextField("6-digit code shown on the Mac", text: $pairingCode)
            .keyboardType(.numberPad)
          Text("On the Mac, choose File › Sync with iPhone to show the code. Enter it once; it is remembered.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Sync now") {
          if library.discoveredMacs.isEmpty {
            Text("Looking for your Mac… Make sure the Mac app is open on the same Wi-Fi.").foregroundStyle(.secondary)
          }
          ForEach(library.discoveredMacs) { mac in
            Button {
              library.sync(with: mac, pairingCode: pairingCode)
            } label: {
              HStack {
                Label(mac.name, systemImage: "desktopcomputer")
                Spacer()
                if library.syncing { ProgressView() } else { Text("Sync").foregroundStyle(.tint) }
              }
            }.disabled(library.syncing || pairingCode.isEmpty)
          }
        }
        Section {
          if let last = library.lastSyncAt {
            Text("Last synced " + last.formatted(date: .abbreviated, time: .shortened)).font(.caption)
          } else {
            Text("Not synced yet.").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Sync")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .onAppear { library.startBrowsing() }
      .onDisappear { library.stopBrowsing() }
    }
  }
}

struct MobileRecipeImage: View {
  @EnvironmentObject var library: MobileLibrary
  let path: String?
  var thumbnail = false
  var fill = false
  var placeholderTitle: String? = nil
  var placeholderCollection = ""
  @State private var image: PlatformRecipeImage?
  var body: some View {
    Group {
      if let image {
        // Fill mode anchors to the caller's box (Color.clear) and clips the overflow, so a grid of
        // mixed-aspect photos all render the same height. Fit mode letterboxes (used for the hero).
        if fill { Color.clear.overlay(Image(uiImage: image).resizable().scaledToFill()) }
        else { Image(uiImage: image).resizable().scaledToFit() }
      }
      else if let title = placeholderTitle { RecipeInitialTile(title: title, notebook: placeholderCollection) }
      else { Color.clear }
    }.clipShape(RoundedRectangle(cornerRadius: 12))
      .accessibilityLabel("Recipe photograph")
      .task(id: path) {
        image = nil
        guard let path, let url = library.store?.assetsDirectory.appendingPathComponent(path) else { return }
        let loaded = await RecipeImageLoader.shared.image(at: url, maximumPixels: thumbnail ? 400 : 1600)
        if !Task.isCancelled { image = loaded }
      }
  }
}

private struct ReferenceFile: Identifiable { let url: URL; var id: URL { url } }
struct MobileRecipeView: View {
  @EnvironmentObject var library: MobileLibrary
  let recipeID: UUID
  @State private var opening = UUID()
  @State private var logShown = false
  @State private var cookedConfirmation: UUID?
  @State private var reference: ReferenceFile?
  @State private var addingCookNote = false
  @State private var cookNote = ""
  var recipe: Recipe? { library.recipes.first { $0.id == recipeID } }
  private func rich(_ text: String) -> Text {
    Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
  }
  var body: some View {
    Group {
      if let recipe {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            if let hero = RecipePresentation(recipe).hero { MobileRecipeImage(path: hero.assetPath).frame(maxHeight: 360) }
            Text(recipe.collection).foregroundStyle(.secondary)
            Text(recipe.warnings.isEmpty ? "Available offline" : "Text offline · Some attachments unavailable").font(.caption)
            CookingModeToggle().id(recipeID)
            HStack(spacing: 12) {
              Button { library.favourite(recipe) } label: { Label(recipe.favourite ? "Favourite" : "Add favourite", systemImage: recipe.favourite ? "heart.fill" : "heart") }
                .buttonStyle(.bordered)
                .help(recipe.favourite ? "Remove from favourites" : "Add to favourites")
              if !recipe.isNote {
                Button { cookNote = ""; addingCookNote = true } label: { Label("Cooked this", systemImage: "checkmark.circle") }
                  .buttonStyle(.borderedProminent)
                  .help("Record that you cooked this, with an optional note")
              }
            }
            if !recipe.isNote {
              if cookedConfirmation != nil { Text("Added to your cooked log").font(.caption).foregroundStyle(.secondary) }
              Button { logShown = true } label: {
                HStack(spacing: 4) {
                  Image(systemName: "clock")
                  Text("Viewed \(recipe.viewCount ?? 0) times · " + CookedPresentation.summary(recipe))
                  Image(systemName: "chevron.right").font(.caption2)
                }.font(.caption)
              }.foregroundStyle(.tint).help("See and edit your cooked dates and notes")
            }
            ForEach(RecipePresentation(recipe).facts, id: \.self) { rich($0).font(.headline) }
            ForEach(RecipePresentation(recipe).originals) { block in
              if let directory = library.store?.assetsDirectory, let url = RecipeAttachments.url(for: block, assetsDirectory: directory) {
                Button("View original") { reference = ReferenceFile(url: url) }
              }
            }
            ForEach(RecipePresentation(recipe).body) { block in
              switch block.kind {
              case .image: MobileRecipeImage(path: block.assetPath).frame(maxHeight: 360)
              case .heading: rich(block.text).font(.title2.bold()).padding(.top, 8)
              case .bullet: HStack(alignment: .top) { Text("•").accessibilityHidden(true); rich(block.text) }
              case .step: HStack(alignment: .top) { Image(systemName: "arrow.right.circle").accessibilityHidden(true); rich(block.text) }
              default: rich(block.text)
              }
            }
            if let notes = recipe.personalNotes, !notes.isEmpty { Text("My notes").font(.headline); Text(notes) }
            if let source = recipe.sourceURL, let url = URL(string: source), ["https", "http"].contains(url.scheme?.lowercased() ?? "") { Link("Original website", destination: url) }
          }.font(.body).padding(24).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }
        .navigationTitle(recipe.title)
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $logShown) {
          CookedDatesView(entries: self.recipe?.cookHistory ?? []) { id in
            do { try library.store?.deleteCookEntry(id); library.refreshRecipe(recipeID) }
            catch { library.error = error.localizedDescription }
          }
        }
        .task(id: cookedConfirmation) {
          guard cookedConfirmation != nil else { return }
          do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
          cookedConfirmation = nil
        }
        .sheet(item: $reference) { OriginalPreview(url: $0.url) }
        .sheet(isPresented: $addingCookNote) {
          AdaptiveNavigation {
            Form {
              Section("Add a note (optional)") {
                TextField("e.g. too much salt, makes 10 not 6", text: $cookNote)
              }
            }
            .navigationTitle("Cooked this")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
              ToolbarItem(placement: .cancellationAction) { Button("Cancel") { addingCookNote = false } }
              ToolbarItem(placement: .confirmationAction) {
                Button("Save") { library.logCook(recipeID, note: cookNote); addingCookNote = false; cookedConfirmation = UUID() }
              }
            }
          }
        }
      } else { Text("Recipe unavailable") }
    }
      .onAppear { library.opened(recipeID, token: opening) }
  }
}

struct OriginalPreview: UIViewControllerRepresentable {
  let url: URL
  func makeCoordinator() -> Coordinator { Coordinator(url: url) }
  func makeUIViewController(context: Context) -> QLPreviewController {
    let controller = QLPreviewController()
    controller.dataSource = context.coordinator
    return controller
  }
  func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
  final class Coordinator: NSObject, QLPreviewControllerDataSource {
    let url: URL
    init(url: URL) { self.url = url }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
  }
}

