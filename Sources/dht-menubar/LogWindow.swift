import AppKit
import SwiftUI

/// Window content: a fixed job panel on top, the `tail -f` log below,
/// with a draggable divider between them.
struct LogView: View {
  @ObservedObject var controller: ServerController

  var body: some View {
    VSplitView {
      JobPanel(controller: controller)
        .frame(minHeight: 200, idealHeight: 250)
      logScroll
        .frame(minHeight: 120)
    }
    .onAppear { controller.jobPanelVisible = true }
    .onDisappear { controller.jobPanelVisible = false }
  }

  private var logScroll: some View {
    ScrollView {
      Text(logPlaceholder)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }
    .defaultScrollAnchor(.bottom)
  }

  /// Secret mode keeps no log, so the tail is always empty — say why,
  /// rather than imply the server is merely quiet.
  private var logPlaceholder: String {
    if controller.secretMode { return "Secret mode is on — logging is disabled." }
    return controller.logTail.isEmpty ? "(no server output yet)" : controller.logTail
  }
}

/// The current job's parameters and live preview, plus queue depth —
/// polled from `/v1/runs` by `ServerController`. Always visible: an idle
/// placeholder makes clear where a job will appear.
struct JobPanel: View {
  @ObservedObject var controller: ServerController

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: 8) {
        Text("CURRENT JOB")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)

        if let run = controller.activeRun {
          Text(run.kind).font(.headline)
          Text("\(run.width)×\(run.height) · \(run.steps > 0 ? run.steps : run.totalSteps) steps")
            .font(.caption).foregroundStyle(.secondary)
          if !run.prompt.isEmpty {
            Text(run.prompt).font(.caption).lineLimit(3)
          }
          if run.totalSteps > 0 {
            ProgressView(
              value: Double(min(run.currentStep, run.totalSteps)),
              total: Double(run.totalSteps)
            ) {
              Text("step \(run.currentStep) / \(run.totalSteps)").font(.caption2)
            }
            if let pace = run.paceDescription {
              Text(pace).font(.caption2).foregroundStyle(.secondary)
            }
          }
        } else {
          Text("No job running").foregroundStyle(.secondary)
        }

        Spacer(minLength: 0)

        if !controller.runs.isEmpty {
          Text("\(controller.runs.count) in flight"
               + (controller.waitingCount > 0 ? " · \(controller.waitingCount) waiting" : ""))
            .font(.caption2).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      previewBox
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var previewBox: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 6)
        .fill(Color(nsColor: .underPageBackgroundColor))
      if let png = controller.activePreviewPNG, let image = NSImage(data: png) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .padding(4)
      } else {
        Image(systemName: "photo")
          .font(.system(size: 32))
          .foregroundStyle(.tertiary)
      }
    }
    .frame(width: 210, height: 210)
  }
}

/// Manages the log window — an on-demand AppKit `NSWindow`. A SwiftUI
/// `Window` scene would auto-open at launch (no opt-out before macOS 15),
/// which a menu-bar agent must not do — so the window is created on demand.
///
/// While the window is open the app runs as `.regular` (Dock icon + app
/// menu visible); closing it drops back to `.accessory`, a pure menu-bar
/// agent. The dht-server process is never affected by the window lifecycle.
final class LogWindowController: NSObject, NSWindowDelegate {
  static let shared = LogWindowController()

  private var window: NSWindow?

  func show() {
    if let window {
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      return
    }

    let hosting = NSHostingController(rootView: LogView(controller: .shared))
    let win = NSWindow(contentViewController: hosting)
    win.title = "DHT Server — Activity"
    win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    win.setContentSize(NSSize(width: 720, height: 560))
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
  }
}
