import Foundation
import Logging
import _MediaGenerationKit

/// In-binary [Model Context Protocol](https://modelcontextprotocol.io) server.
///
/// Transport-agnostic: `handle(envelope:emit:)` consumes one already-parsed
/// JSON-RPC 2.0 object and returns the response object (or `nil` for a
/// notification). The wire transport lives in `MCPRoutes.swift` — it mounts
/// `/mcp` (Streamable HTTP) on the same Hummingbird server as the REST API,
/// so REST and MCP share one `GenerationEngine` + `AssetManager` behind a
/// single process. There is no stdio transport: a localhost client connects
/// to `http://localhost:<port>/mcp` exactly like a remote one.
///
/// Scope:
///   - `initialize` handshake — advertises protocolVersion 2025-11-25 and
///     echoes the client's requested version when it is one we recognise.
///   - `tools/list` + `tools/call` for the tool catalog.
///   - `resources/list` + `prompts/list` returning empty (capability stub).
///   - `ping`.
///   - Progress notifications for long-running tools when the caller passed a
///     `_meta.progressToken` and the transport supplied a notification sink.
final class MCPServer: Sendable {
  private let engine: any GenerationEngine
  private let assets: AssetManager
  /// Shared with the REST routes: generation tools register here so they
  /// show in `GET /v1/runs`, honour `--max-active-runs`, and are cancellable
  /// via `notifications/cancelled` (MCP) or `DELETE /v1/runs/{id}` (REST).
  private let registry: RunRegistry
  /// Mirrors `--read-only`: when true, `install_asset` / `delete_asset`
  /// refuse with `READ_ONLY_MODE`, exactly as the REST mutation routes do.
  /// A server-wide policy must hold on every surface — MCP is not a bypass.
  private let readOnly: Bool
  /// Mirrors `--max-active-runs`: concurrent-run cap, shared with REST.
  private let maxActiveRuns: Int?
  private let logger: Logger

  init(
    engine: any GenerationEngine, assets: AssetManager, registry: RunRegistry,
    readOnly: Bool, maxActiveRuns: Int?, logger: Logger
  ) {
    self.engine = engine
    self.assets = assets
    self.registry = registry
    self.readOnly = readOnly
    self.maxActiveRuns = maxActiveRuns
    self.logger = logger
  }

  /// A sink the transport provides so a long-running tool can push JSON-RPC
  /// notifications (progress) to the client mid-request. The payload is a
  /// fully-serialized JSON-RPC notification. `nil` disables progress.
  typealias NotificationSink = @Sendable (Data) -> Void

  static let latestProtocolVersion = "2025-11-25"
  private static let supportedProtocolVersions: Set<String> = [
    "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25",
  ]

  // MARK: - Entry point

  /// Dispatches one parsed JSON-RPC envelope. Returns the response envelope,
  /// or `nil` for a notification (the transport then answers 202 Accepted).
  func handle(envelope: [String: Any], emit: NotificationSink? = nil) async -> [String: Any]? {
    let rawId = envelope["id"]
    let method = envelope["method"] as? String
    let params = envelope["params"] as? [String: Any]

    // Notifications carry no id and get no response.
    if rawId == nil || rawId is NSNull {
      await handleNotification(method: method ?? "", params: params)
      return nil
    }
    guard let method else {
      return errorEnvelope(id: rawId, code: -32600, message: "Missing method")
    }
    do {
      let result = try await dispatch(
        method: method, params: params, emit: emit, requestId: rawId)
      return ["jsonrpc": "2.0", "id": rawId!, "result": result]
    } catch let e as MCPError {
      return errorEnvelope(id: rawId, code: e.code, message: e.message)
    } catch {
      logger.error("internal error on \(method): \(error)")
      return errorEnvelope(id: rawId, code: -32603, message: "Internal error: \(error)")
    }
  }

  // MARK: - Dispatch

  private func handleNotification(method: String, params: [String: Any]?) async {
    switch method {
    case "notifications/initialized":
      logger.info("client signalled initialized")
    case "notifications/cancelled":
      // params.requestId is the JSON-RPC id of the in-flight request to
      // cancel. We registered that request's run under the same derived id,
      // so cancelling by run id reaches the engine task.
      guard let runId = Self.runId(forRequestId: params?["requestId"]) else {
        logger.debug("cancellation notification without a usable requestId")
        return
      }
      let cancelled = await registry.cancel(runId)
      logger.info(
        "MCP cancel \(runId): \(cancelled ? "cancelled in-flight run" : "no active run")")
    default:
      logger.debug("ignoring unknown notification: \(method)")
    }
  }

  private func dispatch(
    method: String, params: [String: Any]?, emit: NotificationSink?, requestId: Any?
  ) async throws -> Any {
    switch method {
    case "initialize":
      return handleInitialize(params: params)
    case "tools/list":
      return ["tools": MCPToolCatalog.all]
    case "tools/call":
      guard let params else {
        throw MCPError(code: -32602, message: "tools/call requires params")
      }
      return try await handleToolsCall(params: params, emit: emit, requestId: requestId)
    case "resources/list":
      return ["resources": [] as [Any]]
    case "prompts/list":
      return ["prompts": [] as [Any]]
    case "ping":
      return [:] as [String: Any]
    default:
      throw MCPError(code: -32601, message: "Method not found: \(method)")
    }
  }

  // MARK: - initialize

  private func handleInitialize(params: [String: Any]?) -> [String: Any] {
    // Version negotiation (spec §Lifecycle): echo the client's version when
    // we recognise it, otherwise answer with our latest.
    let requested = params?["protocolVersion"] as? String
    let version =
      (requested.map(Self.supportedProtocolVersions.contains) ?? false)
      ? requested! : Self.latestProtocolVersion
    return [
      "protocolVersion": version,
      "capabilities": [
        "tools": [:] as [String: Any]
        // resources/prompts capabilities omitted — empty lists are returned
        // but there is nothing to advertise. Adding them is forward-compatible.
      ],
      "serverInfo": [
        "name": "dht-server",
        "version": dhtAPIVersion,
        // Non-standard extra field mirroring REST `GET /v1/info`'s
        // `engine_version`. MCP clients ignore unknown serverInfo keys, so this
        // is the lightest place to reach parity without a dedicated tool.
        "engineVersion": dhtEngineVersion,
      ],
    ]
  }

