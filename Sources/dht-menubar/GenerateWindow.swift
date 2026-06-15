import AppKit
import SwiftUI
import UniformTypeIdentifiers

// A minimal txt2img panel: a visual builder for the `POST /v1/compose`
// request plus a view of the result. It is, in essence, a curl generator —
// hence the "Copy as curl" button. The generated image lives only in memory
// (an in-window `Data`); it touches disk only when the user clicks Save.

// MARK: - Wire models (mirror the server's JSON for the few fields we use)

/// One installed asset, as returned by `GET /v1/assets`. We only decode the
/// fields the panel needs; everything else in the payload is ignored.
struct GenAsset: Decodable, Identifiable, Hashable {
  let id: String
  let name: String?
  let architecture: String?            // base_model
  let compatibleArchitecture: String?  // lora
  let weightRange: GenWeightRange?     // lora

  var displayName: String { (name?.isEmpty == false) ? name! : id }

  enum CodingKeys: String, CodingKey {
    case id, name, architecture
    case compatibleArchitecture = "compatible_architecture"
    case weightRange = "weight_range"
  }
}

struct GenWeightRange: Decodable, Hashable {
  let lower: Double
  let upper: Double
  let recommended: Double
}

private struct GenAssetList: Decodable { let items: [GenAsset] }

/// Subset of `POST /v1/resolve/compose`'s reply — just the resolved params
/// we surface in the Advanced section.
private struct GenResolveResponse: Decodable {
  let resolvedRequest: GenResolvedRecipe?
  let errors: [GenDiagnostic]?
  let warnings: [GenDiagnostic]?
  enum CodingKeys: String, CodingKey {
    case resolvedRequest = "resolved_request"
    case errors, warnings
  }
}
private struct GenDiagnostic: Decodable { let code: String?; let message: String? }
private struct GenResolvedRecipe: Decodable { let params: GenResolvedParams? }
private struct GenResolvedParams: Decodable {
  let steps: Int?
  let cfgScale: Double?
  let sampler: String?
  enum CodingKeys: String, CodingKey { case steps, sampler; case cfgScale = "cfg_scale" }
}

/// `POST /v1/compose` body. `model`/`prompt`/`negative_prompt` are top-level;
/// the rest lives under `params` (mirrors `ComposeRequest` + `EngineParams`).
private struct GenComposeBody: Encodable {
  let model: String
  let prompt: String
  let negativePrompt: String?
  let params: GenParams
  /// Client-supplied run id so the panel can poll progress / preview and
  /// cancel without waiting for the response. Omitted for resolve / curl.
  let runId: String?
  enum CodingKeys: String, CodingKey {
    case model, prompt, params
    case negativePrompt = "negative_prompt"
    case runId = "run_id"
  }
}
private struct GenParams: Encodable {
  let width: Int
  let height: Int
  var steps: Int?
  var cfgScale: Double?
  var sampler: String?
  var seed: Int?
  var outputFormat: String?
  var loras: [GenLoRARef]?
  enum CodingKeys: String, CodingKey {
    case width, height, steps, sampler, seed, loras
    case cfgScale = "cfg_scale"
    case outputFormat = "output_format"
  }
}
private struct GenLoRARef: Encodable {
  let loraId: String
  let weight: Double
  enum CodingKeys: String, CodingKey { case loraId = "lora_id"; case weight }
}

/// `POST /v1/assets/install` body for a local-file import (LoRA or base model).
private struct GenInstallBody: Encodable {
  let source: Source
  let confirmLargeDownload: Bool
  struct Source: Encodable {
    let type = "local_file"
    let assetType: String
    let path: String
    let name: String?
    /// Architecture hint. For a LoRA we pass the selected model's so the
    /// imported LoRA is tagged compatible and auto-detection never has to
    /// guess; for a base model the importer auto-detects, so we leave it nil.
    let architecture: String?
    enum CodingKeys: String, CodingKey {
      case type, path, name, architecture
      case assetType = "asset_type"
    }
  }
  enum CodingKeys: String, CodingKey {
    case source
    case confirmLargeDownload = "confirm_large_download"
  }
}

/// A typed error body (`{ detail, title, ... }`) for failed requests.
private struct GenErrorBody: Decodable {
  let title: String?
  let detail: String?
}

/// One configurable LoRA slot in the form. Up to 3 chain together; an empty
/// `loraID` means the slot is unused.
struct LoraSlot {
  var loraID = ""
  var weight = 1.0
}

