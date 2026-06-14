import CryptoKit
import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore
import UniformTypeIdentifiers
import _MediaGenerationKit

extension InfoResponse: ResponseEncodable {}
extension HealthResponse: ResponseEncodable {}
extension GenerationResponse: ResponseEncodable {}
extension VideoGenerationResponse: ResponseEncodable {}
extension ResolveResponse: ResponseEncodable {}
extension PipelineResponse: ResponseEncodable {}
extension AssetListResponse: ResponseEncodable {}
extension Asset: ResponseEncodable {}
extension RunListResponse: ResponseEncodable {}
extension RunDetailResponse: ResponseEncodable {}
extension CapabilitiesResponse: ResponseEncodable {}

func makeRouter(
  engine: any GenerationEngine,
  assets: AssetManager,
  registry: RunRegistry,
  config: ServerConfig
) -> Router<BasicRequestContext> {
  let router = Router()

  // Log meaningful requests so a supervisor (the DHTServer.app log window,
  // or a plain `dht-server` terminal) shows real activity. Polling and
  // static-UI endpoints are skipped — see RequestLogMiddleware.
  router.middlewares.add(RequestLogMiddleware<BasicRequestContext>())

  // Bearer auth applies to a public bind. `ServerConfig.parse` already
  // refuses to start public without a token, so the `let` is purely
  // defensive. A private bind skips the middleware entirely.
  if config.scope == .public, let token = config.token {
    router.middlewares.add(BearerAuthMiddleware<BasicRequestContext>(token: token))
  }

  mountSwaggerRoutes(on: router)

  // MCP (Model Context Protocol) over Streamable HTTP. Shares this process's
  // engine + asset manager — `/mcp` is the only MCP transport (there is no
  // stdio mode); a localhost AI client connects to it exactly like a remote
  // one. Sits behind the same BearerAuth middleware as the REST routes.
  var mcpLogger = Logger(label: "dht-mcp")
  mcpLogger.logLevel = config.logLevel
  mountMCPRoutes(
    on: router,
    server: MCPServer(
      engine: engine, assets: assets, registry: registry,
      readOnly: config.readOnly, maxActiveRuns: config.maxActiveRuns, logger: mcpLogger))
  mountMCPSetupRoute(on: router, config: config)

  // Liveness probe. Auth-exempt (see BearerAuthMiddleware) so supervisors and
  // uptime monitors can probe without a token. Returns 200 `{"status":"ok"}`
  // whenever the process is up and routing — the server is stateless, so there
  // is no readiness gate beyond "listening".
  router.get("/health") { _, _ -> HealthResponse in
    HealthResponse(status: "ok")
  }

  router.get("/v1/info") { _, _ -> InfoResponse in
    InfoResponse(apiVersion: dhtAPIVersion, engineVersion: dhtEngineVersion)
  }

  router.post("/v1/compose") { request, context -> Response in
    let body = try await request.decode(as: ComposeRequest.self, context: context)
    guard let params = body.params else { throw TypedError.from(engineError: .paramsRequired) }
    let runId = body.runId ?? UUID().uuidString
    let info = composeRunInfo(runId: runId, body: body, params: params)
    if streamFlag(request) {
      return try await sseGeneration(registry: registry, info: info, cap: config.maxActiveRuns) { onProgress in
        try await engine.compose(body, runId: runId, onProgress: onProgress)
      }
    }
    let result = try await runCancellable(registry: registry, info: info, cap: config.maxActiveRuns) { onProgress in
      try await engine.compose(body, runId: runId, onProgress: onProgress)
    }
    switch result {
    case .image(let response):
      return try imageGenerationResponse(
        response, format: params.outputFormat ?? .png,
        request: request, context: context,
        extraHeaders: recipeHeaders(verb: "compose", request: body,
                                    appliedDefaults: response.metadata.appliedDefaults))
    case .video(let response):
      return try videoGenerationResponse(
        response, request: request, context: context,
        extraHeaders: recipeHeaders(verb: "compose", request: body,
                                    appliedDefaults: response.metadata.appliedDefaults))
    }
  }

  router.post("/v1/edit") { request, context -> Response in
    let body = try await request.decode(as: EditRequest.self, context: context)
    guard let params = body.params else { throw TypedError.from(engineError: .paramsRequired) }
    let runId = body.runId ?? UUID().uuidString
    let info = RunInfo(
      runId: runId, kind: "edit", prompt: body.instruction,
      width: params.width, height: params.height, steps: params.steps ?? 0)
    if streamFlag(request) {
      return try await sseGeneration(registry: registry, info: info, cap: config.maxActiveRuns) { onProgress in
        try await engine.edit(body, runId: runId, onProgress: onProgress)
      }
    }
    let result = try await runCancellable(registry: registry, info: info, cap: config.maxActiveRuns) { onProgress in
      try await engine.edit(body, runId: runId, onProgress: onProgress)
    }
    return try imageGenerationResponse(
      result, format: params.outputFormat ?? .png,
      request: request, context: context,
      extraHeaders: recipeHeaders(verb: "edit", request: body,
                                  appliedDefaults: result.metadata.appliedDefaults))
  }

  router.post("/v1/restore") { request, context -> Response in
    let body = try await request.decode(as: RestoreRequest.self, context: context)
    guard let params = body.params else { throw TypedError.from(engineError: .paramsRequired) }
    let runId = body.runId ?? UUID().uuidString
    let info = RunInfo(
      runId: runId, kind: "restore", prompt: "",
      width: params.width, height: params.height, steps: params.steps ?? 0)
    if streamFlag(request) {
      return try await sseGeneration(registry: registry, info: info, cap: config.maxActiveRuns) { onProgress in
        try await engine.restore(body, runId: runId, onProgress: onProgress)
      }
    }
    let result = try await runCancellable(registry: registry, info: info, cap: config.maxActiveRuns) { onProgress in
      try await engine.restore(body, runId: runId, onProgress: onProgress)
    }
    return try imageGenerationResponse(
      result, format: params.outputFormat ?? .png,
      request: request, context: context,
      extraHeaders: recipeHeaders(verb: "restore", request: body,
                                  appliedDefaults: result.metadata.appliedDefaults))
  }

  router.post("/v1/pipeline") { request, context -> Response in
    let body = try await request.decode(as: PipelineRequest.self, context: context)
    let runId = UUID().uuidString
    // Pipeline runs as a single unit in the registry — sub-steps are tracked
    // internally via `\(runId).stepN` sub-ids on the engine, but the registry
    // only sees the outer run so concurrent-run caps stay sane.
    let info = RunInfo(
      runId: runId, kind: "pipeline",
      prompt: "\(body.steps.count)-step pipeline",
      width: 0, height: 0, steps: body.steps.count)
    let response = try await runCancellable(
      registry: registry, info: info, cap: config.maxActiveRuns
    ) { onProgress in
      try await engine.pipeline(body, runId: runId, onProgress: onProgress)
    }
    var extras = HTTPFields()
    if let v = pipelineRecipeHeaderValue(body) { extras[DHTHeader.recipe] = v }
    return try jsonResponse(response, extraHeaders: extras)
  }

  router.post("/v1/resolve/compose") { request, context -> ResolveResponse in
    let body = try await request.decode(as: ComposeRequest.self, context: context)
    return await engine.resolveCompose(body)
  }

  router.post("/v1/resolve/edit") { request, context -> ResolveResponse in
    let body = try await request.decode(as: EditRequest.self, context: context)
    return await engine.resolveEdit(body)
  }

  router.post("/v1/resolve/restore") { request, context -> ResolveResponse in
    let body = try await request.decode(as: RestoreRequest.self, context: context)
    return await engine.resolveRestore(body)
  }

  router.delete("/v1/runs/:run_id") { _, context -> Response in
    guard let runId = context.parameters.get("run_id") else {
      throw TypedError(
        status: .badRequest, errorCode: "VALIDATION_FAILED",
        title: "Missing run_id path parameter", detail: nil)
    }
    let found = await registry.cancel(runId)
    if !found {
      throw TypedError(
        status: .notFound, errorCode: "RUN_NOT_FOUND",
        title: "No active run with this id",
        detail:
          "run_id '\(runId)' is not currently active (already completed, "
          + "never registered, or the registry entry expired)")
    }
    return Response(status: .noContent)
  }

  router.get("/v1/runs") { _, _ -> RunListResponse in
    RunListResponse(runs: await registry.list().map(runSummary))
  }

  router.get("/v1/runs/:run_id") { _, context -> RunDetailResponse in
    guard let runId = context.parameters.get("run_id") else {
      throw TypedError(
        status: .badRequest, errorCode: "VALIDATION_FAILED",
        title: "Missing run_id path parameter", detail: nil)
    }
    guard let info = await registry.get(runId) else {
      throw TypedError(
        status: .notFound, errorCode: "RUN_NOT_FOUND",
        title: "No active run with this id",
        detail: "run_id '\(runId)' is not currently in flight")
    }
    return runDetail(info)
  }

  router.get("/v1/assets") { request, _ -> AssetListResponse in
    let q = request.uri.queryParameters
    let filter = AssetManager.Filter(
      type: q["type"].flatMap { AssetType(rawValue: String($0)) },
      architecture: q["architecture"].flatMap { Architecture(rawValue: String($0)) },
      domain: q["domain"].flatMap { Domain(rawValue: String($0)) },
      controlnetTask: q["task"].flatMap { ControlNetTask(rawValue: String($0)) },
      downloadedOnly: (q["downloaded"].map(String.init) ?? "true") != "false"
    )
    return AssetListResponse(items: await assets.list(filter: filter))
  }

  router.get("/v1/capabilities/:model_id") { _, context -> CapabilitiesResponse in
    guard let modelId = context.parameters.get("model_id") else {
      throw TypedError(
        status: .badRequest, errorCode: "VALIDATION_FAILED",
        title: "Missing model_id path parameter", detail: nil)
    }
    guard let response = CapabilityMap.response(forModelId: modelId) else {
      throw TypedError(
        status: .notFound, errorCode: "MODEL_NOT_INSTALLED",
        title: "Model not in catalog",
        detail: "no catalog entry for base_model_id '\(modelId)'")
    }
    return response
  }

  router.get("/v1/assets/:id") { _, context -> Asset in
    guard let id = context.parameters.get("id") else {
      throw TypedError(
        status: .badRequest, errorCode: "VALIDATION_FAILED",
        title: "Missing id path parameter", detail: nil)
    }
    guard let asset = await assets.get(id: id) else {
      throw TypedError(
        status: .notFound, errorCode: "MODEL_NOT_INSTALLED",
        title: "Asset not found", detail: "no asset with id '\(id)'")
    }
    return asset
  }

  router.delete("/v1/assets/:id") { _, context -> Response in
    if config.readOnly { throw readOnlyError(operation: "DELETE /v1/assets/{id}") }
    guard let id = context.parameters.get("id") else {
      throw TypedError(
        status: .badRequest, errorCode: "VALIDATION_FAILED",
        title: "Missing id path parameter", detail: nil)
    }
    do {
      try await assets.delete(id: id)
    } catch let error as AssetMutationError {
      throw TypedError.from(mutationError: error)
    }
    return Response(status: .noContent)
  }

  router.post("/v1/assets/install") { request, context -> Response in
    if config.readOnly { throw readOnlyError(operation: "POST /v1/assets/install") }
    let body = try await request.decode(as: InstallAssetRequest.self, context: context)
    if streamFlag(request) {
      return await sseInstall(assets: assets, request: body)
    }
    do {
      let asset = try await assets.install(body)
      return try asset.response(from: request, context: context)
    } catch let error as AssetMutationError {
      throw TypedError.from(mutationError: error)
    } catch let error as MediaGenerationKitError {
      throw TypedError(
        status: .internalServerError, errorCode: "ENGINE_INTERNAL_ERROR",
        title: "Engine error during install", detail: "\(error)")
    }
  }

  return router
}

