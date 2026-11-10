import SwiftUI
#if os(macOS)
import IOKit.pwr_mgt
#else
import UIKit
#endif

@MainActor final class CookingWakeController: ObservableObject {
  #if os(macOS)
  private var assertion: IOPMAssertionID = 0
  #endif
  func setEnabled(_ enabled: Bool) {
    #if os(macOS)
    if enabled && assertion == 0 {
      IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn), "RecipeApp cooking mode" as CFString, &assertion)
    } else if !enabled && assertion != 0 {
      IOPMAssertionRelease(assertion)
      assertion = 0
    }
    #else
    UIApplication.shared.isIdleTimerDisabled = enabled
    #endif
  }
  deinit {
    #if os(macOS)
    if assertion != 0 { IOPMAssertionRelease(assertion) }
    #endif
  }
}

public struct CookingView: View {
  public let recipe: Recipe
  public var onCooked: () -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var session = CookingSession()
  @StateObject private var wake = CookingWakeController()
  @State private var finishing = false
  public init(recipe: Recipe, onCooked: @escaping () -> Void) {
    self.recipe = recipe
    self.onCooked = onCooked
  }
  public var body: some View {
    VStack(spacing: 16) {
      HStack {
        Text(recipe.title).font(.title2.bold())
        Spacer()
        Button("Finish") { finishing = true }
      }
      Toggle("Keep screen awake while cooking", isOn: $session.keepAwake)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 24) {
          ForEach(recipe.blocks.filter { [.heading, .text, .bullet, .step].contains($0.kind) }) { block in
            if RecipePresentation.ingredientIDs(recipe).contains(block.id) {
              Button {
                session.toggleIngredient(block.id)
              } label: {
                HStack(alignment: .top, spacing: 16) {
                  Image(systemName: session.checked.contains(block.id) ? "checkmark.circle.fill" : "circle")
                  Text(block.text).multilineTextAlignment(.leading)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
              }.buttonStyle(.plain)
                .accessibilityValue(session.checked.contains(block.id) ? "Checked" : "Unchecked")
            } else {
              Text(block.text).font(block.kind == .heading ? .title2.bold() : .title2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(session.currentBlock == block.id ? Color.accentColor.opacity(0.15) : Color.clear)
                .onTapGesture { session.highlight(block.id) }
            }
          }
        }.font(.title2).frame(maxWidth: 900)
      }
    }.padding(24)
      .onAppear { session.active = true; session.foreground = scenePhase == .active; wake.setEnabled(session.shouldPreventSleep) }
      .onChange(of: session.keepAwake) { _ in wake.setEnabled(session.shouldPreventSleep) }
      .onChange(of: scenePhase) { phase in session.foreground = phase == .active; wake.setEnabled(session.shouldPreventSleep) }
      .onDisappear { session.finish(); wake.setEnabled(false) }
      .confirmationDialog("Add this meal to your cooking log?", isPresented: $finishing, titleVisibility: .visible) {
        Button("Add to log and finish") { onCooked(); session.finish(); wake.setEnabled(false); dismiss() }
        Button("Finish without logging") { session.finish(); wake.setEnabled(false); dismiss() }
        Button("Keep cooking", role: .cancel) {}
      }
  }
}