// MARK: - Image format presets

enum GenFormat: String, CaseIterable, Identifiable {
  case square = "Square (1024×1024)"
  case portrait = "Portrait (832×1216)"
  case landscape = "Landscape (1216×832)"

  var id: String { rawValue }

  var width: Int {
    switch self {
    case .square: return 1024
    case .portrait: return 832
    case .landscape: return 1216
    }
  }
  var height: Int {
    switch self {
    case .square: return 1024
    case .portrait: return 1216
    case .landscape: return 832
    }
  }
}

// MARK: - View model

@MainActor
final class GenerateModel: ObservableObject {
  // Catalog
  @Published var models: [GenAsset] = []
  @Published var loras: [GenAsset] = []

  // Form. Changes to model / format / LoRA invalidate a prior resolve (the
  // defaults and validation depend on them); prompt / negative / advanced do
  // not, so editing them never silently re-runs resolve over your overrides.
  @Published var selectedModelID = "" { didSet { onModelChange() } }
  /// Up to 3 chained LoRA slots, each independently configurable.
  @Published var loraSlots: [LoraSlot] = [LoraSlot(), LoraSlot(), LoraSlot()] {
    didSet {
      // Only a selection change invalidates the resolve — dragging a weight
      // slider (an override, like the advanced fields) must not.
      if loraSlots.map(\.loraID) != oldValue.map(\.loraID) { invalidateResolve() }
    }
  }
  @Published var prompt = ""
  @Published var negativePrompt = ""
  @Published var format: GenFormat = .square { didSet { invalidateResolve() } }

  // Advanced (pre-filled by resolve, user-editable)
  @Published var steps = 20
  @Published var cfgScale = 7.0
  @Published var sampler = "euler_a"

  // Result (in memory only)
  @Published var imageData: Data?
  @Published var lastSeed: Int64?
  /// True once a resolve succeeded for the current model/format/LoRA: the
  /// primary button reads "Generate"; otherwise "Resolve".
  @Published var resolved = false
  @Published var isGenerating = false
  @Published var isResolving = false
  @Published var isImportingLoRA = false
  @Published var isImportingModel = false
  @Published var statusText: String?
  @Published var errorText: String?
  /// Non-fatal resolve observations shown verbatim (e.g. "this model ignores cfg").
  @Published var warnings: [String] = []
  // Live progress for the in-flight generation (polled from /v1/runs/{id}).
  @Published var genCurrentStep = 0
  @Published var genTotalSteps = 0
  @Published var previewData: Data?
  private var currentRunID: String?
  private var wasCancelled = false

  /// All sampler ids the engine accepts (`SamplerAPI`). The resolved sampler
  /// is always one of these, so the picker never shows an unknown value.
  static let samplers = [
    "dpmpp_2m_karras", "euler_a", "ddim", "plms", "dpmpp_sde_karras", "unipc", "lcm",
    "euler_a_substep", "dpmpp_sde_substep", "tcd", "euler_a_trailing", "dpmpp_sde_trailing",
    "dpmpp_2m_ays", "euler_a_ays", "dpmpp_sde_ays", "dpmpp_2m_trailing", "ddim_trailing",
    "unipc_trailing", "unipc_ays", "tcd_trailing",
  ]

  private var endpoint: String { ServerController.shared.endpoint }
  private var token: String { ServerController.shared.apiToken }

  var selectedModel: GenAsset? { models.first { $0.id == selectedModelID } }

  /// LoRAs whose architecture matches the selected base model — applying a
  /// mismatched LoRA is silently dropped by the engine, so we don't offer it.
  var compatibleLoras: [GenAsset] {
    guard let arch = selectedModel?.architecture else { return [] }
    return loras.filter { $0.compatibleArchitecture == arch }
  }

  func loraAsset(_ id: String) -> GenAsset? { loras.first { $0.id == id } }

  /// Weight band for a slot's chosen LoRA — its catalog `weight_range` if
  /// known, else a sensible default. Used to bound the slider.
  func weightRange(forSlot i: Int) -> ClosedRange<Double> {
    if let r = loraAsset(loraSlots[i].loraID)?.weightRange, r.lower < r.upper {
      return r.lower...r.upper
    }
    return 0...1.5
  }

  /// On selecting a LoRA, seed its slot with the catalog-recommended weight.
  func applyRecommendedWeight(slot i: Int) {
    guard let r = loraAsset(loraSlots[i].loraID)?.weightRange else { return }
    loraSlots[i].weight = r.recommended
  }

