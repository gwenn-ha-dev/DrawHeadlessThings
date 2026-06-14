import Foundation
import UniformTypeIdentifiers
import _MediaGenerationKit

// MARK: - Public-API enums (rawValue is the JSON string)

enum SeedModeAPI: String, Codable, Sendable {
  case legacy
  case torchCpuCompatible = "torch_cpu_compatible"
  case scaleAlike = "scale_alike"
  case nvidiaGpuCompatible = "nvidia_gpu_compatible"

  var sdk: SeedMode {
    switch self {
    case .legacy: return .legacy
    case .torchCpuCompatible: return .torchCpuCompatible
    case .scaleAlike: return .scaleAlike
    case .nvidiaGpuCompatible: return .nvidiaGpuCompatible
    }
  }

  init(_ sdk: SeedMode) {
    switch sdk {
    case .legacy: self = .legacy
    case .torchCpuCompatible: self = .torchCpuCompatible
    case .scaleAlike: self = .scaleAlike
    case .nvidiaGpuCompatible: self = .nvidiaGpuCompatible
    }
  }
}

enum SamplerAPI: String, Codable, Sendable {
  case dpmpp2mKarras = "dpmpp_2m_karras"
  case eulerA = "euler_a"
  case ddim
  case plms
  case dpmppSdeKarras = "dpmpp_sde_karras"
  case unipc
  case lcm
  case eulerASubstep = "euler_a_substep"
  case dpmppSdeSubstep = "dpmpp_sde_substep"
  case tcd
  case eulerATrailing = "euler_a_trailing"
  case dpmppSdeTrailing = "dpmpp_sde_trailing"
  case dpmpp2mAys = "dpmpp_2m_ays"
  case eulerAAys = "euler_a_ays"
  case dpmppSdeAys = "dpmpp_sde_ays"
  case dpmpp2mTrailing = "dpmpp_2m_trailing"
  case ddimTrailing = "ddim_trailing"
  case unipcTrailing = "unipc_trailing"
  case unipcAys = "unipc_ays"
  case tcdTrailing = "tcd_trailing"

  var sdk: SamplerType {
    switch self {
    case .dpmpp2mKarras: return .dPMPP2MKarras
    case .eulerA: return .eulerA
    case .ddim: return .DDIM
    case .plms: return .PLMS
    case .dpmppSdeKarras: return .dPMPPSDEKarras
    case .unipc: return .uniPC
    case .lcm: return .LCM
    case .eulerASubstep: return .eulerASubstep
    case .dpmppSdeSubstep: return .dPMPPSDESubstep
    case .tcd: return .TCD
    case .eulerATrailing: return .eulerATrailing
    case .dpmppSdeTrailing: return .dPMPPSDETrailing
    case .dpmpp2mAys: return .DPMPP2MAYS
    case .eulerAAys: return .eulerAAYS
    case .dpmppSdeAys: return .DPMPPSDEAYS
    case .dpmpp2mTrailing: return .dPMPP2MTrailing
    case .ddimTrailing: return .dDIMTrailing
    case .unipcTrailing: return .uniPCTrailing
    case .unipcAys: return .uniPCAYS
    case .tcdTrailing: return .tCDTrailing
    }
  }

  init(_ sdk: SamplerType) {
    switch sdk {
    case .dPMPP2MKarras: self = .dpmpp2mKarras
    case .eulerA: self = .eulerA
    case .DDIM: self = .ddim
    case .PLMS: self = .plms
    case .dPMPPSDEKarras: self = .dpmppSdeKarras
    case .uniPC: self = .unipc
    case .LCM: self = .lcm
    case .eulerASubstep: self = .eulerASubstep
    case .dPMPPSDESubstep: self = .dpmppSdeSubstep
    case .TCD: self = .tcd
    case .eulerATrailing: self = .eulerATrailing
    case .dPMPPSDETrailing: self = .dpmppSdeTrailing
    case .DPMPP2MAYS: self = .dpmpp2mAys
    case .eulerAAYS: self = .eulerAAys
    case .DPMPPSDEAYS: self = .dpmppSdeAys
    case .dPMPP2MTrailing: self = .dpmpp2mTrailing
    case .dDIMTrailing: self = .ddimTrailing
    case .uniPCTrailing: self = .unipcTrailing
    case .uniPCAYS: self = .unipcAys
    case .tCDTrailing: self = .tcdTrailing
    @unknown default: self = .eulerA
    }
  }
}

enum OutputFormat: String, Codable, Sendable {
  case png
  case jpeg

  var utType: UTType {
    switch self {
    case .png: return .png
    case .jpeg: return .jpeg
    }
  }
}

/// Video container/codec choices supported by `/v1/txt2vid` and `/v1/img2vid`.
/// Both go through AVAssetWriter with `.mp4` file type; the codec differs.
/// Other formats (webm/vp9, gif, frame_sequence) are deferred — webm needs a
/// non-AVFoundation encoder, gif is low-utility for agents, frame_sequence
/// can be emulated client-side by extracting frames from the mp4.
enum VideoFormatAPI: String, Codable, Sendable {
  case mp4H264 = "mp4_h264"
  case mp4Hevc = "mp4_hevc"
}

// MARK: - References

struct LoRARef: Codable, Sendable {
  let loraId: String
  let weight: Float

  enum CodingKeys: String, CodingKey {
    case loraId = "lora_id"
    case weight
  }
}

// MARK: - Generic sub-objects (layer 2)

struct HiresFixParams: Codable, Sendable {
  let enabled: Bool
  let firstPassWidth: Int?
  let firstPassHeight: Int?
  let strength: Float?

  enum CodingKeys: String, CodingKey {
    case enabled
    case firstPassWidth = "first_pass_width"
    case firstPassHeight = "first_pass_height"
    case strength
  }
}

struct RefinerParams: Codable, Sendable {
  let modelId: String
  let start: Float?

  enum CodingKeys: String, CodingKey {
    case modelId = "model_id"
    case start
  }
}

/// Post-diffusion upscaler chain. The selected upscaler asset is run on
/// the diffusion output before encoding. `scale_factor` is engine-side
/// (typically 2 or 4 depending on the upscaler weights); engine default
/// preserved when omitted.
struct UpscalerParams: Codable, Sendable {
  let modelId: String
  let scaleFactor: Int?

  enum CodingKeys: String, CodingKey {
    case modelId = "model_id"
    case scaleFactor = "scale_factor"
  }
}

struct TileSetParams: Codable, Sendable {
  let enabled: Bool
  let tileWidth: Int?
  let tileHeight: Int?
  let overlap: Int?

  enum CodingKeys: String, CodingKey {
    case enabled
    case tileWidth = "tile_width"
    case tileHeight = "tile_height"
    case overlap
  }
}

struct TilingParams: Codable, Sendable {
  let decoding: TileSetParams?
  let diffusion: TileSetParams?
}

struct FlowMatchParams: Codable, Sendable {
  let shift: Float?
  let resolutionDependentShift: Bool?

  enum CodingKeys: String, CodingKey {
    case shift
    case resolutionDependentShift = "resolution_dependent_shift"
  }
}

