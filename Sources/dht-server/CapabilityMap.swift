import ModelZoo

// MARK: - Modifier (1:1 mirror of SDK SamplerModifier)

/// Raw-String mirror of `SamplerModifier` (SDK `Sampler.swift:53`), same
/// convention as `Architecture` mirrors `ModelVersion`. Avoids the
/// `import Diffusion` dependency the project deliberately doesn't take
/// (cf. `AssetMutation.swift:308`). A new modifier added upstream surfaces
/// as a compile-time error on every exhaustive switch over this enum.
enum Modifier: String, Codable, Sendable, CaseIterable, Hashable {
  case none
  case inpainting
  case depth
  case editing
  case double
  case canny
  case kontext
  case qwenimageEditPlus = "qwenimage_edit_plus"
  case qwenimageLayered = "qwenimage_layered"
  case qwenimageEdit2511 = "qwenimage_edit_2511"
  case kontextKv = "kontext_kv"

  /// Resolves the modifier from a spec's `modifier?.rawValue`. A `nil`
  /// modifier or unknown raw string maps to `.none` (vanilla T2I).
  static func from(rawValue: String?) -> Modifier {
    guard let raw = rawValue else { return .none }
    return Modifier(rawValue: raw) ?? .none
  }
}

// MARK: - Operation

/// User-facing operation. Identifies what the caller is asking the engine to do,
/// independently of which model is chosen. `restore` is a v0 invention for
/// SeedVR2-class image super-resolution; the URL `/v1/restore` lands together
/// with the capability endpoint.
enum Operation: String, Codable, Sendable, CaseIterable {
  case txt2img, img2img, inpaint, edit
  case txt2vid, img2vid
  case restore
}

// MARK: - BehaviorClass

/// Quotient over `Architecture` (SDK `ModelVersion`) that groups variants
/// branching alike in the SDK switches. The capability map is keyed on
/// `(BehaviorClass, SamplerModifier)` — 20 image+video classes vs 30 raw
/// architectures. Adding a new `ModelVersion` upstream surfaces as a
/// compile-time error on `Architecture.behaviorClass`, not as silent drift.
enum BehaviorClass: String, Codable, Sendable, CaseIterable {
  // Image (15)
  case sd1x, kandinsky21, sdxl, stableCascade, sd3
  case pixart, auraflow, flux1, flux2, hidream
  case qwenImage, zImage, ernieImage, cosmos2, seedvr2

  // Video (5)
  case svdI2v, hunyuanVideo, wan21, wan22, ltx2
}

extension Architecture {
  /// Exhaustive switch — a new `ModelVersion` added in the SDK fails compile
  /// here. Returns `nil` for architectures that exist as engine stages but are
  /// not publicly callable as a base model: `sdxlRefiner` (refiner stage of an
  /// SDXL pipeline), `wurstchenStageB` (decoder stage of a Stable Cascade
  /// pipeline). Their `/v1/capabilities/{model_id}` returns an empty op set.
  var behaviorClass: BehaviorClass? {
    switch self {
    case .v1, .v2: return .sd1x
    case .kandinsky21: return .kandinsky21
    case .sdxlBase, .ssd1b: return .sdxl
    case .sdxlRefiner: return nil
    case .wurstchenStageC: return .stableCascade
    case .wurstchenStageB: return nil
    case .sd3, .sd3Large: return .sd3
    case .pixart: return .pixart
    case .auraflow: return .auraflow
    case .flux1: return .flux1
    case .flux2, .flux2_9b, .flux2_4b: return .flux2
    case .hiDreamI1: return .hidream
    case .qwenImage: return .qwenImage
    case .zImage: return .zImage
    case .ernieImage: return .ernieImage
    case .cosmos2_5_2b: return .cosmos2
    case .seedvr2_3b, .seedvr2_7b: return .seedvr2
    case .svdI2v: return .svdI2v
    case .hunyuanVideo: return .hunyuanVideo
    case .wan21_1_3b, .wan21_14b: return .wan21
    case .wan22_5b: return .wan22
    case .ltx2, .ltx2_3: return .ltx2
    }
  }
}

// MARK: - FieldConstraint

/// Per-field constraint published in `accepted[field]` of a contract. Enum by
/// kind so the Swift API can't express nonsensical combinations
/// (`min` on a `string` would be a type error). The Codable conformance
/// flattens to a single JSON object `{"type": ..., <kind-specific keys>}`.
enum FieldConstraint: Sendable, Equatable {
  case bool(required: Bool = false)
  case int(min: Int? = nil, max: Int? = nil, multipleOf: Int? = nil, required: Bool = false)
  case int64(min: Int64? = nil, max: Int64? = nil, required: Bool = false)
  case float(
    min: Double? = nil, max: Double? = nil,
    exclusiveMin: Bool = false, exclusiveMax: Bool = false,
    required: Bool = false)
  case string(maxLength: Int? = nil, enumValues: [String]? = nil, required: Bool = false)
  case base64(required: Bool = false)
  case array(itemsRef: String, required: Bool = false)
  case object(ref: String, required: Bool = false)
}