  // MARK: - tools/call

  private func handleToolsCall(
    params: [String: Any], emit: NotificationSink?, requestId: Any?
  ) async throws -> [String: Any] {
    guard let name = params["name"] as? String else {
      throw MCPError(code: -32602, message: "tools/call requires 'name'")
    }
    let arguments = params["arguments"] as? [String: Any] ?? [:]
    let token = ProgressToken(metaValue: (params["_meta"] as? [String: Any])?["progressToken"])

    switch name {
    case "resolve_compose":
      return try await callResolveCompose(arguments)
    case "resolve_edit":
      return try await callResolveEdit(arguments)
    case "resolve_restore":
      return try await callResolveRestore(arguments)
    case "compose":
      return try await callCompose(
        arguments, requestId: requestId, token: token, emit: emit)
    case "edit":
      return try await callEdit(
        arguments, requestId: requestId, token: token, emit: emit)
    case "restore":
      return try await callRestore(
        arguments, requestId: requestId, token: token, emit: emit)
    case "pipeline":
      return try await callPipeline(
        arguments, requestId: requestId, token: token, emit: emit)
    case "get_capabilities":
      return try await callGetCapabilities(arguments)
    case "list_runs":
      return try await callListRuns()
    case "get_run":
      return try await callGetRun(arguments)
    case "list_assets":
      return try await callListAssets(arguments)
    case "get_asset":
      return try await callGetAsset(arguments)
    case "install_asset":
      return try await callInstallAsset(arguments, token: token, emit: emit)
    case "delete_asset":
      return try await callDeleteAsset(arguments)
    default:
      throw MCPError(code: -32602, message: "Unknown tool: \(name)")
    }
  }

  /// Builds an engine `ProgressCallback` that maps per-step progress onto MCP
  /// `notifications/progress`. Returns `nil` when the caller didn't opt in
  /// with a `_meta.progressToken` or the transport can't stream — the spec
  /// only permits progress notifications when the client supplied a token.
  private func progressCallback(
    token: ProgressToken?, emit: NotificationSink?
  ) -> ProgressCallback? {
    guard let emit, let token else { return nil }
    return { step, total, _ in
      let notification: [String: Any] = [
        "jsonrpc": "2.0",
        "method": "notifications/progress",
        "params": [
          "progressToken": token.jsonValue,
          "progress": step,
          "total": total,
        ],
      ]
      guard
        let data = try? JSONSerialization.data(
          withJSONObject: notification, options: [.withoutEscapingSlashes])
      else { return }
      emit(data)
    }
  }

  // MARK: - Tool: resolve_compose / resolve_edit / resolve_restore

  private func callResolveCompose(_ args: [String: Any]) async throws -> [String: Any] {
    let request = try decode(args, as: ComposeRequest.self)
    let response = await engine.resolveCompose(request)
    return toolResult(content: [try jsonTextBlock(response, label: "ResolveResponse")])
  }

  private func callResolveEdit(_ args: [String: Any]) async throws -> [String: Any] {
    var args = args
    try Self.inlineImagePath(&args, pathKey: "from_image_path", into: "from")
    let request = try decode(args, as: EditRequest.self)
    let response = await engine.resolveEdit(request)
    return toolResult(content: [try jsonTextBlock(response, label: "ResolveResponse")])
  }

  private func callResolveRestore(_ args: [String: Any]) async throws -> [String: Any] {
    var args = args
    try Self.inlineImagePath(&args, pathKey: "from_image_path", into: "from")
    let request = try decode(args, as: RestoreRequest.self)
    let response = await engine.resolveRestore(request)
    return toolResult(content: [try jsonTextBlock(response, label: "ResolveResponse")])
  }

  // MARK: - Tool: compose

  private func callCompose(
    _ args: [String: Any], requestId: Any?, token: ProgressToken?, emit: NotificationSink?
  ) async throws -> [String: Any] {
    var args = args
    try Self.inlineImagePath(&args, pathKey: "from_image_path", into: "from")
    let request = try decode(args, as: ComposeRequest.self)
    guard let params = request.params else {
      return errorToolResult(error: EngineError.paramsRequired)
    }
    return await runRegisteredGenerationCompose(
      requestId: requestId, kind: "compose",
      prompt: request.prompt, width: params.width, height: params.height, steps: params.steps,
      progressToken: token, emit: emit,
      recipe: { Self.recipe(verb: "compose", request: request, appliedDefaults: $0) }
    ) { [engine] runId, onProgress in
      try await engine.compose(request, runId: runId, onProgress: onProgress)
    }
  }

  // MARK: - Tool: edit

  private func callEdit(
    _ args: [String: Any], requestId: Any?, token: ProgressToken?, emit: NotificationSink?
  ) async throws -> [String: Any] {
    var args = args
    try Self.inlineImagePath(&args, pathKey: "from_image_path", into: "from")
    try Self.inlineImagePath(&args, pathKey: "mask_path", into: "mask", isPlainScalar: true)
    let request = try decode(args, as: EditRequest.self)
    guard let params = request.params else {
      return errorToolResult(error: EngineError.paramsRequired)
    }
    return await runRegisteredGeneration(
      requestId: requestId, kind: "edit",
      prompt: request.instruction, width: params.width, height: params.height, steps: params.steps,
      progressToken: token, emit: emit,
      recipe: { Self.recipe(verb: "edit", request: request, appliedDefaults: $0) }
    ) { [engine] runId, onProgress in
      try await engine.edit(request, runId: runId, onProgress: onProgress)
    }
  }

  // MARK: - Tool: restore

  private func callRestore(
    _ args: [String: Any], requestId: Any?, token: ProgressToken?, emit: NotificationSink?
  ) async throws -> [String: Any] {
    var args = args
    try Self.inlineImagePath(&args, pathKey: "from_image_path", into: "from")
    let request = try decode(args, as: RestoreRequest.self)
    guard let params = request.params else {
      return errorToolResult(error: EngineError.paramsRequired)
    }
    return await runRegisteredGeneration(
      requestId: requestId, kind: "restore",
      prompt: "", width: params.width, height: params.height, steps: params.steps,
      progressToken: token, emit: emit,
      recipe: { Self.recipe(verb: "restore", request: request, appliedDefaults: $0) }
    ) { [engine] runId, onProgress in
      try await engine.restore(request, runId: runId, onProgress: onProgress)
    }
  }

