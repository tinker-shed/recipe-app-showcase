import AppKit
import SwiftUI

/// Arrow-key navigation and Return for the grid, which (unlike List) has no built-in keyboard support.
/// Up/Down move by one row (the current column count), Left/Right by one. Text fields keep their keys.
struct RecipeGridKeyboard: NSViewRepresentable {
  var columns: Int
  var move: (Int) -> Void
  var open: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.view = view
    context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
      guard let coordinator, let window = coordinator.view?.window, event.window === window,
        event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
      // Never steal keys from a text field such as the search box or an editor.
      var responder = window.firstResponder as? NSView
      while let current = responder {
        if current is NSTextView { return event }
        responder = current.superview
      }
      let columns = max(1, coordinator.columns)
      switch event.keyCode {
      case 36, 76: coordinator.open?(); return nil       // Return / Enter
      case 126: coordinator.move?(-columns); return nil  // Up
      case 125: coordinator.move?(columns); return nil   // Down
      case 123: coordinator.move?(-1); return nil        // Left
      case 124: coordinator.move?(1); return nil         // Right
      default: return event
      }
    }
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.move = move
    context.coordinator.open = open
    context.coordinator.columns = columns
  }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
  }
  final class Coordinator {
    weak var view: NSView?
    var monitor: Any?
    var move: ((Int) -> Void)?
    var open: (() -> Void)?
    var columns = 1
  }
}