/// SDXL-family micro-conditioning. All fields optional; engine defaults preserved when omitted.
struct SDXLConditioningParams: Codable, Sendable {
  let originalWidth: Int?
  let originalHeight: Int?
  let cropTop: Int?
  let cropLeft: Int?
  let targetWidth: Int?
  let targetHeight: Int?
  let negativeOriginalWidth: Int?
  let negativeOriginalHeight: Int?
  let aestheticScore: Float?
  let negativeAestheticScore: Float?
  let zeroNegativePrompt: Bool?

  enum CodingKeys: String, CodingKey {
    case originalWidth = "original_width"
    case originalHeight = "original_height"
    case cropTop = "crop_top"
    case cropLeft = "crop_left"
    case targetWidth = "target_width"
    case targetHeight = "target_height"
    case negativeOriginalWidth = "negative_original_width"
    case negativeOriginalHeight = "negative_original_height"
    case aestheticScore = "aesthetic_score"
    case negativeAestheticScore = "negative_aesthetic_score"
    case zeroNegativePrompt = "zero_negative_prompt"
  }
}

struct SeparatePromptParams: Codable, Sendable {
  let enabled: Bool
  let text: String?
}

/// Text-encoder fan-out for multi-encoder architectures (SDXL CLIP-L/G, T5).
struct TextEncodersParams: Codable, Sendable {
  let t5Decoding: Bool?
  let separateClipL: SeparatePromptParams?
  let separateOpenClipG: SeparatePromptParams?
  let separateT5: SeparatePromptParams?

  enum CodingKeys: String, CodingKey {
    case t5Decoding = "t5_decoding"
    case separateClipL = "separate_clip_l"
    case separateOpenClipG = "separate_open_clip_g"
    case separateT5 = "separate_t5"
  }
}

/// Würstchen / Stable Cascade two-stage settings.
struct CascadeParams: Codable, Sendable {
  let stage2Steps: Int?
  let stage2Guidance: Float?
  let stage2Shift: Float?

  enum CodingKeys: String, CodingKey {
    case stage2Steps = "stage2_steps"
    case stage2Guidance = "stage2_guidance"
    case stage2Shift = "stage2_shift"
  }
}

/// Kandinsky-style image prior step settings.
struct ImagePriorParams: Codable, Sendable {
  let steps: Int?
  let negativePromptEnabled: Bool?
  let clipWeight: Float?

  enum CodingKeys: String, CodingKey {
    case steps
    case negativePromptEnabled = "negative_prompt_enabled"
    case clipWeight = "clip_weight"
  }
}

// MARK: - Engine-specific extensions (layer 3)

struct TeaCacheParams: Codable, Sendable {
  let enabled: Bool
  let start: Int?
  let end: Int?
  let threshold: Float?
  let maxSkipSteps: Int?

  enum CodingKeys: String, CodingKey {
    case enabled, start, end, threshold
    case maxSkipSteps = "max_skip_steps"
  }
}

struct CausalInferenceParams: Codable, Sendable {
  let length: Int?
  let pad: Int?
}

struct CfgZeroStarParams: Codable, Sendable {
  let enabled: Bool
  let initSteps: Int?

  enum CodingKeys: String, CodingKey {
    case enabled
    case initSteps = "init_steps"
  }
}

struct GuidanceEmbedParams: Codable, Sendable {
  let enabled: Bool
  let value: Float?
}

enum CompressionMethodAPI: String, Codable, Sendable {
  case disabled
  case h264
  case h265
  case jpeg

  var sdk: CompressionMethod {
    switch self {
    case .disabled: return .disabled
    case .h264: return .H264
    case .h265: return .H265
    case .jpeg: return .jpeg
    }
  }
}

enum ControlModeAPI: String, Codable, Sendable {
  case balanced
  case prompt
  case control

  var sdk: ControlMode {
    switch self {
    case .balanced: return .balanced
    case .prompt: return .prompt
    case .control: return .control
    }
  }
}

enum ControlInputTypeAPI: String, Codable, Sendable {
  case unspecified
  case custom
  case depth
  case canny
  case scribble
  case pose
  case normalbae
  case color
  case lineart
  case softedge
  case seg
  case inpaint
  case ip2p
  case shuffle
  case mlsd
  case tile
  case blur
  case lowquality
  case gray

  var sdk: ControlInputType {
    switch self {
    case .unspecified: return .unspecified
    case .custom: return .custom
    case .depth: return .depth
    case .canny: return .canny
    case .scribble: return .scribble
    case .pose: return .pose
    case .normalbae: return .normalbae
    case .color: return .color
    case .lineart: return .lineart
    case .softedge: return .softedge
    case .seg: return .seg
    case .inpaint: return .inpaint
    case .ip2p: return .ip2p
    case .shuffle: return .shuffle
    case .mlsd: return .mlsd
    case .tile: return .tile
    case .blur: return .blur
    case .lowquality: return .lowquality
    case .gray: return .gray
    }
  }
}

/// Public-API ControlNet entry. Maps 1:1 to a `Configuration.Control` entry.
///
/// IMPORTANT: hint images live OUTSIDE this struct. See
/// `GenerationParams.referenceImage` and `.depthImage`, plus the request's
/// source image for img2img/inpaint. The public SDK surface only transports
/// image / mask / moodboard / depth hint roles — see
/// `controlnets-public-surface` memory. ControlNets whose modifier is
/// `pose / lineart / normalbae / seg / tile / recolor / ip2p` have no public
/// hint path in v0 and will silently no-op engine-side.
struct ControlNetRef: Codable, Sendable {
  let modelId: String
  let weight: Float?
  let guidanceStart: Float?
  let guidanceEnd: Float?
  let controlMode: ControlModeAPI?
  let inputTypeOverride: ControlInputTypeAPI?
  let noPrompt: Bool?
  let globalAveragePooling: Bool?
  let downSamplingRate: Float?
  let targetBlocks: [String]?

  enum CodingKeys: String, CodingKey {
    case modelId = "model_id"
    case weight
    case guidanceStart = "guidance_start"
    case guidanceEnd = "guidance_end"
    case controlMode = "control_mode"
    case inputTypeOverride = "input_type_override"
    case noPrompt = "no_prompt"
    case globalAveragePooling = "global_average_pooling"
    case downSamplingRate = "down_sampling_rate"
    case targetBlocks = "target_blocks"
  }

  var sdkControl: Control {
    Control(
      file: modelId,
      weight: weight,
      guidanceStart: guidanceStart,
      guidanceEnd: guidanceEnd,
      noPrompt: noPrompt,
      globalAveragePooling: globalAveragePooling,
      downSamplingRate: downSamplingRate,
      controlMode: controlMode?.sdk,
      targetBlocks: targetBlocks,
      inputOverride: inputTypeOverride?.sdk
    )
  }
}

struct CompressionArtifactsParams: Codable, Sendable {
  let method: CompressionMethodAPI
  let quality: Float?
}

struct FaceRestorationParams: Codable, Sendable {
  let modelId: String

  enum CodingKeys: String, CodingKey {
    case modelId = "model_id"
  }
}