  // MARK: Networking

  private func authorized(_ req: inout URLRequest) {
    if !token.isEmpty {
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
  }

  /// Fetch installed base models + LoRAs (downloaded only) for the dropdowns.
  func loadAssets() async {
    async let baseModels = fetchAssets(type: "base_model")
    async let loraList = fetchAssets(type: "lora")
    let (m, l) = await (baseModels, loraList)
    models = m
    loras = l
    if selectedModelID.isEmpty, let first = m.first {
      selectedModelID = first.id  // triggers onModelChange → resolve
    }
  }

  private func fetchAssets(type: String) async -> [GenAsset] {
    guard let url = URL(string: "\(endpoint)/v1/assets?type=\(type)&downloaded=true") else {
      return []
    }
    var req = URLRequest(url: url)
    req.timeoutInterval = 5
    authorized(&req)
    do {
      let (data, _) = try await URLSession.shared.data(for: req)
      return (try? JSONDecoder().decode(GenAssetList.self, from: data))?.items ?? []
    } catch {
      return []
    }
  }

  /// Pick a local LoRA file and import it (`POST /v1/assets/install`,
  /// `local_file` / `lora`), then refresh the LoRA list and select it.
  func importLoRA() async {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Import"
    let types = ["safetensors", "ckpt"].compactMap { UTType(filenameExtension: $0) }
    if !types.isEmpty { panel.allowedContentTypes = types }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    await installLoRA(from: url)
  }

  private func installLoRA(from url: URL) async {
    guard let endpointURL = URL(string: "\(endpoint)/v1/assets/install") else { return }
    isImportingLoRA = true
    errorText = nil
    statusText = "Importing LoRA…"
    defer { isImportingLoRA = false }

    let body = GenInstallBody(
      source: .init(
        assetType: "lora",
        path: url.path,
        name: url.deletingPathExtension().lastPathComponent,
        architecture: selectedModel?.architecture),
      confirmLargeDownload: true)

    var req = URLRequest(url: endpointURL)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 120
    authorized(&req)
    req.httpBody = try? JSONEncoder().encode(body)

    do {
      let (data, response) = try await URLSession.shared.data(for: req)
      let http = response as? HTTPURLResponse
      guard http?.statusCode == 200, let asset = try? JSONDecoder().decode(GenAsset.self, from: data)
      else {
        let msg = (try? JSONDecoder().decode(GenErrorBody.self, from: data))
          .flatMap { $0.detail ?? $0.title }
        errorText = msg ?? "LoRA import failed (HTTP \(http?.statusCode ?? -1))."
        statusText = nil
        return
      }
      // Refresh the catalog, then drop the new LoRA into the first free slot.
      loras = await fetchAssets(type: "lora")
      if compatibleLoras.contains(where: { $0.id == asset.id }),
        let i = loraSlots.firstIndex(where: { $0.loraID.isEmpty }) {
        loraSlots[i].loraID = asset.id
      }
      statusText = "Imported \(asset.displayName)."
    } catch {
      errorText = "LoRA import request failed: \(error.localizedDescription)"
      statusText = nil
    }
  }

  /// Pick a local checkpoint and import it as a base model
  /// (`POST /v1/assets/install`, `local_file` / `base_model`), then refresh
  /// the model list and select it.
  func importModel() async {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Import"
    let types = ["safetensors", "ckpt"].compactMap { UTType(filenameExtension: $0) }
    if !types.isEmpty { panel.allowedContentTypes = types }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    await installModel(from: url)
  }

  private func installModel(from url: URL) async {
    guard let endpointURL = URL(string: "\(endpoint)/v1/assets/install") else { return }
    isImportingModel = true
    errorText = nil
    statusText = "Importing model… (conversion can take a few minutes)"
    defer { isImportingModel = false }

    // The importer auto-detects the architecture, so no hint is sent.
    let body = GenInstallBody(
      source: .init(
        assetType: "base_model",
        path: url.path,
        name: url.deletingPathExtension().lastPathComponent,
        architecture: nil),
      confirmLargeDownload: true)

    var req = URLRequest(url: endpointURL)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // Base-model conversion is heavy (minutes for a large model) and the call
    // is synchronous, so give it a generous ceiling.
    req.timeoutInterval = 1800
    authorized(&req)
    req.httpBody = try? JSONEncoder().encode(body)

    do {
      let (data, response) = try await URLSession.shared.data(for: req)
      let http = response as? HTTPURLResponse
      guard http?.statusCode == 200, let asset = try? JSONDecoder().decode(GenAsset.self, from: data)
      else {
        let msg = (try? JSONDecoder().decode(GenErrorBody.self, from: data))
          .flatMap { $0.detail ?? $0.title }
        errorText = msg ?? "Model import failed (HTTP \(http?.statusCode ?? -1))."
        statusText = nil
        return
      }
      // Refresh the catalog and select the freshly imported model.
      models = await fetchAssets(type: "base_model")
      if models.contains(where: { $0.id == asset.id }) {
        selectedModelID = asset.id  // triggers onModelChange → resolve
      }
      statusText = "Imported \(asset.displayName)."
    } catch {
      errorText = "Model import request failed: \(error.localizedDescription)"
      statusText = nil
    }
  }

  private func onModelChange() {
    // Drop any LoRA selections incompatible with the new model (this mutates
    // loraSlots, which itself invalidates the resolve via its didSet).
    let valid = Set(compatibleLoras.map { $0.id })
    for i in loraSlots.indices where !loraSlots[i].loraID.isEmpty
      && !valid.contains(loraSlots[i].loraID) {
      loraSlots[i].loraID = ""
    }
    invalidateResolve()
  }

  /// Mark the resolved state stale → primary button reverts to "Resolve".
  private func invalidateResolve() {
    resolved = false
    warnings = []
  }

  /// The primary button: resolve first, then (once resolved cleanly) generate.
  func primaryAction() async {
    if resolved {
      await generate()
    } else {
      await resolveDefaults()
    }
  }

  /// Dry-run the request with no advanced params set, so the engine reports
  /// the per-model defaults — mirror them into the Advanced fields, surface
  /// errors/warnings, and flip `resolved` so the button becomes "Generate".
  func resolveDefaults() async {
    guard !selectedModelID.isEmpty else { return }
    guard let url = URL(string: "\(endpoint)/v1/resolve/compose") else { return }
    isResolving = true
    errorText = nil
    statusText = nil
    defer { isResolving = false }

    let body = GenComposeBody(
      model: selectedModelID,
      prompt: prompt,
      negativePrompt: negativePrompt.isEmpty ? nil : negativePrompt,
      params: GenParams(
        width: format.width, height: format.height,
        steps: nil, cfgScale: nil, sampler: nil, seed: nil,
        outputFormat: "png", loras: loraRefs()),
      runId: nil)

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    authorized(&req)
    req.httpBody = try? JSONEncoder().encode(body)

    do {
      let (data, response) = try await URLSession.shared.data(for: req)
      let http = response as? HTTPURLResponse
      guard http?.statusCode == 200,
        let decoded = try? JSONDecoder().decode(GenResolveResponse.self, from: data)
      else {
        errorText = "Resolve failed (HTTP \(http?.statusCode ?? -1))."
        resolved = false
        return
      }
      // Errors mean the request won't generate — stay on "Resolve".
      if let first = decoded.errors?.first {
        errorText = first.message ?? first.code ?? "Resolve reported an error."
        resolved = false
        return
      }
      if let params = decoded.resolvedRequest?.params {
        if let s = params.steps { steps = s }
        if let c = params.cfgScale { cfgScale = c }
        if let smp = params.sampler, Self.samplers.contains(smp) { sampler = smp }
      }
      warnings = decoded.warnings?.compactMap { $0.message ?? $0.code } ?? []
      statusText = "Resolved. Review params, then Generate."
      resolved = true
    } catch {
      errorText = "Resolve request failed: \(error.localizedDescription)"
      resolved = false
    }
  }

  /// Generate. `reuseSeed` re-runs with the previous seed for an identical
  /// image; otherwise the server randomizes and returns the seed it used.
  /// A client-supplied run id lets us poll live progress / preview and cancel.
  func generate(reuseSeed: Bool = false) async {
    guard !selectedModelID.isEmpty else { errorText = "Select a model first."; return }
    guard let url = URL(string: "\(endpoint)/v1/compose") else { return }
    let runID = uuid()
    currentRunID = runID
    wasCancelled = false
    isGenerating = true
    errorText = nil
    statusText = "Generating…"
    genCurrentStep = 0
    genTotalSteps = 0
    previewData = nil
    // Poll progress + live preview concurrently with the (blocking) compose.
    let poll = Task { await pollProgress(runID: runID) }
    defer {
      poll.cancel()
      isGenerating = false
      statusText = nil
      currentRunID = nil
      previewData = nil
    }

    let seed: Int? = reuseSeed ? lastSeed.map(Int.init) : nil
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("image/png", forHTTPHeaderField: "Accept")  // raw bytes, not base64
    req.timeoutInterval = 600
    authorized(&req)
    req.httpBody = try? JSONEncoder().encode(composeBody(seed: seed, runID: runID))

    do {
      let (data, response) = try await URLSession.shared.data(for: req)
      let http = response as? HTTPURLResponse
      guard http?.statusCode == 200 else {
        if wasCancelled {
          statusText = "Cancelled."
        } else {
          let msg = (try? JSONDecoder().decode(GenErrorBody.self, from: data))
            .flatMap { $0.detail ?? $0.title }
          errorText = msg ?? "Generation failed (HTTP \(http?.statusCode ?? -1))."
        }
        return
      }
      imageData = data
      if let raw = http?.value(forHTTPHeaderField: "X-DHT-Seed"), let s = Int64(raw) {
        lastSeed = s
      }
    } catch {
      if wasCancelled { statusText = "Cancelled." } else {
        errorText = "Request failed: \(error.localizedDescription)"
      }
    }
  }

  /// Cancel the in-flight generation (`DELETE /v1/runs/{id}`); the compose
  /// request then returns and `generate()` reports "Cancelled".
  func cancel() async {
    guard let id = currentRunID,
      let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "\(endpoint)/v1/runs/\(encoded)")
    else { return }
    wasCancelled = true
    var req = URLRequest(url: url)
    req.httpMethod = "DELETE"
    authorized(&req)
    _ = try? await URLSession.shared.data(for: req)
  }