/// True if the request's URI carries `?stream=true`.
private func streamFlag(_ request: Request) -> Bool {
  request.uri.queryParameters["stream"].map(String.init) == "true"
}

/// Builds the `RunInfo` recorded for a `/v1/compose` run. Matches the engine's
/// internal dispatch (`compose`): the `kind` field on the registry stays as
/// `"compose"` regardless of which underlying pipeline path runs, so listings
/// reflect the verb the caller asked for.
private func composeRunInfo(
  runId: String, body: ComposeRequest, params: EngineParams
) -> RunInfo {
  RunInfo(
    runId: runId, kind: "compose", prompt: body.prompt,
    width: params.width, height: params.height, steps: params.steps ?? 0)
}

/// Refuse a mutation that's gated by `--read-only`.
private func readOnlyError(operation: String) -> TypedError {
  TypedError(
    status: .forbidden,
    errorCode: "READ_ONLY_MODE",
    title: "Server is running in read-only mode",
    detail: "\(operation) is disabled. Restart without --read-only to enable.")
}

/// Refuse a generation when the registry is already at `--max-active-runs`.
private func tooManyActiveRunsError(active: Int, cap: Int) -> TypedError {
  TypedError(
    status: .init(code: 503, reasonPhrase: "Service Unavailable"),
    errorCode: "TOO_MANY_ACTIVE_RUNS",
    title: "Server is at concurrent-run capacity",
    detail: "\(active) active runs, --max-active-runs=\(cap). Retry later.")
}