struct DrawThingsExtensions: Codable, Sendable {
  let preserveOriginalAfterInpaint: Bool?
  let teaCache: TeaCacheParams?
  let causalInference: CausalInferenceParams?
  let cfgZeroStar: CfgZeroStarParams?
  let guidanceEmbed: GuidanceEmbedParams?
  let stochasticSamplingGamma: Float?
  let imageGuidanceScale: Float?
  let compressionArtifacts: CompressionArtifactsParams?
  let faceRestoration: FaceRestorationParams?
  let maskBlur: Float?
  let maskBlurOutset: Int?

  enum CodingKeys: String, CodingKey {
    case preserveOriginalAfterInpaint = "preserve_original_after_inpaint"
    case teaCache = "tea_cache"
    case causalInference = "causal_inference"
    case cfgZeroStar = "cfg_zero_star"
    case guidanceEmbed = "guidance_embed"
    case stochasticSamplingGamma = "stochastic_sampling_gamma"
    case imageGuidanceScale = "image_guidance_scale"
    case compressionArtifacts = "compression_artifacts"
    case faceRestoration = "face_restoration"
    case maskBlur = "mask_blur"
    case maskBlurOutset = "mask_blur_outset"
  }
}

struct Extensions: Codable, Sendable {
  let drawThings: DrawThingsExtensions?

  enum CodingKeys: String, CodingKey {
    case drawThings = "draw_things"
  }
}

// MARK: - GenerationParams (3-layer request body)

/// Common params for any image-generation endpoint. Three layers:
/// 1. Core flat fields.
/// 2. Thematic sub-objects at root (`loras`, `hires_fix`, `refiner`, …) — generic, would survive
///    a swap of the underlying engine.
/// 3. `extensions.draw_things.*` — strictly engine-specific knobs that wouldn't exist if we
///    plugged Comfy or A1111 behind this API.
///
/// All optional fields keep the engine-recommended default for the chosen base model when absent.
struct GenerationParams: Codable, Sendable {
  // Layer 1 — Core flat
  let prompt: String
  let negativePrompt: String?
  let baseModelId: String
  let width: Int
  let height: Int
  /// `nil` requests the chosen model's default step count (filled from the
  /// pristine config at apply/resolve time), mirroring `cfgScale`.
  let steps: Int?
  let cfgScale: Float?
  let seed: Int64?
  let seedMode: SeedModeAPI?
  let sampler: SamplerAPI?
  let clipSkip: Int?
  let outputFormat: OutputFormat?
  let batchSize: Int?
  let batchCount: Int?
  /// Optional client-supplied run identifier. When present, lets the client
  /// cancel the run via `DELETE /v1/runs/{run_id}` without having to wait
  /// for the response to learn the id. When absent, the server generates a
  /// fresh UUID. The resolved id is always echoed in `RunMetadata.run_id`.
  let runId: String?

  // Layer 2 — Generic sub-objects. All optional.
  let loras: [LoRARef]?
  let controlnets: [ControlNetRef]?
  let referenceImage: String?  // base64; routed to a `.moodboard()` typed input
  let depthImage: String?      // base64; routed to a `.depth()` typed input
  let hiresFix: HiresFixParams?
  let refiner: RefinerParams?
  let upscaler: UpscalerParams?
  let tiling: TilingParams?
  let flowMatch: FlowMatchParams?
  let sdxlConditioning: SDXLConditioningParams?
  let textEncoders: TextEncodersParams?
  let cascade: CascadeParams?
  let imagePrior: ImagePriorParams?
  let sharpness: Float?

  // Layer 3 — Engine-specific
  let extensions: Extensions?

  enum CodingKeys: String, CodingKey {
    case prompt
    case negativePrompt = "negative_prompt"
    case baseModelId = "base_model_id"
    case width, height, steps
    case cfgScale = "cfg_scale"
    case seed
    case seedMode = "seed_mode"
    case sampler
    case clipSkip = "clip_skip"
    case outputFormat = "output_format"
    case batchSize = "batch_size"
    case batchCount = "batch_count"
    case runId = "run_id"
    case loras
    case controlnets
    case referenceImage = "reference_image"
    case depthImage = "depth_image"
    case hiresFix = "hires_fix"
    case refiner
    case upscaler
    case tiling
    case flowMatch = "flow_match"
    case sdxlConditioning = "sdxl_conditioning"
    case textEncoders = "text_encoders"
    case cascade
    case imagePrior = "image_prior"
    case sharpness
    case extensions
  }

  /// Validates the request body before touching the engine. Throws a
  /// TypedError(VALIDATION_FAILED) with a structured detail when a field is
  /// out of range. Keeps the engine from producing a confusing crash deep in
  /// the diffusion stack on invalid input.
  func validate() throws {
    // Engine enforces multiples of 64 (cf MediaGenerationPipeline.runtimeConfiguration).
    if width < 64 || width > 4096 || width % 64 != 0 {
      throw ValidationError("width must be a multiple of 64 in [64, 4096], got \(width)")
    }
    if height < 64 || height > 4096 || height % 64 != 0 {
      throw ValidationError("height must be a multiple of 64 in [64, 4096], got \(height)")
    }
    if let steps, steps < 1 || steps > 200 {
      throw ValidationError("steps must be in [1, 200], got \(steps)")
    }
    if let cfgScale, (cfgScale <= 0 || cfgScale > 30) {
      throw ValidationError("cfg_scale must be in (0, 30], got \(cfgScale)")
    }
    if let clipSkip, (clipSkip < 1 || clipSkip > 12) {
      throw ValidationError("clip_skip must be in [1, 12], got \(clipSkip)")
    }
    if let batchSize, (batchSize < 1 || batchSize > 8) {
      throw ValidationError("batch_size must be in [1, 8], got \(batchSize)")
    }
    if let batchCount, (batchCount < 1 || batchCount > 16) {
      throw ValidationError("batch_count must be in [1, 16], got \(batchCount)")
    }
    if let upscaler {
      if upscaler.modelId.isEmpty {
        throw ValidationError("upscaler.model_id must not be empty")
      }
      if let s = upscaler.scaleFactor, (s < 2 || s > 8) {
        throw ValidationError("upscaler.scale_factor must be in [2, 8], got \(s)")
      }
    }
    if let controlnets {
      for (i, c) in controlnets.enumerated() {
        if c.modelId.isEmpty {
          throw ValidationError("controlnets[\(i)].model_id must not be empty")
        }
        if let w = c.weight, (!w.isFinite || w < 0 || w > 10) {
          throw ValidationError(
            "controlnets[\(i)].weight must be finite in [0, 10], got \(w)")
        }
        if let s = c.guidanceStart, (!s.isFinite || s < 0 || s > 1) {
          throw ValidationError(
            "controlnets[\(i)].guidance_start must be in [0, 1], got \(s)")
        }
        if let e = c.guidanceEnd, (!e.isFinite || e < 0 || e > 1) {
          throw ValidationError(
            "controlnets[\(i)].guidance_end must be in [0, 1], got \(e)")
        }
        if let s = c.guidanceStart, let e = c.guidanceEnd, s > e {
          throw ValidationError(
            "controlnets[\(i)].guidance_start (\(s)) must be ≤ guidance_end (\(e))")
        }
        if let d = c.downSamplingRate, (!d.isFinite || d < 1 || d > 16) {
          throw ValidationError(
            "controlnets[\(i)].down_sampling_rate must be in [1, 16], got \(d)")
        }
      }
    }
  }