extension FieldConstraint: Codable {
  private enum Kind: String, Codable {
    case bool, int, int64, float, string, base64, array, object
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case min, max
    case multipleOf = "multiple_of"
    case exclusiveMin = "exclusive_min"
    case exclusiveMax = "exclusive_max"
    case maxLength = "max_length"
    case enumValues = "enum"
    case itemsRef = "items_ref"
    case ref
    case required
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .bool(let required):
      try c.encode(Kind.bool, forKey: .type)
      if required { try c.encode(true, forKey: .required) }
    case .int(let min, let max, let multipleOf, let required):
      try c.encode(Kind.int, forKey: .type)
      try c.encodeIfPresent(min, forKey: .min)
      try c.encodeIfPresent(max, forKey: .max)
      try c.encodeIfPresent(multipleOf, forKey: .multipleOf)
      if required { try c.encode(true, forKey: .required) }
    case .int64(let min, let max, let required):
      try c.encode(Kind.int64, forKey: .type)
      try c.encodeIfPresent(min, forKey: .min)
      try c.encodeIfPresent(max, forKey: .max)
      if required { try c.encode(true, forKey: .required) }
    case .float(let min, let max, let exMin, let exMax, let required):
      try c.encode(Kind.float, forKey: .type)
      try c.encodeIfPresent(min, forKey: .min)
      try c.encodeIfPresent(max, forKey: .max)
      if exMin { try c.encode(true, forKey: .exclusiveMin) }
      if exMax { try c.encode(true, forKey: .exclusiveMax) }
      if required { try c.encode(true, forKey: .required) }
    case .string(let maxLength, let enumValues, let required):
      try c.encode(Kind.string, forKey: .type)
      try c.encodeIfPresent(maxLength, forKey: .maxLength)
      try c.encodeIfPresent(enumValues, forKey: .enumValues)
      if required { try c.encode(true, forKey: .required) }
    case .base64(let required):
      try c.encode(Kind.base64, forKey: .type)
      if required { try c.encode(true, forKey: .required) }
    case .array(let itemsRef, let required):
      try c.encode(Kind.array, forKey: .type)
      try c.encode(itemsRef, forKey: .itemsRef)
      if required { try c.encode(true, forKey: .required) }
    case .object(let ref, let required):
      try c.encode(Kind.object, forKey: .type)
      try c.encode(ref, forKey: .ref)
      if required { try c.encode(true, forKey: .required) }
    }
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try c.decode(Kind.self, forKey: .type)
    let required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
    switch kind {
    case .bool:
      self = .bool(required: required)
    case .int:
      self = .int(
        min: try c.decodeIfPresent(Int.self, forKey: .min),
        max: try c.decodeIfPresent(Int.self, forKey: .max),
        multipleOf: try c.decodeIfPresent(Int.self, forKey: .multipleOf),
        required: required)
    case .int64:
      self = .int64(
        min: try c.decodeIfPresent(Int64.self, forKey: .min),
        max: try c.decodeIfPresent(Int64.self, forKey: .max),
        required: required)
    case .float:
      self = .float(
        min: try c.decodeIfPresent(Double.self, forKey: .min),
        max: try c.decodeIfPresent(Double.self, forKey: .max),
        exclusiveMin: try c.decodeIfPresent(Bool.self, forKey: .exclusiveMin) ?? false,
        exclusiveMax: try c.decodeIfPresent(Bool.self, forKey: .exclusiveMax) ?? false,
        required: required)
    case .string:
      self = .string(
        maxLength: try c.decodeIfPresent(Int.self, forKey: .maxLength),
        enumValues: try c.decodeIfPresent([String].self, forKey: .enumValues),
        required: required)
    case .base64:
      self = .base64(required: required)
    case .array:
      self = .array(
        itemsRef: try c.decode(String.self, forKey: .itemsRef),
        required: required)
    case .object:
      self = .object(
        ref: try c.decode(String.self, forKey: .ref),
        required: required)
    }
  }
}

// MARK: - Silent drops / refused entries

struct SilentDrop: Codable, Sendable, Equatable {
  let field: String
  let reason: String
}

struct Refused: Codable, Sendable, Equatable {
  let field: String
  let errorCode: String

  enum CodingKeys: String, CodingKey {
    case field
    case errorCode = "error_code"
  }
}

// MARK: - Contract template + Contract (wire)

