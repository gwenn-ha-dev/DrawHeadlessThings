import Foundation
import ModelZoo

// MARK: - Core enums

/// 1:1 mirror of `ModelVersion` (raw String identical), so we never diverge from the engine.
/// If the engine adds a new architecture, we extend this enum.
enum Architecture: String, Codable, Sendable, CaseIterable {
  case v1
  case v2
  case kandinsky21 = "kandinsky2.1"
  case sdxlBase = "sdxl_base_v0.9"
  case sdxlRefiner = "sdxl_refiner_v0.9"
  case ssd1b = "ssd_1b"
  case svdI2v = "svd_i2v"
  case wurstchenStageC = "wurstchen_v3.0_stage_c"
  case wurstchenStageB = "wurstchen_v3.0_stage_b"
  case sd3
  case pixart
  case auraflow
  case flux1
  case sd3Large = "sd3_large"
  case hunyuanVideo = "hunyuan_video"
  case wan21_1_3b = "wan_v2.1_1.3b"
  case wan21_14b = "wan_v2.1_14b"
  case hiDreamI1 = "hidream_i1"
  case qwenImage = "qwen_image"
  case wan22_5b = "wan_v2.2_5b"
  case zImage = "z_image"
  case ernieImage = "ernie_image"
  case flux2
  case flux2_9b
  case flux2_4b
  case cosmos2_5_2b = "cosmos2.5_2b"
  case ltx2
  case ltx2_3 = "ltx2.3"
  case seedvr2_3b
  case seedvr2_7b

  /// Truth source: `ImageGeneratorUtils.isVideoModel` in the SDK
  /// (`Libraries/ImageGenerator/Sources/ImageGeneratorUtils.swift:180`).
  /// `cosmos2_5_2b` is a Qwen-Image-cohort T2I model; `seedvr2_*` is image
  /// super-resolution (single-frame by default). Both stay in `.image`.
  var domain: Domain {
    switch self {
    case .svdI2v, .hunyuanVideo, .wan21_1_3b, .wan21_14b, .wan22_5b,
      .ltx2, .ltx2_3:
      return .video
    default:
      return .image
    }
  }
}

enum Domain: String, Codable, Sendable {
  case image
  case video
}

/// Agent-facing semantic category derived from a base model's
/// `SamplerModifier`. Lets a caller decide *which generation endpoint to
/// use* and *what shape the prompt + inputs take* without having to
/// know the raw SDK modifier string. The raw modifier stays on the
/// asset (`modifier` field) for traceability.
///
/// Nil when the model is vanilla text-to-image (modifier `.none`).
enum EditingMode: String, Codable, Sendable {
  /// SD 1.5 / 2.x inpaint fine-tunes (modifier `.inpainting`). Call
  /// `POST /v1/inpaint` with a `mask`.
  case inpainting
  /// Depth- or canny-conditioned base models (modifier `.depth` /
  /// `.canny`). Provide the matching hint image via `depth_image` /
  /// `reference_image` or a `controlnets[]` entry with the right
  /// `input_type_override`.
  case hintConditioned = "hint_conditioned"
  /// Instruction-based editing models: Flux Kontext, Qwen-Image-Edit
  /// (Plus / 2511). `prompt` is a natural-language edit instruction; the
  /// image to edit is a conditioning reference, not a denoising init.
  /// Call `POST /v1/edit` — `/v1/img2img` is rejected for these models.
  case instructionEdit = "instruction_edit"
  /// Qwen Image Layered variant — same wire as instruction_edit but
  /// the engine treats it as a single-canvas flow (no shuffles).
  case layeredEdit = "layered_edit"
  /// Legacy / rarely-used modifiers (`.editing`, `.double`). Falls
  /// back to the raw `modifier` field for the agent to interpret.
  case other

  /// Maps the raw `SamplerModifier.rawValue` string to a semantic
  /// category. Returns `nil` for the vanilla text-to-image case
  /// (`modifier == .none` or absent).
  init?(modifier: String?) {
    guard let raw = modifier, raw != "none" else { return nil }
    switch raw {
    case "inpainting":
      self = .inpainting
    case "depth", "canny":
      self = .hintConditioned
    case "kontext", "kontext_kv",
      "qwenimage_edit_plus", "qwenimage_edit_2511":
      self = .instructionEdit
    case "qwenimage_layered":
      self = .layeredEdit
    case "editing", "double":
      self = .other
    default:
      self = .other
    }
  }
}

/// 1:1 mirror of `ControlHintType` (raw String identical).
enum ControlNetTask: String, Codable, Sendable, CaseIterable {
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
}