/// SSE event envelope: `event: <name>\ndata: <json>\n\n`. The JSON payload is
/// produced by the caller (already serialized).
private func sseEvent(name: String, payload: Data) -> ByteBuffer {
  var buf = ByteBuffer()
  buf.writeString("event: \(name)\ndata: ")
  buf.writeBytes(payload)
  buf.writeString("\n\n")
  return buf
}

private struct SSEProgressPayload: Encodable {
  let step: Int
  let total: Int
}

private struct SSEErrorPayload: Encodable {
  let errorCode: String
  let title: String
  let detail: String?

  enum CodingKeys: String, CodingKey {
    case errorCode = "error_code"
    case title, detail
  }
}

/// Runs a generation through the SSE wire protocol. Emits `event: progress`
/// per diffusion step (best-effort — depends on the engine emitting
/// `.generating(step, totalSteps)`), then either `event: done` (with the full
/// response payload) or `event: error` on failure. Generic over the response
/// type so the same scaffolding serves image and video routes. The HTTP
/// response is always 200 once the stream has started, so failures show up
/// via the `error` event, not the status code.
private func sseGeneration<R: Encodable & Sendable>(
  registry: RunRegistry,
  info: RunInfo,
  cap: Int?,
  run: @Sendable @escaping (
    _ onProgress: @escaping ProgressCallback
  ) async throws -> R
) async throws -> Response {
  let runId = info.runId
  let (events, continuation) = AsyncStream<ByteBuffer>.makeStream()
  let encoder = JSONEncoder()

  let task = Task<Void, Never> {
    let onProgress: ProgressCallback = { step, total, previewPNG in
      Task { await registry.updateProgress(runId, step: step, total: total, previewPNG: previewPNG) }
      guard let data = try? encoder.encode(SSEProgressPayload(step: step, total: total)) else {
        return
      }
      continuation.yield(sseEvent(name: "progress", payload: data))
    }
    do {
      let response = try await run(onProgress)
      do {
        let data = try encoder.encode(response)
        continuation.yield(sseEvent(name: "done", payload: data))
      } catch let encodeError {
        // Generation succeeded but we can't serialize the result. Surface
        // as `event: error` rather than truncating the stream silently —
        // the client otherwise can't tell success from a dropped connection.
        let payload = SSEErrorPayload(
          errorCode: "ENGINE_INTERNAL_ERROR",
          title: "Failed to encode generation response",
          detail: "\(encodeError)")
        if let data = try? encoder.encode(payload) {
          continuation.yield(sseEvent(name: "error", payload: data))
        }
      }
    } catch let error {
      let payload = sseErrorPayload(for: error, runId: runId)
      if let data = try? encoder.encode(payload) {
        continuation.yield(sseEvent(name: "error", payload: data))
      }
    }
    continuation.finish()
    await registry.unregister(runId)
  }
  let admitted = await registry.tryRegister(info, cap: cap, cancel: { task.cancel() })
  guard admitted else {
    task.cancel()
    let count = await registry.activeCount()
    throw tooManyActiveRunsError(active: count, cap: cap!)
  }

  var headers = HTTPFields()
  headers[.contentType] = "text/event-stream"
  headers[.cacheControl] = "no-store"
  return Response(status: .ok, headers: headers, body: .init(asyncSequence: events))
}

/// SSE payloads for `/v1/assets/install?stream=true`.
private struct SSEEnsureResolvingPayload: Encodable {}

private struct SSEEnsureVerifyingPayload: Encodable {
  let file: String
  let fileIndex: Int
  let totalFiles: Int

  enum CodingKeys: String, CodingKey {
    case file
    case fileIndex = "file_index"
    case totalFiles = "total_files"
  }
}

private struct SSEEnsureProgressPayload: Encodable {
  let file: String
  let fileIndex: Int
  let totalFiles: Int
  let bytesWritten: Int64
  let totalBytesExpected: Int64

  enum CodingKeys: String, CodingKey {
    case file
    case fileIndex = "file_index"
    case totalFiles = "total_files"
    case bytesWritten = "bytes_written"
    case totalBytesExpected = "total_bytes_expected"
  }
}

/// SSE handler for `POST /v1/assets/install?stream=true`. Yields
/// `event: resolving` → `event: verifying` (per file) → `event: progress`
/// (per file, per chunk) → `event: done` with the resolved Asset, or
/// `event: error` on failure. Mirrors the wire shape of the generation
/// SSE so a client that consumes one can consume the other with the
/// same scaffolding.
private func sseInstall(
  assets: AssetManager, request: InstallAssetRequest
) async -> Response {
  let (events, continuation) = AsyncStream<ByteBuffer>.makeStream()
  let encoder = JSONEncoder()

  Task<Void, Never> {
    let onState: @Sendable (MediaGenerationEnvironment.EnsureState) -> Void = { state in
      switch state {
      case .resolving:
        if let data = try? encoder.encode(SSEEnsureResolvingPayload()) {
          continuation.yield(sseEvent(name: "resolving", payload: data))
        }
      case .verifying(let file, let fileIndex, let totalFiles):
        if let data = try? encoder.encode(
          SSEEnsureVerifyingPayload(
            file: file, fileIndex: fileIndex, totalFiles: totalFiles))
        {
          continuation.yield(sseEvent(name: "verifying", payload: data))
        }
      case .downloading(let file, let fileIndex, let totalFiles, let bytesWritten, let totalBytes):
        if let data = try? encoder.encode(
          SSEEnsureProgressPayload(
            file: file, fileIndex: fileIndex, totalFiles: totalFiles,
            bytesWritten: bytesWritten, totalBytesExpected: totalBytes))
        {
          continuation.yield(sseEvent(name: "progress", payload: data))
        }
      }
    }
    do {
      let asset = try await assets.install(request, onState: onState)
      if let data = try? encoder.encode(asset) {
        continuation.yield(sseEvent(name: "done", payload: data))
      }
    } catch let error {
      let payload = sseInstallErrorPayload(for: error)
      if let data = try? encoder.encode(payload) {
        continuation.yield(sseEvent(name: "error", payload: data))
      }
    }
    continuation.finish()
  }

  var headers = HTTPFields()
  headers[.contentType] = "text/event-stream"
  headers[.cacheControl] = "no-store"
  return Response(status: .ok, headers: headers, body: .init(asyncSequence: events))
}

