import CoreGraphics
import Foundation
import ImageIO
import Logging
import ModelZoo
import _MediaGenerationKit

/// Pinned engine commit. Bumped when we re-resolve the `draw-things-community`
/// dependency in `Package.swift` / `Package.resolved`. Surfaced via
/// `/v1/info` and on every generation response's `RunMetadata`.
let dhtEngineVersion = "draw-things-community@9f3f04b"

/// Per-step progress callback shared by every generation method. Called with
/// `(step, totalSteps, previewPNG)` for each diffusion step the engine emits
/// during `.generating(...)`. `previewPNG` carries the latest live-preview
/// frame as PNG bytes when the SDK emits one (periodically — nil on the steps
/// in between). Other engine states are not surfaced.
typealias ProgressCallback = @Sendable (_ step: Int, _ totalSteps: Int, _ previewPNG: Data?) -> Void

/// Encodes a preview `CGImage` (from `MediaGenerationPipeline.Preview`) to
/// PNG bytes for the run registry / `GET /v1/runs/{id}`.
private func encodePNG(_ image: CGImage) -> Data? {
  let data = NSMutableData()
  guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
  else { return nil }
  CGImageDestinationAddImage(dest, image, nil)
  guard CGImageDestinationFinalize(dest) else { return nil }
  return data as Data
}

/// A short, single-line excerpt of a prompt, for I/O log lines.
private func promptExcerpt(_ prompt: String) -> String {
  let flat = prompt.replacingOccurrences(of: "\n", with: " ")
    .trimmingCharacters(in: .whitespaces)
  guard !flat.isEmpty else { return "" }
  let limit = 48
  let body = flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
  return "  “\(body)”"
}

/// A compact ` [warnings: A, B]` suffix, empty when there are none.
private func warningExcerpt(_ warnings: [Diagnostic]) -> String {
  guard !warnings.isEmpty else { return "" }
  return "  [warnings: \(warnings.map(\.code).joined(separator: ", "))]"
}

/// The surface `makeRouter` consumes — abstract over `DrawThingsEngine` so
/// tests can inject a deterministic fake without loading any model.
/// Three semantic verbs (`compose` / `edit` / `restore`) + a `pipeline`
/// sugar + a per-verb `resolve` dry-run.
protocol GenerationEngine: Sendable {
  func compose(
    _ request: ComposeRequest, runId: String, onProgress: ProgressCallback?
  ) async throws -> ComposeResult
  func edit(
    _ request: EditRequest, runId: String, onProgress: ProgressCallback?
  ) async throws -> GenerationResponse
  func restore(
    _ request: RestoreRequest, runId: String, onProgress: ProgressCallback?
  ) async throws -> GenerationResponse
  func pipeline(
    _ request: PipelineRequest, runId: String, onProgress: ProgressCallback?
  ) async throws -> PipelineResponse
  func resolveCompose(_ request: ComposeRequest) async -> ResolveResponse
  func resolveEdit(_ request: EditRequest) async -> ResolveResponse
  func resolveRestore(_ request: RestoreRequest) async -> ResolveResponse
}

extension GenerationEngine {
  /// Default-arg convenience wrappers so non-streaming callers can omit
  /// the `onProgress:` label. Protocol witnesses can't carry defaults
  /// directly.
  func compose(_ request: ComposeRequest, runId: String) async throws -> ComposeResult {
    try await compose(request, runId: runId, onProgress: nil)
  }
  func edit(_ request: EditRequest, runId: String) async throws -> GenerationResponse {
    try await edit(request, runId: runId, onProgress: nil)
  }
  func restore(_ request: RestoreRequest, runId: String) async throws -> GenerationResponse {
    try await restore(request, runId: runId, onProgress: nil)
  }
  func pipeline(_ request: PipelineRequest, runId: String) async throws -> PipelineResponse {
    try await pipeline(request, runId: runId, onProgress: nil)
  }
}

/// Model architectures where the engine silently forces `batchSize = 1`
/// regardless of the user-requested batch size. Source of truth:
/// `LocalImageGenerator.swift:3789, 5141, 6444, 7343` — identical guard in
/// all four generate paths: `isVideoModel(version) || .seedvr2_3b ||
/// .seedvr2_7b`. Z-Image / Flux / SD3 / other Flow-Matching archs do NOT
/// trigger the cap, contrary to earlier folklore in `engine-quirks.md`.
private let batchSizeCappedVersions: Set<String> = [
  // Video architectures (per ImageGeneratorUtils.isVideoModel)
  "svd_i2v",
  "hunyuan_video",
  "wan_v2.1_1.3b", "wan_v2.1_14b", "wan_v2.2_5b",
  "ltx2", "ltx2.3",
  // Plus the two seedvr2 variants
  "seedvr2_3b", "seedvr2_7b",
]