  /// Poll `/v1/runs/{id}` ~1.5×/s for step progress + the live preview frame,
  /// until the surrounding generate() cancels this task.
  private func pollProgress(runID: String) async {
    guard let encoded = runID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "\(endpoint)/v1/runs/\(encoded)")
    else { return }
    while !Task.isCancelled {
      var req = URLRequest(url: url)
      req.timeoutInterval = 2
      authorized(&req)
      if let (data, _) = try? await URLSession.shared.data(for: req),
        let detail = try? JSONDecoder().decode(RunDetail.self, from: data) {
        genCurrentStep = detail.currentStep
        genTotalSteps = detail.totalSteps
        if let b64 = detail.previewPngBase64, let png = Data(base64Encoded: b64) {
          previewData = png
        }
      }
      try? await Task.sleep(nanoseconds: 700_000_000)
    }
  }

  /// Foundation `UUID()` wrapped so the call site reads intent, not ceremony.
  private func uuid() -> String { UUID().uuidString }

  // MARK: Request building (shared by generate + curl)

  private func loraRefs() -> [GenLoRARef]? {
    let refs = loraSlots
      .filter { !$0.loraID.isEmpty }
      .map { GenLoRARef(loraId: $0.loraID, weight: $0.weight) }
    return refs.isEmpty ? nil : refs
  }

  private func composeBody(seed: Int?, runID: String? = nil) -> GenComposeBody {
    GenComposeBody(
      model: selectedModelID,
      prompt: prompt,
      negativePrompt: negativePrompt.isEmpty ? nil : negativePrompt,
      params: GenParams(
        width: format.width, height: format.height,
        steps: steps, cfgScale: cfgScale, sampler: sampler, seed: seed,
        outputFormat: "png", loras: loraRefs()),
      runId: runID)
  }

  /// The exact `curl` for the current form — the panel's reason to exist as a
  /// "curl generator". Mirrors `generate()`: binary Accept, `-o out.png`.
  func curlCommand() -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let bodyData = (try? enc.encode(composeBody(seed: lastSeed.map(Int.init)))) ?? Data()
    let json = String(data: bodyData, encoding: .utf8) ?? "{}"
    var lines = ["curl -X POST \(endpoint)/v1/compose \\"]
    lines.append("  -H 'content-type: application/json' \\")
    lines.append("  -H 'accept: image/png' \\")
    if !token.isEmpty {
      lines.append("  -H 'authorization: Bearer \(token)' \\")
    }
    // Single-quote the JSON for the shell; escape any embedded single quotes.
    let shellJSON = json.replacingOccurrences(of: "'", with: "'\\''")
    lines.append("  -d '\(shellJSON)' \\")
    lines.append("  -o out.png")
    return lines.joined(separator: "\n")
  }

  func copyCurl() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(curlCommand(), forType: .string)
    statusText = "curl copied to clipboard"
  }

  /// Save the in-memory PNG to a user-chosen location. The only path to disk.
  func save() {
    guard let data = imageData else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "generated.png"
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url {
      try? data.write(to: url)
    }
  }

  /// Copy the result image to the clipboard.
  func copyImage() {
    guard let data = imageData, let image = NSImage(data: data) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
    statusText = "Image copied to clipboard"
  }

  /// Open the result full-size in the default viewer (Preview) via a temp file.
  func openImage() {
    guard let url = writeTempPNG() else { return }
    NSWorkspace.shared.open(url)
  }

  private func writeTempPNG() -> URL? {
    guard let data = imageData else { return nil }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dht-generated-\(uuid()).png")
    try? data.write(to: url)
    return url
  }
}