  // MARK: - Tool: pipeline (R4)

  private func callPipeline(
    _ args: [String: Any], requestId: Any?, token: ProgressToken?, emit: NotificationSink?
  ) async throws -> [String: Any] {
    let request = try decode(args, as: PipelineRequest.self)
    let runId = Self.runId(forRequestId: requestId) ?? "mcp-\(UUID().uuidString)"
    let info = RunInfo(
      runId: runId, kind: "pipeline",
      prompt: "\(request.steps.count)-step pipeline",
      width: 0, height: 0, steps: request.steps.count)
    let mcpProgress = progressCallback(token: token, emit: emit)
    let registry = self.registry

    let task = Task<PipelineResponse, Error> { [engine] in
      try await engine.pipeline(request, runId: runId) { step, total, preview in
        Task { await registry.updateProgress(runId, step: step, total: total, previewPNG: preview) }
        mcpProgress?(step, total, preview)
      }
    }
    let admitted = await registry.tryRegister(
      info, cap: maxActiveRuns, cancel: { task.cancel() })
    guard admitted else {
      task.cancel()
      let count = await registry.activeCount()
      return toolResult(
        content: [textBlock(
          "[TOO_MANY_ACTIVE_RUNS] Server is at concurrent-run capacity "
          + "(\(count) active, --max-active-runs=\(maxActiveRuns.map(String.init) ?? "?")). "
          + "Retry later.")],
        isError: true)
    }
    do {
      let response = try await task.value
      await registry.unregister(runId)
      return pipelineResult(response, recipe: pipelineRecipeObject(request).flatMap(recipeJSONString))
    } catch let error {
      await registry.unregister(runId)
      logger.info("pipeline (mcp)  → error")
      return errorToolResult(error: error)
    }
  }

  /// Shapes a pipeline response into a `tools/call` result. Image blocks
  /// for each named output (so hosts that render images can display them),
  /// followed by a summary text block.
  private func pipelineResult(_ response: PipelineResponse, recipe: String? = nil) -> [String: Any] {
    var content: [[String: Any]] = []
    for (name, b64) in response.outputs.sorted(by: { $0.key < $1.key }) {
      content.append(imageBlock(base64: b64, mimeType: "image/png"))
      content.append(textBlock("Output `\(name)`:"))
    }
    let names = response.outputs.keys.sorted().joined(separator: ", ")
    content.append(textBlock(
      "Pipeline completed in \(response.generationTimeMs) ms. "
      + "Outputs: [\(names)]."))
    if let block = recipeBlock(recipe) { content.append(block) }
    return toolResult(content: content)
  }

  /// Convenience preprocessing: when the caller passed `<pathKey>` (a
  /// filesystem path — natural for desktop hosts) instead of base64 bytes,
  /// read the file and inject the wire-shape replacement. `pathKey` is the
  /// arg name to consume (e.g. `"from_image_path"`); `into` is the target
  /// arg name (`"from"` for FromSource, `"mask"` for the plain base64 mask).
  /// `isPlainScalar=true` writes a bare base64 string; otherwise wraps in
  /// `{"image": "<b64>"}` to match `FromSource.image`.
  private static func inlineImagePath(
    _ args: inout [String: Any], pathKey: String, into target: String,
    isPlainScalar: Bool = false
  ) throws {
    guard let path = args[pathKey] as? String else { return }
    args.removeValue(forKey: pathKey)
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let data = try Data(contentsOf: url)
    let b64 = data.base64EncodedString()
    args[target] = isPlainScalar ? b64 : ["image": b64]
  }

  // MARK: - Registered, cancellable generation

  /// Derives a `RunRegistry` run id from a JSON-RPC request id. The same
  /// derivation is applied to `notifications/cancelled`'s `requestId`, so a
  /// cancellation reaches the run registered for that request. The `mcp-`
  /// prefix keeps MCP runs from colliding with REST run ids.
  private static func runId(forRequestId id: Any?) -> String? {
    switch id {
    case let s as String: return "mcp-\(s)"
    case let n as NSNumber: return "mcp-\(n)"
    default: return nil
    }
  }

  /// Runs an image-returning generation (edit / restore) registered in the
  /// shared `RunRegistry`, inside a cancellable task — so it shows in
  /// `GET /v1/runs`, honours `--max-active-runs`, and is cancellable via
  /// `notifications/cancelled` (MCP) or `DELETE /v1/runs/{id}` (REST): parity
  /// with the REST routes. Errors — cancellation included — come back as
  /// tool-result errors.
  private func runRegisteredGeneration(
    requestId: Any?, kind: String,
    prompt: String, width: Int, height: Int, steps: Int,
    progressToken: ProgressToken?, emit: NotificationSink?,
    recipe: @escaping @Sendable ([AppliedDefault]) -> String?,
    _ block: @escaping @Sendable (_ runId: String, _ onProgress: @escaping ProgressCallback)
      async throws -> GenerationResponse
  ) async -> [String: Any] {
    let runId = Self.runId(forRequestId: requestId) ?? "mcp-\(UUID().uuidString)"
    let info = RunInfo(
      runId: runId, kind: kind, prompt: prompt,
      width: width, height: height, steps: steps)
    let mcpProgress = progressCallback(token: progressToken, emit: emit)
    let registry = self.registry

    let task = Task<GenerationResponse, Error> {
      try await block(runId) { step, total, preview in
        Task { await registry.updateProgress(runId, step: step, total: total, previewPNG: preview) }
        mcpProgress?(step, total, preview)
      }
    }
    let admitted = await registry.tryRegister(
      info, cap: maxActiveRuns, cancel: { task.cancel() })
    guard admitted else {
      task.cancel()
      let count = await registry.activeCount()
      return toolResult(
        content: [textBlock(
          "[TOO_MANY_ACTIVE_RUNS] Server is at concurrent-run capacity "
          + "(\(count) active, --max-active-runs=\(maxActiveRuns.map(String.init) ?? "?")). "
          + "Retry later.")],
        isError: true)
    }
    do {
      let response = try await task.value
      await registry.unregister(runId)
      return imageGenerationResult(response, recipe: recipe(response.metadata.appliedDefaults))
    } catch let error {
      await registry.unregister(runId)
      logger.info("\(kind) (mcp)  → error")
      return errorToolResult(error: error)
    }
  }

