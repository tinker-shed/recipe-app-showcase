import AppKit
import RecipeCore
import SwiftUI
import UniformTypeIdentifiers

struct RecipeEditor: View {
  @EnvironmentObject var library: LibraryModel
  @Environment(\.dismiss) private var dismiss
  @State private var draft: Recipe
  @State private var tagsText: String
  @State private var stagedImages: [String: Data] = [:]
  @State private var error: String?
  @State private var saving = false
  @State private var showDetails = false
  @State private var previousCount: Int
  @State private var markdownMode = false
  @State private var showCategories = false
  @State private var markdownText = ""
  /// Photo and attachment sections set aside while editing as markdown, restored by their [[media N]] tokens.
  @State private var preservedMedia: [RecipeBlock] = []
  /// A brand-new item created just to open this editor. Cancelling discards it entirely.
  private let isNew: Bool
  init(recipe: Recipe, isNew: Bool = false) {
    _draft = State(initialValue: recipe)
    _tagsText = State(initialValue: (recipe.tags ?? []).map { "#" + $0 }.joined(separator: ", "))
    _previousCount = State(initialValue: recipe.blocks.count)
    self.isNew = isNew
  }
  private func add(_ kind: BlockKind) {
    draft.blocks.append(
      RecipeBlock(
        id: (draft.blocks.map(\.id).max() ?? -1) + 1, kind: kind, text: "",
        level: kind == .heading ? 3 : 0))
  }
  private func move(_ id: Int, by offset: Int) {
    guard let index = draft.blocks.firstIndex(where: { $0.id == id }),
      draft.blocks.indices.contains(index + offset)
    else { return }
    draft.blocks.swapAt(index, index + offset)
  }
  private func addImage(replacing blockID: Int? = nil) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = blockID == nil
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      do {
        try stage(try Data(contentsOf: url), name: url.lastPathComponent, replacing: blockID)
      } catch {
        self.error = "Could not read the image: \(url.lastPathComponent)"
      }
    }
  }
  /// Insert an image copied to the clipboard. Screenshots and copied pictures arrive as file URLs, PNG or TIFF.
  private func pasteImage(replacing blockID: Int? = nil) {
    let pasteboard = NSPasteboard.general
    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL], !urls.isEmpty
    {
      for url in urls {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { try stage(try Data(contentsOf: url), name: url.lastPathComponent, replacing: blockID) }
        catch { self.error = "Could not read the image: \(url.lastPathComponent)" }
      }
      return
    }
    for type in [NSPasteboard.PasteboardType.png, .tiff] where pasteboard.data(forType: type) != nil {
      do { try stage(pasteboard.data(forType: type)!, name: "Pasted image", replacing: blockID); return }
      catch { self.error = "Could not read the pasted image."; return }
    }
    self.error = "No image found on the clipboard. Copy an image first, then paste."
  }
  /// Validate, stage and insert image data, replacing a block when given or inserting a new photograph.
  private func stage(_ data: Data, name: String, replacing blockID: Int? = nil) throws {
    _ = try RecipeImages.fileExtension(for: data)
    let key = "staged:" + UUID().uuidString
    stagedImages[key] = data
    if let blockID, let index = draft.blocks.firstIndex(where: { $0.id == blockID }) {
      draft.blocks[index] = RecipeBlock(id: blockID, kind: .image, text: name, assetPath: key)
    } else {
      let image = RecipeBlock(id: (draft.blocks.map(\.id).max() ?? -1) + 1, kind: .image, text: name, assetPath: key)
      if draft.heroImagePath == nil {
        let position = draft.blocks.firstIndex { $0.kind == .heading && $0.level == 1 }.map { $0 + 1 } ?? 0
        draft.blocks.insert(image, at: position)
      } else {
        draft.blocks.append(image)
      }
    }
  }
  /// Section names in catalogue order, each appearing once, for grouping the category checklist.
  private var categorySections: [String] {
    var seen = Set<String>()
    return CatalogueVocabulary.all.map(\.section).filter { seen.insert($0).inserted }
  }
  private func markReviewed() {
    library.markReviewed(draft)
    draft.reviewedAt = Date()
  }
  private func toggleMarkdown() {
    if markdownMode {
      draft.blocks = parsedBlocks()
      markdownMode = false
    } else {
      buildMarkdown()
      markdownMode = true
    }
  }
  /// Render the current sections as one markdown document, setting photos aside as [[media N]] tokens.
  private func buildMarkdown() {
    preservedMedia = []
    var out = ""
    var previousKind: BlockKind?
    for block in draft.blocks {
      let line: String
      switch block.kind {
      case .heading:
        let levels = max(1, min(6, block.level == 0 ? 2 : block.level))
        line = String(repeating: "#", count: levels) + " " + block.text
      case .bullet: line = "- " + block.text
      case .step: line = "1. " + block.text
      case .text: line = block.text
      default:
        line = "[[media \(preservedMedia.count)]]"
        preservedMedia.append(block)
      }
      if out.isEmpty {
        out = line
      } else {
        // Keep consecutive list items tight; separate everything else with a blank line.
        let tight = (block.kind == .bullet && previousKind == .bullet) || (block.kind == .step && previousKind == .step)
        out += (tight ? "\n" : "\n\n") + line
      }
      previousKind = block.kind
    }
    markdownText = out
  }
  /// Parse the markdown document back into sections, restoring photos from their [[media N]] tokens.
  private func parsedBlocks() -> [RecipeBlock] {
    var blocks: [RecipeBlock] = []
    var paragraph: [String] = []
    func flush() {
      let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { blocks.append(RecipeBlock(id: 0, kind: .text, text: text)) }
      paragraph = []
    }
    for rawLine in markdownText.components(separatedBy: "\n") {
      let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { flush(); continue }
      if trimmed.range(of: #"^\[\[media \d+\]\]$"#, options: .regularExpression) != nil {
        flush()
        if let index = Int(trimmed.filter(\.isNumber)), preservedMedia.indices.contains(index) {
          blocks.append(preservedMedia[index])
        }
      } else if trimmed.hasPrefix("#") {
        flush()
        let levels = trimmed.prefix { $0 == "#" }.count
        let text = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        blocks.append(RecipeBlock(id: 0, kind: .heading, text: text, level: min(6, levels)))
      } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
        flush()
        blocks.append(RecipeBlock(id: 0, kind: .bullet, text: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
      } else if let range = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
        flush()
        blocks.append(RecipeBlock(id: 0, kind: .step, text: String(trimmed[range.upperBound...])))
      } else {
        paragraph.append(rawLine)
      }
    }
    flush()
    for index in blocks.indices { blocks[index].id = index }
    return blocks
  }
  private func save() {
    guard let store = library.store else {
      error = "Library unavailable"
      return
    }
    saving = true
    do {
      if markdownMode { draft.blocks = parsedBlocks() }
      draft.tags = tagsText.components(separatedBy: ",").map(CatalogueVocabulary.tag)
      draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
      // Drop text sections left blank, so empty starter boxes are not saved. Photographs and attachments are always kept.
      let textKinds: Set<BlockKind> = [.text, .heading, .bullet, .step]
      draft.blocks.removeAll { textKinds.contains($0.kind) && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      try store.saveEdits(draft, newImages: stagedImages)
      if let updated = try store.recipe(id: draft.id),
        let index = library.recipes.firstIndex(where: { $0.id == draft.id })
      {
        library.recipes[index] = updated
      }
      dismiss()
    } catch { self.error = error.localizedDescription }
    saving = false
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(draft.isNote ? "Edit note" : "Edit recipe").font(.title2.bold())
        Spacer()
        Picker("View", selection: Binding(get: { markdownMode }, set: { newValue in
          if newValue != markdownMode { toggleMarkdown() }
        })) {
          Text("Sections").tag(false)
          Text("Markdown").tag(true)
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
          .help("Edit the recipe as structured sections or as one markdown document")
      }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 12)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            if draft.needsReview {
              HStack(spacing: 8) {
                Label("Needs review", systemImage: "exclamationmark.bubble").foregroundStyle(.orange)
                Button("Mark as reviewed") { markReviewed() }
                Spacer()
              }.font(.callout)
            }
            TextField("Recipe title", text: $draft.title).font(.title3).textFieldStyle(.roundedBorder)
            DisclosureGroup(isExpanded: $showDetails) {
              VStack(alignment: .leading, spacing: 10) {
                TextField("Tags, separated by commas", text: $tagsText)
                if tagsText.contains("#") {
                  let prefix = CatalogueVocabulary.tag(tagsText.components(separatedBy: ",").last ?? "")
                  let suggestions = Array(Set(CatalogueVocabulary.knownTags + library.recipes.flatMap { $0.tags ?? [] })).sorted().filter { prefix.isEmpty || $0.hasPrefix(prefix) }
                  ScrollView(.horizontal) {
                    HStack {
                      ForEach(suggestions.prefix(10), id: \.self) { tag in
                        Button("#" + tag) {
                          var values = tagsText.components(separatedBy: ",")
                          values[values.count - 1] = "#" + tag
                          tagsText = values.joined(separator: ", ")
                        }
                      }
                    }
                  }
                }
                VStack(alignment: .leading, spacing: 4) {
                  Button {
                    showCategories = true
                  } label: {
                    HStack(spacing: 4) { Text("Categories"); Image(systemName: "chevron.down").font(.caption2) }
                  }
                  .popover(isPresented: $showCategories, arrowEdge: .bottom) {
                    ScrollView {
                      VStack(alignment: .leading, spacing: 2) {
                        ForEach(categorySections, id: \.self) { section in
                          Text(section).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 8)
                          ForEach(CatalogueVocabulary.all.filter { $0.section == section }) { category in
                            Toggle(category.name, isOn: Binding(get: { (draft.categories ?? []).contains(category.id) }, set: { enabled in
                              var values = Set(draft.categories ?? [])
                              if enabled { values.insert(category.id) } else { values.remove(category.id) }
                              draft.categories = values.sorted()
                            }))
                            .toggleStyle(.checkbox)
                            .padding(.leading, category.parentId == nil ? 0 : 16)
                          }
                        }
                      }.padding(12)
                    }.frame(width: 300, height: 360)
                  }
                  // The ticked categories, so the selection is visible without opening the popover.
                  let selected = (draft.categories ?? []).compactMap { id in CatalogueVocabulary.all.first { $0.id == id }?.name }
                  Text(selected.isEmpty ? "No categories selected" : selected.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                  Text("Main photograph").font(.headline)
                  if let hero = RecipePresentation(draft).hero {
                    Button("Replace…") { addImage(replacing: hero.id) }
                    Button("Remove", role: .destructive) { draft.blocks.removeAll { $0.id == hero.id } }
                  } else {
                    Text("None").foregroundStyle(.secondary)
                    Button("Add…") { addImage() }
                  }
                }
                TextField("My notes (kept separately from the clipping)", text: Binding(get: { draft.personalNotes ?? "" }, set: { draft.personalNotes = $0 }))
              }.padding(.top, 6)
            } label: {
              Text("Details — tags, categories, photo, notes").font(.headline)
            }
            if markdownMode {
              Text(
                "Editing as markdown. Headings use #, list items use -, instructions use 1. Lines reading [[media N]] stand in for your photographs and attachments; leave them in place to keep them. Switch back to Edit as sections, or Save, to apply your changes."
              ).font(.caption).foregroundStyle(.secondary)
              TextEditor(text: $markdownText).font(.body.monospaced()).frame(minHeight: 360)
                .padding(4).background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
            Text(
              "Edit or remove any section. Changes are saved only when you choose Save. The original clipping is kept separately."
            ).font(.caption).foregroundStyle(.secondary)
            HStack {
              Menu("Add text") {
                Button("Paragraph") { add(.text) }
                Button("Heading") { add(.heading) }
                Button("List item") { add(.bullet) }
                Button("Instruction") { add(.step) }
              }
              Button("Add photographs…") { addImage() }
              Button("Paste photograph") { pasteImage() }
              Spacer()
              Text("\(draft.blocks.count) sections").font(.caption).foregroundStyle(.secondary)
            }
            ForEach($draft.blocks) { $block in
              VStack(alignment: .leading, spacing: 10) {
                HStack {
                  if block.kind != .image && block.kind != .missingImage && block.kind != .pdf && block.kind != .missingAttachment && block.kind != .originalImage {
                    Picker("Type", selection: $block.kind) {
                      Text("Text").tag(BlockKind.text)
                      Text("Heading").tag(BlockKind.heading)
                      Text("List item").tag(BlockKind.bullet)
                      Text("Instruction").tag(BlockKind.step)
                    }.frame(width: 190)
                  } else {
                    Text(block.kind == .originalImage ? "Original page attachment" : block.kind == .pdf ? "PDF attachment" : block.kind == .missingAttachment ? "Unavailable PDF" : block.kind == .image ? "Photograph" : "Unavailable photograph").font(
                      .headline)
                  }
                  Spacer()
                  Button {
                    move(block.id, by: -1)
                  } label: {
                    Image(systemName: "arrow.up")
                  }.help("Move section up").accessibilityLabel("Move section up").disabled(draft.blocks.first?.id == block.id)
                  Button {
                    move(block.id, by: 1)
                  } label: {
                    Image(systemName: "arrow.down")
                  }.help("Move section down").accessibilityLabel("Move section down").disabled(draft.blocks.last?.id == block.id)
                  Button(role: .destructive) {
                    let id = block.id
                    draft.blocks.removeAll { $0.id == id }
                  } label: {
                    Image(systemName: "trash")
                  }.help("Remove section").accessibilityLabel("Remove section")
                }
                if block.kind == .image {
                  Button("Replace photograph…") { addImage(replacing: block.id) }
                  if let key = block.assetPath, let data = stagedImages[key],
                    let image = NSImage(data: data)
                  {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                  } else {
                    RecipeImage(path: block.assetPath, height: 180)
                  }
                } else if block.kind != .missingImage && block.kind != .pdf && block.kind != .missingAttachment && block.kind != .originalImage {
                  TextEditor(text: $block.text).font(.body).frame(minHeight: 70, maxHeight: 180)
                    .padding(4).background(Color(nsColor: .textBackgroundColor))
                }
              }.padding(12).background(Color.secondary.opacity(0.07)).clipShape(
                RoundedRectangle(cornerRadius: 10)
              ).id(block.id)
            }
            }
          }.padding(.horizontal, 24).padding(.bottom, 12)
        }.onChange(of: draft.blocks.count) { count in
          if count > previousCount, let last = draft.blocks.last {
            proxy.scrollTo(last.id, anchor: .bottom)
          }
          previousCount = count
        }
      }
      Divider()
      HStack {
        Spacer()
        Button("Cancel") {
          if isNew { library.discard(draft.id) }
          dismiss()
        }.keyboardShortcut(.cancelAction)
        Button("Save", action: save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
          .disabled(saving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }.padding(.horizontal, 24).padding(.vertical, 12)
    }.frame(minWidth: 580, idealWidth: 760, maxWidth: .infinity, minHeight: 400, idealHeight: 640, maxHeight: .infinity)
      .interactiveDismissDisabled()
      .alert(
        "Could not update recipe",
        isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
      ) {
        Button("OK") { error = nil }
      } message: {
        Text(error ?? "")
      }
  }
}