  /// Returns a copy with Core optional fields filled in from the pristine
  /// engine config for the chosen base model. Sub-objects (loras,
  /// controlnets, hires_fix, …) are opt-in features and are NOT auto-filled
  /// — they appear unchanged. Seed stays as-passed: `nil` / `-1` is a request
  /// for randomization that gets resolved at generate-time, not here.
  func withDefaults(from pristine: MediaGenerationPipeline.Configuration) -> GenerationParams {
    GenerationParams(
      prompt: prompt,
      negativePrompt: negativePrompt ?? "",
      baseModelId: baseModelId,
      width: width,
      height: height,
      steps: steps ?? pristine.steps,
      cfgScale: cfgScale ?? pristine.guidanceScale,
      seed: seed,
      seedMode: seedMode ?? SeedModeAPI(pristine.seedMode),
      sampler: sampler ?? SamplerAPI(pristine.sampler),
      clipSkip: clipSkip ?? pristine.clipSkip,
      outputFormat: outputFormat ?? .png,
      batchSize: batchSize ?? pristine.batchSize,
      batchCount: batchCount ?? pristine.batchCount,
      runId: runId,
      loras: loras,
      controlnets: controlnets,
      referenceImage: referenceImage,
      depthImage: depthImage,
      hiresFix: hiresFix,
      refiner: refiner,
      upscaler: upscaler,
      tiling: tiling,
      flowMatch: flowMatch,
      sdxlConditioning: sdxlConditioning,
      textEncoders: textEncoders,
      cascade: cascade,
      imagePrior: imagePrior,
      sharpness: sharpness,
      extensions: extensions
    )
  }

  /// Lists the Core fields the engine had to default because the request
  /// didn't carry them. Mirror of `withDefaults(from:)` but emits structured
  /// records instead of returning a new struct. Only engine-derived defaults
  /// are reported — `negative_prompt = ""` and `output_format = png` are
  /// wrapper-side fall-backs and skipped here.
  func appliedDefaults(from pristine: MediaGenerationPipeline.Configuration) -> [AppliedDefault] {
    var out: [AppliedDefault] = []
    if steps == nil {
      out.append(.init(fieldPath: "steps", value: .int(Int64(pristine.steps))))
    }
    if cfgScale == nil {
      out.append(.init(fieldPath: "cfg_scale", value: .double(Double(pristine.guidanceScale))))
    }
    if seedMode == nil {
      out.append(
        .init(fieldPath: "seed_mode", value: .string(SeedModeAPI(pristine.seedMode).rawValue)))
    }
    if sampler == nil {
      out.append(
        .init(fieldPath: "sampler", value: .string(SamplerAPI(pristine.sampler).rawValue)))
    }
    if clipSkip == nil {
      out.append(.init(fieldPath: "clip_skip", value: .int(Int64(pristine.clipSkip))))
    }
    if batchSize == nil {
      out.append(.init(fieldPath: "batch_size", value: .int(Int64(pristine.batchSize))))
    }
    if batchCount == nil {
      out.append(.init(fieldPath: "batch_count", value: .int(Int64(pristine.batchCount))))
    }
    return out
  }

  /// Decodes optional `reference_image` / `depth_image` base64 strings into typed
  /// `MediaGenerationPipeline.Input`s. Throws typed `EngineError` (→ 400) on bad
  /// base64, mirroring `INVALID_IMAGE_DATA` / `INVALID_MASK_DATA` for symmetry.
  func extraInputs() throws -> [MediaGenerationPipeline.Input] {
    var inputs: [MediaGenerationPipeline.Input] = []
    if let referenceImage {
      guard let data = Data(base64Encoded: referenceImage) else {
        throw EngineError.invalidReferenceImage
      }
      inputs.append(MediaGenerationPipeline.data(data).moodboard())
    }
    if let depthImage {
      guard let data = Data(base64Encoded: depthImage) else {
        throw EngineError.invalidDepthImage
      }
      inputs.append(MediaGenerationPipeline.data(data).depth())
    }
    return inputs
  }

  /// Resolves the effective seed for this request. `seed == nil` or `seed == -1`
  /// (our "random" convention) yields a freshly generated UInt32 — passing -1
  /// straight through would degenerate to `0xFFFFFFFF`, a single deterministic
  /// value masquerading as random.
  func effectiveSeed() -> UInt32 {
    if let seed, seed >= 0 {
      return UInt32(truncatingIfNeeded: seed)
    }
    return UInt32.random(in: 0...UInt32.max)
  }

