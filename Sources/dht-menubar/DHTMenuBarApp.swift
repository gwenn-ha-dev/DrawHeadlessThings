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
      // Status is the symbol shape; a job in progress pulses.
      Image(systemName: controller.menuBarSymbol)
        .symbolEffect(.pulse, isActive: controller.isBusy)
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

/// Contents of the menu-bar dropdown.
struct MenuContent: View {
  @ObservedObject var controller: ServerController

  var body: some View {
    Text("Draw Things Server")
    Text("\(controller.status.label) — \(controller.boundScope) · port \(controller.boundPort)")

    Divider()

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

    Button("Show Activity") {
      LogWindowController.shared.show()
    }

    Button("Generate…") {
      GenerateWindowController.shared.show()
    }
    .disabled(controller.status != .running)

    Button("Open API Docs") {
      guard let url = URL(string: "\(controller.endpoint)/docs") else { return }
      NSWorkspace.shared.open(url)
    }
    .disabled(controller.status != .running)

    Button("MCP Setup") {
      guard let url = URL(string: "\(controller.endpoint)/mcp/setup") else { return }
      NSWorkspace.shared.open(url)
    }
    .disabled(controller.status != .running)

    Divider()

    Button("Settings…") {
      SettingsWindowController.shared.show()
    }

    Divider()

    Button("Quit") {
      controller.stopAndWait()
      NSApplication.shared.terminate(nil)
    }
  }
}