// MARK: - View

struct GenerateView: View {
  @StateObject private var model = GenerateModel()

  // Trackpad pinch-to-zoom + drag-to-pan on the result image.
  @State private var zoom: CGFloat = 1
  @State private var pan: CGSize = .zero
  @GestureState private var pinch: CGFloat = 1
  @GestureState private var dragPan: CGSize = .zero

  var body: some View {
    HSplitView {
      formColumn
        .frame(minWidth: 320, idealWidth: 360)
      resultColumn
        .frame(minWidth: 320)
    }
    .task { await model.loadAssets() }
  }

  private var formColumn: some View {
    Form {
      Section("Model") {
        if model.models.isEmpty {
          Text("No base models installed. Install one (the catalog, "
               + "POST /v1/assets/install, or Import Model… below), then it appears here.")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          Picker("Model", selection: $model.selectedModelID) {
            ForEach(model.models) { m in Text(m.displayName).tag(m.id) }
          }
          ForEach(model.loraSlots.indices, id: \.self) { i in
            Picker("LoRA \(i + 1)", selection: $model.loraSlots[i].loraID) {
              Text("None").tag("")
              ForEach(model.compatibleLoras) { l in Text(l.displayName).tag(l.id) }
            }
            .onChange(of: model.loraSlots[i].loraID) { model.applyRecommendedWeight(slot: i) }
            if !model.loraSlots[i].loraID.isEmpty {
              HStack {
                Text("Weight").font(.caption).foregroundStyle(.secondary)
                Slider(value: $model.loraSlots[i].weight, in: model.weightRange(forSlot: i))
                Text(String(format: "%.2f", model.loraSlots[i].weight))
                  .monospacedDigit().frame(width: 40, alignment: .trailing)
              }
            }
          }
        }
        // Import controls. A base model can be imported even with an empty
        // catalog; a LoRA needs a selected model to tag it compatible.
        HStack {
          Button("Import Model…") { Task { await model.importModel() } }
            .disabled(model.isImportingModel || model.isImportingLoRA)
          if !model.models.isEmpty {
            Button("Import LoRA…") { Task { await model.importLoRA() } }
              .disabled(model.isImportingLoRA || model.isImportingModel)
          }
          if model.isImportingModel || model.isImportingLoRA {
            ProgressView().controlSize(.small)
          }
        }
      }

      Section("Prompt") {
        TextField("Prompt", text: $model.prompt, axis: .vertical)
          .lineLimit(2...5)
        TextField("Negative prompt", text: $model.negativePrompt, axis: .vertical)
          .lineLimit(1...3)
        Picker("Format", selection: $model.format) {
          ForEach(GenFormat.allCases) { f in Text(f.rawValue).tag(f) }
        }
      }

      Section {
        DisclosureGroup("Advanced (from resolve)") {
          HStack {
            Text("Steps")
            Spacer()
            TextField("", value: $model.steps, format: .number)
              .frame(width: 60).multilineTextAlignment(.trailing)
            Stepper("", value: $model.steps, in: 1...200).labelsHidden()
          }
          HStack {
            Text("CFG")
            Slider(value: $model.cfgScale, in: 0...30)
            Text(String(format: "%.1f", model.cfgScale))
              .monospacedDigit().frame(width: 40, alignment: .trailing)
          }
          Picker("Sampler", selection: $model.sampler) {
            ForEach(GenerateModel.samplers, id: \.self) { Text($0).tag($0) }
          }
        }
        if model.isResolving {
          Text("Resolving defaults…").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(model.warnings, id: \.self) { w in
          Label(w, systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
        }
      }

      Section {
        HStack {
          Button(action: { Task { await model.primaryAction() } }) {
            if model.isGenerating || model.isResolving {
              ProgressView().controlSize(.small)
            } else {
              Text(model.resolved ? "Generate" : "Resolve")
            }
          }
          .keyboardShortcut(.return, modifiers: [])
          .buttonStyle(.borderedProminent)
          .disabled(model.isGenerating || model.isResolving || model.selectedModelID.isEmpty)

          Button("Copy as curl") { model.copyCurl() }
            .disabled(model.selectedModelID.isEmpty)
        }
        if let status = model.statusText {
          Text(status).font(.caption).foregroundStyle(.secondary)
        }
        if let err = model.errorText {
          Label(err, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange)
        }
      }
    }
    .formStyle(.grouped)
  }

  /// What fills the image box: the live preview while generating, otherwise
  /// the final result.
  private var displayImageData: Data? {
    model.isGenerating ? model.previewData : model.imageData
  }

  /// Trackpad pinch → zoom (1×–8×). Live scale via `pinch`, committed to `zoom`.
  private var zoomGesture: some Gesture {
    MagnifyGesture()
      .updating($pinch) { value, state, _ in state = value.magnification }
      .onEnded { value in
        zoom = min(max(zoom * value.magnification, 1), 8)
        if zoom == 1 { pan = .zero }
      }
  }

  /// Drag to pan — only meaningful once zoomed in.
  private var panGesture: some Gesture {
    DragGesture()
      .updating($dragPan) { value, state, _ in if zoom > 1 { state = value.translation } }
      .onEnded { value in
        guard zoom > 1 else { return }
        pan.width += value.translation.width
        pan.height += value.translation.height
      }
  }

  private var resultColumn: some View {
    VStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 8)
          .fill(Color(nsColor: .underPageBackgroundColor))
        if let data = displayImageData, let image = NSImage(data: data) {
          Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(zoom * pinch)
            .offset(x: pan.width + dragPan.width, y: pan.height + dragPan.height)
            .gesture(zoomGesture)
            .simultaneousGesture(panGesture)
            .onTapGesture(count: 2) { withAnimation { zoom = 1; pan = .zero } }
            .padding(6)
        } else {
          VStack(spacing: 6) {
            Image(systemName: model.isGenerating ? "hourglass" : "photo")
              .font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(model.isGenerating ? "Generating…" : "The generated image appears here")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
      // Each new result (or a new run) starts back at fit.
      .onChange(of: model.imageData) { zoom = 1; pan = .zero }
      .onChange(of: model.isGenerating) { if model.isGenerating { zoom = 1; pan = .zero } }

      if model.isGenerating {
        VStack(spacing: 8) {
          if model.genTotalSteps > 0 {
            ProgressView(
              value: Double(min(model.genCurrentStep, model.genTotalSteps)),
              total: Double(model.genTotalSteps)
            ) {
              Text("step \(model.genCurrentStep) / \(model.genTotalSteps)").font(.caption2)
            }
          } else {
            ProgressView().controlSize(.small)
          }
          Button("Stop", role: .destructive) { Task { await model.cancel() } }
            .controlSize(.small)
        }
      } else {
        HStack {
          if let seed = model.lastSeed {
            Text("seed: \(String(seed))").font(.caption).monospacedDigit().textSelection(.enabled)
            Button("Reuse") { Task { await model.generate(reuseSeed: true) } }
              .controlSize(.small)
          }
          Spacer()
          Button("Copy") { model.copyImage() }.disabled(model.imageData == nil)
          Button("Open") { model.openImage() }.disabled(model.imageData == nil)
          Button("Save…") { model.save() }.disabled(model.imageData == nil)
        }
      }
    }
    .padding(12)
  }
}

// MARK: - Window controller (on-demand NSWindow, like the log window)

final class GenerateWindowController: NSObject, NSWindowDelegate {
  static let shared = GenerateWindowController()

  private var window: NSWindow?

  func show() {
    if let window {
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      return
    }
    let hosting = NSHostingController(rootView: GenerateView())
    let win = NSWindow(contentViewController: hosting)
    win.title = "DHT Server — Generate"
    win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    win.setContentSize(NSSize(width: 760, height: 560))
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
