import Foundation

@testable import dht_server

/// In-process fake of `GenerationEngine`. Drives a deterministic canned
/// response so route + SSE tests can exercise happy paths without loading
/// any real model. Wraps an internal lock because XCTest may invoke the
/// engine from multiple Tasks concurrently inside one test.
final class FakeEngine: GenerationEngine, @unchecked Sendable {
  struct Recipe: Sendable {
    /// Bytes used as the per-image payload. Tiny default ("fakeimg")
    /// keeps the on-wire transcript easy to read in assertion failures.
    var imageBytes: Data = Data("fakeimg".utf8)
    /// Bytes used as the per-video payload (mp4 base64 in the wire shape).
    var videoBytes: Data = Data("fakevid".utf8)
    /// Echoed as `metadata.effective_seed`.
    var seed: Int64 = 42
    /// Echoed as `metadata.warnings` and resolve `warnings`.
    var warnings: [Diagnostic] = []
    /// Echoed as `metadata.applied_defaults` and resolve `applied_defaults`.
    var appliedDefaults: [AppliedDefault] = []
    /// Echoed as resolve `errors[]`.
    var errors: [Diagnostic] = []
    /// Echoed as resolve `estimated_compute_units`.
    var estimatedComputeUnits: Int?
    /// When > 0 the fake fires that many `onProgress(i, total)` callbacks
    /// before resolving the response — used to drive SSE wire tests.
    var progressTotalSteps: Int = 0
    /// When set, every generation method throws this instead of returning.
    var error: Error?
    /// When true, generation blocks until its task is cancelled, then
    /// surfaces `CancellationError` — used to drive cancellation tests.
    var blockUntilCancelled: Bool = false
    /// Honor batch_size × batch_count on image responses (deterministic count).
    var honorBatchCount: Bool = true
  }

  private let lock = NSLock()
  private var recipe: Recipe

  init(_ recipe: Recipe = Recipe()) { self.recipe = recipe }

  func update(_ block: (inout Recipe) -> Void) {
    lock.lock(); defer { lock.unlock() }
    block(&recipe)
  }

  private func snapshot() -> Recipe {
    lock.lock(); defer { lock.unlock() }
    return recipe
  }

  private func makeMetadata(runId: String, recipe: Recipe) -> RunMetadata {
    RunMetadata(
      runId: runId,
      engineVersion: "fake-engine",
      effectiveSeed: recipe.seed,
      warnings: recipe.warnings,
      appliedDefaults: recipe.appliedDefaults)
  }

  private func firePromptProgress(
    _ onProgress: ProgressCallback?, total: Int
  ) {
    guard let onProgress, total > 0 else { return }
    for i in 1...total { onProgress(i, total, nil) }
  }

  private func imageCount(for params: EngineParams?, honor: Bool) -> Int {
    guard honor, let p = params else { return 1 }
    return max(1, (p.batchSize ?? 1) * (p.batchCount ?? 1))
  }

  private func makeImageResponse(
    runId: String, params: EngineParams?, onProgress: ProgressCallback?
  ) async throws -> GenerationResponse {
    let r = snapshot()
    if let err = r.error { throw err }
    if r.blockUntilCancelled {
      while true { try await Task.sleep(for: .milliseconds(20)) }
    }
    firePromptProgress(onProgress, total: r.progressTotalSteps)
    let n = imageCount(for: params, honor: r.honorBatchCount)
    return GenerationResponse(
      images: Array(repeating: r.imageBytes.base64EncodedString(), count: n),
      seed: r.seed,
      generationTimeMs: 0,
      metadata: makeMetadata(runId: runId, recipe: r))
  }

  private func makeVideoResponse(
    runId: String, params: EngineParams, video: VideoExtraParams,
    onProgress: ProgressCallback?
  ) async throws -> VideoGenerationResponse {
    let r = snapshot()
    if let err = r.error { throw err }
    firePromptProgress(onProgress, total: r.progressTotalSteps)
    let count = max(1, params.batchCount ?? 1)
    let videos = (0..<count).map { i in
      VideoResult(
        data: r.videoBytes.base64EncodedString(),
        format: video.effectiveFormat,
        width: params.width,
        height: params.height,
        numFrames: video.numFrames,
        fps: video.effectiveFps,
        durationMs: 0,
        seed: r.seed &+ Int64(i))
    }
    return VideoGenerationResponse(
      videos: videos, generationTimeMs: 0,
      metadata: makeMetadata(runId: runId, recipe: r))
  }

  func compose(
    _ request: ComposeRequest, runId: String, onProgress: ProgressCallback?
  ) async throws -> ComposeResult {
    // Mirror DrawThingsEngine: when the request carries `params.video`,
    // treat it as a video output; otherwise an image. Lets video tests run
    // through the fake without inspecting the catalog.
    if let video = request.params?.video, let p = request.params {
      return .video(try await makeVideoResponse(
        runId: runId, params: p, video: video, onProgress: onProgress))
    }
    return .image(try await makeImageResponse(
      runId: runId, params: request.params, onProgress: onProgress))
  }

  func edit(
    _ request: EditRequest, runId: String, onProgress: ProgressCallback?
  ) async throws -> GenerationResponse {
    try await makeImageResponse(
      runId: runId, params: request.params, onProgress: onProgress)
  }

  func restore(
    _ request: RestoreRequest, runId: String, onProgress: ProgressCallback?
  ) async throws -> GenerationResponse {
    try await makeImageResponse(
      runId: runId, params: request.params, onProgress: onProgress)
  }

  /// Deterministic pipeline fake: emits one entry per step (or per requested
  /// `return` name) under the step's `as` label (or `"result"` for the last
  /// step when `return` is omitted). Bytes are the configured `imageBytes`.
  /// Mirrors enough of the real engine that route + MCP tests can exercise
  /// `/v1/pipeline` without recipe execution.
  func pipeline(
    _ request: PipelineRequest, runId: String, onProgress: ProgressCallback?
  ) async throws -> PipelineResponse {
    let r = snapshot()
    if let err = r.error { throw err }
    let b64 = r.imageBytes.base64EncodedString()
    var outputs: [String: String] = [:]
    if let names = request.return, !names.isEmpty {
      for n in names { outputs[n] = b64 }
    } else {
      let label = request.steps.last?.as ?? "result"
      outputs[label] = b64
    }
    return PipelineResponse(outputs: outputs, generationTimeMs: 0)
  }

  private func makeResolveResponse(_ resolved: dht_server.Recipe?) -> ResolveResponse {
    let r = snapshot()
    return ResolveResponse(
      resolvedRequest: resolved,
      appliedDefaults: r.appliedDefaults,
      warnings: r.warnings,
      errors: r.errors,
      estimatedComputeUnits: r.estimatedComputeUnits)
  }

  func resolveCompose(_ request: ComposeRequest) async -> ResolveResponse {
    makeResolveResponse(request.params == nil ? nil : .compose(request))
  }

  func resolveEdit(_ request: EditRequest) async -> ResolveResponse {
    makeResolveResponse(request.params == nil ? nil : .edit(request))
  }

  func resolveRestore(_ request: RestoreRequest) async -> ResolveResponse {
    makeResolveResponse(request.params == nil ? nil : .restore(request))
  }
}