  func apply(to configuration: inout MediaGenerationPipeline.Configuration, seed: UInt32) {
    configuration.width = width
    configuration.height = height
    // nil → leave the model's pristine step count (config is seeded from it).
    if let steps { configuration.steps = steps }
    if let cfgScale { configuration.guidanceScale = cfgScale }
    configuration.seed = seed
    if let seedMode { configuration.seedMode = seedMode.sdk }
    if let sampler { configuration.sampler = sampler.sdk }
    if let clipSkip { configuration.clipSkip = clipSkip }
    if let batchSize { configuration.batchSize = batchSize }
    if let batchCount { configuration.batchCount = batchCount }
    if let loras {
      configuration.loras = loras.map { LoRA(file: $0.loraId, weight: $0.weight, mode: .all) }
    }
    if let controlnets {
      configuration.controls = controlnets.map { $0.sdkControl }
    }
    if let hiresFix {
      configuration.hiresFix = hiresFix.enabled
      if let w = hiresFix.firstPassWidth { configuration.hiresFixWidth = w }
      if let h = hiresFix.firstPassHeight { configuration.hiresFixHeight = h }
      if let s = hiresFix.strength { configuration.hiresFixStrength = s }
    }
    if let refiner {
      configuration.refinerModel = refiner.modelId
      if let start = refiner.start { configuration.refinerStart = start }
    }
    if let upscaler {
      configuration.upscaler = upscaler.modelId
      if let s = upscaler.scaleFactor { configuration.upscalerScaleFactor = s }
    }
    if let tiling {
      if let dec = tiling.decoding {
        configuration.tiledDecoding = dec.enabled
        if let w = dec.tileWidth { configuration.decodingTileWidth = w }
        if let h = dec.tileHeight { configuration.decodingTileHeight = h }
        if let o = dec.overlap { configuration.decodingTileOverlap = o }
      }
      if let diff = tiling.diffusion {
        configuration.tiledDiffusion = diff.enabled
        if let w = diff.tileWidth { configuration.diffusionTileWidth = w }
        if let h = diff.tileHeight { configuration.diffusionTileHeight = h }
        if let o = diff.overlap { configuration.diffusionTileOverlap = o }
      }
    }
    if let flowMatch {
      if let s = flowMatch.shift { configuration.shift = s }
      if let r = flowMatch.resolutionDependentShift { configuration.resolutionDependentShift = r }
    }
    if let sdxl = sdxlConditioning {
      if let v = sdxl.originalWidth { configuration.originalImageWidth = v }
      if let v = sdxl.originalHeight { configuration.originalImageHeight = v }
      if let v = sdxl.cropTop { configuration.cropTop = v }
      if let v = sdxl.cropLeft { configuration.cropLeft = v }
      if let v = sdxl.targetWidth { configuration.targetImageWidth = v }
      if let v = sdxl.targetHeight { configuration.targetImageHeight = v }
      if let v = sdxl.negativeOriginalWidth { configuration.negativeOriginalImageWidth = v }
      if let v = sdxl.negativeOriginalHeight { configuration.negativeOriginalImageHeight = v }
      if let v = sdxl.aestheticScore { configuration.aestheticScore = v }
      if let v = sdxl.negativeAestheticScore { configuration.negativeAestheticScore = v }
      if let v = sdxl.zeroNegativePrompt { configuration.zeroNegativePrompt = v }
    }
    if let textEncoders {
      if let v = textEncoders.t5Decoding { configuration.t5TextEncoder = v }
      if let cl = textEncoders.separateClipL {
        configuration.separateClipL = cl.enabled
        if let text = cl.text { configuration.clipLText = text }
      }
      if let og = textEncoders.separateOpenClipG {
        configuration.separateOpenClipG = og.enabled
        if let text = og.text { configuration.openClipGText = text }
      }
      if let t5 = textEncoders.separateT5 {
        configuration.separateT5 = t5.enabled
        if let text = t5.text { configuration.t5Text = text }
      }
    }
    if let cascade {
      if let v = cascade.stage2Steps { configuration.stage2Steps = v }
      if let v = cascade.stage2Guidance { configuration.stage2Guidance = v }
      if let v = cascade.stage2Shift { configuration.stage2Shift = v }
    }
    if let imagePrior {
      if let v = imagePrior.steps { configuration.imagePriorSteps = v }
      if let v = imagePrior.negativePromptEnabled {
        configuration.negativePromptForImagePrior = v
      }
      if let v = imagePrior.clipWeight { configuration.clipWeight = v }
    }
    if let sharpness { configuration.sharpness = sharpness }
    if let drawThings = extensions?.drawThings {
      if let p = drawThings.preserveOriginalAfterInpaint {
        configuration.preserveOriginalAfterInpaint = p
      }
      if let tc = drawThings.teaCache {
        configuration.teaCache = tc.enabled
        if let s = tc.start { configuration.teaCacheStart = s }
        if let e = tc.end { configuration.teaCacheEnd = e }
        if let t = tc.threshold { configuration.teaCacheThreshold = t }
        if let m = tc.maxSkipSteps { configuration.teaCacheMaxSkipSteps = m }
      }
      if let ci = drawThings.causalInference {
        if let l = ci.length { configuration.causalInference = l }
        if let p = ci.pad { configuration.causalInferencePad = p }
      }
      if let cfg = drawThings.cfgZeroStar {
        configuration.cfgZeroStar = cfg.enabled
        if let s = cfg.initSteps { configuration.cfgZeroInitSteps = s }
      }
      if let ge = drawThings.guidanceEmbed {
        configuration.speedUpWithGuidanceEmbed = ge.enabled
        if let v = ge.value { configuration.guidanceEmbed = v }
      }
      if let g = drawThings.stochasticSamplingGamma {
        configuration.stochasticSamplingGamma = g
      }
      if let s = drawThings.imageGuidanceScale {
        configuration.imageGuidanceScale = s
      }
      if let ca = drawThings.compressionArtifacts {
        configuration.compressionArtifacts = ca.method.sdk
        configuration.compressionArtifactsQuality = ca.quality
      }
      if let fr = drawThings.faceRestoration {
        configuration.faceRestoration = fr.modelId
      }
      if let mb = drawThings.maskBlur { configuration.maskBlur = mb }
      if let mbo = drawThings.maskBlurOutset { configuration.maskBlurOutset = mbo }
    }
  }
}

// MARK: - Video knob types
//
// `VideoExtraParams` / `VideoMotionParams` are now reached only via
// `EngineParams.video` (semantic-API wire). The legacy `/v1/txt2vid` and
// `/v1/img2vid` request bodies that used to host them were deleted in the
// semantic-API rewrite.

/// Video-specific knobs layered on top of `GenerationParams`. The shared
/// generation fields (prompt, base_model_id, seed, …) flow through
/// `GenerationParams` unchanged; only the new video fields live here.
/// Architecture-conditional motion knobs. `motion_scale` is honored by
/// SVD-family models; `guiding_frame_noise` by Wan i2v; `start_frame_guidance`
/// by both. Engine defaults preserved when omitted.
struct VideoMotionParams: Codable, Sendable {
  let motionScale: Int?
  let guidingFrameNoise: Float?
  let startFrameGuidance: Float?

  enum CodingKeys: String, CodingKey {
    case motionScale = "motion_scale"
    case guidingFrameNoise = "guiding_frame_noise"
    case startFrameGuidance = "start_frame_guidance"
  }

  func validate() throws {
    if let m = motionScale, (m < 0 || m > 1023) {
      throw ValidationError("motion.motion_scale must be in [0, 1023], got \(m)")
    }
    if let g = guidingFrameNoise, (!g.isFinite || g < 0 || g > 1) {
      throw ValidationError(
        "motion.guiding_frame_noise must be finite in [0, 1], got \(g)")
    }
    if let s = startFrameGuidance, (!s.isFinite || s < 0 || s > 10) {
      throw ValidationError(
        "motion.start_frame_guidance must be finite in [0, 10], got \(s)")
    }
  }
}

struct VideoExtraParams: Codable, Sendable {
  let numFrames: Int
  let fps: Int?
  let videoFormat: VideoFormatAPI?
  let motion: VideoMotionParams?

  enum CodingKeys: String, CodingKey {
    case numFrames = "num_frames"
    case fps
    case videoFormat = "video_format"
    case motion
  }

  func validate() throws {
    if numFrames < 1 || numFrames > 256 {
      throw ValidationError("num_frames must be in [1, 256], got \(numFrames)")
    }
    if let fps, (fps < 1 || fps > 120) {
      throw ValidationError("fps must be in [1, 120], got \(fps)")
    }
    try motion?.validate()
  }

  var effectiveFps: Int { fps ?? 24 }
  var effectiveFormat: VideoFormatAPI { videoFormat ?? .mp4H264 }
}

// MARK: - Video response

/// A single generated video. The `data` field is the base64-encoded mp4
/// payload. Future video formats (webm, gif, frame_sequence) would extend
/// this struct rather than replace it; see [[plan-v0]].
struct VideoResult: Codable, Sendable {
  let data: String   // base64-encoded mp4
  let format: VideoFormatAPI
  let width: Int
  let height: Int
  let numFrames: Int
  let fps: Int
  let durationMs: Int
  let seed: Int64

  enum CodingKeys: String, CodingKey {
    case data, format, width, height
    case numFrames = "num_frames"
    case fps
    case durationMs = "duration_ms"
    case seed
  }
}

struct VideoGenerationResponse: Codable, Sendable {
  let videos: [VideoResult]
  let generationTimeMs: Int
  let metadata: RunMetadata

