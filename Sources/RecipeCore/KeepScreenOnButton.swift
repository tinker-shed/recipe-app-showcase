import SwiftUI

public struct ScreenAwakeState {
  public private(set) var enabled = false
  public init() {}
  public mutating func toggle() { enabled.toggle() }
  /// Closing or leaving the foreground cancels the request, rather than resuming it later.
  public mutating func deactivate() { enabled = false }
}

/// A labelled switch that keeps the display awake while a recipe is open, for
/// reading a recipe hands-free at the hob. Leaving the recipe or sending the app
/// to the background turns it off, rather than resuming it later.
public struct CookingModeToggle: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var state = ScreenAwakeState()
  @StateObject private var wake = CookingWakeController()
  public init() {}
  public var body: some View {
    let isOn = Binding(
      get: { state.enabled },
      set: { on in
        if on != state.enabled { state.toggle() }
        wake.setEnabled(state.enabled && scenePhase == .active)
      })
    // A compact labelled switch, sized to sit neatly inline in the recipe.
    return HStack(spacing: 8) {
      Image(systemName: "sun.max").foregroundStyle(.secondary).accessibilityHidden(true)
      Text("Cooking Mode")
      Toggle("Cooking Mode", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
    .font(.callout)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Cooking Mode")
    .accessibilityValue(state.enabled ? "On" : "Off")
    .help(state.enabled
      ? "Cooking Mode is on: the screen stays awake. Switch off to let it sleep."
      : "Cooking Mode: keep the screen awake while this recipe is open")
    .onChange(of: scenePhase) { phase in
      if phase != .active { state.deactivate(); wake.setEnabled(false) }
    }
    .onDisappear { state.deactivate(); wake.setEnabled(false) }
  }
}