  /// Compose-specific registered generation. Compose returns image OR video
  /// (`ComposeResult`) so the result shaping differs from the image-only
  /// twin above.
  private func runRegisteredGenerationCompose(
    requestId: Any?, kind: String,
    prompt: String, width: Int, height: Int, steps: Int,
    progressToken: ProgressToken?, emit: NotificationSink?,
    recipe: @escaping @Sendable ([AppliedDefault]) -> String?,
    _ block: @escaping @Sendable (_ runId: String, _ onProgress: @escaping ProgressCallback)
      async throws -> ComposeResult
  ) async -> [String: Any] {
    let runId = Self.runId(forRequestId: requestId) ?? "mcp-\(UUID().uuidString)"
    let info = RunInfo(
      runId: runId, kind: kind, prompt: prompt,
      width: width, height: height, steps: steps)
    let mcpProgress = progressCallback(token: progressToken, emit: emit)
    let registry = self.registry

    let task = Task<ComposeResult, Error> {
      try await block(runId) { step, total, preview in
        Task { await registry.updateProgress(runId, step: step, total: total, previewPNG: preview) }
        mcpProgress?(step, total, preview)
      }
    }
    let admitted = await registry.tryRegister(
      info, cap: maxActiveRuns, cancel: { task.cancel() })
    guard admitted else {
      task.cancel()
      let count = await registry.activeCount()
      return toolResult(
        content: [textBlock(
          "[TOO_MANY_ACTIVE_RUNS] Server is at concurrent-run capacity "
          + "(\(count) active, --max-active-runs=\(maxActiveRuns.map(String.init) ?? "?")). "
          + "Retry later.")],
        isError: true)
    }
    do {
      let result = try await task.value
      await registry.unregister(runId)
      switch result {
      case .image(let r): return imageGenerationResult(r, recipe: recipe(r.metadata.appliedDefaults))
      case .video(let r): return videoGenerationResult(r, recipe: recipe(r.metadata.appliedDefaults))
      }
    } catch let error {
      await registry.unregister(runId)
      logger.info("\(kind) (mcp)  → error")
      return errorToolResult(error: error)
    }
  }

  /// Shapes a video response into a `tools/call` result. Currently emits
  /// the summary text block only — the bytes are too large to inline in an
  /// MCP text payload by default; agents fetch them via REST when they need
  /// the raw mp4.
  private func videoGenerationResult(_ response: VideoGenerationResponse, recipe: String? = nil) -> [String: Any] {
    var lines: [String] = []
    lines.append(
      "Generated \(response.videos.count) video(s) in \(response.generationTimeMs) ms.")
    for (i, v) in response.videos.enumerated() {
      lines.append(
        "  - [\(i)] \(v.numFrames) frame(s) @ \(v.fps) fps, "
        + "\(v.width)×\(v.height), seed=\(v.seed) — base64 mp4 inline below.")
    }
    if !response.metadata.warnings.isEmpty {
      lines.append("Warnings:")
      for w in response.metadata.warnings { lines.append("  - [\(w.code)] \(w.message)") }
    }
    if !response.metadata.appliedDefaults.isEmpty {
      let filled = response.metadata.appliedDefaults.map { $0.fieldPath }.joined(separator: ", ")
      lines.append("Engine-filled fields: \(filled)")
    }
    var content: [[String: Any]] = [textBlock(lines.joined(separator: "\n"))]
    for v in response.videos {
      // mp4 isn't an MCP "image" type — use a resource link so hosts that
      // know how to render video can; otherwise the summary above carries
      // the bookkeeping.
      content.append([
        "type": "resource",
        "resource": [
          "uri": "data:video/mp4;base64,\(v.data)",
          "mimeType": "video/mp4",
        ],
      ])
    }
    if let block = recipeBlock(recipe) { content.append(block) }
    return toolResult(content: content)
  }

  // MARK: - Tool: get_capabilities

  /// Mirrors REST `GET /v1/capabilities/{model_id}`: the per-model capability
  /// contract (operations, accepted/silently-dropped/refused params, notes).
  private func callGetCapabilities(_ args: [String: Any]) async throws -> [String: Any] {
    guard let modelId = args["model_id"] as? String else {
      throw MCPError(code: -32602, message: "get_capabilities requires 'model_id' (string)")
    }
    guard let response = CapabilityMap.response(forModelId: modelId) else {
      return toolResult(
        content: [textBlock(
          "No capability entry for base_model_id '\(modelId)' — not in the catalog. "
          + "Use list_assets(type='base_model') to discover installed ids.")],
        isError: true)
    }
    return toolResult(content: [try jsonTextBlock(response, label: "CapabilitiesResponse")])
  }

  // MARK: - Tool: list_runs / get_run

  /// Mirrors REST `GET /v1/runs`: in-flight runs, most recent first. Shares the
  /// `RunRegistry` and the `runSummary` shaping with the REST route.
  private func callListRuns() async throws -> [String: Any] {
    let response = RunListResponse(runs: await registry.list().map(runSummary))
    return toolResult(content: [try jsonTextBlock(response, label: "RunListResponse")])
  }

  /// Mirrors REST `GET /v1/runs/{run_id}`: one run with its latest preview frame.
  private func callGetRun(_ args: [String: Any]) async throws -> [String: Any] {
    guard let runId = args["run_id"] as? String else {
      throw MCPError(code: -32602, message: "get_run requires 'run_id' (string)")
    }
    guard let info = await registry.get(runId) else {
      return toolResult(
        content: [textBlock(
          "No in-flight run with id '\(runId)'. Use list_runs to see active runs.")],
        isError: true)
    }
    return toolResult(content: [try jsonTextBlock(runDetail(info), label: "RunDetailResponse")])
  }

  // MARK: - Tool: list_assets

