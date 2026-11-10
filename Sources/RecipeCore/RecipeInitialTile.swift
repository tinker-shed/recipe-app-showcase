import SwiftUI

public struct RecipeTileAppearance: Equatable {
  public let initial: String
  public let paletteIndex: Int
  public init(title: String, notebook: String) {
    initial = title.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "?"
    // Stable between launches, unlike Swift's randomised Hasher.
    paletteIndex = notebook.lowercased().unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 6 }
  }
}

public struct RecipeInitialTile: View {
  let appearance: RecipeTileAppearance
  public init(title: String, notebook: String) {
    appearance = RecipeTileAppearance(title: title, notebook: notebook)
  }
  private let colours: [Color] = [
    Color(red: 0.43, green: 0.53, blue: 0.45), Color(red: 0.55, green: 0.49, blue: 0.39),
    Color(red: 0.43, green: 0.51, blue: 0.57), Color(red: 0.57, green: 0.45, blue: 0.42),
    Color(red: 0.52, green: 0.46, blue: 0.56), Color(red: 0.48, green: 0.53, blue: 0.52)
  ]
  public var body: some View {
    ZStack {
      colours[appearance.paletteIndex].opacity(0.18)
      Text(appearance.initial).font(.system(size: 32, weight: .medium, design: .serif)).foregroundStyle(.primary)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