enum AssetType: String, Codable, Sendable, CaseIterable {
  case baseModel = "base_model"
  case lora
  case controlnet
  case embedding
  case upscaler
  case faceRestoration = "face_restoration"
  // vae and motion_module: not yet mapped (no dedicated Zoo upstream).
}

// MARK: - Per-type asset structs (typed strictly)

/// Each variant declares only the fields that make sense for its type.
/// `type` is encoded in JSON so the union is discriminated client-side.

struct BaseModelAsset: Codable, Sendable {
  let type: AssetType                  // always .baseModel — serialized
  let id: String                       // file name (canonical id)
  let name: String
  let architecture: Architecture
  let domain: Domain
  let downloaded: Bool
  let recommendedResolution: ImageSize?
  let hiresFixRecommendedResolution: ImageSize?
  let framesPerSecond: Double?         // video models only
  let isConsistencyModel: Bool         // turbo / LCM / Lightning
  let supportsRemoteApi: Bool
  let guidanceEmbed: Bool?             // Flux distilled
  let builtinLora: Bool?
  let isBf16: Bool?
  let deprecated: Bool
  let modifier: String?                // SamplerModifier raw (inpainting/depth/canny/...)
  let editingMode: EditingMode?        // semantic category derived from `modifier`
  let huggingFaceLink: String?
  let note: String?
  let copyright: String?
  /// Total install footprint in bytes (checkpoint + every companion
  /// file: text encoder, autoencoder, CLIP encoder, …).
  /// - For downloaded models: filesystem sum, exact.
  /// - For not-downloaded catalog models: HEAD against the SDK's CDN
  ///   (`static.libnnc.org`), summed across companions.
  /// - `null` when the size is genuinely unknown (CDN unreachable, or
  ///   at least one companion can't be resolved). Partial sums are
  ///   intentionally NOT reported — they'd be misleading.
  let installSizeBytes: Int64?

  enum CodingKeys: String, CodingKey {
    case type, id, name, architecture, domain, downloaded
    case recommendedResolution = "recommended_resolution"
    case hiresFixRecommendedResolution = "hires_fix_recommended_resolution"
    case framesPerSecond = "frames_per_second"
    case isConsistencyModel = "is_consistency_model"
    case supportsRemoteApi = "supports_remote_api"
    case guidanceEmbed = "guidance_embed"
    case builtinLora = "builtin_lora"
    case isBf16 = "is_bf16"
    case deprecated, modifier
    case editingMode = "editing_mode"
    case huggingFaceLink = "hugging_face_link"
    case note, copyright
    case installSizeBytes = "install_size_bytes"
  }
}

struct LoRAAsset: Codable, Sendable {
  let type: AssetType
  let id: String
  let name: String
  let compatibleArchitecture: Architecture    // singular — a LoRA targets one architecture family
  let domain: Domain                          // derived from compatibleArchitecture
  let downloaded: Bool
  let weightRange: WeightRange?
  let isConsistencyModel: Bool
  let isLoHa: Bool
  let modifier: String?
  let deprecated: Bool
  let note: String?

  enum CodingKeys: String, CodingKey {
    case type, id, name
    case compatibleArchitecture = "compatible_architecture"
    case domain, downloaded
    case weightRange = "weight_range"
    case isConsistencyModel = "is_consistency_model"
    case isLoHa = "is_loha"
    case modifier, deprecated, note
  }
}

struct ControlNetAsset: Codable, Sendable {
  let type: AssetType
  let id: String
  let name: String
  let compatibleArchitecture: Architecture
  let downloaded: Bool
  let task: ControlNetTask?                   // hint type — nil if unrecognized
  let controlType: String                     // "controlnet", "t2iadapter", "ipadapterplus", etc.
  let deprecated: Bool

  enum CodingKeys: String, CodingKey {
    case type, id, name
    case compatibleArchitecture = "compatible_architecture"
    case downloaded, task
    case controlType = "control_type"
    case deprecated
  }
}

struct EmbeddingAsset: Codable, Sendable {
  let type: AssetType
  let id: String
  let name: String
  let compatibleArchitecture: Architecture
  let downloaded: Bool
  let keyword: String                          // trigger word
  let length: Int                              // number of tokens
  let deprecated: Bool

  enum CodingKeys: String, CodingKey {
    case type, id, name
    case compatibleArchitecture = "compatible_architecture"
    case downloaded, keyword, length, deprecated
  }
}