  private func callListAssets(_ args: [String: Any]) async throws -> [String: Any] {
    let filter = AssetManager.Filter(
      type: (args["type"] as? String).flatMap(AssetType.init(rawValue:)),
      architecture: (args["architecture"] as? String).flatMap(Architecture.init(rawValue:)),
      domain: (args["domain"] as? String).flatMap(Domain.init(rawValue:)),
      controlnetTask: (args["task"] as? String).flatMap(ControlNetTask.init(rawValue:)),
      downloadedOnly: (args["downloaded_only"] as? Bool) ?? true
    )
    let items = await assets.list(filter: filter)
    let response = AssetListResponse(items: items)
    return toolResult(content: [
      try jsonTextBlock(response, label: "AssetListResponse")
    ])
  }

  // MARK: - Tool: get_asset

  private func callGetAsset(_ args: [String: Any]) async throws -> [String: Any] {
    guard let id = args["id"] as? String else {
      throw MCPError(code: -32602, message: "get_asset requires 'id' (string)")
    }
    guard let asset = await assets.get(id: id) else {
      return toolResult(
        content: [textBlock("Asset not found: '\(id)'. Use list_assets to discover available ids.")],
        isError: true)
    }
    return toolResult(content: [try jsonTextBlock(asset, label: "Asset")])
  }

  // MARK: - Tool: install_asset

  private func callInstallAsset(
    _ args: [String: Any], token: ProgressToken?, emit: NotificationSink?
  ) async throws -> [String: Any] {
    if readOnly {
      return toolResult(
        content: [textBlock(
          "[READ_ONLY_MODE] Server is running read-only; asset installs are disabled.")],
        isError: true)
    }
    let request = try decode(args, as: InstallAssetRequest.self)
    do {
      let asset = try await assets.install(
        request, onState: installProgressSink(token: token, emit: emit))
      return toolResult(content: [try jsonTextBlock(asset, label: "Asset")])
    } catch let error {
      return errorToolResult(error: error)
    }
  }

  /// Maps SDK install-state ticks onto MCP `notifications/progress`. Returns
  /// `nil` when the caller didn't opt in with a `_meta.progressToken` or the
  /// transport can't stream. The per-file byte counts are not monotonic
  /// across a multi-file download — the `message` carries the human detail.
  private func installProgressSink(
    token: ProgressToken?, emit: NotificationSink?
  ) -> (@Sendable (MediaGenerationEnvironment.EnsureState) -> Void)? {
    guard let emit, let token else { return nil }
    return { state in
      let progress: Int
      let total: Int?
      let message: String
      switch state {
      case .resolving:
        progress = 0
        total = nil
        message = "Resolving install plan…"
      case .verifying(let file, let fileIndex, let totalFiles):
        progress = 0
        total = nil
        message = "Verifying \(file) (file \(fileIndex)/\(totalFiles))"
      case .downloading(let file, let fileIndex, let totalFiles, let bytesWritten, let totalBytes):
        progress = Int(bytesWritten)
        total = Int(totalBytes)
        message = "Downloading \(file) (file \(fileIndex)/\(totalFiles))"
      }
      var params: [String: Any] = [
        "progressToken": token.jsonValue,
        "progress": progress,
        "message": message,
      ]
      if let total { params["total"] = total }
      let notification: [String: Any] = [
        "jsonrpc": "2.0",
        "method": "notifications/progress",
        "params": params,
      ]
      guard
        let data = try? JSONSerialization.data(
          withJSONObject: notification, options: [.withoutEscapingSlashes])
      else { return }
      emit(data)
    }
  }

  // MARK: - Tool: delete_asset

  private func callDeleteAsset(_ args: [String: Any]) async throws -> [String: Any] {
    if readOnly {
      return toolResult(
        content: [textBlock(
          "[READ_ONLY_MODE] Server is running read-only; asset deletes are disabled.")],
        isError: true)
    }
    guard let id = args["id"] as? String else {
      throw MCPError(code: -32602, message: "delete_asset requires 'id' (string)")
    }
    do {
      try await assets.delete(id: id)
      return toolResult(content: [textBlock("Deleted asset '\(id)'.")])
    } catch let error {
      return errorToolResult(error: error)
    }
  }

  // MARK: - Shared response shaping

  private func imageGenerationResult(_ response: GenerationResponse, recipe: String? = nil) -> [String: Any] {
    // The image content blocks come first so they render inline in
    // hosts that visualize content. The summary text block follows so
    // the model can reason about timing / seed / warnings without
    // re-parsing the image bytes. The recipe block (REST `X-DHT-Recipe`
    // parity) comes last.
    var content: [[String: Any]] = []
    for image in response.images {
      content.append(imageBlock(base64: image, mimeType: "image/png"))
    }
    content.append(textBlock(summarize(response)))
    if let block = recipeBlock(recipe) { content.append(block) }
    return toolResult(content: content)
  }

  /// The canonical, re-postable recipe for a verb result, as compact JSON —
  /// REST parity with the `X-DHT-Recipe` header (`recipeObject` /
  /// `recipeJSONString` in Routes.swift). Inline images appear as
  /// `sha256:<hex>;bytes=<n>` digest references, exactly as in the header, so
  /// the block stays small and the agent re-attaches the bytes it already holds.
  private static func recipe<R: Encodable>(
    verb: String, request: R, appliedDefaults: [AppliedDefault]
  ) -> String? {
    recipeObject(verb: verb, request: request, appliedDefaults: appliedDefaults)
      .flatMap(recipeJSONString)
  }

  /// A `Recipe:` text block carrying the canonical re-postable recipe. `nil`
  /// recipe → no block (encoding failed; the recipe is metadata-on-the-side,
  /// never load-bearing).
  private func recipeBlock(_ recipe: String?) -> [String: Any]? {
    guard let recipe else { return nil }
    return textBlock(
      "Recipe (re-postable to this verb; inline images shown as "
      + "sha256:<hex>;bytes=<n> digest refs — re-attach the bytes you hold):\n\(recipe)")
  }

  private func summarize(_ r: GenerationResponse) -> String {
    var lines: [String] = []
    lines.append("Generated \(r.images.count) image(s) in \(r.generationTimeMs) ms (seed=\(r.seed)).")
    if !r.metadata.warnings.isEmpty {
      lines.append("Warnings:")
      for w in r.metadata.warnings {
        lines.append("  - [\(w.code)] \(w.message)")
      }
    }
    if !r.metadata.appliedDefaults.isEmpty {
      let filled = r.metadata.appliedDefaults.map { $0.fieldPath }.joined(separator: ", ")
      lines.append("Engine-filled fields: \(filled)")
    }
    return lines.joined(separator: "\n")
  }

