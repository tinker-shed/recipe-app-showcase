import SwiftUI
import RecipeCore

struct CatalogueReviewCard: View {
  @State var recipe: Recipe
  var resolve: (Recipe, Bool) -> Void
  @State private var tags = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField("Display title", text: $recipe.title).font(.headline)
      Text("Catalogue confidence: \(recipe.catalogueConfidence ?? 0, specifier: "%.2f")").font(.caption)
      Toggle("This is a recipe", isOn: Binding(get: { !recipe.isNote }, set: { recipe.isRecipe = $0 }))
      TextField("Tags, separated by commas", text: $tags)
      Menu("Categories") {
        ForEach(CatalogueVocabulary.all) { category in
          Toggle(category.name, isOn: Binding(get: { (recipe.categories ?? []).contains(category.id) }, set: { enabled in
            var values = Set(recipe.categories ?? [])
            if enabled { values.insert(category.id) } else { values.remove(category.id) }
            recipe.categories = values.sorted()
          }))
        }
      }
      Text((recipe.categories ?? []).joined(separator: ", ")).font(.caption)
      DisclosureGroup("Read original text") { Text(recipe.markdown).textSelection(.enabled) }
      HStack {
        Button("Accept and import") {
          recipe.tags = tags.components(separatedBy: ",").map(CatalogueVocabulary.tag).filter { !$0.isEmpty }
          resolve(recipe, true)
        }.disabled(recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Skip") { resolve(recipe, false) }
      }
    }.onAppear { tags = (recipe.tags ?? []).joined(separator: ", ") }
  }
}