actor DrawThingsEngine: GenerationEngine {
  private let modelsDirectory: String
  /// Cached pipeline paired with the pristine `Configuration` captured at
  /// load time (recommendedTemplate for the model). Before every request we
  /// snap the pipeline back to the pristine config so optional request
  /// fields reliably fall back to engine defaults across consecutive calls.
  /// The cache also keeps idle RSS stable (~190 MB) — removing it ramps
  /// RSS up by ~30 MB per request via SDK-internal allocator fragmentation
  /// that we can't reach.
  private var cached: (
    model: String, pipeline: MediaGenerationPipeline,
    pristineConfig: MediaGenerationPipeline.Configuration
  )?

  private let logger: Logger

  /// Serialisation gate for every engine-touching section.
  ///
  /// `DrawThingsEngine` is an `actor`, but an actor is *reentrant*: at each
  /// `await` it may admit another call. The work happens against the
  /// process-wide `MediaGenerationEnvironment.default` singleton — driving it
  /// from two `generate()` (or `fromPretrained`) calls at once corrupts shared
  /// engine state. `engineBusy` + `engineWaiters` make the critical section
  /// strictly one-at-a-time: a second request parks (FIFO) instead of
  /// interleaving. Invariant: `engineWaiters` non-empty ⟹ `engineBusy` true.
  ///
  /// This is not a throughput regression — a single GPU pipeline was always
  /// serial; concurrent calls never parallelised, they only raced.
  /// `--max-active-runs` therefore bounds queue depth, not true concurrency.
  private var engineBusy = false
  private var engineWaiters: [CheckedContinuation<Void, Never>] = []

  init(modelsDirectory: String, logger: Logger = Logger(label: "dht-engine")) {
    self.modelsDirectory = modelsDirectory
    self.logger = logger
  }

  /// Runs `body` as the sole owner of the engine. If the gate is held, the
  /// caller parks until the current owner hands it over directly (the gate is
  /// never released to "free" while a waiter exists — ownership transfers).
  ///
  /// A request cancelled while parked still occupies its FIFO slot until its
  /// turn; when handed the gate its `body` hits the engine's own
  /// `Task.checkCancellation()` and returns near-instantly. Correct, just not
  /// the tightest possible — kept simple deliberately.
  private func withEngineGate<T>(_ body: () async throws -> T) async rethrows -> T {
    if engineBusy {
      await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        engineWaiters.append(cont)
      }
      // Resumed: ownership was handed to us; `engineBusy` is already true.
    } else {
      engineBusy = true
    }
    defer {
      if engineWaiters.isEmpty {
        engineBusy = false
      } else {
        engineWaiters.removeFirst().resume()  // hand ownership to the next waiter
      }
    }
    return try await body()
  }

  /// Diagnostics half of the dry-run path, shared by every verb. Takes the
  /// already-materialized `GenerationParams` (built from a verb body by the
  /// public `resolveCompose` / `resolveEdit` / `resolveRestore` wrappers) and
  /// produces validation diagnostics, engine-quirk warnings, the
  /// applied-defaults diff, an ECU estimate, and the pristine config (so
  /// the verb wrapper can rebuild a verb-shaped `resolved_request`). Never
  /// throws on user errors; they're returned as structured `errors[]`.
  fileprivate func resolveDiagnostics(_ params: GenerationParams) async -> (
    pristine: MediaGenerationPipeline.Configuration?,
    appliedDefaults: [AppliedDefault],
    warnings: [Diagnostic],
    errors: [Diagnostic],
    ecu: Int?
  ) {
    var warnings: [Diagnostic] = []
    var errors: [Diagnostic] = []

    do {
      try params.validate()
    } catch let e as ValidationError {
      errors.append(Diagnostic(code: "VALIDATION_FAILED", fieldPath: nil, message: e.detail))
    } catch {
      errors.append(
        Diagnostic(code: "VALIDATION_FAILED", fieldPath: nil, message: "\(error)"))
    }

    // Body-shape checks: these don't require a base model spec.
    collectShapeWarnings(params: params, into: &warnings)

    // Architecture-dependent quirks + asset id catalog checks.
    if let spec = ModelZoo.specificationForModel(params.baseModelId) {
      collectArchitectureWarnings(params: params, spec: spec, into: &warnings)
    }
    collectAssetIdErrors(params: params, into: &errors)
    collectControlHintPathErrors(params: params, into: &errors)

    // Base64 well-formedness for the optional hint images. Errors instead of
    // throwing so resolve() can report several problems in one round-trip.
    if let s = params.referenceImage, Data(base64Encoded: s) == nil {
      errors.append(
        Diagnostic(
          code: "INVALID_REFERENCE_IMAGE_DATA",
          fieldPath: "reference_image",
          message: "reference_image is not valid base64"))
    }
    if let s = params.depthImage, Data(base64Encoded: s) == nil {
      errors.append(
        Diagnostic(
          code: "INVALID_DEPTH_IMAGE_DATA",
          fieldPath: "depth_image",
          message: "depth_image is not valid base64"))
    }

    // Compute units estimate + applied_defaults / pristine load both depend
    // on the loaded pristine config. Skipped when validation already flagged
    // errors so the caller still gets a useful diagnostic set without paying
    // the model-load cost.
    var ecu: Int? = nil
    var pristine: MediaGenerationPipeline.Configuration? = nil
    var applied: [AppliedDefault] = []
    if errors.isEmpty {
      // pristineConfig + computeEstimatedComputeUnits both load a pipeline —
      // run them under the same gate as the generation routes.
      await withEngineGate {
        if let p = await pristineConfig(for: params.baseModelId) {
          pristine = p
          applied = params.appliedDefaults(from: p)
          ecu = await computeEstimatedComputeUnits(params: params)
        }
      }
    }

    return (pristine, applied, warnings, errors, ecu)
  }

  /// Load (or reuse the cached) pipeline for `model` and return its pristine
  /// `Configuration`. Returns `nil` if the model can't be loaded — callers
  /// fall back to echoing the request as-passed.
  private func pristineConfig(for model: String)
    async -> MediaGenerationPipeline.Configuration?
  {
    return (try? await loadPipeline(forModel: model))?.pristine
  }

  /// ControlNet modifiers whose hint tensor (custom/pose) the public SDK
  /// surface does not transport in v0. Submitting one would silently no-op
  /// engine-side — the principle 6 ("erreurs typées, pas de dégradation
  /// silencieuse") says we refuse outright. See `controlnets-public-surface`
  /// memory.
  private static let noPublicHintPathModifiers: Set<ControlInputTypeAPI> = [
    .pose, .lineart, .normalbae, .seg, .color, .blur, .lowquality, .gray, .custom,
  ]

  /// Throws the first ControlNet entry whose modifier has no public hint
  /// path. Called by the generation routes after `verifyAssetIds`. The
  /// resolve path emits the same condition non-throwing via
  /// `collectControlHintPathErrors`.
  private func verifyControlHintPaths(params: GenerationParams) throws {
    for (i, c) in (params.controlnets ?? []).enumerated() {
      if let modifier = c.inputTypeOverride,
        Self.noPublicHintPathModifiers.contains(modifier)
      {
        throw EngineError.controlnetNoPublicHintPath(
          id: c.modelId, modifier: modifier.rawValue, index: i)
      }
    }
  }

  /// Non-throwing twin of `verifyControlHintPaths` for `/v1/resolve`.
  private func collectControlHintPathErrors(
    params: GenerationParams, into errors: inout [Diagnostic]
  ) {
    for (i, c) in (params.controlnets ?? []).enumerated() {
      if let modifier = c.inputTypeOverride,
        Self.noPublicHintPathModifiers.contains(modifier)
      {
        errors.append(
          Diagnostic(
            code: "CONTROL_HAS_NO_PUBLIC_HINT_PATH",
            fieldPath: "controlnets[\(i)].input_type_override",
            message:
              "ControlNet modifier '\(modifier.rawValue)' requires a hint tensor "
              + "that the public SDK does not expose. Submitting this request to a "
              + "generation endpoint will return 400 with the same code. Use a "
              + "modifier that has a public hint path (depth via depth_image, "
              + "shuffle/reference via reference_image, canny/softedge/mlsd/scribble "
              + "via the primary image)."))
      }
    }
  }

  /// Warnings that don't require loading any engine state.
  private func collectShapeWarnings(
    params: GenerationParams, into warnings: inout [Diagnostic]
  ) {
    // reference_image / depth_image without a matching control entry → user
    // likely expected an effect that won't trigger. We only check the override
    // (the model file may also imply the modifier, but checking that requires
    // ControlNetZoo and is left to a later pass).
    if params.referenceImage != nil {
      let any = (params.controlnets ?? []).contains { $0.inputTypeOverride == .shuffle }
      if !any {
        warnings.append(
          Diagnostic(
            code: "REFERENCE_IMAGE_UNUSED",
            fieldPath: "reference_image",
            message:
              "reference_image supplied but no controlnets[] entry has "
              + "input_type_override='shuffle'. The hint may be silently ignored unless "
              + "the base model has an IP-Adapter pipeline that consumes it implicitly."))
      }
    }
    if params.depthImage != nil {
      let any = (params.controlnets ?? []).contains { $0.inputTypeOverride == .depth }
      if !any {
        warnings.append(
          Diagnostic(
            code: "DEPTH_IMAGE_UNUSED",
            fieldPath: "depth_image",
            message:
              "depth_image supplied but no controlnets[] entry has "
              + "input_type_override='depth'."))
      }
    }
  }

  /// Verifies that every model id referenced by the request is installed
  /// (catalog-known AND downloaded) and architecture-compatible with the base
  /// model. Throws the first failure as a typed EngineError (→ 400). Catalog
  /// alone is not enough: a Specification can exist for a known model that
  /// isn't downloaded yet, and the engine silently skips it
  /// (`LocalImageGenerator.swift:2310-2312`). We fail loud instead.
  private func verifyAssetIds(params: GenerationParams) throws {
    guard let baseSpec = ModelZoo.specificationForModel(params.baseModelId),
      ModelZoo.isModelDownloaded(baseSpec)
    else {
      throw EngineError.baseModelNotInstalled(id: params.baseModelId)
    }
    let baseArch = baseSpec.version.rawValue

    for (i, c) in (params.controlnets ?? []).enumerated() {
      guard let spec = ControlNetZoo.specificationForModel(c.modelId),
        ControlNetZoo.isModelDownloaded(spec)
      else {
        throw EngineError.controlnetNotInstalled(id: c.modelId, index: i)
      }
      let controlArch = spec.version.rawValue
      if controlArch != baseArch {
        throw EngineError.controlnetIncompatible(
          id: c.modelId, baseArch: baseArch, controlArch: controlArch, index: i)
      }
    }

    for (i, l) in (params.loras ?? []).enumerated() {
      guard let spec = LoRAZoo.specificationForModel(l.loraId),
        LoRAZoo.isModelDownloaded(spec)
      else {
        throw EngineError.loraNotInstalled(id: l.loraId, index: i)
      }
      let loraArch = spec.version.rawValue
      if loraArch != baseArch {
        throw EngineError.loraIncompatible(
          id: l.loraId, baseArch: baseArch, loraArch: loraArch, index: i)
      }
    }

    if let upscaler = params.upscaler {
      guard let spec = UpscalerZoo.specificationForModel(upscaler.modelId),
        UpscalerZoo.isModelDownloaded(spec.file)
      else {
        throw EngineError.upscalerNotInstalled(id: upscaler.modelId)
      }
    }
  }

  /// Same as `verifyAssetIds(params:)` but non-throwing — converts every
  /// failure into a `Diagnostic` so `/v1/resolve` can report multiple
  /// problems at once.
  private func collectAssetIdErrors(
    params: GenerationParams, into errors: inout [Diagnostic]
  ) {
    guard let baseSpec = ModelZoo.specificationForModel(params.baseModelId),
      ModelZoo.isModelDownloaded(baseSpec)
    else {
      errors.append(
        Diagnostic(
          code: "MODEL_NOT_INSTALLED",
          fieldPath: "base_model_id",
          message: "no installed base model with id '\(params.baseModelId)'"))
      return
    }
    let baseArch = baseSpec.version.rawValue

    for (i, c) in (params.controlnets ?? []).enumerated() {
      guard let spec = ControlNetZoo.specificationForModel(c.modelId),
        ControlNetZoo.isModelDownloaded(spec)
      else {
        errors.append(
          Diagnostic(
            code: "CONTROLNET_NOT_INSTALLED",
            fieldPath: "controlnets[\(i)].model_id",
            message: "no installed ControlNet with id '\(c.modelId)'"))
        continue
      }
      let controlArch = spec.version.rawValue
      if controlArch != baseArch {
        errors.append(
          Diagnostic(
            code: "CONTROLNET_INCOMPATIBLE_WITH_BASE_MODEL",
            fieldPath: "controlnets[\(i)].model_id",
            message:
              "ControlNet '\(c.modelId)' targets architecture '\(controlArch)' "
              + "but the base model is '\(baseArch)'. The engine silently skips "
              + "version-mismatched controls."))
      }
    }

    for (i, l) in (params.loras ?? []).enumerated() {
      guard let spec = LoRAZoo.specificationForModel(l.loraId),
        LoRAZoo.isModelDownloaded(spec)
      else {
        errors.append(
          Diagnostic(
            code: "LORA_NOT_INSTALLED",
            fieldPath: "loras[\(i)].lora_id",
            message: "no installed LoRA with id '\(l.loraId)'"))
        continue
      }
      let loraArch = spec.version.rawValue
      if loraArch != baseArch {
        errors.append(
          Diagnostic(
            code: "LORA_INCOMPATIBLE_WITH_BASE_MODEL",
            fieldPath: "loras[\(i)].lora_id",
            message:
              "LoRA '\(l.loraId)' targets architecture '\(loraArch)' but the "
              + "base model is '\(baseArch)'."))
      }
    }

    if let upscaler = params.upscaler {
      let installed = UpscalerZoo.specificationForModel(upscaler.modelId)
        .map { UpscalerZoo.isModelDownloaded($0.file) } ?? false
      if !installed {
        errors.append(
          Diagnostic(
            code: "UPSCALER_NOT_INSTALLED",
            fieldPath: "upscaler.model_id",
            message: "no installed upscaler with id '\(upscaler.modelId)'"))
      }
    }
  }

  /// Warnings whose firing depends on the base model's spec.
  private func collectArchitectureWarnings(
    params: GenerationParams, spec: ModelZoo.Specification, into warnings: inout [Diagnostic]
  ) {
    let archRaw = spec.version.rawValue

    if let bs = params.batchSize, bs > 1, batchSizeCappedVersions.contains(archRaw) {
      warnings.append(
        Diagnostic(
          code: "BATCH_SIZE_MAY_CAP",
          fieldPath: "batch_size",
          message:
            "Architecture '\(archRaw)' caps engine-side batch_size to 1; the "
            + "request's batch_size=\(bs) will be honored only via the wrapper's "
            + "batch_count loop. Effective image count may be lower than "
            + "batch_size × batch_count."))
    }

    if params.extensions?.drawThings?.preserveOriginalAfterInpaint == true {
      let modifierRaw = spec.modifier?.rawValue
      if modifierRaw != "inpainting" {
        warnings.append(
          Diagnostic(
            code: "PRESERVE_ORIGINAL_AFTER_INPAINT_IGNORED",
            fieldPath: "extensions.draw_things.preserve_original_after_inpaint",
            message:
              "The flag is only honored by base models whose modifier is "
              + "'inpainting' (typically SD 1.5 / SD 2.x inpaint fine-tunes). The "
              + "selected base model has modifier '\(modifierRaw ?? "none")'; the "
              + "engine ignores the flag and regenerates the whole canvas."))
      }
    }

    if let modifier = spec.modifier, modifier.rawValue != "none" {
      let raw = modifier.rawValue
      let mode = EditingMode(modifier: raw)?.rawValue ?? "other"
      let hint = editingModelHint(raw: raw)
      warnings.append(
        Diagnostic(
          code: "EDITING_MODEL_DETECTED",
          fieldPath: "base_model_id",
          message:
            "Base model has modifier='\(raw)' (editing_mode='\(mode)'). \(hint)"))
    }
  }

  /// Endpoint + input shape guidance for each editing modifier. Tied to
  /// `EditingMode` so an agent who reads `Asset.editing_mode` and the
  /// resolve warning sees the same vocabulary in both places.
  private func editingModelHint(raw: String) -> String {
    switch raw {
    case "inpainting":
      return
        "Inpaint fine-tune (SD 1.5 / 2.x family). Call POST /v1/inpaint with "
        + "a `mask` (non-zero pixels mark the region to regenerate). Using "
        + "/v1/txt2img or /v1/img2img on this model gives non-inpaint output."
    case "depth":
      return
        "Depth-conditioned base model. Provide a depth map via `depth_image` "
        + "(base64, routed to the `.depth` typed input) or via a `controlnets[]` "
        + "entry whose `input_type_override` is `depth`."
    case "canny":
      return
        "Canny-conditioned base model. Provide a canny edge map via the primary "
        + "image input (source_image on /v1/img2img) or via a `controlnets[]` "
        + "entry with `input_type_override='canny'`."
    case "kontext", "kontext_kv":
      return
        "Flux Kontext instruction-edit model. Call POST /v1/edit with the "
        + "image to edit as `image` and the editing instruction as `prompt` "
        + "(e.g. 'remove the text overlay, keep the rest unchanged'). Extra "
        + "reference images go through `reference_image` (base64). /v1/img2img "
        + "is rejected for this model: it would renoise from the source and "
        + "leave the instruction inert."
    case "qwenimage_edit_plus", "qwenimage_edit_2511":
      return
        "Qwen-Image-Edit (instruction-based). Call POST /v1/edit with the "
        + "image to edit as `image` and the editing instruction as `prompt` "
        + "(e.g. 'remove the text overlay'). Multiple reference images "
        + "supported via `reference_image`; the 2511 variant recommends 40 "
        + "steps. /v1/img2img is rejected for this model."
    case "qwenimage_layered":
      return
        "Qwen Image Layered. Single-canvas variant — pass the canvas as "
        + "`source_image` on /v1/img2img. Layer references are not exposed via "
        + "the public SDK in v0."
    case "editing", "double":
      return
        "Legacy editing modifier ('\(raw)'). Refer to the model's note for the "
        + "expected input shape."
    default:
      return
        "Refer to the model card or the SDK source for the expected input shape."
    }
  }

  private func computeEstimatedComputeUnits(params: GenerationParams) async -> Int? {
    guard let prep = try? await prepareConfiguration(for: params) else { return nil }
    let extras = (try? params.extraInputs()) ?? []
    return (try? prep.pipeline.estimatedComputeUnits(inputs: extras)) ?? nil
  }

  private func generateVideo(
    params: GenerationParams,
    video: VideoExtraParams,
    inputs: [MediaGenerationPipeline.Input],
    strengthOverride: Float?,
    runId: String,
    kind: String,
    onProgress: ProgressCallback?
  ) async throws -> VideoGenerationResponse {
    logger.info(
      "\(kind)  model=\(params.baseModelId)  \(params.width)×\(params.height)  steps=\(params.steps.map(String.init) ?? "default")\(promptExcerpt(params.prompt))")
    try verifyAssetIds(params: params)
    try verifyControlHintPaths(params: params)

    let stateHandler: ((MediaGenerationPipeline.State, MediaGenerationPipeline.Preview?) -> Void)? =
      onProgress.map { onProg in
        { state, preview in
          if case .generating(let step, let totalSteps) = state {
            onProg(step, totalSteps, preview.flatMap { encodePNG($0[0]) })
          }
        }
      }

    // batch_count loop here would mean multiple separate videos. For v0,
    // honor batch_count by emitting that many videos with seed-stepping.
    // batch_size is forced to 1 by the engine for video archs.
    let batchCount = params.batchCount ?? 1

    // Engine-touching span under the serialisation gate (see generate()).
    let (videos, pristine, seed, elapsedMs) = try await withEngineGate {
      () -> ([VideoResult], MediaGenerationPipeline.Configuration, UInt32, Int) in
      let start = Date()
      let prep = try await prepareConfiguration(
        for: params, strengthOverride: strengthOverride)
      var pipeline = prep.pipeline
      pipeline.configuration.numFrames = video.numFrames
      pipeline.configuration.fps = video.effectiveFps
      if let motion = video.motion {
        if let m = motion.motionScale { pipeline.configuration.motionScale = m }
        if let g = motion.guidingFrameNoise { pipeline.configuration.guidingFrameNoise = g }
        if let s = motion.startFrameGuidance { pipeline.configuration.startFrameGuidance = s }
      }
      var results: [VideoResult] = []
      for i in 0..<batchCount {
        let currentSeed = prep.seed &+ UInt32(i)
        pipeline.configuration.seed = currentSeed
        let frames = try await pipeline.generate(
          prompt: params.prompt,
          negativePrompt: params.negativePrompt ?? "",
          inputs: inputs,
          stateHandler: stateHandler
        )
        if frames.isEmpty {
          throw EngineError.noImageProduced
        }
        let encoded: Data
        do {
          encoded = try await VideoEncoder.encode(
            frames: frames, fps: video.effectiveFps, format: video.effectiveFormat)
        } catch let e as VideoEncodingError {
          throw EngineError.videoEncoding(e)
        }
        let durationMs = Int(Double(frames.count) / Double(video.effectiveFps) * 1000)
        results.append(
          VideoResult(
            data: encoded.base64EncodedString(),
            format: video.effectiveFormat,
            width: frames[0].width,
            height: frames[0].height,
            numFrames: frames.count,
            fps: video.effectiveFps,
            durationMs: durationMs,
            seed: Int64(currentSeed)
          ))
      }
      return (results, prep.pristine, prep.seed, Int(Date().timeIntervalSince(start) * 1000))
    }

    var warnings: [Diagnostic] = []
    collectShapeWarnings(params: params, into: &warnings)
    if let spec = ModelZoo.specificationForModel(params.baseModelId) {
      collectArchitectureWarnings(params: params, spec: spec, into: &warnings)
    }
    let appliedDefaults = params.appliedDefaults(from: pristine)

    let metadata = RunMetadata(
      runId: runId,
      engineVersion: dhtEngineVersion,
      effectiveSeed: Int64(seed),
      warnings: warnings,
      appliedDefaults: appliedDefaults
    )
    logger.info(
      "\(kind)  → \(videos.count) video(s)  \(elapsedMs)ms  seed=\(seed)\(warningExcerpt(warnings))")
    return VideoGenerationResponse(
      videos: videos, generationTimeMs: elapsedMs, metadata: metadata)
  }

  private func validateStrength(_ strength: Float) throws {
    if strength < 0 || strength > 1 {
      throw ValidationError("denoising_strength must be in [0, 1], got \(strength)")
    }
  }

  private func generate(
    params: GenerationParams,
    inputs: [MediaGenerationPipeline.Input],
    strengthOverride: Float?,
    runId: String,
    kind: String,
    onProgress: ProgressCallback? = nil
  ) async throws -> GenerationResponse {
    logger.info(
      "\(kind)  model=\(params.baseModelId)  \(params.width)×\(params.height)  steps=\(params.steps.map(String.init) ?? "default")\(promptExcerpt(params.prompt))")
    try verifyAssetIds(params: params)
    try verifyControlHintPaths(params: params)

    // Adapt our (step, total, preview) callback into the SDK's
    // (State, Preview?) handler. We forward `.generating(...)` ticks; other
    // engine states (text encoding, decoding, postprocessing) are dropped.
    // The SDK emits a Preview periodically — decode its first CGImage to PNG
    // so the run registry can surface a live preview.
    let stateHandler: ((MediaGenerationPipeline.State, MediaGenerationPipeline.Preview?) -> Void)? =
      onProgress.map { onProg in
        { state, preview in
          if case .generating(let step, let totalSteps) = state {
            onProg(step, totalSteps, preview.flatMap { encodePNG($0[0]) })
          }
        }
      }

    // The SDK's batchSize fans out images within one generate() call, but
    // batchCount is a UI-side multiplier — the local engine does not loop
    // internally. We do it here, advancing the seed by batchSize between
    // batches to match Draw Things' "next batch" seed semantics.
    let batchCount = params.batchCount ?? 1
    let batchSize = params.batchSize ?? 1

    // Model load, config apply and every generate() call run under the
    // serialisation gate — they must not interleave with another request.
    // `start` is taken inside the gate so queue wait is excluded from
    // generationTimeMs; the timer only counts time this request owns the engine.
    let (allResults, pristine, seed, elapsedMs) = try await withEngineGate {
      () -> ([MediaGenerationPipeline.Result], MediaGenerationPipeline.Configuration, UInt32, Int) in
      let start = Date()
      let prep = try await prepareConfiguration(
        for: params, strengthOverride: strengthOverride)
      var pipeline = prep.pipeline
      var results: [MediaGenerationPipeline.Result] = []
      for i in 0..<batchCount {
        pipeline.configuration.seed = prep.seed &+ UInt32(i * batchSize)
        let batch = try await pipeline.generate(
          prompt: params.prompt,
          negativePrompt: params.negativePrompt ?? "",
          inputs: inputs,
          stateHandler: stateHandler
        )
        results.append(contentsOf: batch)
      }
      return (results, prep.pristine, prep.seed, Int(Date().timeIntervalSince(start) * 1000))
    }

    // Collect the same quirk warnings + applied_defaults `/v1/resolve` would
    // have surfaced, so a client that skipped the dry-run still sees them
    // via RunMetadata.
    var warnings: [Diagnostic] = []
    collectShapeWarnings(params: params, into: &warnings)
    if let spec = ModelZoo.specificationForModel(params.baseModelId) {
      collectArchitectureWarnings(params: params, spec: spec, into: &warnings)
    }
    let appliedDefaults = params.appliedDefaults(from: pristine)

    if allResults.isEmpty {
      throw EngineError.noImageProduced
    }
    let outputFormat = params.outputFormat ?? .png
    let images = try allResults.map { result -> String in
      let data = try encodeImage(result: result, format: outputFormat)
      return data.base64EncodedString()
    }
    let metadata = RunMetadata(
      runId: runId,
      engineVersion: dhtEngineVersion,
      effectiveSeed: Int64(seed),
      warnings: warnings,
      appliedDefaults: appliedDefaults
    )
    logger.info(
      "\(kind)  → \(images.count) image(s)  \(elapsedMs)ms  seed=\(seed)\(warningExcerpt(warnings))")
    return GenerationResponse(
      images: images,
      seed: Int64(seed),
      generationTimeMs: elapsedMs,
      metadata: metadata
    )
  }

  /// Loads (or returns the cached) pipeline for `model` paired with its
  /// pristine `Configuration` (the `recommendedTemplate` captured at load
  /// time). Callers use the pristine to reset request-mutated state before
  /// every generate() call — without this snapback, optional API fields
  /// would inherit the previous request's values.
  private func loadPipeline(forModel model: String) async throws -> (
    pipeline: MediaGenerationPipeline,
    pristine: MediaGenerationPipeline.Configuration
  ) {
    if let cached, cached.model == model {
      return (cached.pipeline, cached.pristineConfig)
    }
    cached = nil
    let pipeline = try await MediaGenerationPipeline.fromPretrained(
      model,
      backend: .local(directory: modelsDirectory)
    )
    let pristine = pipeline.configuration
    cached = (model, pipeline, pristine)
    return (pipeline, pristine)
  }

  /// Loads the pipeline for `params.baseModelId`, snaps its configuration
  /// back to the pristine recommendedTemplate, then applies the request
  /// params (and optional strength override). Returns the prepared pipeline
  /// plus the pristine config (for `appliedDefaults` reporting) and the
  /// resolved seed (so callers don't recompute it for `RunMetadata`).
  ///
  /// Single source of truth for the "snapback → apply" pattern — used by
  /// `generate`, `generateVideo`, and `computeEstimatedComputeUnits`. Folds
  /// in the fix from `engine-quirks` memory (pristine snapback) so it can't
  /// drift between call sites.
  private func prepareConfiguration(
    for params: GenerationParams, strengthOverride: Float? = nil
  ) async throws -> (
    pipeline: MediaGenerationPipeline,
    pristine: MediaGenerationPipeline.Configuration,
    seed: UInt32
  ) {
    var (pipeline, pristine) = try await loadPipeline(forModel: params.baseModelId)
    pipeline.configuration = pristine
    let seed = params.effectiveSeed()
    params.apply(to: &pipeline.configuration, seed: seed)
    if let strengthOverride { pipeline.configuration.strength = strengthOverride }
    return (pipeline, pristine, seed)
  }
}