  private func errorToolResult(error: Error) -> [String: Any] {
    // Translate engine/validation errors using the same taxonomy as the
    // HTTP path. The text payload mirrors what an HTTP client would see
    // in the Problem Details body — so an agent gets the same
    // `error_code` to reason about whether to retry, fix, or escalate.
    let code: String
    let message: String
    if error is CancellationError {
      code = "RUN_CANCELLED"
      message = "The run was cancelled."
    } else if let mgk = error as? MediaGenerationKitError, case .cancelled = mgk {
      code = "RUN_CANCELLED"
      message = "The engine reported the run was cancelled."
    } else if let typed = error as? TypedError {
      code = typed.errorCode
      message = typed.detail ?? typed.title
    } else if let e = error as? EngineError {
      let typed = TypedError.from(engineError: e)
      code = typed.errorCode
      message = typed.detail ?? typed.title
    } else if let m = error as? AssetMutationError {
      // The LARGE_MODEL_DOWNLOAD detail already tells the agent to read
      // install_size_bytes via get_asset and re-submit with
      // confirm_large_download: true — so it flows straight through.
      let typed = TypedError.from(mutationError: m)
      code = typed.errorCode
      message = typed.detail ?? typed.title
    } else if let v = error as? ValidationError {
      code = "VALIDATION_FAILED"
      message = v.detail
    } else {
      code = "ENGINE_INTERNAL_ERROR"
      message = "\(error)"
    }
    return toolResult(
      content: [textBlock("[\(code)] \(message)")],
      isError: true)
  }

  // MARK: - Content helpers

  private func toolResult(content: [[String: Any]], isError: Bool = false) -> [String: Any] {
    return ["content": content, "isError": isError]
  }

  private func textBlock(_ text: String) -> [String: Any] {
    return ["type": "text", "text": text]
  }

  private func imageBlock(base64: String, mimeType: String) -> [String: Any] {
    return ["type": "image", "data": base64, "mimeType": mimeType]
  }

  private func jsonTextBlock<T: Encodable>(_ value: T, label: String) throws -> [String: Any] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    let json = String(data: data, encoding: .utf8) ?? "{}"
    return textBlock("\(label):\n\(json)")
  }

  // MARK: - Decoding args

  private func decode<T: Decodable>(_ args: [String: Any], as type: T.Type) throws -> T {
    let data: Data
    do {
      data = try JSONSerialization.data(withJSONObject: args)
    } catch {
      throw MCPError(code: -32602, message: "Cannot serialize tool arguments: \(error)")
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw MCPError(code: -32602, message: "Invalid tool arguments: \(error)")
    }
  }

  // MARK: - Error envelopes

  private func errorEnvelope(id: Any?, code: Int, message: String) -> [String: Any] {
    return [
      "jsonrpc": "2.0",
      "id": id ?? NSNull(),
      "error": ["code": code, "message": message],
    ]
  }

  /// JSON-RPC parse-error envelope (`-32700`). Used by the transport when the
  /// request body isn't valid JSON, so it can't be parsed into an envelope.
  static func parseErrorEnvelope(message: String) -> [String: Any] {
    return [
      "jsonrpc": "2.0",
      "id": NSNull(),
      "error": ["code": -32700, "message": "Parse error: \(message)"],
    ]
  }
}

struct MCPError: Error {
  let code: Int
  let message: String
}

/// A JSON-RPC progress token (`string | integer`, per MCP spec). Modelled as a
/// concrete `Sendable` type so it can be captured by the `@Sendable` progress
/// callback without smuggling an `Any` across the concurrency boundary.
enum ProgressToken: Sendable {
  case string(String)
  case int(Int)

  init?(metaValue: Any?) {
    switch metaValue {
    case let s as String: self = .string(s)
    case let n as Int: self = .int(n)
    case let n as NSNumber: self = .int(n.intValue)
    default: return nil
    }
  }

  var jsonValue: Any {
    switch self {
    case .string(let s): return s
    case .int(let i): return i
    }
  }
}

// MARK: - Tool catalog

/// Hand-written tool schemas mirroring the REST surface. Three semantic
/// verbs (`compose`, `edit`,
/// `restore`) + a per-verb resolve dry-run + `pipeline`, the per-model
/// `get_capabilities` contract, run introspection (`list_runs` / `get_run`),
/// and the asset CRUD tools. Cancellation has no tool — it is the MCP
/// `notifications/cancelled` mechanism, mirroring REST `DELETE /v1/runs/{id}`.
/// Advanced engine knobs (refiner, upscaler, controlnets, hires_fix,
/// extensions.draw_things.*) are not enumerated in the schemas — the pattern
/// is for the agent to call `resolve_<verb>` first (which accepts the full
/// schema and reports applied defaults + warnings), then iterate.
enum MCPToolCatalog {
  static var all: [[String: Any]] {
    return [
      resolveCompose,
      resolveEdit,
      resolveRestore,
      compose,
      edit,
      restore,
      pipeline,
      getCapabilities,
      listRuns,
      getRun,
      listAssets,
      getAsset,
      installAsset,
      deleteAsset,
    ]
  }

  /// Common engine knobs that live inside `params` on every verb. Kept compact
  /// (required + most-used optionals); the contract endpoint returns the full
  /// per-model story.
  private static var engineParamsProperties: [String: Any] {
    return [
      "width": ["type": "integer", "minimum": 64, "maximum": 4096, "default": 512],
      "height": ["type": "integer", "minimum": 64, "maximum": 4096, "default": 512],
      "steps": ["type": "integer", "minimum": 1, "maximum": 200, "default": 20],
      "cfg_scale": ["type": "number", "minimum": 0, "maximum": 30],
      "seed": [
        "type": "integer",
        "description": "Omit or pass -1 for random.",
      ],
      "sampler": ["type": "string"],
      "batch_size": ["type": "integer", "minimum": 1, "maximum": 8],
      "batch_count": ["type": "integer", "minimum": 1, "maximum": 16],
      "denoising_strength": [
        "type": "number", "minimum": 0, "maximum": 1,
        "description":
          "Used by compose when `from` carries an image (img2img path). "
          + "0 = source untouched, 1 = full reimagining. Default 0.7.",
      ],
      "conditioning_strength": [
        "type": "number", "minimum": 0, "maximum": 1,
        "description":
          "Used by compose when targeting a video model with `from` (img2vid).",
      ],
      "loras": [
        "type": "array",
        "items": [
          "type": "object",
          "required": ["lora_id"],
          "properties": [
            "lora_id": ["type": "string"],
            "weight": ["type": "number", "minimum": 0, "maximum": 10, "default": 1.0],
          ],
        ],
      ],
      "video": [
        "type": "object",
        "description":
          "Required when `model` is a video architecture. Carries num_frames "
          + "(required), plus optional fps / video_format / motion.",
        "properties": [
          "num_frames": ["type": "integer", "minimum": 1, "maximum": 256],
          "fps": ["type": "integer", "minimum": 1, "maximum": 120, "default": 24],
          "video_format": ["type": "string", "enum": ["mp4_h264", "mp4_hevc"], "default": "mp4_h264"],
        ],
      ],
    ]
  }