struct UpscalerAsset: Codable, Sendable {
  let type: AssetType
  let id: String
  let name: String
  let downloaded: Bool
  let scaleFactor: String                      // raw value of UpscaleFactor enum
  let blocks: Int

  enum CodingKeys: String, CodingKey {
    case type, id, name, downloaded
    case scaleFactor = "scale_factor"
    case blocks
  }
}

struct FaceRestorationAsset: Codable, Sendable {
  let type: AssetType
  let id: String
  let name: String
  let downloaded: Bool

  enum CodingKeys: String, CodingKey {
    case type, id, name, downloaded
  }
}

struct ImageSize: Codable, Sendable {
  let width: Int
  let height: Int
}

struct WeightRange: Codable, Sendable {
  let lower: Float
  let upper: Float
  let recommended: Float?
}

// MARK: - Asset enum (discriminated union)

enum Asset: Sendable {
  case baseModel(BaseModelAsset)
  case lora(LoRAAsset)
  case controlnet(ControlNetAsset)
  case embedding(EmbeddingAsset)
  case upscaler(UpscalerAsset)
  case faceRestoration(FaceRestorationAsset)

  var id: String {
    switch self {
    case .baseModel(let a): return a.id
    case .lora(let a): return a.id
    case .controlnet(let a): return a.id
    case .embedding(let a): return a.id
    case .upscaler(let a): return a.id
    case .faceRestoration(let a): return a.id
    }
  }

  var type: AssetType {
    switch self {
    case .baseModel: return .baseModel
    case .lora: return .lora
    case .controlnet: return .controlnet
    case .embedding: return .embedding
    case .upscaler: return .upscaler
    case .faceRestoration: return .faceRestoration
    }
  }

  var downloaded: Bool {
    switch self {
    case .baseModel(let a): return a.downloaded
    case .lora(let a): return a.downloaded
    case .controlnet(let a): return a.downloaded
    case .embedding(let a): return a.downloaded
    case .upscaler(let a): return a.downloaded
    case .faceRestoration(let a): return a.downloaded
    }
  }

  /// The architecture this asset applies to or describes, if any.
  /// `nil` for type-agnostic assets (upscaler, face_restoration).
  var architecture: Architecture? {
    switch self {
    case .baseModel(let a): return a.architecture
    case .lora(let a): return a.compatibleArchitecture
    case .controlnet(let a): return a.compatibleArchitecture
    case .embedding(let a): return a.compatibleArchitecture
    case .upscaler, .faceRestoration: return nil
    }
  }

  var domain: Domain? {
    switch self {
    case .baseModel(let a): return a.domain
    case .lora(let a): return a.domain
    case .controlnet(let a): return a.compatibleArchitecture.domain
    case .embedding(let a): return a.compatibleArchitecture.domain
    case .upscaler, .faceRestoration: return nil
    }
  }
}

extension Asset: Encodable {
  func encode(to encoder: Encoder) throws {
    switch self {
    case .baseModel(let a): try a.encode(to: encoder)
    case .lora(let a): try a.encode(to: encoder)
    case .controlnet(let a): try a.encode(to: encoder)
    case .embedding(let a): try a.encode(to: encoder)
    case .upscaler(let a): try a.encode(to: encoder)
    case .faceRestoration(let a): try a.encode(to: encoder)
    }
  }
}

extension Asset: Decodable {
  private enum TypeKey: String, CodingKey { case type }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: TypeKey.self)
    let type = try c.decode(AssetType.self, forKey: .type)
    switch type {
    case .baseModel: self = .baseModel(try BaseModelAsset(from: decoder))
    case .lora: self = .lora(try LoRAAsset(from: decoder))
    case .controlnet: self = .controlnet(try ControlNetAsset(from: decoder))
    case .embedding: self = .embedding(try EmbeddingAsset(from: decoder))
    case .upscaler: self = .upscaler(try UpscalerAsset(from: decoder))
    case .faceRestoration: self = .faceRestoration(try FaceRestorationAsset(from: decoder))
    }
  }
}

struct AssetListResponse: Codable, Sendable {
  let items: [Asset]
}

// MARK: - Specification → typed variant constructors