// MARK: - Semantic API adapters

/// Output of `compose` — image or video, decided by the chosen model's
/// `Architecture.domain`. The R3 route layer dispatches on the variant to
/// emit the right Content-Type.
enum ComposeResult: Sendable {
  case image(GenerationResponse)
  case video(VideoGenerationResponse)
}

extension ComposeResult: Encodable {
  /// Encodes the underlying variant's shape — the wire payload is identical
  /// to what `/v1/restore` (image) or the legacy `/v1/*vid` (video) would
  /// have produced. Client distinguishes by the presence of `images` vs
  /// `videos`, same as today.
  func encode(to encoder: Encoder) throws {
    switch self {
    case .image(let r): try r.encode(to: encoder)
    case .video(let r): try r.encode(to: encoder)
    }
  }
}

extension DrawThingsEngine {
  /// `POST /v1/compose` — produce an output. Top-level entry point: no step
  /// outputs in scope. See [[composeImpl]] for the actual logic.
  func compose(
    _ request: ComposeRequest, runId: String, onProgress: ProgressCallback? = nil
  ) async throws -> ComposeResult {
    try await composeImpl(request, runId: runId, stepOutputs: [:], onProgress: onProgress)
  }

  /// Compose with an in-scope pipeline step-output map. Resolves any
  /// `.recipe` / `.ref` in `from` and `guides[].image` to image bytes before
  /// dispatching to the underlying engine path. The sub-recipe execution
  /// happens here — BEFORE we acquire the engine gate via `generate(...)`
  /// — so nested recipes serialize cleanly without deadlocking.
  ///
  /// Dispatches based on `(from, domain)`:
  ///   - `(nil,    .image)` → txt2img path
  ///   - `(.image, .image)` → img2img path (`denoising_strength` from params)
  ///   - `(nil,    .video)` → txt2vid path (`params.video` carries the knobs)
  ///   - `(.image, .video)` → img2vid path (`conditioning_strength` from params)
  fileprivate func composeImpl(
    _ request: ComposeRequest, runId: String,
    stepOutputs: [String: Data], onProgress: ProgressCallback?
  ) async throws -> ComposeResult {
    guard let params = request.params else { throw EngineError.paramsRequired }
    let fromData = try await resolveOptionalFromSource(
      request.from, stepOutputs: stepOutputs, runId: runId, onProgress: onProgress)
    let guideInputs = try await resolveGuideInputs(
      request.guides ?? [], stepOutputs: stepOutputs, runId: runId, onProgress: onProgress)
    let gParams = params.materialize(
      model: request.model, prompt: request.prompt,
      negativePrompt: request.negativePrompt, runId: runId)
    try gParams.validate()

    let dom = try modelDomain(of: request.model)
    switch (fromData, dom) {
    case (nil, .image):
      try CapabilityMap.assertSupported(modelId: request.model, operation: .txt2img)
      let extras = try gParams.extraInputs()
      let out = try await generate(
        params: gParams, inputs: guideInputs + extras, strengthOverride: nil,
        runId: runId, kind: "compose", onProgress: onProgress)
      return .image(out)

    case (let data?, .image):
      try CapabilityMap.assertSupported(modelId: request.model, operation: .img2img)
      let strength = params.denoisingStrength ?? 0.7
      try validateStrength(strength)
      let extras = try gParams.extraInputs()
      let out = try await generate(
        params: gParams,
        inputs: [MediaGenerationPipeline.data(data)] + guideInputs + extras,
        strengthOverride: strength,
        runId: runId, kind: "compose", onProgress: onProgress)
      return .image(out)

    case (nil, .video):
      try CapabilityMap.assertSupported(modelId: request.model, operation: .txt2vid)
      guard let video = params.video else {
        throw EngineError.videoParamsRequired(baseModelId: request.model)
      }
      try video.validate()
      let extras = try gParams.extraInputs()
      let out = try await generateVideo(
        params: gParams, video: video, inputs: guideInputs + extras,
        strengthOverride: nil, runId: runId, kind: "compose", onProgress: onProgress)
      return .video(out)

    case (let data?, .video):
      try CapabilityMap.assertSupported(modelId: request.model, operation: .img2vid)
      guard let video = params.video else {
        throw EngineError.videoParamsRequired(baseModelId: request.model)
      }
      try video.validate()
      if let s = params.conditioningStrength, (s < 0 || s > 1) {
        throw ValidationError("conditioning_strength must be in [0, 1], got \(s)")
      }
      let extras = try gParams.extraInputs()
      let out = try await generateVideo(
        params: gParams, video: video,
        inputs: [MediaGenerationPipeline.data(data)] + guideInputs + extras,
        strengthOverride: params.conditioningStrength,
        runId: runId, kind: "compose", onProgress: onProgress)
      return .video(out)
    }
  }