private func sseInstallErrorPayload(for error: Error) -> SSEErrorPayload {
  if let typed = error as? TypedError {
    return SSEErrorPayload(
      errorCode: typed.errorCode, title: typed.title, detail: typed.detail)
  }
  if let mutation = error as? AssetMutationError {
    let typed = TypedError.from(mutationError: mutation)
    return SSEErrorPayload(
      errorCode: typed.errorCode, title: typed.title, detail: typed.detail)
  }
  if let mgk = error as? MediaGenerationKitError {
    return SSEErrorPayload(
      errorCode: "ENGINE_INTERNAL_ERROR",
      title: "Engine error during install",
      detail: "\(mgk)")
  }
  return SSEErrorPayload(
    errorCode: "ENGINE_INTERNAL_ERROR",
    title: "Unexpected install error",
    detail: "\(error)")
}

/// Translates an engine/SDK error into the SSE `error` event payload. Mirrors
/// the codes used by the JSON path (see `runEngine`), so SSE clients see the
/// same `error_code` taxonomy.
private func sseErrorPayload(for error: Error, runId: String) -> SSEErrorPayload {
  if error is CancellationError {
    return SSEErrorPayload(
      errorCode: "RUN_CANCELLED",
      title: "Run was cancelled",
      detail: "DELETE /v1/runs/\(runId) was acknowledged mid-stream.")
  }
  if let mgk = error as? MediaGenerationKitError, case .cancelled = mgk {
    return SSEErrorPayload(
      errorCode: "RUN_CANCELLED",
      title: "Run was cancelled",
      detail: "Engine reported MediaGenerationKitError.cancelled mid-stream.")
  }
  if let validation = error as? ValidationError {
    return SSEErrorPayload(
      errorCode: "VALIDATION_FAILED",
      title: "Request validation failed",
      detail: validation.detail)
  }
  if let engineError = error as? EngineError {
    let typed = TypedError.from(engineError: engineError)
    return SSEErrorPayload(errorCode: typed.errorCode, title: typed.title, detail: typed.detail)
  }
  return SSEErrorPayload(
    errorCode: "ENGINE_INTERNAL_ERROR",
    title: "Engine error",
    detail: "\(error)")
}

/// Runs an engine call wrapped in a `Task` so it can be cancelled via the
/// run registry. Translates `CancellationError` to the nginx-style 499
/// `RUN_CANCELLED`, all other errors via `runEngine(_:)`. Respects the
/// `--max-active-runs` cap when one is configured.
private func runCancellable<T: Sendable>(
  registry: RunRegistry,
  info: RunInfo,
  cap: Int?,
  _ block: @Sendable @escaping (_ onProgress: @escaping ProgressCallback) async throws -> T
) async throws -> T {
  let runId = info.runId
  let task = Task<T, Error> {
    try await block { step, total, previewPNG in
      Task { await registry.updateProgress(runId, step: step, total: total, previewPNG: previewPNG) }
    }
  }
  let admitted = await registry.tryRegister(info, cap: cap, cancel: { task.cancel() })
  guard admitted else {
    task.cancel()  // dispose the Task we just spawned
    let count = await registry.activeCount()
    throw tooManyActiveRunsError(active: count, cap: cap!)
  }
  return try await runEngine {
    defer { Task { await registry.unregister(runId) } }
    do {
      return try await task.value
    } catch is CancellationError {
      throw TypedError(
        status: .init(code: 499, reasonPhrase: "Client Closed Request"),
        errorCode: "RUN_CANCELLED",
        title: "Run was cancelled",
        detail: "DELETE /v1/runs/\(runId) was acknowledged before this run completed."
      )
    }
  }
}

/// Maps the registry's internal `RunInfo` onto the `GET /v1/runs` wire types.
/// Internal (not private): the MCP `list_runs` / `get_run` tools reuse these
/// so REST and MCP project run state through the exact same shaping.
func runSummary(_ info: RunInfo) -> RunSummary {
  RunSummary(
    runId: info.runId, kind: info.kind, prompt: info.prompt,
    width: info.width, height: info.height, steps: info.steps,
    startedAt: info.startedAt.ISO8601Format(),
    currentStep: info.currentStep, totalSteps: info.totalSteps)
}

func runDetail(_ info: RunInfo) -> RunDetailResponse {
  RunDetailResponse(
    runId: info.runId, kind: info.kind, prompt: info.prompt,
    width: info.width, height: info.height, steps: info.steps,
    startedAt: info.startedAt.ISO8601Format(),
    currentStep: info.currentStep, totalSteps: info.totalSteps,
    previewPngBase64: info.previewPNG?.base64EncodedString())
}

