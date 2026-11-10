import AppKit
import SwiftUI

/// Return belongs to the recipe list, not a search field or an editor.
struct RecipeListKeyboard: NSViewRepresentable {
  var open: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.view = view
    context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
      guard let coordinator, let window = coordinator.view?.window,
        event.window === window, [36, 76].contains(event.keyCode),
        event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
      var responder = window.firstResponder as? NSView
      while let current = responder {
        if current is NSTextView { return event }
        if current is NSTableView { coordinator.open?(); return nil }
        responder = current.superview
      }
      return event
    }
    return view
  }
  func updateNSView(_ view: NSView, context: Context) { context.coordinator.open = open }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
  }
  final class Coordinator {
    weak var view: NSView?
    var monitor: Any?
    var open: (() -> Void)?
  }
}