  enum CodingKeys: String, CodingKey {
    case videos
    case generationTimeMs = "generation_time_ms"
    case metadata
  }
}

// MARK: - Responses

/// Metadata returned with every generation response. Echoes what
/// `/v1/resolve` would have surfaced — engine-quirk warnings AND the Core
/// defaults the engine filled in — so a caller that skipped the dry-run
/// still gets the same visibility.
struct RunMetadata: Codable, Sendable {
  let runId: String
  let engineVersion: String
  let effectiveSeed: Int64
  let warnings: [Diagnostic]
  let appliedDefaults: [AppliedDefault]

  enum CodingKeys: String, CodingKey {
    case runId = "run_id"
    case engineVersion = "engine_version"
    case effectiveSeed = "effective_seed"
    case warnings
    case appliedDefaults = "applied_defaults"
  }
}

struct GenerationResponse: Codable, Sendable {
  /// Base64-encoded image bytes, one entry per generated image.
  /// Upper bound: `batch_size × batch_count`. Some architectures
  /// (Z-Image, video models) cap engine-side `batch_size` to 1 — so
  /// actual count may be lower than `batch_size × batch_count`.
  let images: [String]
  /// Seed used for `images[0]`. Subsequent indices derive from this base
  /// following the configured `seed_mode` (replay scheme depends on it).
  let seed: Int64
  let generationTimeMs: Int
  let metadata: RunMetadata

  enum CodingKeys: String, CodingKey {
    case images
    case seed
    case generationTimeMs = "generation_time_ms"
    case metadata
  }
}

// MARK: - /v1/resolve

/// Structured diagnostic emitted by `/v1/resolve/{verb}` (and surfaced in
/// `RunMetadata` on the generation responses).
/// `code` is a stable identifier (e.g. `BATCH_SIZE_MAY_CAP`); `message` is a
/// human-readable explanation; `field_path` points at the request field that
/// caused the diagnostic when applicable.
struct Diagnostic: Codable, Sendable {
  let code: String
  let fieldPath: String?
  let message: String

  enum CodingKeys: String, CodingKey {
    case code, message
    case fieldPath = "field_path"
  }
}

/// Tagged JSON value. Used by `applied_defaults` (scalars only) AND by the
/// `example` field on capability `Contract` (full JSON tree). The `array` /
/// `object` cases make this a general JSON model — `indirect` keeps the enum
/// finite in size despite the recursive cases.
indirect enum JSONValue: Codable, Sendable, Equatable {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null; return }
    if let v = try? c.decode(Bool.self) { self = .bool(v); return }
    if let v = try? c.decode(Int64.self) { self = .int(v); return }
    if let v = try? c.decode(Double.self) { self = .double(v); return }
    if let v = try? c.decode(String.self) { self = .string(v); return }
    if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
    if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
    throw DecodingError.dataCorruptedError(
      in: c, debugDescription: "expected null/bool/int/double/string/array/object")
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .int(let v): try c.encode(v)
    case .double(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }
}

/// One Core-field default the engine filled in because the request didn't.
/// `field_path` is the JSON path in the request (snake_case, no leading slash),
/// `value` is the engine-side default at request-time (so it reflects what
/// the chosen base model's pristine template carries — values differ between
/// say SDXL and Z-Image).
struct AppliedDefault: Codable, Sendable {
  let fieldPath: String
  let value: JSONValue

  enum CodingKeys: String, CodingKey {
    case fieldPath = "field_path"
    case value
  }
}

struct ResolveResponse: Codable, Sendable {
  /// The verb body the caller submitted, replayed with engine defaults
  /// folded into `params` for the chosen base model. Wrapped as a
  /// `Recipe` (`{ via: compose|edit|restore, ... }`) — the agent can
  /// re-POST it to `/v1/<via>` as-is. Sub-objects (loras, controlnets,
  /// hires_fix, …) are opt-in and not auto-filled — they appear in
  /// `resolved_request` only if the caller supplied them. `nil` when
  /// validation refused materialization (e.g. `PARAMS_REQUIRED` on a
  /// verb body without a `params` block) — the diagnostic lives in
  /// `errors[]`.
  let resolvedRequest: Recipe?
  /// Per-field record of which Core defaults the engine had to fill
  /// because the request didn't carry them. Matches what was injected
  /// into `resolved_request`.
  let appliedDefaults: [AppliedDefault]
  /// Non-fatal observations the agent should consider before generating.
  let warnings: [Diagnostic]
  /// Issues that will prevent (or undermine) generation. Errors do not cause
  /// `/v1/resolve` to fail with 4xx — they are reported here so an agent can
  /// inspect and iterate. A request with `errors[].isEmpty == false` will
  /// also fail (with a typed 4xx/5xx) when submitted to a generation endpoint.
  let errors: [Diagnostic]
  /// Best-effort engine estimate of the compute units required to run this
  /// request as resolved. `nil` when the engine does not expose an estimate
  /// for the chosen architecture.
  let estimatedComputeUnits: Int?

  enum CodingKeys: String, CodingKey {
    case resolvedRequest = "resolved_request"
    case appliedDefaults = "applied_defaults"
    case warnings, errors
    case estimatedComputeUnits = "estimated_compute_units"
  }
}

struct InfoResponse: Codable, Sendable {
  let apiVersion: String
  let engineVersion: String

  enum CodingKeys: String, CodingKey {
    case apiVersion = "api_version"
    case engineVersion = "engine_version"
  }
}

/// `GET /health` liveness payload. Deliberately minimal and auth-exempt: a
/// supervisor (launchd `KeepAlive`, the menu-bar app, an uptime monitor) must
/// be able to probe whether the process is up and answering without holding a
/// token. The server is stateless, so "up and routing" *is* "ready" — there's
/// no model load or backing store to gate readiness on.
struct HealthResponse: Codable, Sendable {
  let status: String
}

struct ValidationError: Error {
  let detail: String
  init(_ detail: String) { self.detail = detail }
}

struct ProblemBody: Codable, Sendable {
  let type: String
  let title: String
  let status: Int
  let detail: String?
  let errorCode: String

  enum CodingKeys: String, CodingKey {
    case type, title, status, detail
    case errorCode = "error_code"
  }
}

/// One in-flight run in the `GET /v1/runs` list. No preview frame — kept
/// light so the list stays cheap to poll.
struct RunSummary: Codable, Sendable {
  let runId: String
  let kind: String
  let prompt: String
  let width: Int
  let height: Int
  let steps: Int
  let startedAt: String
  let currentStep: Int
  let totalSteps: Int

  enum CodingKeys: String, CodingKey {
    case runId = "run_id"
    case kind, prompt, width, height, steps
    case startedAt = "started_at"
    case currentStep = "current_step"
    case totalSteps = "total_steps"
  }
}

struct RunListResponse: Codable, Sendable {
  let runs: [RunSummary]
}

/// One run from `GET /v1/runs/{run_id}` — same fields as `RunSummary` plus
/// the latest live-preview frame, base64-encoded PNG (nil until the engine
/// emits one).
struct RunDetailResponse: Codable, Sendable {
  let runId: String
  let kind: String
  let prompt: String
  let width: Int
  let height: Int
  let steps: Int
  let startedAt: String
  let currentStep: Int
  let totalSteps: Int
  let previewPngBase64: String?

