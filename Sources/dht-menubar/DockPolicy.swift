import AppKit

/// An `LSUIElement` agent has no Dock icon. While one or more auxiliary
/// windows (logs, settings) are open the app switches to `.regular` so a
/// Dock icon appears and the windows can take focus; when the last one
/// closes it drops back to `.accessory`. Callers must balance the calls.
enum DockPolicy {
  private static var openWindowCount = 0

  static func windowOpened() {
    openWindowCount += 1
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  static func windowClosed() {
    openWindowCount = max(0, openWindowCount - 1)
    if openWindowCount == 0 {
      NSApp.setActivationPolicy(.accessory)
    }
  }
}