extension BaseModelAsset {
  init(_ spec: ModelZoo.Specification) {
    let scale = Int(spec.defaultScale) * 64
    let hires = spec.hiresFixScale.map { Int($0) * 64 }
    let arch = Architecture(rawValue: spec.version.rawValue) ?? .v1
    self.type = .baseModel
    self.id = spec.file
    self.name = spec.name
    self.architecture = arch
    self.domain = arch.domain
    self.downloaded = ModelZoo.isModelDownloaded(spec)
    self.recommendedResolution = scale > 0 ? ImageSize(width: scale, height: scale) : nil
    self.hiresFixRecommendedResolution = hires.map { ImageSize(width: $0, height: $0) }
    self.framesPerSecond = spec.framesPerSecond
    self.isConsistencyModel = spec.isConsistencyModel ?? false
    self.supportsRemoteApi = spec.remoteApiModelConfig != nil
    self.guidanceEmbed = spec.guidanceEmbed
    self.builtinLora = spec.builtinLora
    self.isBf16 = spec.isBf16
    self.deprecated = spec.deprecated ?? false
    self.modifier = spec.modifier?.rawValue
    self.editingMode = EditingMode(modifier: spec.modifier?.rawValue)
    self.huggingFaceLink = spec.huggingFaceLink
    self.note = spec.note
    self.copyright = spec.copyright
    self.installSizeBytes = nil  // populated post-hoc by AssetManager
  }

  /// Returns a copy with `installSizeBytes` set. Used by `AssetManager`
  /// after the parallel size resolution pass — keeps `BaseModelAsset`
  /// fields immutable while letting us layer enrichment without
  /// threading the resolver through every Spec init site.
  func withInstallSize(_ size: Int64?) -> BaseModelAsset {
    BaseModelAsset(
      type: type, id: id, name: name, architecture: architecture,
      domain: domain, downloaded: downloaded,
      recommendedResolution: recommendedResolution,
      hiresFixRecommendedResolution: hiresFixRecommendedResolution,
      framesPerSecond: framesPerSecond,
      isConsistencyModel: isConsistencyModel,
      supportsRemoteApi: supportsRemoteApi,
      guidanceEmbed: guidanceEmbed, builtinLora: builtinLora,
      isBf16: isBf16, deprecated: deprecated,
      modifier: modifier, editingMode: editingMode,
      huggingFaceLink: huggingFaceLink, note: note, copyright: copyright,
      installSizeBytes: size)
  }
}

extension LoRAAsset {
  init(_ spec: LoRAZoo.Specification) {
    let arch = Architecture(rawValue: spec.version.rawValue) ?? .v1
    let weight = spec.weight.map {
      WeightRange(lower: $0.lowerBound, upper: $0.upperBound, recommended: $0.value)
    }
    self.type = .lora
    self.id = spec.file
    self.name = spec.name
    self.compatibleArchitecture = arch
    self.domain = arch.domain
    self.downloaded = LoRAZoo.isModelDownloaded(spec)
    self.weightRange = weight
    self.isConsistencyModel = spec.isConsistencyModel ?? false
    self.isLoHa = spec.isLoHa ?? false
    self.modifier = spec.modifier?.rawValue
    self.deprecated = spec.deprecated ?? false
    self.note = spec.note
  }
}

extension ControlNetAsset {
  init(_ spec: ControlNetZoo.Specification) {
    self.type = .controlnet
    self.id = spec.file
    self.name = spec.name
    self.compatibleArchitecture = Architecture(rawValue: spec.version.rawValue) ?? .v1
    self.downloaded = ControlNetZoo.isModelDownloaded(spec)
    self.task = spec.modifier.flatMap { ControlNetTask(rawValue: $0.rawValue) }
    self.controlType = spec.type.rawValue
    self.deprecated = spec.deprecated ?? false
  }
}

extension EmbeddingAsset {
  init(_ spec: TextualInversionZoo.Specification) {
    self.type = .embedding
    self.id = spec.file
    self.name = spec.name
    self.compatibleArchitecture = Architecture(rawValue: spec.version.rawValue) ?? .v1
    self.downloaded = TextualInversionZoo.isModelDownloaded(spec.file)
    self.keyword = spec.keyword
    self.length = spec.length
    self.deprecated = spec.deprecated ?? false
  }
}

extension UpscalerAsset {
  init(_ spec: UpscalerZoo.Specification) {
    self.type = .upscaler
    self.id = spec.file
    self.name = spec.name
    self.downloaded = UpscalerZoo.isModelDownloaded(spec.file)
    self.scaleFactor = String(describing: spec.scaleFactor)
    self.blocks = spec.blocks
  }
}

extension FaceRestorationAsset {
  init(_ spec: EverythingZoo.Specification) {
    self.type = .faceRestoration
    self.id = spec.file
    self.name = spec.name
    self.downloaded = EverythingZoo.isModelDownloaded(spec.file)
  }
}
