import Combine
import Foundation

/// Lifecycle state of the wrapped `dht-server` process, mapped to the
/// menu-bar dot. Status is conveyed by symbol shape (monochrome label).
enum ServerStatus {
  case stopped
  case starting
  case running
  case stopping

  var label: String {
    switch self {
    case .stopped: return "Stopped"
    case .starting: return "Starting…"
    case .running: return "Running"
    case .stopping: return "Stopping…"
    }
  }

  var symbolName: String {
    switch self {
    case .stopped: return "circle"
    case .starting, .stopping: return "circle.dotted"
    case .running: return "circle.fill"
    }
  }
}

/// Owns the `dht-server` child process: spawn, graceful termination,
/// log capture, and `/v1/info` + `/v1/runs` polling. A single shared
/// instance so the SwiftUI scene and the `NSApplicationDelegate` operate on
/// the same state. All mutation happens on the main thread — background
/// callbacks (process exit, pipe reads, HTTP) hop back via
/// `Task { @MainActor in }`.
final class ServerController: ObservableObject {
  static let shared = ServerController()

  @Published private(set) var status: ServerStatus = .stopped
  @Published private(set) var logTail: String = ""

  /// Effective config of the running (or last-started) server. Snapshotted
  /// from `DHTSettings` at start() time so changing Settings mid-run never
  /// desyncs the health poll or the menu.
  @Published private(set) var boundScope = DHTSettings.defaultBindScope
  @Published private(set) var boundPort = DHTSettings.defaultPort
  /// Secret mode snapshot for the running server: when true the child runs
  /// with `--silent`, its stdout/stderr are discarded, and the app keeps no
  /// log — `logTail` stays empty and the activity window shows a notice.
  @Published private(set) var secretMode = false
  private var runningToken = ""

  /// In-flight runs polled from `GET /v1/runs`, and the active run's latest
  /// preview frame. Drive the job panel in the log window.
  @Published private(set) var runs: [RunSummary] = []
  @Published private(set) var activePreviewPNG: Data?
  /// Set by the log window so the heavier preview poll only runs while a
  /// panel is actually displaying it.
  var jobPanelVisible = false

  /// The run currently executing — with the engine serialising, that is the
  /// one furthest along. `waitingCount` is the rest, not yet started.
  var activeRun: RunSummary? { runs.max { $0.currentStep < $1.currentStep } }
  var waitingCount: Int { runs.filter { $0.currentStep == 0 }.count }

  /// True when the server is up and at least one generation is in flight.
  var isBusy: Bool { status == .running && !runs.isEmpty }

  /// Menu-bar icon: server-state symbol, or a distinct one while a job runs
  /// (paired with a pulse effect, so it reads even without the animation).
  var menuBarSymbol: String { isBusy ? "circle.circle.fill" : status.symbolName }

  private var process: Process?
  private var outputPipe: Pipe?
  private var pollTimer: Timer?
  private var restartPending = false

  /// Keep the in-memory log from growing unbounded; trim oldest half on overflow.
  private let maxLogBytes = 256 * 1024

  /// Local endpoint for health checks and links. The server is always
  /// dual-stack loopback (`127.0.0.1` + `::1`) in private scope and binds
  /// loopback under public too, so `localhost` reaches it whichever scope is
  /// active — and reads the same as the URLs in the docs.
  var endpoint: String { "http://localhost:\(boundPort)" }

  private init() {}

  // MARK: - Lifecycle

  func start() {
    guard process == nil else { return }
    // Snapshot secret mode first: it gates appendLog, so even start-time
    // errors below stay silent when secret mode is on. Clear any prior tail.
    secretMode = DHTSettings.secretMode
    if secretMode { logTail = "" }
    guard let binary = Self.locateServerBinary() else {
      appendLog("[dht-menubar] ERROR: dht-server binary not found in app bundle\n")
      return
    }

    let modelsDir = DHTSettings.modelsDirectory
    let scope = DHTSettings.bindScope
    let port = DHTSettings.port
    let token = DHTSettings.authToken

    // dht-server refuses a public bind without a token.
    if scope == "public" && token.isEmpty {
      appendLog("[dht-menubar] ERROR: a public bind requires a Bearer token — "
        + "set one in Settings\n")
      return
    }

    // dht-server refuses to start if the models directory is absent;
    // create the autonomous one on first run.
    do {
      try FileManager.default.createDirectory(
        atPath: modelsDir, withIntermediateDirectories: true)
    } catch {
      appendLog("[dht-menubar] ERROR: cannot create models directory "
        + "\(modelsDir): \(error)\n")
      return
    }

    var arguments = ["--bind", scope, "--port", String(port),
                     "--models-dir", modelsDir]
    if !token.isEmpty {
      arguments += ["--token", token]
    }
    if secretMode {
      arguments.append("--silent")
    }

    let proc = Process()
    proc.executableURL = binary
    proc.arguments = arguments

    // Secret mode: discard the child's stdout/stderr entirely (/dev/null) so
    // nothing it emits — including engine C-level output — is ever captured.
    // Otherwise capture into the in-memory tail shown by the activity window.
    var pipe: Pipe?
    if secretMode {
      proc.standardOutput = FileHandle.nullDevice
      proc.standardError = FileHandle.nullDevice
    } else {
      let p = Pipe()
      proc.standardOutput = p
      proc.standardError = p
      p.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        if data.isEmpty {
          handle.readabilityHandler = nil
          return
        }
        guard let text = String(data: data, encoding: .utf8) else { return }
        Task { @MainActor in self?.appendLog(text) }
      }
      pipe = p
    }