  /// `POST /v1/edit` — top-level entry. See [[editImpl]] for logic.
  func edit(
    _ request: EditRequest, runId: String, onProgress: ProgressCallback? = nil
  ) async throws -> GenerationResponse {
    try await editImpl(request, runId: runId, stepOutputs: [:], onProgress: onProgress)
  }

  /// Edit with in-scope step outputs. Resolves `from`, `references[].image`
  /// recipes/refs to bytes before invoking the engine. `mask != nil` →
  /// inpaint path; `mask == nil` → instruction-edit path (target as
  /// `.moodboard()`).
  fileprivate func editImpl(
    _ request: EditRequest, runId: String,
    stepOutputs: [String: Data], onProgress: ProgressCallback?
  ) async throws -> GenerationResponse {
    guard let params = request.params else { throw EngineError.paramsRequired }
    let targetData = try await resolveRequiredFromSource(
      request.from, stepOutputs: stepOutputs, runId: runId, onProgress: onProgress)
    var referenceDataList: [Data] = []
    for ref in (request.references ?? []) {
      referenceDataList.append(try await resolveRequiredFromSource(
        ref.image, stepOutputs: stepOutputs, runId: runId, onProgress: onProgress))
    }
    let maskData: Data? = try request.mask.map { mask in
      guard let d = Data(base64Encoded: mask) else { throw EngineError.invalidMaskData }
      return d
    }
    let gParams = params.materialize(
      model: request.model, prompt: request.instruction,
      negativePrompt: nil, runId: runId)
    try gParams.validate()
    try assertCfgCompatibleWithEdit(gParams)

    if let mData = maskData {
      try CapabilityMap.assertSupported(modelId: request.model, operation: .inpaint)
      let strength = params.denoisingStrength ?? 1.0
      try validateStrength(strength)
      let image = MediaGenerationPipeline.data(targetData)
      let mask = MediaGenerationPipeline.data(mData).mask()
      let refs = referenceDataList.map { MediaGenerationPipeline.data($0).moodboard() }
      let extras = try gParams.extraInputs()
      return try await generate(
        params: gParams,
        inputs: [image, mask] + refs + extras,
        strengthOverride: strength,
        runId: runId, kind: "edit", onProgress: onProgress)
    } else {
      try CapabilityMap.assertSupported(modelId: request.model, operation: .edit)
      let target = MediaGenerationPipeline.data(targetData).moodboard()
      let refs = referenceDataList.map { MediaGenerationPipeline.data($0).moodboard() }
      let extras = try gParams.extraInputs()
      return try await generate(
        params: gParams,
        inputs: [target] + refs + extras,
        strengthOverride: nil,
        runId: runId, kind: "edit", onProgress: onProgress)
    }
  }

