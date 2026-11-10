import Foundation

/// Presentation only: preserve quantities, section order and all unclassified clipping text.
public struct RecipePresentation {
  public let hero: RecipeBlock?
  public let facts: [String]
  public let body: [RecipeBlock]
  public let originals: [RecipeBlock]
  public init(_ recipe: Recipe) {
    hero = recipe.heroImagePath.flatMap { path in recipe.blocks.first { $0.kind == .image && $0.assetPath == path && !Self.isReference($0) } }
    originals = recipe.blocks.filter { $0.kind == .pdf || Self.isReference($0) }
    facts = recipe.blocks.filter { block in
      guard block.kind == .text else { return false }
      return MarkdownImporter.match(#"(?i)^(serves?|servings?|yield|prep(?:aration)? time|cook(?:ing)? time|total time)\s*[:：]?\s+.+"#, block.text.replacingOccurrences(of: "**", with: "")) != nil
    }.map(\.text)
    let heroID = hero?.id
    let titleID = recipe.blocks.first { $0.kind == .heading && $0.level == 1 }?.id
    let factTexts = facts
    body = recipe.blocks.filter {
      $0.id != heroID && $0.id != titleID && !($0.kind == .heading && $0.text == recipe.title)
        && !factTexts.contains($0.text) && $0.kind != .pdf && !Self.isReference($0)
    }
  }
  public static func isReference(_ block: RecipeBlock) -> Bool {
    block.kind == .originalImage || block.kind == .image && (block.text.lowercased().contains("reference/")
      || block.text.lowercased().contains("original-page"))
  }
  public static func ingredientIDs(_ recipe: Recipe) -> Set<Int> {
    var inIngredients = false
    var ids = Set<Int>()
    for block in recipe.blocks {
      if block.kind == .heading {
        let title = block.text.lowercased()
        if title.contains("ingredient") { inIngredients = true }
        else if ["method", "instruction", "direction", "preparation", "notes", "nutrition"].contains(where: title.contains) { inIngredients = false }
      } else if inIngredients && (block.kind == .bullet || block.kind == .text) {
        ids.insert(block.id)
      }
    }
    return ids
  }
}