private func runEngine<T>(_ block: () async throws -> T) async throws -> T {
  do {
    return try await block()
  } catch let error as TypedError {
    throw error
  } catch let error as ValidationError {
    throw TypedError(
      status: .badRequest, errorCode: "VALIDATION_FAILED",
      title: "Request validation failed", detail: error.detail)
  } catch let error as EngineError {
    throw TypedError.from(engineError: error)
  } catch let error as MediaGenerationKitError {
    if case .cancelled = error {
      throw TypedError(
        status: .init(code: 499, reasonPhrase: "Client Closed Request"),
        errorCode: "RUN_CANCELLED",
        title: "Run was cancelled",
        detail: "Engine reported MediaGenerationKitError.cancelled.")
    }
    throw TypedError(
      status: .internalServerError,
      errorCode: "ENGINE_INTERNAL_ERROR",
      title: "Engine error",
      detail: "\(error)"
    )
  } catch is CancellationError {
    throw TypedError(
      status: .init(code: 499, reasonPhrase: "Client Closed Request"),
      errorCode: "RUN_CANCELLED",
      title: "Run was cancelled",
      detail: nil
    )
  } catch {
    throw TypedError(
      status: .internalServerError,
      errorCode: "ENGINE_INTERNAL_ERROR",
      title: "Unexpected error",
      detail: "\(error)"
    )
  }
}

/// RFC 7807 Problem Details + typed `error_code`, served as `application/problem+json`.
struct TypedError: HTTPResponseError {
  let status: HTTPResponse.Status
  let errorCode: String
  let title: String
  let detail: String?

  func response(from request: Request, context: some RequestContext) throws -> Response {
    let body = ProblemBody(
      type: "about:blank",
      title: title,
      status: Int(status.code),
      detail: detail,
      errorCode: errorCode
    )
    let data = try JSONEncoder().encode(body)
    var headers = HTTPFields()
    headers[.contentType] = "application/problem+json"
    return Response(
      status: status,
      headers: headers,
      body: .init(byteBuffer: ByteBuffer(bytes: data))
    )
  }

  static func from(engineError: EngineError) -> TypedError {
    switch engineError {
    case .noImageProduced:
      return TypedError(
        status: .internalServerError,
        errorCode: "ENGINE_INTERNAL_ERROR",
        title: "Engine produced no image",
        detail: nil
      )
    case .pngEncodingFailed:
      return TypedError(
        status: .internalServerError,
        errorCode: "ENGINE_INTERNAL_ERROR",
        title: "PNG encoding failed",
        detail: nil
      )
    case .invalidImageData:
      return TypedError(
        status: .badRequest,
        errorCode: "INVALID_IMAGE_DATA",
        title: "Invalid base64 image data",
        detail: nil
      )
    case .invalidMaskData:
      return TypedError(
        status: .badRequest,
        errorCode: "INVALID_MASK_DATA",
        title: "Invalid base64 mask data",
        detail: nil
      )
    case .invalidReferenceImage:
      return TypedError(
        status: .badRequest,
        errorCode: "INVALID_REFERENCE_IMAGE_DATA",
        title: "Invalid base64 reference_image data",
        detail: nil
      )
    case .invalidDepthImage:
      return TypedError(
        status: .badRequest,
        errorCode: "INVALID_DEPTH_IMAGE_DATA",
        title: "Invalid base64 depth_image data",
        detail: nil
      )
    case .baseModelNotInstalled(let id):
      return TypedError(
        status: .badRequest,
        errorCode: "MODEL_NOT_INSTALLED",
        title: "Base model not installed",
        detail: "no installed base model with id '\(id)'"
      )
    case .controlnetNotInstalled(let id, let i):
      return TypedError(
        status: .badRequest,
        errorCode: "CONTROLNET_NOT_INSTALLED",
        title: "ControlNet not installed",
        detail: "controlnets[\(i)].model_id '\(id)' is not installed"
      )
    case .controlnetIncompatible(let id, let baseArch, let cnArch, let i):
      return TypedError(
        status: .badRequest,
        errorCode: "CONTROLNET_INCOMPATIBLE_WITH_BASE_MODEL",
        title: "ControlNet architecture mismatch",
        detail:
          "controlnets[\(i)].model_id '\(id)' targets '\(cnArch)' but the base "
          + "model is '\(baseArch)'."
      )
    case .loraNotInstalled(let id, let i):
      return TypedError(
        status: .badRequest,
        errorCode: "LORA_NOT_INSTALLED",
        title: "LoRA not installed",
        detail: "loras[\(i)].lora_id '\(id)' is not installed"
      )
    case .loraIncompatible(let id, let baseArch, let loraArch, let i):
      return TypedError(
        status: .badRequest,
        errorCode: "LORA_INCOMPATIBLE_WITH_BASE_MODEL",
        title: "LoRA architecture mismatch",
        detail:
          "loras[\(i)].lora_id '\(id)' targets '\(loraArch)' but the base "
          + "model is '\(baseArch)'."
      )
    case .upscalerNotInstalled(let id):
      return TypedError(
        status: .badRequest,
        errorCode: "UPSCALER_NOT_INSTALLED",
        title: "Upscaler not installed",
        detail: "upscaler.model_id '\(id)' is not installed"
      )
    case .controlnetNoPublicHintPath(let id, let modifier, let i):
      return TypedError(
        status: .badRequest,
        errorCode: "CONTROL_HAS_NO_PUBLIC_HINT_PATH",
        title: "ControlNet modifier has no public hint transport",
        detail:
          "controlnets[\(i)].model_id '\(id)' uses modifier '\(modifier)' whose "
          + "hint tensor the public SDK does not expose. The engine would "
          + "silently no-op this control. Use depth (via depth_image), shuffle "
          + "or reference (via reference_image), or canny/softedge/mlsd/scribble "
          + "(via the primary image)."
      )
    case .domainMismatch(let id, let baseDomain, let requested):
      return TypedError(
        status: .badRequest,
        errorCode: "BASE_MODEL_DOMAIN_MISMATCH",
        title: "Base model domain mismatch",
        detail:
          "base_model_id '\(id)' is a '\(baseDomain)' model; this endpoint "
          + "requires a '\(requested)' model. The engine would silently "
          + "degenerate (image routes emit a single frame on a video model; "
          + "video routes emit one frame ignoring num_frames on an image "
          + "model)."
      )
    case .editingModelRequiresEditEndpoint(let id):
      return TypedError(
        status: .badRequest,
        errorCode: "EDITING_MODEL_REQUIRES_EDIT_ENDPOINT",
        title: "Editing model requires POST /v1/edit",
        detail:
          "base_model_id '\(id)' is an instruction-edit model "
          + "(editing_mode='instruction_edit'). /v1/img2img would route the "
          + "image into the primary slot and the engine would renoise from it, "
          + "leaving the edit instruction inert. Call POST /v1/edit with the "
          + "image to edit as `image` and the instruction as `prompt`."
      )
    case .notAnInstructionEditModel(let id, let mode):
      return TypedError(
        status: .badRequest,
        errorCode: "NOT_AN_INSTRUCTION_EDIT_MODEL",
        title: "Not an instruction-edit model",
        detail:
          "base_model_id '\(id)' has editing_mode='\(mode ?? "none")'. "
          + "/v1/edit only drives instruction-edit models (Flux Kontext, "
          + "Qwen-Image-Edit). Use /v1/txt2img, /v1/img2img or /v1/inpaint "
          + "as appropriate for this model."
      )
    case .cfgUnsupportedForDistilledEdit(let id, let cfg):
      return TypedError(
        status: .badRequest,
        errorCode: "CFG_SCALE_UNSUPPORTED_FOR_DISTILLED_EDIT",
        title: "cfg_scale unsupported for guidance-distilled edit model",
        detail:
          "base_model_id '\(id)' is a guidance-distilled FLUX edit model "
          + "(Kontext / Klein); it bakes guidance in and has no unconditional "
          + "branch. The request's cfg_scale=\(cfg) would make the engine build "
          + "a classifier-free-guidance graph whose reference tokens are "
          + "asymmetric between branches, crashing on a tensor-shape assertion. "
          + "Omit cfg_scale (or set it to 1) and steer instruction adherence "
          + "with extensions.draw_things.guidance_embed instead."
      )
    case .operationNotSupportedForModel(let id, let op, let supported):
      return TypedError(
        status: .badRequest,
        errorCode: "OPERATION_NOT_SUPPORTED_FOR_MODEL",
        title: "Operation not supported by this model",
        detail:
          "Model '\(id)' does not support operation '\(op)'. "
          + "Supported operations: [\(supported.joined(separator: ", "))]. "
          + "Read GET /v1/capabilities/\(id) for the full contract."
      )
    case .videoEncoding(let err):
      return TypedError(
        status: .internalServerError,
        errorCode: "ENGINE_INTERNAL_ERROR",
        title: "Video encoding failed",
        detail: "\(err)"
      )
    case .pipelineStepNotFound(let name):
      return TypedError(
        status: .badRequest,
        errorCode: "PIPELINE_STEP_NOT_FOUND",
        title: "Step reference not resolvable",
        detail:
          "from: \"$\(name)\" references a step that has not run (or has no "
          + "`as` label). Step refs only resolve inside POST /v1/pipeline, "
          + "and only to prior steps with an `as` label."
      )
    case .recipeProducedVideoOutput:
      return TypedError(
        status: .badRequest,
        errorCode: "RECIPE_PRODUCED_VIDEO_OUTPUT",
        title: "Sub-recipe produced a video, expected image bytes",
        detail:
          "A sub-recipe in `from` / `references[].image` / `guides[].image` "
          + "resolved to a video output. Pipelines + recipes only chain image "
          + "bytes for now — extract frames client-side if you need them."
      )
    case .pipelineEmpty:
      return TypedError(
        status: .badRequest,
        errorCode: "PIPELINE_EMPTY",
        title: "Pipeline must have at least one step",
        detail: "POST /v1/pipeline body's `steps[]` is empty."
      )
    case .pipelineReturnUnknownStep(let name):
      return TypedError(
        status: .badRequest,
        errorCode: "PIPELINE_RETURN_UNKNOWN_STEP",
        title: "`return[]` references an unknown step",
        detail:
          "POST /v1/pipeline `return: [\"\(name)\"]` does not match any "
          + "step's `as` label. The implicit `\"result\"` is reserved for "
          + "the last step when `return` is omitted."
      )
    case .videoParamsRequired(let id):
      return TypedError(
        status: .badRequest,
        errorCode: "VIDEO_PARAMS_REQUIRED",
        title: "Video knobs missing",
        detail:
          "base_model_id '\(id)' is a video model; params.video must carry "
          + "at least `num_frames` (with optional `fps`, `video_format`, "
          + "`motion`)."
      )
    case .paramsRequired:
      return TypedError(
        status: .badRequest,
        errorCode: "PARAMS_REQUIRED",
        title: "Missing `params` block",
        detail:
          "Semantic-API request bodies require a `params` object carrying "
          + "the engine knobs (at minimum width / height / steps)."
      )
    }
  }
}