  enum CodingKeys: String, CodingKey {
    case runId = "run_id"
    case kind, prompt, width, height, steps
    case startedAt = "started_at"
    case currentStep = "current_step"
    case totalSteps = "total_steps"
    case previewPngBase64 = "preview_png_base64"
  }
}

// MARK: - Semantic API wire types
//
// Three verbs (compose / edit / restore) + a pipeline sugar, keyed on
// preservation level (input → output). All bodies are stateless: composition
// lives in `from.via` sub-recipes or in `/v1/pipeline` steps. Old
// `Txt2ImgRequest` / `Img2ImgRequest` / `LegacyEditRequest` / `InpaintRequest`
// / `Txt2VidRequest` / `Img2VidRequest` stay alongside until R3 deletes the
// old route set.

/// Polymorphic "where the input image comes from". Wire shapes:
///   - JSON `null`                              → field absent (decoded as nil at the parent)
///   - `{ "image": "<base64>" }`                → `.image(bytes)`
///   - `{ "via": "compose"|"edit"|"restore", … }` → `.recipe(inline sub-recipe)`
///   - `"$name"` (bare string, pipeline only)   → `.ref(stepName)`
///
/// A `.ref` outside a pipeline step is invalid; the engine adapter rejects it
/// at execution time rather than failing decode (decode is context-free).
enum FromSource: Sendable {
  case image(String)              // base64 bytes
  indirect case recipe(Recipe)    // inline sub-recipe; `indirect` breaks the
                                  // FromSource→Recipe→*Request→FromSource cycle
  case ref(String)                // "$name", resolves to a prior pipeline step output
}

extension FromSource: Codable {
  private enum DiscriminatorKey: String, CodingKey { case image, via }

  init(from decoder: Decoder) throws {
    if let scalar = try? decoder.singleValueContainer().decode(String.self) {
      guard scalar.hasPrefix("$"), scalar.count > 1 else {
        throw DecodingError.dataCorruptedError(
          in: try decoder.singleValueContainer(),
          debugDescription: "from string must start with '$' followed by a step name")
      }
      self = .ref(String(scalar.dropFirst()))
      return
    }
    let c = try decoder.container(keyedBy: DiscriminatorKey.self)
    if c.contains(.image) {
      self = .image(try c.decode(String.self, forKey: .image))
      return
    }
    if c.contains(.via) {
      self = .recipe(try Recipe(from: decoder))
      return
    }
    throw DecodingError.dataCorruptedError(
      forKey: .image, in: c,
      debugDescription: "expected { image }, { via, … }, or \"$name\"")
  }

  func encode(to encoder: Encoder) throws {
    switch self {
    case .image(let bytes):
      var c = encoder.container(keyedBy: DiscriminatorKey.self)
      try c.encode(bytes, forKey: .image)
    case .recipe(let r):
      try r.encode(to: encoder)
    case .ref(let name):
      var c = encoder.singleValueContainer()
      try c.encode("$" + name)
    }
  }
}

/// A full verb body, tagged with `via`. Used when a recipe is nested inside
/// `from.via` or as a pipeline step. The top-level POST body for /v1/compose,
/// /v1/edit, /v1/restore does NOT carry `via` (the URL supplies it).
enum Recipe: Sendable {
  case compose(ComposeRequest)
  case edit(EditRequest)
  case restore(RestoreRequest)
}

extension Recipe: Codable {
  private enum DiscriminatorKey: String, CodingKey { case via }
  private enum Verb: String, Codable { case compose, edit, restore }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: DiscriminatorKey.self)
    let verb = try c.decode(Verb.self, forKey: .via)
    switch verb {
    case .compose: self = .compose(try ComposeRequest(from: decoder))
    case .edit:    self = .edit(try EditRequest(from: decoder))
    case .restore: self = .restore(try RestoreRequest(from: decoder))
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: DiscriminatorKey.self)
    switch self {
    case .compose(let r): try c.encode(Verb.compose, forKey: .via); try r.encode(to: encoder)
    case .edit(let r):    try c.encode(Verb.edit, forKey: .via);    try r.encode(to: encoder)
    case .restore(let r): try c.encode(Verb.restore, forKey: .via); try r.encode(to: encoder)
    }
  }
}

/// Friendly-name guide kind on `guides[].kind`. Restricted to the two roles
/// the public MGK surface actually plumbs distinctly:
/// - `depth` → `.depth()` typed input (for depth ControlNets / depth-aware models),
/// - `reference` → `.moodboard()` typed input (IP-Adapter, shuffle-class controls).
/// Any other ControlNet task (canny/pose/scribble/…) requires the full
/// `controlnets[]` entry on `EngineParams` — guides[] deliberately stays narrow
/// so the wire never advertises a kind the SDK cannot honor.
enum GuideKind: String, Codable, Sendable {
  case depth, reference
}

struct GuideRef: Codable, Sendable {
  let kind: GuideKind
  let image: FromSource
  let weight: Float?
}

/// Role of a `references[]` entry on `/v1/edit`. Closed list per plan
/// question #4; start narrow, expand on demand.
enum ReferenceRole: String, Codable, Sendable {
  case style, identity, layout, pose, subject, reference
}

struct Reference: Codable, Sendable {
  let image: FromSource
  let role: ReferenceRole?
}

/// Engine knobs (the contents of the `params` sub-object on every verb body).
/// Same field set as the legacy `GenerationParams` minus the four root fields
/// that moved up in the semantic API (`prompt`, `negative_prompt`,
/// `base_model_id`, `run_id`), plus three R2 additions:
/// - `denoising_strength` — used when a compose has `from.image` (img2img-equivalent)
/// - `conditioning_strength` — used when a video model has `from.image` (img2vid-equivalent)
/// - `video` — video knobs (num_frames / fps / video_format / motion) — see [[VideoExtraParams]]
///
/// `materialize(model:prompt:negativePrompt:runId:)` rebuilds a complete
/// `GenerationParams` for the internal engine path. R3 deletes the legacy
/// bodies and `GenerationParams` collapses into this struct.
struct EngineParams: Codable, Sendable {
  // Core flat (required)
  let width: Int
  let height: Int
  /// `nil` requests the chosen model's default step count (filled from the
  /// pristine config at resolve / apply time), mirroring `cfgScale`.
  let steps: Int?
  // Core flat (optional)
  let cfgScale: Float?
  let seed: Int64?
  let seedMode: SeedModeAPI?
  let sampler: SamplerAPI?
  let clipSkip: Int?
  let outputFormat: OutputFormat?
  let batchSize: Int?
  let batchCount: Int?
  // R2 additions
  let denoisingStrength: Float?
  let conditioningStrength: Float?
  let video: VideoExtraParams?
  // Layer 2 sub-objects (carried through to GenerationParams unchanged)
  let loras: [LoRARef]?
  let controlnets: [ControlNetRef]?
  let referenceImage: String?
  let depthImage: String?
  let hiresFix: HiresFixParams?
  let refiner: RefinerParams?
  let upscaler: UpscalerParams?
  let tiling: TilingParams?
  let flowMatch: FlowMatchParams?
  let sdxlConditioning: SDXLConditioningParams?
  let textEncoders: TextEncodersParams?
  let cascade: CascadeParams?
  let imagePrior: ImagePriorParams?
  let sharpness: Float?
  // Layer 3 engine-specific
  let extensions: Extensions?