  private static var paramsSchema: [String: Any] {
    return [
      "type": "object",
      "required": ["width", "height", "steps"],
      "properties": engineParamsProperties,
    ]
  }

  /// `from` field — polymorphic image source shared by compose / edit /
  /// restore. The path-shortcut sibling fields (`from_image_path`,
  /// `mask_path`) are MCP-only conveniences (the handler reads the file and
  /// inlines the bytes before decoding).
  private static var fromSchema: [String: Any] {
    return [
      "type": "object",
      "description":
        "Where the input image comes from. Use { image: \"<base64>\" }, or "
        + "{ via: \"compose\"|\"edit\"|\"restore\", … } to nest a sub-recipe.",
      "properties": [
        "image": ["type": "string", "description": "Base64-encoded image bytes."],
        "via": ["type": "string", "enum": ["compose", "edit", "restore"]],
      ],
    ]
  }

  // MARK: Compose

  static var compose: [String: Any] {
    return [
      "name": "compose",
      "description":
        "Produce an image or video — the chosen model's domain decides. "
        + "`from` is *a guide*, not a target: omit for pure text-to-output, "
        + "or pass a literal `{image: <b64>}` (use `from_image_path` to read "
        + "a local file instead) or a nested sub-recipe via `{via: ..., ...}`. "
        + "Width / height / steps live in `params`. Use `resolve_compose` "
        + "first to surface engine quirks cheaply.",
      "inputSchema": [
        "type": "object",
        "required": ["model", "prompt"],
        "properties": [
          "model": [
            "type": "string",
            "description":
              "An installed base-model id (filename in the models directory). "
              + "Discover via list_assets(type='base_model').",
          ],
          "prompt": ["type": "string"],
          "negative_prompt": ["type": "string"],
          "from": fromSchema,
          "from_image_path": [
            "type": "string",
            "description":
              "MCP-only convenience: filesystem path to a local image. Tilde "
              + "expansion supported. Read by the handler and inlined as "
              + "`from: {image: <b64>}` before decoding.",
          ],
          "params": paramsSchema,
        ],
      ],
    ]
  }

  static var resolveCompose: [String: Any] {
    return [
      "name": "resolve_compose",
      "description":
        "Dry-run a compose request: validate, surface engine quirks as "
        + "warnings, list which Core fields the engine will default, return "
        + "an estimated compute-units cost. Side-effect-free.",
      "inputSchema": compose["inputSchema"]!,
    ]
  }

  // MARK: Edit

  static var edit: [String: Any] {
    return [
      "name": "edit",
      "description":
        "Preserve-and-change an image. `instruction` is the natural-language "
        + "ask (e.g. 'remove the watermark'). With an instruction-edit base "
        + "model (Flux Kontext, Qwen-Image-Edit) the engine generates from "
        + "noise steered by the instruction. Pass `mask` (base64) — or "
        + "`mask_path` (local file path) — to switch to the inpaint path "
        + "(non-zero pixels mark regenerate region). `references[]` add extra "
        + "context images.",
      "inputSchema": [
        "type": "object",
        "required": ["model", "from", "instruction"],
        "properties": [
          "model": ["type": "string"],
          "from": fromSchema,
          "from_image_path": [
            "type": "string",
            "description":
              "MCP-only convenience. Tilde expansion supported. Read by the "
              + "handler and inlined as `from: {image: <b64>}`.",
          ],
          "instruction": ["type": "string"],
          "mask": [
            "type": "string",
            "description":
              "Optional base64-encoded mask (non-zero pixels = regenerate). "
              + "Presence flips the engine path from instruction-edit to inpaint.",
          ],
          "mask_path": [
            "type": "string",
            "description":
              "MCP-only convenience: filesystem path to a local mask. Tilde "
              + "expansion supported. Read by the handler and inlined as `mask`.",
          ],
          "references": [
            "type": "array",
            "items": [
              "type": "object",
              "required": ["image"],
              "properties": [
                "image": fromSchema,
                "role": [
                  "type": "string",
                  "enum": ["style", "identity", "layout", "pose", "subject", "reference"],
                ],
              ],
            ],
          ],
          "params": paramsSchema,
        ],
      ],
    ]
  }

  static var resolveEdit: [String: Any] {
    return [
      "name": "resolve_edit",
      "description":
        "Dry-run an edit request — same shape as `edit`, no diffusion run.",
      "inputSchema": edit["inputSchema"]!,
    ]
  }

  // MARK: Restore

  static var restore: [String: Any] {
    return [
      "name": "restore",
      "description":
        "Preserve-and-enhance an image. Same content, higher fidelity. "
        + "Currently driven by SeedVR2 (`seedvr2_3b` / `seedvr2_7b`). No "
        + "prompt, no creative liberty.",
      "inputSchema": [
        "type": "object",
        "required": ["model", "from"],
        "properties": [
          "model": ["type": "string"],
          "from": fromSchema,
          "from_image_path": [
            "type": "string",
            "description":
              "MCP-only convenience. Tilde expansion supported. Read by the "
              + "handler and inlined as `from: {image: <b64>}`.",
          ],
          "params": paramsSchema,
        ],
      ],
    ]
  }

  static var resolveRestore: [String: Any] {
    return [
      "name": "resolve_restore",
      "description":
        "Dry-run a restore request — same shape as `restore`, no diffusion run.",
      "inputSchema": restore["inputSchema"]!,
    ]
  }