/// Encode a `Result` to bytes in memory via the patched
/// `encodedData(type:)` API (see `scripts/dtc-products.patch`). Avoids the
/// temp-file roundtrip the public `write(to:type:)` API would force.
func encodeImage(result: MediaGenerationPipeline.Result, format: OutputFormat) throws -> Data {
  try result.encodedData(type: format.utType)
}

// MARK: - Binary content negotiation

/// `X-DHT-*` response headers carrying generation metadata when a generation
/// route serves a raw binary body instead of the JSON envelope. Structured
/// fields (`warnings`, `applied_defaults`) are base64-encoded JSON — their
/// messages contain non-ASCII text not safe verbatim in an HTTP header value.
private enum DHTHeader {
  static let runId = HTTPField.Name("X-DHT-Run-Id")!
  static let seed = HTTPField.Name("X-DHT-Seed")!
  static let generationTimeMs = HTTPField.Name("X-DHT-Generation-Time-Ms")!
  static let engineVersion = HTTPField.Name("X-DHT-Engine-Version")!
  static let warnings = HTTPField.Name("X-DHT-Warnings")!
  static let appliedDefaults = HTTPField.Name("X-DHT-Applied-Defaults")!
  static let width = HTTPField.Name("X-DHT-Width")!
  static let height = HTTPField.Name("X-DHT-Height")!
  static let numFrames = HTTPField.Name("X-DHT-Num-Frames")!
  static let fps = HTTPField.Name("X-DHT-Fps")!
  static let durationMs = HTTPField.Name("X-DHT-Duration-Ms")!
  /// Base64-encoded JSON of the recipe that produced the response. Carries
  /// the verb body with `via` injected (so it's re-postable to /v1/<verb>)
  /// and applied defaults folded into `params`. Pipelines carry the full
  /// `PipelineRequest` instead. Set on JSON and binary responses; not surfaced on SSE (the
  /// `done` payload still carries enough metadata to reconstruct).
  static let recipe = HTTPField.Name("X-DHT-Recipe")!
}

