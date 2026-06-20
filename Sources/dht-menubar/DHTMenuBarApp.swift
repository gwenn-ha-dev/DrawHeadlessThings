import AppKit
import SwiftUI

/// Menu-bar agent that supervises the `dht-server` process. No Dock icon
/// (`LSUIElement` in the assembled bundle's Info.plist) — the only surface
/// is the status dot in the menu bar.
@main
struct DHTMenuBarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var controller = ServerController.shared

  var body: some Scene {
    MenuBarExtra {
      MenuContent(controller: controller)
    } label: {
      // Monochrome template image — adapts to the menu-bar appearance.
      // Status is the symbol *shape*; the pulse (job + transient states) is
      // a reinforcement, never the only cue.
      Image(systemName: controller.menuBarSymbol)
        .symbolEffect(.pulse, isActive: controller.isAnimating)
    }
  }
}

/// Drives server start/stop with the app's own lifecycle: launching the app
/// starts the server, quitting it (or logging out) stops the server.
/// Nothing here runs at machine boot — the user opens the app explicitly.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    ServerController.shared.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    ServerController.shared.stopAndWait()
  }
}

/// Contents of the menu-bar dropdown. A native menu (no rich views), so state
/// reads through grouping and text: a header + status line, a job line only
/// while busy, then clipboard / create / server-control / app sections.
struct MenuContent: View {
  @ObservedObject var controller: ServerController

  private var isRunning: Bool { controller.status == .running }

  var body: some View {
    // Status
    Text("Draw Things Server")
    Text(statusLine)
    if controller.isBusy {
      Text(jobLine)
    }

    Divider()

    // Clipboard — the endpoint reflects the configured bind even when stopped;
    // the token only exists in public scope.
    Button("Copy Endpoint") { copy(controller.endpoint) }
    if !controller.apiToken.isEmpty {
      Button("Copy API Token") { copy(controller.apiToken) }
    }

    Divider()

    // Create — explain the disabled state rather than greying out in silence.
    if !isRunning {
      Text("Start the server to generate")
    }
    Button("Generate…") { GenerateWindowController.shared.show() }
      .keyboardShortcut("g")
      .disabled(!isRunning)
    Button("Activity") { LogWindowController.shared.show() }

    Divider()

    // Server control
    switch controller.status {
    case .stopped:
      Button("Start Server") { controller.start() }
    case .starting, .running:
      Button("Stop Server") { controller.stop() }
    case .stopping:
      Button("Stopping…") {}.disabled(true)
    }
    Button("Restart Server") { controller.restart() }
      .disabled(controller.status == .stopped || controller.status == .stopping)
    Button("API Docs") { openPath("/docs") }
      .disabled(!isRunning)
    Button("MCP Setup") { openPath("/mcp/setup") }
      .disabled(!isRunning)

    Divider()

    Button("Settings…") { SettingsWindowController.shared.show() }
      .keyboardShortcut(",")

    Divider()

    Button("Quit") {
      controller.stopAndWait()
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }

  private var statusLine: String {
    "\(controller.status.label) · localhost:\(controller.boundPort) · \(controller.boundScope)"
  }

  private var jobLine: String {
    let waiting = controller.waitingCount
    return "\(controller.runs.count) in flight"
      + (waiting > 0 ? " · \(waiting) waiting" : "")
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func openPath(_ path: String) {
    guard let url = URL(string: "\(controller.endpoint)\(path)") else { return }
    NSWorkspace.shared.open(url)
  }
}
