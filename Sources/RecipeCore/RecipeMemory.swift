import Foundation

public enum RecipeMemory {
  /// Replace fetched records without loading or decoding unrelated recipes.
  public static func updating(_ recipes: [Recipe], with updates: [Recipe]) -> [Recipe] {
    var result = recipes
    var positions = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.id, $0.offset) })
    for recipe in updates {
      if let index = positions[recipe.id] { result[index] = recipe }
      else { positions[recipe.id] = result.count; result.append(recipe) }
    }
    return result
  }
}