/// True when the client opted into a raw binary body for `mediaType`
/// (`"image"` or `"video"`) via `Accept`. Absent, `*/*`, or
/// `application/json` → the JSON envelope (the unchanged default).
/// `Accept` only toggles binary vs JSON; the encoding stays governed by the
/// request's `output_format` / `video_format`.
private func wantsBinary(_ request: Request, mediaType: String) -> Bool {
  guard let accept = request.headers[.accept] else { return false }
  return accept.contains("\(mediaType)/") || accept.contains("application/octet-stream")
}

/// 406 raised when a binary body was requested for a generation that produced
/// more than one result — a single binary body cannot carry a batch.
private func notAcceptableMultiResult(count: Int) -> TypedError {
  TypedError(
    status: .notAcceptable,
    errorCode: "BINARY_RESPONSE_IS_SINGLE_RESULT_ONLY",
    title: "Binary response requires a single result",
    detail:
      "This request produced \(count) results; a raw binary body carries only "
      + "one. Drop the binary Accept header for the JSON envelope, or set "
      + "batch_size=1 and batch_count=1.")
}

/// Base64-encoded JSON of an `Encodable`, for transport-safe structured headers.
private func jsonHeaderValue<T: Encodable>(_ value: T) -> String? {
  guard let data = try? JSONEncoder().encode(value) else { return nil }
  return data.base64EncodedString()
}

/// Convenience: builds an `HTTPFields` carrying just the `X-DHT-Recipe`
/// header (or empty when encoding the recipe failed — the response still
/// goes through; the recipe is metadata-on-the-side, never load-bearing).
private func recipeHeaders<R: Encodable>(
  verb: String, request: R, appliedDefaults: [AppliedDefault]
) -> HTTPFields {
  var fields = HTTPFields()
  if let v = recipeHeaderValue(verb: verb, request: request, appliedDefaults: appliedDefaults) {
    fields[DHTHeader.recipe] = v
  }
  return fields
}

/// Builds the canonical recipe object for a verb response: the request body
/// with the `via` discriminator injected (so the recipe is self-describing —
/// re-postable to `/v1/<verb>` or nested under another `from.via`) and applied
/// defaults folded into the `params` block. Inline image payloads are stripped
/// to digest references (see `redactRecipeImages`). Returns `nil` if encoding
/// fails. Shared by the REST `X-DHT-Recipe` header (`recipeHeaderValue`) and the
/// MCP tool-result recipe block (`recipeJSONString`) so both surfaces emit the
/// exact same canonical recipe — REST/MCP parity by construction.
func recipeObject<R: Encodable>(
  verb: String, request: R, appliedDefaults: [AppliedDefault]
) -> Any? {
  guard let data = try? JSONEncoder().encode(request),
        var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  else { return nil }
  dict["via"] = verb
  if !appliedDefaults.isEmpty {
    var params = (dict["params"] as? [String: Any]) ?? [:]
    for ad in appliedDefaults {
      params[ad.fieldPath] = jsonScalar(ad.value)
    }
    dict["params"] = params
  }
  return redactRecipeImages(dict)
}

/// The canonical recipe object for a `PipelineRequest` (as-submitted), with
/// inline image payloads stripped to digest references. Per-step applied
/// defaults aren't propagated through `PipelineResponse` in R5 — pipelines
/// re-execute deterministically given the same steps and per-step `params`.
func pipelineRecipeObject(_ request: PipelineRequest) -> Any? {
  guard let data = try? JSONEncoder().encode(request),
        let obj = try? JSONSerialization.jsonObject(with: data)
  else { return nil }
  return redactRecipeImages(obj)
}

/// Base64 `X-DHT-Recipe` header value for a verb response, or `nil` if encoding
/// fails or the result exceeds the 64 KB header-line limit (see
/// `encodeRecipeHeader`). The caller drops the header silently rather than
/// failing the response — the recipe is metadata-on-the-side, never load-bearing.
private func recipeHeaderValue<R: Encodable>(
  verb: String, request: R, appliedDefaults: [AppliedDefault]
) -> String? {
  recipeObject(verb: verb, request: request, appliedDefaults: appliedDefaults)
    .flatMap(encodeRecipeHeader)
}

/// Base64 `X-DHT-Recipe` header value for a pipeline response.
private func pipelineRecipeHeaderValue(_ request: PipelineRequest) -> String? {
  pipelineRecipeObject(request).flatMap(encodeRecipeHeader)
}