    proc.terminationHandler = { [weak self] _ in
      Task { @MainActor in self?.handleProcessExit() }
    }

    do {
      try proc.run()
    } catch {
      appendLog("[dht-menubar] ERROR: failed to launch dht-server: \(error)\n")
      return
    }

    process = proc
    outputPipe = pipe
    boundScope = scope
    boundPort = port
    runningToken = token
    status = .starting
    appendLog("[dht-menubar] started dht-server (pid \(proc.processIdentifier))"
      + " — \(scope), port \(port), models: \(modelsDir)\n")
    startPolling()
  }

  /// Asynchronous stop — SIGTERM, then `terminationHandler` flips state.
  func stop() {
    guard let proc = process else { return }
    status = .stopping
    appendLog("[dht-menubar] stopping dht-server…\n")
    proc.terminate()
  }

  /// Stop, then start again with the current Settings. Async: the start
  /// half runs from `handleProcessExit` once the old process is gone.
  func restart() {
    guard process != nil else {
      start()
      return
    }
    restartPending = true
    stop()
  }

  /// Synchronous stop used on app termination: blocks until the child is
  /// gone so the agent never leaves an orphaned server behind.
  func stopAndWait() {
    guard let proc = process, proc.isRunning else { return }
    proc.terminate()
    proc.waitUntilExit()
  }

  private func handleProcessExit() {
    pollTimer?.invalidate()
    pollTimer = nil
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    outputPipe = nil
    process = nil
    status = .stopped
    runs = []
    activePreviewPNG = nil
    appendLog("[dht-menubar] dht-server exited\n")
    if restartPending {
      restartPending = false
      start()
    }
  }

  // MARK: - Polling

  private func startPolling() {
    pollTimer?.invalidate()
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.poll() }
    }
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer
    poll()
  }

  private func poll() {
    pollHealth()
    pollRuns()
  }

  private func authorize(_ request: inout URLRequest) {
    if !runningToken.isEmpty {
      request.setValue("Bearer \(runningToken)", forHTTPHeaderField: "Authorization")
    }
  }

  private func pollHealth() {
    guard process != nil, let url = URL(string: "\(endpoint)/v1/info") else { return }
    var request = URLRequest(url: url)
    request.timeoutInterval = 1.5
    authorize(&request)
    URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
      let ok = (response as? HTTPURLResponse)?.statusCode == 200
      Task { @MainActor in self?.applyHealth(ok: ok) }
    }.resume()
  }

  private func applyHealth(ok: Bool) {
    guard let proc = process, proc.isRunning, status != .stopping else { return }
    status = ok ? .running : .starting
  }

  private func pollRuns() {
    guard process != nil, let url = URL(string: "\(endpoint)/v1/runs") else { return }
    var request = URLRequest(url: url)
    request.timeoutInterval = 1.5
    authorize(&request)
    URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
      let list = data.flatMap { try? JSONDecoder().decode(RunListResponse.self, from: $0) }
      Task { @MainActor in self?.applyRuns(list?.runs ?? []) }
    }.resume()
  }

  private func applyRuns(_ runs: [RunSummary]) {
    guard process != nil else { return }
    self.runs = runs
    guard jobPanelVisible, let active = activeRun else {
      activePreviewPNG = nil
      return
    }
    pollPreview(runId: active.runId)
  }

  private func pollPreview(runId: String) {
    let safeId = runId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runId
    guard let url = URL(string: "\(endpoint)/v1/runs/\(safeId)") else { return }
    var request = URLRequest(url: url)
    request.timeoutInterval = 1.5
    authorize(&request)
    URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
      let detail = data.flatMap { try? JSONDecoder().decode(RunDetail.self, from: $0) }
      let png = detail?.previewPngBase64.flatMap { Data(base64Encoded: $0) }
      Task { @MainActor in self?.activePreviewPNG = png }
    }.resume()
  }

  // MARK: - Logs

  private func appendLog(_ text: String) {
    // Secret mode: keep no log at all, not even the app's own status lines.
    guard !secretMode else { return }
    logTail += text
    if logTail.utf8.count > maxLogBytes {
      logTail = String(logTail.suffix(maxLogBytes / 2))
    }
  }

  // MARK: - Binary location

  /// In the assembled `.app` the server lives at `Contents/Resources/dht-server`.
  /// The dev fallback covers `swift run dht-menubar`, where both executables
  /// sit side by side in `.build/<config>/`.
  private static func locateServerBinary() -> URL? {
    let fm = FileManager.default
    if let resources = Bundle.main.resourceURL {
      let url = resources.appendingPathComponent("dht-server")
      if fm.isExecutableFile(atPath: url.path) { return url }
    }
    if let exe = Bundle.main.executableURL {
      let sibling = exe.deletingLastPathComponent().appendingPathComponent("dht-server")
      if fm.isExecutableFile(atPath: sibling.path) { return sibling }
    }
    return nil
  }
}