  /// True when `spec` is a guidance-distilled FLUX edit model that crashes the
  /// engine's cond/uncond concat under an explicit `cfg_scale > 1`. Catches the
  /// FLUX.1 family (catalog sets `guidanceEmbed == true`) *and* FLUX.2
  /// (`flux2_*`, whose catalog entry omits that flag) via the stable `kontext`
  /// modifier marker. Qwen-Image-Edit (non-distilled, real CFG) carries a
  /// different modifier and is intentionally excluded. Single source of truth
  /// for both the generation guard and the `/v1/resolve/edit` prediction so the
  /// two can't drift.
  fileprivate static func isGuidanceDistilledEditModel(_ spec: ModelZoo.Specification) -> Bool {
    if spec.guidanceEmbed == true { return true }
    switch spec.modifier?.rawValue {
    case "kontext", "kontext_kv": return true
    default: return false
    }
  }

  /// Rejects `cfg_scale > 1` on a guidance-distilled FLUX edit model before it
  /// reaches the engine. Such models (Kontext / Klein, FLUX.1 *and* FLUX.2)
  /// have no unconditional branch; an explicit CFG drives a dual cond/uncond
  /// graph whose reference-token sequences are asymmetric and the engine
  /// asserts at `ccv_cnnp_concat_build`. Scope is deliberately narrow (see
  /// [[isGuidanceDistilledEditModel]]), so Qwen-Image-Edit (non-distilled, real
  /// CFG) and plain FLUX dev txt2img are untouched. Only an *explicit* cfg_scale
  /// is checked: the distilled default (≈1) generates fine.
  fileprivate func assertCfgCompatibleWithEdit(_ params: GenerationParams) throws {
    guard let cfg = params.cfgScale, cfg > 1 else { return }
    guard let spec = ModelZoo.specificationForModel(params.baseModelId),
      Self.isGuidanceDistilledEditModel(spec)
    else { return }
    throw EngineError.cfgUnsupportedForDistilledEdit(
      baseModelId: params.baseModelId, cfgScale: cfg)
  }