/// Renders a recipe object (from `recipeObject` / `pipelineRecipeObject`) as
/// compact canonical JSON text — used by the MCP tool-result recipe block. No
/// base64 wrapping and no size cap, unlike `encodeRecipeHeader`: MCP results
/// aren't subject to the HTTP header-line limit, and the recipe is already
/// image-redacted so it stays small.
func recipeJSONString(_ object: Any) -> String? {
  guard let out = try? JSONSerialization.data(
    withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
  else { return nil }
  return String(data: out, encoding: .utf8)
}

/// Largest `X-DHT-Recipe` value (base64 chars) we will emit. Belt-and-suspenders
/// past image redaction: a pathologically large recipe (huge prompt, deep
/// pipeline) is dropped rather than tripping a client's header-line limit. The
/// recipe is metadata-on-the-side, so omitting it degrades nothing load-bearing.
private let recipeHeaderMaxBytes = 32 * 1024

/// Serializes a redacted recipe tree to the base64 header value, or `nil` if
/// serialization fails or the result would exceed `recipeHeaderMaxBytes`.
private func encodeRecipeHeader(_ object: Any) -> String? {
  guard let out = try? JSONSerialization.data(
    withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
  else { return nil }
  let encoded = out.base64EncodedString()
  return encoded.utf8.count <= recipeHeaderMaxBytes ? encoded : nil
}

/// Recipe keys whose string value is inline base64 image bytes. Stripped from
/// the `X-DHT-Recipe` header so it can't exceed the HTTP header-line limit when
/// the request carried inline images. Covers `from.image`, `guides[].image`,
/// `references[].image` (all `FromSource`, which serializes its bytes under an
/// `image` key), `reference_image` / `depth_image` (`EngineParams`), and the
/// inpaint `mask` (`EditRequest`).
private let recipeImageKeys: Set<String> = ["image", "reference_image", "depth_image", "mask"]

/// Recursively replaces inline base64 image payloads in a decoded recipe JSON
/// tree with a `sha256:<hex>;bytes=<n>` reference string. The redacted recipe
/// stays structurally re-postable — the image field is still a string — so a
/// caller swaps the real bytes back in, keyed by the digest of the image it
/// already holds. Non-string values at image keys (e.g. a nested `from.via`
/// sub-recipe under `image`) are recursed into, not redacted.
private func redactRecipeImages(_ value: Any) -> Any {
  if let dict = value as? [String: Any] {
    var out = dict
    for (k, v) in dict {
      if recipeImageKeys.contains(k), let s = v as? String, !s.isEmpty {
        out[k] = imageDigestReference(s)
      } else {
        out[k] = redactRecipeImages(v)
      }
    }
    return out
  }
  if let arr = value as? [Any] {
    return arr.map(redactRecipeImages)
  }
  return value
}

/// SHA-256 digest reference standing in for stripped inline image bytes:
/// `sha256:<hex>;bytes=<n>`. Hashes the decoded bytes when the value is valid
/// base64 (stable per image regardless of base64 padding), else the raw string.
private func imageDigestReference(_ base64: String) -> String {
  let bytes = Data(base64Encoded: base64) ?? Data(base64.utf8)
  let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  return "sha256:\(hex);bytes=\(bytes.count)"
}

/// Maps a `JSONValue` (tagged scalar from `AppliedDefault.value`) onto the
/// native Foundation type `JSONSerialization` expects.
private func jsonScalar(_ v: JSONValue) -> Any {
  switch v {
  case .null: return NSNull()
  case .bool(let b): return b
  case .int(let i): return i
  case .double(let d): return d
  case .string(let s): return s
  case .array(let arr): return arr.map(jsonScalar)
  case .object(let dict): return dict.mapValues(jsonScalar)
  }
}

/// Common `X-DHT-*` metadata headers shared by the image and video binary
/// responses. `seed` differs per media (image: response seed; video: the
/// single video's seed) so it is passed in rather than read off `metadata`.
private func dhtMetadataHeaders(
  into headers: inout HTTPFields, metadata: RunMetadata, seed: Int64, generationTimeMs: Int
) {
  headers[DHTHeader.runId] = metadata.runId
  headers[DHTHeader.seed] = String(seed)
  headers[DHTHeader.generationTimeMs] = String(generationTimeMs)
  headers[DHTHeader.engineVersion] = metadata.engineVersion
  if !metadata.warnings.isEmpty, let v = jsonHeaderValue(metadata.warnings) {
    headers[DHTHeader.warnings] = v
  }
  if !metadata.appliedDefaults.isEmpty, let v = jsonHeaderValue(metadata.appliedDefaults) {
    headers[DHTHeader.appliedDefaults] = v
  }
}

/// Builds the response for an image generation route: a raw image body when
/// the client asked for binary (single-result only — 406 otherwise), the JSON
/// envelope otherwise. `extraHeaders` (typically `X-DHT-Recipe`) is set on
/// both branches.
private func imageGenerationResponse(
  _ result: GenerationResponse, format: OutputFormat,
  request: Request, context: some RequestContext,
  extraHeaders: HTTPFields = HTTPFields()
) throws -> Response {
  guard wantsBinary(request, mediaType: "image") else {
    return try jsonResponse(result, extraHeaders: extraHeaders)
  }
  guard result.images.count == 1 else {
    throw notAcceptableMultiResult(count: result.images.count)
  }
  guard let bytes = Data(base64Encoded: result.images[0]) else {
    throw TypedError(
      status: .internalServerError, errorCode: "ENGINE_INTERNAL_ERROR",
      title: "Generated image is not decodable base64", detail: nil)
  }
  var headers = HTTPFields()
  headers[.contentType] = format == .png ? "image/png" : "image/jpeg"
  dhtMetadataHeaders(
    into: &headers, metadata: result.metadata, seed: result.seed,
    generationTimeMs: result.generationTimeMs)
  for field in extraHeaders { headers.append(field) }
  return Response(
    status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: bytes)))
}

/// Video twin of `imageGenerationResponse`. Both `VideoFormatAPI` cases use
/// the `.mp4` container, so the binary body is always `video/mp4`.
private func videoGenerationResponse(
  _ result: VideoGenerationResponse,
  request: Request, context: some RequestContext,
  extraHeaders: HTTPFields = HTTPFields()
) throws -> Response {
  guard wantsBinary(request, mediaType: "video") else {
    return try jsonResponse(result, extraHeaders: extraHeaders)
  }
  guard result.videos.count == 1 else {
    throw notAcceptableMultiResult(count: result.videos.count)
  }
  let video = result.videos[0]
  guard let bytes = Data(base64Encoded: video.data) else {
    throw TypedError(
      status: .internalServerError, errorCode: "ENGINE_INTERNAL_ERROR",
      title: "Generated video is not decodable base64", detail: nil)
  }
  var headers = HTTPFields()
  headers[.contentType] = "video/mp4"
  dhtMetadataHeaders(
    into: &headers, metadata: result.metadata, seed: video.seed,
    generationTimeMs: result.generationTimeMs)
  headers[DHTHeader.width] = String(video.width)
  headers[DHTHeader.height] = String(video.height)
  headers[DHTHeader.numFrames] = String(video.numFrames)
  headers[DHTHeader.fps] = String(video.fps)
  headers[DHTHeader.durationMs] = String(video.durationMs)
  for field in extraHeaders { headers.append(field) }
  return Response(
    status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: bytes)))
}

/// Serializes an `Encodable` to JSON and wraps it in a 200 response with
/// `Content-Type: application/json` plus any extra headers (typically the
/// `X-DHT-Recipe` from R5). Replaces the implicit `ResponseEncodable` path
/// for generation routes where we need to attach custom headers.
private func jsonResponse<T: Encodable>(_ value: T, extraHeaders: HTTPFields) throws -> Response {
  let data = try JSONEncoder().encode(value)
  var headers = HTTPFields()
  headers[.contentType] = "application/json; charset=utf-8"
  for field in extraHeaders { headers.append(field) }
  return Response(
    status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
}