/// Static, model-agnostic part of a contract. Stored in the capability map.
/// `model_id` / `engine_version` / `behavior_class` / `modifier` are injected
/// at serialization time when the caller asks for a concrete model's contract.
struct ContractTemplate: Sendable, Equatable {
  let accepted: [String: FieldConstraint]
  let silentDrops: [SilentDrop]
  let refused: [Refused]
  let notes: [String]

  init(
    accepted: [String: FieldConstraint] = [:],
    silentDrops: [SilentDrop] = [],
    refused: [Refused] = [],
    notes: [String] = []
  ) {
    self.accepted = accepted
    self.silentDrops = silentDrops
    self.refused = refused
    self.notes = notes
  }
}

/// Minimal valid request body for a given Operation — one hand-written entry
/// per Operation in `CapabilityMap.examplesByOperation`. Carries the target
/// endpoint (`/v1/compose`, `/v1/edit`, or `/v1/restore`) and the JSON body
/// to POST. Lets agents copy, substitute placeholders, send.
struct ContractExample: Codable, Sendable, Equatable {
  let endpoint: String
  let body: JSONValue
}

/// Serializable contract returned by `GET /v1/capabilities/{model_id}`.
struct Contract: Codable, Sendable, Equatable {
  let modelId: String
  let operation: Operation
  let engineVersion: String
  let behaviorClass: BehaviorClass
  let modifier: String
  let accepted: [String: FieldConstraint]
  let silentDrops: [SilentDrop]
  let refused: [Refused]
  let notes: [String]
  /// Hand-written minimal valid request body for this operation. Injected
  /// at serialization time from `CapabilityMap.example(for:)`. Optional
  /// because we may add Operations before adding their examples — agents
  /// fall back to the `accepted` schema.
  let example: ContractExample?

  enum CodingKeys: String, CodingKey {
    case modelId = "model_id"
    case operation
    case engineVersion = "engine_version"
    case behaviorClass = "behavior_class"
    case modifier
    case accepted
    case silentDrops = "silent_drops"
    case refused
    case notes
    case example
  }
}

// MARK: - The map

/// `(BehaviorClass, SamplerModifier)` → operations supported, with the static
/// template per op. The table itself is the v0 hand-transcribed source of
/// truth; cells are filled in `CapabilityMap+Cells.swift` to keep this file
/// focused on the types and the lookup mechanics.
enum CapabilityMap {
  /// Looks up the operations supported by a `(class, modifier)` cell and
  /// returns the per-operation template. Empty dictionary for cells that have
  /// no public surface (`sdxlRefiner` standalone, `wurstchenStageB`, etc.).
  static func contracts(
    behaviorClass: BehaviorClass,
    modifier: Modifier
  ) -> [Operation: ContractTemplate] {
    cells[Key(behaviorClass: behaviorClass, modifier: modifier)] ?? [:]
  }

  struct Key: Hashable, Sendable {
    let behaviorClass: BehaviorClass
    let modifier: Modifier
  }

  /// v0 hand-transcribed source of truth. Defined in
  /// `CapabilityMap+Cells.swift`. A `(class, modifier)` absent from the dict
  /// resolves to no supported operations.
  static let cells: [Key: [Operation: ContractTemplate]] = capabilityCells
}

extension CapabilityMap {
  /// Asserts that the model supports the requested operation. Throws an
  /// `EngineError` with the most informative code for the situation,
  /// preserving the prior error codes:
  /// - `baseModelNotInstalled` when the catalog has no spec for the id,
  /// - `domainMismatch` when the model's domain doesn't match the op's,
  /// - `notAnInstructionEditModel` on `.edit` with a non-instruction-edit model,
  /// - `editingModelRequiresEditEndpoint` on `.img2img` with an instruction-edit model,
  /// - `operationNotSupportedForModel` for the generic fallback (e.g. `.txt2img`
  ///   on a `.canny` base model — that model's cell lists only `.img2img`).
  ///
  /// Consolidates the prior `verifyDomain` / `verifyInstructionEditModel` /
  /// `rejectInstructionEditModel` checks behind a single contract lookup.
  static func assertSupported(modelId: String, operation: Operation) throws {
    guard let response = response(forModelId: modelId) else {
      throw EngineError.baseModelNotInstalled(id: modelId)
    }
    if response.operations.contains(where: { $0.operation == operation }) {
      return
    }

    // Op not supported. Pick the most informative error code.

    let opDomain: Domain =
      (operation == .txt2vid || operation == .img2vid) ? .video : .image
    if let arch = Architecture(rawValue: response.architecture),
      arch.domain != opDomain
    {
      throw EngineError.domainMismatch(
        baseModelId: modelId,
        baseDomain: arch.domain.rawValue,
        requestedDomain: opDomain.rawValue)
    }

    let editingMode = ModelZoo.specificationForModel(modelId)
      .flatMap { EditingMode(modifier: $0.modifier?.rawValue) }
    if operation == .edit {
      throw EngineError.notAnInstructionEditModel(
        baseModelId: modelId, editingMode: editingMode?.rawValue)
    }
    if operation == .img2img, editingMode == .instructionEdit {
      throw EngineError.editingModelRequiresEditEndpoint(baseModelId: modelId)
    }

    // Generic fallback: cell exists, op not in its list, none of the
    // specific cases above apply (e.g. /v1/txt2img on a .canny model).
    let supported = response.operations.map { $0.operation.rawValue }.sorted()
    throw EngineError.operationNotSupportedForModel(
      baseModelId: modelId,
      operation: operation.rawValue,
      supportedOperations: supported)
  }

