import AppKit
import SwiftUI

/// UserDefaults-backed server configuration, shared between the Settings
/// form (via `@AppStorage`) and `ServerController` (which reads the
/// effective values when it spawns dht-server). Keys and defaults live
/// here so the two never drift.
enum DHTSettings {
  static let modelsDirectoryKey = "models_directory"
  static let portKey = "port"
  static let bindScopeKey = "bind_scope"
  static let authTokenKey = "auth_token"
  static let secretModeKey = "secret_mode"

  static let defaultPort = 7766
  /// Reachability scope: "private" (loopback only) or "public" (LAN).
  /// The server is always dual-stack — no IPv4/IPv6 choice is exposed.
  static let defaultBindScope = "private"

  /// Autonomous, app-owned model store — independent of the Draw Things app.
  static var defaultModelsDirectory: String {
    let base = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("DHTServer/Models", isDirectory: true).path
  }

  /// The Draw Things app's own model directory — offered as a one-click
  /// alternative in the Settings form.
  static var drawThingsModelsDirectory: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Containers/com.liuliu.draw-things/Data/Documents/Models",
        isDirectory: true).path
  }

  // Effective values — what ServerController launches dht-server with.

  static var modelsDirectory: String {
    let stored = UserDefaults.standard.string(forKey: modelsDirectoryKey)
    return (stored?.isEmpty == false) ? stored! : defaultModelsDirectory
  }

  static var port: Int {
    let stored = UserDefaults.standard.integer(forKey: portKey)
    return stored == 0 ? defaultPort : stored
  }

  static var bindScope: String {
    UserDefaults.standard.string(forKey: bindScopeKey) ?? defaultBindScope
  }

  static var authToken: String {
    UserDefaults.standard.string(forKey: authTokenKey) ?? ""
  }

  /// "Secret mode": when on, the server runs with `--silent` and the app
  /// discards its stdout/stderr — the run produces no logs of any kind.
  /// Defaults to off (UserDefaults.bool defaults to false).
  static var secretMode: Bool {
    UserDefaults.standard.bool(forKey: secretModeKey)
  }
}

/// The Settings form. Edits write straight through to UserDefaults via
/// `@AppStorage`; closing the window restarts the server to apply them.
struct SettingsView: View {
  @AppStorage(DHTSettings.modelsDirectoryKey)
  private var modelsDirectory = DHTSettings.defaultModelsDirectory
  @AppStorage(DHTSettings.portKey)
  private var port = DHTSettings.defaultPort
  @AppStorage(DHTSettings.bindScopeKey)
  private var bindScope = DHTSettings.defaultBindScope
  @AppStorage(DHTSettings.authTokenKey)
  private var authToken = ""
  @AppStorage(DHTSettings.secretModeKey)
  private var secretMode = false

  var body: some View {
    Form {
      Section("Models") {
        Text(modelsDirectory)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        HStack {
          Button("Choose…", action: chooseDirectory)
          Button("Use Draw Things' Models") {
            modelsDirectory = DHTSettings.drawThingsModelsDirectory
          }
          Button("Default") {
            modelsDirectory = DHTSettings.defaultModelsDirectory
          }
        }
      }

      Section("Network") {
        TextField("Port", value: $port, format: .number.grouping(.never))
        Picker("Reachability", selection: $bindScope) {
          Text("Private — this Mac only").tag("private")
          Text("Public — local network").tag("public")
        }
        .pickerStyle(.radioGroup)
        if bindScope == "public" {
          TextField("Bearer token", text: $authToken)
          if authToken.isEmpty {
            Label("A token is required for a public bind.",
                  systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      }

      Section("Privacy") {
        Toggle("Secret mode", isOn: $secretMode)
        Text("Produces no logs of any kind: the server runs silently and "
             + "its output is discarded, so the activity window stays empty "
             + "and nothing is written anywhere. Restarts the server.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        Text("The server is dual-stack (IPv4 + IPv6). Network changes "
             + "restart it when you close this window.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Select"
    if panel.runModal() == .OK, let url = panel.url {
      modelsDirectory = url.path
    }
  }
}

/// Manages the Settings window — an on-demand AppKit `NSWindow`, like the
/// log window. See `LogWindowController` for why a SwiftUI scene is not used.
///
/// On close, if any server setting changed, the server is restarted to apply
/// it — with a confirmation when generations are in flight (a restart cancels
/// them).
final class SettingsWindowController: NSObject, NSWindowDelegate {
  static let shared = SettingsWindowController()

  private var window: NSWindow?
  /// Snapshot of the settings taken when the window opened, compared on
  /// close to decide whether a restart is needed.
  private var openedWith: [String: String] = [:]

  func show() {
    if let window {
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      return
    }

    openedWith = Self.currentSettings()

    let hosting = NSHostingController(rootView: SettingsView())
    let win = NSWindow(contentViewController: hosting)
    win.title = "DHT Server — Settings"
    win.styleMask = [.titled, .closable, .resizable]
    win.setContentSize(NSSize(width: 480, height: 420))
    win.isReleasedWhenClosed = false
    win.delegate = self
    win.center()
    window = win
    DockPolicy.windowOpened()
    win.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    window = nil
    DockPolicy.windowClosed()
    if Self.currentSettings() != openedWith {
      Self.applyChangedSettings()
    }
  }

  private static func currentSettings() -> [String: String] {
    [
      "scope": DHTSettings.bindScope,
      "port": String(DHTSettings.port),
      "models": DHTSettings.modelsDirectory,
      "token": DHTSettings.authToken,
      "secret": String(DHTSettings.secretMode),
    ]
  }

  /// Restarts the server to apply changed settings. Warns first when
  /// generations are in flight, since a restart cancels them.
  private static func applyChangedSettings() {
    let controller = ServerController.shared
    guard controller.status == .running || controller.status == .starting else { return }
    // Deferred so the alert never runs while the window is mid-close.
    DispatchQueue.main.async {
      let active = controller.runs.count
      guard active > 0 else {
        controller.restart()
        return
      }
      let alert = NSAlert()
      alert.messageText = "Restart the server to apply changes?"
      alert.informativeText =
        "\(active) generation\(active == 1 ? " is" : "s are") in progress. "
        + "Restarting cancels \(active == 1 ? "it" : "them")."
      alert.addButton(withTitle: "Restart Now")
      alert.addButton(withTitle: "Later")
      if alert.runModal() == .alertFirstButtonReturn {
        controller.restart()
      }
    }
  }
}