  /// `POST /v1/restore` — top-level entry. See [[restoreImpl]] for logic.
  func restore(
    _ request: RestoreRequest, runId: String, onProgress: ProgressCallback? = nil
  ) async throws -> GenerationResponse {
    try await restoreImpl(request, runId: runId, stepOutputs: [:], onProgress: onProgress)
  }

  /// Restore with in-scope step outputs.
  fileprivate func restoreImpl(
    _ request: RestoreRequest, runId: String,
    stepOutputs: [String: Data], onProgress: ProgressCallback?
  ) async throws -> GenerationResponse {
    guard let params = request.params else { throw EngineError.paramsRequired }
    let sourceData = try await resolveRequiredFromSource(
      request.from, stepOutputs: stepOutputs, runId: runId, onProgress: onProgress)
    let gParams = params.materialize(
      model: request.model, prompt: "",
      negativePrompt: nil, runId: runId)
    try gParams.validate()
    try CapabilityMap.assertSupported(modelId: request.model, operation: .restore)
    let extras = try gParams.extraInputs()
    return try await generate(
      params: gParams,
      inputs: [MediaGenerationPipeline.data(sourceData)] + extras,
      strengthOverride: nil,
      runId: runId, kind: "restore", onProgress: onProgress)
  }

  // MARK: - Recipe / FromSource resolution (R4)

