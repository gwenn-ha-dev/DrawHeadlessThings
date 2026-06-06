import Foundation

/// Live snapshot of one in-flight generation run, exposed via `GET /v1/runs`.
struct RunInfo: Sendable {
  let runId: String
  let kind: String
  let prompt: String
  let width: Int
  let height: Int
  let steps: Int
  let startedAt: Date
  var currentStep: Int = 0
  var totalSteps: Int = 0
  /// Latest live-preview frame as PNG bytes, once the engine has emitted one.
  var previewPNG: Data?

  init(
    runId: String, kind: String,
    prompt: String, width: Int, height: Int, steps: Int
  ) {
    self.runId = runId
    self.kind = kind
    self.prompt = prompt
    self.width = width
    self.height = height
    self.steps = steps
    self.startedAt = Date()
  }
}

/// Tracks in-flight generation runs by `run_id`: their cancellation thunk
/// (for `DELETE /v1/runs/{id}`) and a live `RunInfo` snapshot (for the
/// `GET /v1/runs` observability endpoints). The engine feeds per-step
/// progress and preview frames in through `updateProgress`.
actor RunRegistry {
  private struct Entry {
    var info: RunInfo
    let cancel: () -> Void
  }
  private var active: [String: Entry] = [:]

  /// Register a run unconditionally, overwriting any entry with the same id.
  func register(_ info: RunInfo, cancel: @escaping () -> Void) {
    active[info.runId] = Entry(info: info, cancel: cancel)
  }

  /// Register only if the active count is strictly under `cap`. Check +
  /// insert happen inside the actor so concurrent requests can't race past
  /// the limit. `cap == nil` means uncapped. Returns false when at the cap.
  func tryRegister(_ info: RunInfo, cap: Int?, cancel: @escaping () -> Void) -> Bool {
    if let cap, active.count >= cap { return false }
    active[info.runId] = Entry(info: info, cancel: cancel)
    return true
  }

  /// Number of currently registered (in-flight) runs.
  func activeCount() -> Int { active.count }

  /// Fold a per-step progress tick — and an optional fresh preview frame —
  /// into a run's snapshot. The step counter only advances, so out-of-order
  /// delivery (each tick hops the actor on its own Task) can't rewind it.
  func updateProgress(_ runId: String, step: Int, total: Int, previewPNG: Data?) {
    guard var entry = active[runId] else { return }
    if step >= entry.info.currentStep {
      entry.info.currentStep = step
      entry.info.totalSteps = total
    }
    if let previewPNG {
      entry.info.previewPNG = previewPNG
    }
    active[runId] = entry
  }

  /// All in-flight runs, most recently started first.
  func list() -> [RunInfo] {
    active.values.map(\.info).sorted { $0.startedAt > $1.startedAt }
  }

  /// One run's snapshot, or nil if it is not (or no longer) in flight.
  func get(_ runId: String) -> RunInfo? {
    active[runId]?.info
  }

  /// Remove a run without cancelling it — called when it completes.
  func unregister(_ runId: String) {
    active.removeValue(forKey: runId)
  }

  /// Cancel the run if active. Returns true iff it existed at call time.
  func cancel(_ runId: String) -> Bool {
    guard let entry = active.removeValue(forKey: runId) else { return false }
    entry.cancel()
    return true
  }
}
