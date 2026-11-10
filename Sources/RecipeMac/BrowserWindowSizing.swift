import AppKit
import SwiftUI

/// Configure the actual browser window without imposing an ideal/fixed content size.
struct BrowserWindowSizing: NSViewRepresentable {
  func makeNSView(context: Context) -> SizingView { SizingView() }
  func updateNSView(_ view: SizingView, context: Context) {}
  final class SizingView: NSView {
    private weak var configuredWindow: NSWindow?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window, window !== configuredWindow else { return }
      configuredWindow = window
      window.styleMask.insert(.resizable)
      window.contentMinSize = NSSize(width: 700, height: 500)
      let name = NSWindow.FrameAutosaveName("RecipeApp.Browser")
      // On first run (no remembered frame) open at a generous three-pane size, centred and
      // clamped to the screen. After that the user's own size is restored.
      if !window.setFrameUsingName(name) {
        let target = NSSize(width: 1400, height: 860)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
          let size = NSSize(width: min(target.width, visible.width), height: min(target.height, visible.height))
          let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
          window.setFrame(NSRect(origin: origin, size: size), display: true)
        } else {
          window.setContentSize(target)
          window.center()
        }
      }
      window.setFrameAutosaveName(name)
    }
  }
}