  /// Resolves an optional `FromSource` to image bytes — `nil` passes through.
  /// `stepOutputs` is the live pipeline step-output map (empty outside pipeline).
  fileprivate func resolveOptionalFromSource(
    _ from: FromSource?, stepOutputs: [String: Data],
    runId: String, onProgress: ProgressCallback?
  ) async throws -> Data? {
    guard let from else { return nil }
    return try await resolveRequiredFromSource(
      from, stepOutputs: stepOutputs, runId: runId, onProgress: onProgress)
  }

  /// Resolves a required `FromSource` to image bytes. Handles all three
  /// cases: `.image(base64)` → decode; `.recipe(r)` → execute r recursively,
  /// pull bytes; `.ref(name)` → look up in `stepOutputs`.
  fileprivate func resolveRequiredFromSource(
    _ from: FromSource, stepOutputs: [String: Data],
    runId: String, onProgress: ProgressCallback?
  ) async throws -> Data {
    switch from {
    case .image(let b64):
      guard let data = Data(base64Encoded: b64) else { throw EngineError.invalidImageData }
      return data
    case .recipe(let r):
      return try await executeRecipeForImageBytes(
        r, stepOutputs: stepOutputs, runId: runId, onProgress: onProgress)
    case .ref(let name):
      guard let bytes = stepOutputs[name] else {
        throw EngineError.pipelineStepNotFound(name: name)
      }
      return bytes
    }
  }

  /// Walks a `guides[]` list, resolving each entry's `image` to bytes and
  /// shaping the pipeline `Input` for the requested `kind`. Order is preserved
  /// so the engine sees guides in the same sequence the caller wrote them.
  /// Mapping: `depth` → `.depth()`, `reference` → `.moodboard()`. Any other
  /// ControlNet task must use the full `controlnets[]` path on `EngineParams`.
  fileprivate func resolveGuideInputs(
    _ guides: [GuideRef], stepOutputs: [String: Data],
    runId: String, onProgress: ProgressCallback?
  ) async throws -> [MediaGenerationPipeline.Input] {
    var out: [MediaGenerationPipeline.Input] = []
    for g in guides {
      let data = try await resolveRequiredFromSource(
        g.image, stepOutputs: stepOutputs, runId: runId, onProgress: onProgress)
      switch g.kind {
      case .depth:
        out.append(MediaGenerationPipeline.data(data).depth())
      case .reference:
        out.append(MediaGenerationPipeline.data(data).moodboard())
      }
    }
    return out
  }

  /// Runs a sub-recipe and extracts the first image byte payload. Used by
  /// `from.recipe` and `guides[].image.recipe` resolution, and by the
  /// pipeline executor for each step. Sub-recipes that produce video raise
  /// `recipeProducedVideoOutput` — bytes-as-image is the only chained shape
  /// in R4.
  fileprivate func executeRecipeForImageBytes(
    _ recipe: Recipe, stepOutputs: [String: Data],
    runId: String, onProgress: ProgressCallback?
  ) async throws -> Data {
    switch recipe {
    case .compose(let req):
      let result = try await composeImpl(
        req, runId: runId, stepOutputs: stepOutputs, onProgress: onProgress)
      switch result {
      case .image(let r): return try Self.firstImageBytes(r)
      case .video: throw EngineError.recipeProducedVideoOutput
      }
    case .edit(let req):
      let r = try await editImpl(
        req, runId: runId, stepOutputs: stepOutputs, onProgress: onProgress)
      return try Self.firstImageBytes(r)
    case .restore(let req):
      let r = try await restoreImpl(
        req, runId: runId, stepOutputs: stepOutputs, onProgress: onProgress)
      return try Self.firstImageBytes(r)
    }
  }

  private static func firstImageBytes(_ response: GenerationResponse) throws -> Data {
    guard let first = response.images.first,
          let data = Data(base64Encoded: first) else {
      throw EngineError.noImageProduced
    }
    return data
  }

  // MARK: - Pipeline (R4)

  /// `POST /v1/pipeline` — execute an ordered chain of recipes. Each step's
  /// output bytes become addressable via `"$<as>"` in later steps' `from`,
  /// `references[].image`, and `guides[].image`. Stateless: no asset persists
  /// between calls; the in-memory step-output map lives only for this
  /// `pipeline(...)` invocation. `return` controls which step outputs come
  /// back (defaults to the last step under the implicit key `"result"`).
  func pipeline(
    _ request: PipelineRequest, runId: String, onProgress: ProgressCallback? = nil
  ) async throws -> PipelineResponse {
    guard !request.steps.isEmpty else { throw EngineError.pipelineEmpty }
    let start = Date()
    var outputs: [String: Data] = [:]
    var lastBytes: Data = Data()
    var lastLabel: String? = nil
    for (i, step) in request.steps.enumerated() {
      let subRunId = "\(runId).step\(i)"
      let bytes = try await executeRecipeForImageBytes(
        step.recipe, stepOutputs: outputs,
        runId: subRunId, onProgress: onProgress)
      if let label = step.as { outputs[label] = bytes }
      lastBytes = bytes
      lastLabel = step.as
    }
    var result: [String: String] = [:]
    if let names = request.return, !names.isEmpty {
      for n in names {
        guard let bytes = outputs[n] else {
          throw EngineError.pipelineReturnUnknownStep(name: n)
        }
        result[n] = bytes.base64EncodedString()
      }
    } else {
      // Implicit: last step under "result" (or its `as` label if it had one,
      // because addressing by its real name is less surprising).
      result[lastLabel ?? "result"] = lastBytes.base64EncodedString()
    }
    let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
    return PipelineResponse(outputs: result, generationTimeMs: elapsedMs)
  }

  /// Catalog + Architecture-mirror lookup for the model's `.image`/`.video`
  /// domain. Throws `baseModelNotInstalled` for the same code the legacy
  /// generate paths emit when the model is not in the catalog.
  fileprivate func modelDomain(of modelId: String) throws -> Domain {
    guard let spec = ModelZoo.specificationForModel(modelId),
          let arch = Architecture(rawValue: spec.version.rawValue) else {
      throw EngineError.baseModelNotInstalled(id: modelId)
    }
    return arch.domain
  }

  /// `POST /v1/resolve/compose` — dry-run the compose verb. Materializes the
  /// body, runs the shared diagnostics, then replays the request with engine
  /// defaults folded into `params` so the caller gets a verb-shaped
  /// `resolved_request` re-postable to `/v1/compose`. A missing `params` block
  /// surfaces as a `PARAMS_REQUIRED` diagnostic rather than throwing —
  /// resolve never throws.
  func resolveCompose(_ request: ComposeRequest) async -> ResolveResponse {
    guard let p = request.params else { return Self.paramsRequiredResolveResponse }
    let g = p.materialize(
      model: request.model, prompt: request.prompt,
      negativePrompt: request.negativePrompt, runId: request.runId)
    let d = await resolveDiagnostics(g)
    let resolvedParams = d.pristine.map { p.withDefaults(from: $0) } ?? p
    let resolved = ComposeRequest(
      model: request.model, prompt: request.prompt,
      negativePrompt: request.negativePrompt,
      from: request.from, guides: request.guides,
      params: resolvedParams, runId: request.runId)
    return ResolveResponse(
      resolvedRequest: .compose(resolved),
      appliedDefaults: d.appliedDefaults,
      warnings: d.warnings, errors: d.errors,
      estimatedComputeUnits: d.ecu)
  }