  // MARK: Pipeline

  static var pipeline: [String: Any] {
    return [
      "name": "pipeline",
      "description":
        "Run an ordered chain of compose / edit / restore recipes. Each "
        + "step's image output becomes addressable in later steps via "
        + "`from: \"$<as>\"`, `references[].image: \"$<as>\"`, or "
        + "`guides[].image: \"$<as>\"`. Stateless: no asset persists "
        + "between calls. `return` controls which outputs come back "
        + "(defaults to the last step under the key `\"result\"`).",
      "inputSchema": [
        "type": "object",
        "required": ["steps"],
        "properties": [
          "steps": [
            "type": "array",
            "minItems": 1,
            "items": [
              "type": "object",
              "required": ["via"],
              "description":
                "A step is a verb body (compose/edit/restore) plus an "
                + "optional `as` label naming its output.",
              "properties": [
                "as": ["type": "string"],
                "via": ["type": "string", "enum": ["compose", "edit", "restore"]],
              ],
            ],
          ],
          "return": [
            "type": "array",
            "items": ["type": "string"],
            "description":
              "Names of steps whose outputs to return (must match `as` "
              + "labels). Omit for the last step only.",
          ],
        ],
      ],
    ]
  }

  // MARK: Capabilities / runs

  static var getCapabilities: [String: Any] {
    return [
      "name": "get_capabilities",
      "description":
        "Report what one base model supports: which operations apply, which "
        + "params are accepted vs silently dropped vs refused, conditional-field "
        + "requirements, and engine quirks. Call before compose / edit / restore "
        + "to avoid OPERATION_NOT_SUPPORTED_FOR_MODEL and friends. Mirrors REST "
        + "GET /v1/capabilities/{model_id}.",
      "inputSchema": [
        "type": "object",
        "required": ["model_id"],
        "properties": [
          "model_id": [
            "type": "string",
            "description": "Installed base-model id (filename in the models directory).",
          ],
        ],
      ],
    ]
  }

  static var listRuns: [String: Any] {
    return [
      "name": "list_runs",
      "description":
        "List in-flight generation runs (compose / edit / restore / pipeline), "
        + "most recent first, with per-run step progress. Mirrors REST "
        + "GET /v1/runs. Cancel a run by sending a notifications/cancelled for "
        + "the request id that started it.",
      "inputSchema": [
        "type": "object",
        "properties": [:] as [String: Any],
      ],
    ]
  }

  static var getRun: [String: Any] {
    return [
      "name": "get_run",
      "description":
        "Fetch one in-flight run by id, including the latest live-preview frame "
        + "(base64 PNG) once the engine has emitted one. Mirrors REST "
        + "GET /v1/runs/{run_id}.",
      "inputSchema": [
        "type": "object",
        "required": ["run_id"],
        "properties": [
          "run_id": ["type": "string"],
        ],
      ],
    ]
  }

  static var listAssets: [String: Any] {
    return [
      "name": "list_assets",
      "description":
        "List installed assets (base models, LoRAs, ControlNets, embeddings, "
        + "upscalers, face-restoration). Filterable by type, architecture, "
        + "domain (image vs video), and ControlNet task. Use this to "
        + "discover available `model` ids before `compose` / `edit` / "
        + "`restore` / `pipeline`.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "type": [
            "type": "string",
            "enum": ["base_model", "lora", "controlnet", "embedding", "upscaler", "face_restoration"],
          ],
          "architecture": ["type": "string"],
          "domain": ["type": "string", "enum": ["image", "video"]],
          "task": [
            "type": "string",
            "description": "ControlNet task filter (depth, canny, pose, ...).",
          ],
          "downloaded_only": ["type": "boolean", "default": true],
        ],
      ],
    ]
  }

  static var getAsset: [String: Any] {
    return [
      "name": "get_asset",
      "description":
        "Fetch the full metadata for one asset by id. Surfaces information "
        + "list_assets summarises (architecture, file, deprecated flag, etc.).",
      "inputSchema": [
        "type": "object",
        "required": ["id"],
        "properties": [
          "id": ["type": "string"],
        ],
      ],
    ]
  }

  static var installAsset: [String: Any] {
    return [
      "name": "install_asset",
      "description":
        "Install a model or asset into the models directory. Either a catalog "
        + "model (source.type='catalog', source.model=<catalog id>) or a local "
        + "file (source.type='local_file' — currently 'lora' only). Catalog "
        + "installs over ~5 GB are gated: the first call fails with "
        + "LARGE_MODEL_DOWNLOAD; read install_size_bytes via get_asset, then "
        + "re-call with confirm_large_download=true. Long-running — pass a "
        + "progress token to receive download progress. Refused with "
        + "READ_ONLY_MODE when the server runs read-only.",
      "inputSchema": [
        "type": "object",
        "required": ["source"],
        "properties": [
          "source": [
            "type": "object",
            "required": ["type"],
            "properties": [
              "type": ["type": "string", "enum": ["catalog", "local_file"]],
              "model": [
                "type": "string",
                "description": "Catalog model id (when type='catalog').",
              ],
              "asset_type": [
                "type": "string",
                "enum": ["lora"],
                "description":
                  "Asset type for a local-file install (only 'lora' is supported).",
              ],
              "path": [
                "type": "string",
                "description": "Filesystem path to the file (when type='local_file').",
              ],
              "name": ["type": "string", "description": "Optional display name."],
              "architecture": [
                "type": "string",
                "description": "Optional architecture hint when auto-detection fails.",
              ],
            ],
          ],
          "confirm_large_download": [
            "type": "boolean",
            "description":
              "Set true to proceed past the large-install gate, after reading "
              + "install_size_bytes via get_asset.",
          ],
        ],
      ],
    ]
  }

  static var deleteAsset: [String: Any] {
    return [
      "name": "delete_asset",
      "description":
        "Delete an installed asset by id, removing its files from disk. Files "
        + "still referenced by another installed asset are kept. Refused with "
        + "READ_ONLY_MODE when the server runs read-only.",
      "inputSchema": [
        "type": "object",
        "required": ["id"],
        "properties": [
          "id": ["type": "string"],
        ],
      ],
    ]
  }
}