  enum CodingKeys: String, CodingKey {
    case width, height, steps
    case cfgScale = "cfg_scale"
    case seed
    case seedMode = "seed_mode"
    case sampler
    case clipSkip = "clip_skip"
    case outputFormat = "output_format"
    case batchSize = "batch_size"
    case batchCount = "batch_count"
    case denoisingStrength = "denoising_strength"
    case conditioningStrength = "conditioning_strength"
    case video
    case loras, controlnets
    case referenceImage = "reference_image"
    case depthImage = "depth_image"
    case hiresFix = "hires_fix"
    case refiner, upscaler, tiling
    case flowMatch = "flow_match"
    case sdxlConditioning = "sdxl_conditioning"
    case textEncoders = "text_encoders"
    case cascade
    case imagePrior = "image_prior"
    case sharpness
    case extensions
  }

  /// Returns a copy with the Core optional fields filled in from the
  /// pristine engine config — mirror of `GenerationParams.withDefaults`
  /// at the verb-shaped layer. Sub-objects are opt-in and pass through
  /// unchanged; `denoising_strength` / `conditioning_strength` / `video`
  /// (R2 additions) also pass through — they are verb-side knobs, not
  /// engine defaults.
  func withDefaults(from pristine: MediaGenerationPipeline.Configuration) -> EngineParams {
    EngineParams(
      width: width,
      height: height,
      steps: steps ?? pristine.steps,
      cfgScale: cfgScale ?? pristine.guidanceScale,
      seed: seed,
      seedMode: seedMode ?? SeedModeAPI(pristine.seedMode),
      sampler: sampler ?? SamplerAPI(pristine.sampler),
      clipSkip: clipSkip ?? pristine.clipSkip,
      outputFormat: outputFormat ?? .png,
      batchSize: batchSize ?? pristine.batchSize,
      batchCount: batchCount ?? pristine.batchCount,
      denoisingStrength: denoisingStrength,
      conditioningStrength: conditioningStrength,
      video: video,
      loras: loras,
      controlnets: controlnets,
      referenceImage: referenceImage,
      depthImage: depthImage,
      hiresFix: hiresFix,
      refiner: refiner,
      upscaler: upscaler,
      tiling: tiling,
      flowMatch: flowMatch,
      sdxlConditioning: sdxlConditioning,
      textEncoders: textEncoders,
      cascade: cascade,
      imagePrior: imagePrior,
      sharpness: sharpness,
      extensions: extensions
    )
  }

  /// Folds the EngineParams plus the body-root identity fields into the
  /// `GenerationParams` shape consumed by the internal `generate` /
  /// `generateVideo` paths. `negativePrompt = nil` is mapped to `""` to
  /// match the engine's expectation.
  func materialize(
    model: String, prompt: String, negativePrompt: String?, runId: String?
  ) -> GenerationParams {
    GenerationParams(
      prompt: prompt, negativePrompt: negativePrompt, baseModelId: model,
      width: width, height: height, steps: steps,
      cfgScale: cfgScale, seed: seed, seedMode: seedMode, sampler: sampler,
      clipSkip: clipSkip, outputFormat: outputFormat,
      batchSize: batchSize, batchCount: batchCount, runId: runId,
      loras: loras, controlnets: controlnets,
      referenceImage: referenceImage, depthImage: depthImage,
      hiresFix: hiresFix, refiner: refiner, upscaler: upscaler,
      tiling: tiling, flowMatch: flowMatch, sdxlConditioning: sdxlConditioning,
      textEncoders: textEncoders, cascade: cascade, imagePrior: imagePrior,
      sharpness: sharpness, extensions: extensions)
  }
}

/// `POST /v1/compose` body. Produces an output (image or video, decided by the
/// chosen model's domain). `from` is *a guide*, not a target — the engine may
/// diverge freely. `from == nil` is pure text2img.
struct ComposeRequest: Codable, Sendable {
  let model: String
  let prompt: String
  let negativePrompt: String?
  let from: FromSource?
  let guides: [GuideRef]?
  let params: EngineParams?
  let runId: String?

  enum CodingKeys: String, CodingKey {
    case model, prompt
    case negativePrompt = "negative_prompt"
    case from, guides, params
    case runId = "run_id"
  }
}

/// `POST /v1/edit` body. Preserves `from`, changes the aspects called out by
/// `instruction`. A non-nil `mask` turns the call into an inpaint
/// (non-zero pixels mark the region to regenerate).
struct EditRequest: Codable, Sendable {
  let model: String
  let from: FromSource
  let instruction: String
  let mask: String?                // base64 PNG/JPEG; present → inpaint
  let references: [Reference]?
  let params: EngineParams?
  let runId: String?

  enum CodingKeys: String, CodingKey {
    case model, from, instruction, mask, references, params
    case runId = "run_id"
  }
}

/// `POST /v1/restore` body. Preserves `from` integrally; only improves
/// fidelity (upscaler / face restoration / similar). No creative liberty.
struct RestoreRequest: Codable, Sendable {
  let model: String
  let from: FromSource
  let params: EngineParams?
  let runId: String?

  enum CodingKeys: String, CodingKey {
    case model, from, params
    case runId = "run_id"
  }
}

/// One step in a `POST /v1/pipeline` body. Wire shape:
/// `{ "as": "...", "via": "...", …recipe body… }`. The `as` label names the
/// step output so later steps can refer to it via `"$as"` in their `from`.
/// Omit `as` → step is unreachable from `return` / `$ref` (only useful if
/// it's the last step and `return` is nil).
struct PipelineStep: Sendable {
  let `as`: String?
  let recipe: Recipe
}

extension PipelineStep: Codable {
  private enum CodingKeys: String, CodingKey { case `as` }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.as = try c.decodeIfPresent(String.self, forKey: .as)
    self.recipe = try Recipe(from: decoder)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(self.as, forKey: .as)
    try recipe.encode(to: encoder)
  }
}

/// `POST /v1/pipeline` body. Ordered chain of recipes; later steps reference
/// earlier outputs by `"$name"`. Stateless (no asset persists between calls).
/// `return == nil` → return last step's output only; otherwise return the
/// named steps in order.
struct PipelineRequest: Codable, Sendable {
  let steps: [PipelineStep]
  let `return`: [String]?
}

/// `POST /v1/pipeline` response. `outputs` keys are step `as` labels (or
/// `"result"` when `return` is omitted and the last step had no `as`).
/// Values are base64-encoded image bytes. Multi-step returns share this
/// envelope shape per plan question #3 (JSON envelope is the default;
/// multipart is the planned alternative if a caller asks for it).
struct PipelineResponse: Codable, Sendable {
  let outputs: [String: String]
  let generationTimeMs: Int

  enum CodingKeys: String, CodingKey {
    case outputs
    case generationTimeMs = "generation_time_ms"
  }
}