  /// `POST /v1/resolve/edit` — dry-run the edit verb. The `instruction`
  /// becomes the prompt in the materialized params, matching what the
  /// generation path does.
  func resolveEdit(_ request: EditRequest) async -> ResolveResponse {
    guard let p = request.params else { return Self.paramsRequiredResolveResponse }
    let g = p.materialize(
      model: request.model, prompt: request.instruction,
      negativePrompt: nil, runId: request.runId)
    let d = await resolveDiagnostics(g)
    // Predict the same rejection the generation path raises: cfg_scale > 1 on a
    // guidance-distilled FLUX edit model crashes the engine's cond/uncond concat.
    var errors = d.errors
    if let cfg = g.cfgScale, cfg > 1,
      let spec = ModelZoo.specificationForModel(request.model),
      Self.isGuidanceDistilledEditModel(spec)
    {
      errors.append(
        Diagnostic(
          code: "CFG_SCALE_UNSUPPORTED_FOR_DISTILLED_EDIT",
          fieldPath: "params.cfg_scale",
          message:
            "base_model_id '\(request.model)' is a guidance-distilled FLUX edit "
            + "model; cfg_scale=\(cfg) would crash the engine's cond/uncond "
            + "concat. Omit cfg_scale (or set it to 1) and use "
            + "extensions.draw_things.guidance_embed to steer adherence."))
    }
    let resolvedParams = d.pristine.map { p.withDefaults(from: $0) } ?? p
    let resolved = EditRequest(
      model: request.model, from: request.from,
      instruction: request.instruction, mask: request.mask,
      references: request.references,
      params: resolvedParams, runId: request.runId)
    return ResolveResponse(
      resolvedRequest: .edit(resolved),
      appliedDefaults: d.appliedDefaults,
      warnings: d.warnings, errors: errors,
      estimatedComputeUnits: d.ecu)
  }

  /// `POST /v1/resolve/restore` — dry-run the restore verb. Empty prompt
  /// (restore is preserve-and-enhance, no creative guidance).
  func resolveRestore(_ request: RestoreRequest) async -> ResolveResponse {
    guard let p = request.params else { return Self.paramsRequiredResolveResponse }
    let g = p.materialize(
      model: request.model, prompt: "",
      negativePrompt: nil, runId: request.runId)
    let d = await resolveDiagnostics(g)
    let resolvedParams = d.pristine.map { p.withDefaults(from: $0) } ?? p
    let resolved = RestoreRequest(
      model: request.model, from: request.from,
      params: resolvedParams, runId: request.runId)
    return ResolveResponse(
      resolvedRequest: .restore(resolved),
      appliedDefaults: d.appliedDefaults,
      warnings: d.warnings, errors: d.errors,
      estimatedComputeUnits: d.ecu)
  }

  /// Shared response shape when a resolve verb receives a body with no
  /// `params` block — the diagnostic spans every verb identically.
  fileprivate static var paramsRequiredResolveResponse: ResolveResponse {
    ResolveResponse(
      resolvedRequest: nil,
      appliedDefaults: [],
      warnings: [],
      errors: [Diagnostic(
        code: "PARAMS_REQUIRED",
        fieldPath: "params",
        message:
          "Semantic-API request bodies require a `params` object carrying "
          + "engine knobs (at minimum width / height / steps).")],
      estimatedComputeUnits: nil)
  }
}

enum EngineError: Error {
  case noImageProduced
  case pngEncodingFailed
  case invalidImageData
  case invalidMaskData
  case invalidReferenceImage
  case invalidDepthImage
  case baseModelNotInstalled(id: String)
  case controlnetNotInstalled(id: String, index: Int)
  case controlnetIncompatible(id: String, baseArch: String, controlArch: String, index: Int)
  case loraNotInstalled(id: String, index: Int)
  case loraIncompatible(id: String, baseArch: String, loraArch: String, index: Int)
  /// ControlNet whose modifier requires a hint tensor the public SDK does
  /// not expose (pose/lineart/normalbae/seg/color/blur/lowquality/gray/custom).
  /// The engine would silently no-op the control. We fail loud.
  case controlnetNoPublicHintPath(id: String, modifier: String, index: Int)
  case upscalerNotInstalled(id: String)
  /// Image route invoked with a video base model, or video route invoked
  /// with an image base model. The engine would silently degenerate
  /// (txt2img on Wan/Hunyuan/SVD produces a single frame; txt2vid on SDXL
  /// produces a single image). We fail loud instead.
  case domainMismatch(baseModelId: String, baseDomain: String, requestedDomain: String)
  /// `/v1/img2img` invoked with an instruction-edit base model. The source
  /// would occupy the primary image slot and the engine would renoise from
  /// it at `strength`, leaving the edit instruction inert. Use `/v1/edit`.
  case editingModelRequiresEditEndpoint(baseModelId: String)
  /// `/v1/edit` invoked with a model that is not an instruction-edit model.
  /// `/v1/edit` only drives Flux Kontext / Qwen-Image-Edit base models.
  case notAnInstructionEditModel(baseModelId: String, editingMode: String?)
  /// `/v1/edit` with `cfg_scale > 1` on a guidance-distilled FLUX edit model
  /// (Kontext / Klein). These models bake guidance in (`guidance_embed`) and
  /// have no unconditional branch; an explicit CFG makes the engine build a
  /// dual cond/uncond graph whose reference-token sequences are asymmetric,
  /// tripping the `ccv_cnnp_concat_build` shape assertion. We reject up front.
  case cfgUnsupportedForDistilledEdit(baseModelId: String, cfgScale: Float)
  /// The model's `(behavior_class, modifier)` cell exists in the capability
  /// map but does not list the requested operation. e.g. `/v1/txt2img` on a
  /// `.canny` base model — that model supports only `.img2img` (source_image
  /// is the canny edge map). Read `GET /v1/capabilities/{model_id}` to know
  /// which operations are supported.
  case operationNotSupportedForModel(
    baseModelId: String, operation: String, supportedOperations: [String])
  case videoEncoding(VideoEncodingError)
  /// `from: "$name"` referenced a step that doesn't exist in the current
  /// scope: either the verb wasn't invoked inside `/v1/pipeline` at all
  /// (no step map), or the named step hasn't run yet / has no `as` label.
  case pipelineStepNotFound(name: String)
  /// A sub-recipe in `from` / `references[].image` / `guides[].image`
  /// resolved to a video output. Pipelines + recipes only chain bytes that
  /// the downstream engine can consume as image inputs; video outputs would
  /// need explicit frame extraction we don't expose yet.
  case recipeProducedVideoOutput
  /// `POST /v1/pipeline` body has no steps.
  case pipelineEmpty
  /// `POST /v1/pipeline` `return` named a step that has no `as` label (or
  /// no step at all). The implicit `"result"` is reserved for the last
  /// step's output when `return` is omitted.
  case pipelineReturnUnknownStep(name: String)
  /// Compose targeting a video model requires the video knobs sub-object
  /// (`params.video` carrying `num_frames`, optional `fps` / `video_format`
  /// / `motion`). Image models do not consume `params.video`.
  case videoParamsRequired(baseModelId: String)
  /// `params` block missing from a semantic-API request body. Width / height
  /// / steps live there; the engine cannot proceed without them.
  case paramsRequired
}