  /// Resolves a model_id to its full capabilities response. Returns `nil`
  /// when the catalog has no spec for the id (route layer maps that to a
  /// 404 MODEL_NOT_INSTALLED). All other states (unknown arch, non-callable
  /// arch, empty cell) yield a 200 response with `operations: []` and a
  /// human-readable `notes` line explaining why.
  static func response(forModelId modelId: String) -> CapabilitiesResponse? {
    guard let spec = ModelZoo.specificationForModel(modelId) else { return nil }
    let archRaw = spec.version.rawValue
    let modifierRaw = spec.modifier?.rawValue ?? "none"

    guard let arch = Architecture(rawValue: archRaw) else {
      return CapabilitiesResponse(
        modelId: modelId,
        engineVersion: dhtEngineVersion,
        architecture: archRaw,
        behaviorClass: nil,
        modifier: modifierRaw,
        operations: [],
        notes: [
          "Architecture '\(archRaw)' is not yet mirrored on the DHT side; capabilities cannot be resolved.",
        ])
    }
    let modifier = Modifier.from(rawValue: spec.modifier?.rawValue)
    guard let behaviorClass = arch.behaviorClass else {
      return CapabilitiesResponse(
        modelId: modelId,
        engineVersion: dhtEngineVersion,
        architecture: archRaw,
        behaviorClass: nil,
        modifier: modifier.rawValue,
        operations: [],
        notes: [
          "Architecture '\(archRaw)' is an engine stage that is not directly callable as a base model (e.g. SDXL refiner, Stable Cascade decoder).",
        ])
    }
    let templates = contracts(behaviorClass: behaviorClass, modifier: modifier)
    if templates.isEmpty {
      return CapabilitiesResponse(
        modelId: modelId,
        engineVersion: dhtEngineVersion,
        architecture: archRaw,
        behaviorClass: behaviorClass,
        modifier: modifier.rawValue,
        operations: [],
        notes: [
          "No capability contract defined for (\(behaviorClass.rawValue), \(modifier.rawValue)) in v0.",
        ])
    }
    let ops = templates.map { op, template in
      Contract(
        modelId: modelId,
        operation: op,
        engineVersion: dhtEngineVersion,
        behaviorClass: behaviorClass,
        modifier: modifier.rawValue,
        accepted: template.accepted,
        silentDrops: template.silentDrops,
        refused: template.refused,
        notes: template.notes,
        example: CapabilityMap.example(for: op))
    }.sorted { $0.operation.rawValue < $1.operation.rawValue }
    return CapabilitiesResponse(
      modelId: modelId,
      engineVersion: dhtEngineVersion,
      architecture: archRaw,
      behaviorClass: behaviorClass,
      modifier: modifier.rawValue,
      operations: ops,
      notes: [])
  }
}

// MARK: - Capabilities response (wire)

/// Returned by `GET /v1/capabilities/{model_id}`. `behavior_class` is nullable
/// because some catalogued architectures (refiner / decoder stages) have no
/// publicly-callable BehaviorClass; in that case `operations` is empty and
/// `notes` explains why.
struct CapabilitiesResponse: Codable, Sendable {
  let modelId: String
  let engineVersion: String
  let architecture: String
  let behaviorClass: BehaviorClass?
  let modifier: String
  let operations: [Contract]
  let notes: [String]

  enum CodingKeys: String, CodingKey {
    case modelId = "model_id"
    case engineVersion = "engine_version"
    case architecture
    case behaviorClass = "behavior_class"
    case modifier
    case operations
    case notes
  }

  /// Encodes nil `behaviorClass` as JSON `null` (not as an absent key) so
  /// consumers see the field reliably in every response.
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(modelId, forKey: .modelId)
    try c.encode(engineVersion, forKey: .engineVersion)
    try c.encode(architecture, forKey: .architecture)
    if let behaviorClass {
      try c.encode(behaviorClass, forKey: .behaviorClass)
    } else {
      try c.encodeNil(forKey: .behaviorClass)
    }
    try c.encode(modifier, forKey: .modifier)
    try c.encode(operations, forKey: .operations)
    try c.encode(notes, forKey: .notes)
  }
}
