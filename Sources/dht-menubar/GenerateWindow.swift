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
  enum CodingKeys: String, CodingKey {
    case model, prompt, params
    case negativePrompt = "negative_prompt"
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
    didSet { invalidateResolve() }
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
  @Published var statusText: String?
  @Published var errorText: String?

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
        outputFormat: "png", loras: loraRefs()))

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
      let warnCount = decoded.warnings?.count ?? 0
      statusText = warnCount > 0
        ? "Resolved — \(warnCount) warning\(warnCount == 1 ? "" : "s"). Review, then Generate."
        : "Resolved. Review params, then Generate."
      resolved = true
    } catch {
      errorText = "Resolve request failed: \(error.localizedDescription)"
      resolved = false
    }
  }

  /// Generate. `reuseSeed` re-runs with the previous seed for an identical
  /// image; otherwise the server randomizes and returns the seed it used.
  func generate(reuseSeed: Bool = false) async {
    guard !selectedModelID.isEmpty else { errorText = "Select a model first."; return }
    guard let url = URL(string: "\(endpoint)/v1/compose") else { return }
    isGenerating = true
    errorText = nil
    statusText = "Generating…"
    defer { isGenerating = false; statusText = nil }

    let seed: Int? = reuseSeed ? lastSeed.map(Int.init) : nil
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("image/png", forHTTPHeaderField: "Accept")  // raw bytes, not base64
    req.timeoutInterval = 600
    authorized(&req)
    req.httpBody = try? JSONEncoder().encode(composeBody(seed: seed))

    do {
      let (data, response) = try await URLSession.shared.data(for: req)
      let http = response as? HTTPURLResponse
      guard http?.statusCode == 200 else {
        let msg = (try? JSONDecoder().decode(GenErrorBody.self, from: data))
          .flatMap { $0.detail ?? $0.title }
        errorText = msg ?? "Generation failed (HTTP \(http?.statusCode ?? -1))."
        return
      }
      imageData = data
      if let raw = http?.value(forHTTPHeaderField: "X-DHT-Seed"), let s = Int64(raw) {
        lastSeed = s
      }
    } catch {
      errorText = "Request failed: \(error.localizedDescription)"
    }
  }

  // MARK: Request building (shared by generate + curl)

  private func loraRefs() -> [GenLoRARef]? {
    let refs = loraSlots
      .filter { !$0.loraID.isEmpty }
      .map { GenLoRARef(loraId: $0.loraID, weight: $0.weight) }
    return refs.isEmpty ? nil : refs
  }

  private func composeBody(seed: Int?) -> GenComposeBody {
    GenComposeBody(
      model: selectedModelID,
      prompt: prompt,
      negativePrompt: negativePrompt.isEmpty ? nil : negativePrompt,
      params: GenParams(
        width: format.width, height: format.height,
        steps: steps, cfgScale: cfgScale, sampler: sampler, seed: seed,
        outputFormat: "png", loras: loraRefs()))
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
}

// MARK: - View

struct GenerateView: View {
  @StateObject private var model = GenerateModel()

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
        Picker("Model", selection: $model.selectedModelID) {
          ForEach(model.models) { m in Text(m.displayName).tag(m.id) }
        }
        ForEach(model.loraSlots.indices, id: \.self) { i in
          Picker("LoRA \(i + 1)", selection: $model.loraSlots[i].loraID) {
            Text("None").tag("")
            ForEach(model.compatibleLoras) { l in Text(l.displayName).tag(l.id) }
          }
          if !model.loraSlots[i].loraID.isEmpty {
            HStack {
              Text("Weight").font(.caption).foregroundStyle(.secondary)
              Slider(value: $model.loraSlots[i].weight, in: 0...1.5)
              Text(String(format: "%.2f", model.loraSlots[i].weight))
                .monospacedDigit().frame(width: 40, alignment: .trailing)
            }
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

  private var resultColumn: some View {
    VStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 8)
          .fill(Color(nsColor: .underPageBackgroundColor))
        if let data = model.imageData, let image = NSImage(data: data) {
          Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .padding(6)
        } else {
          VStack(spacing: 6) {
            Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("The generated image appears here").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      HStack {
        if let seed = model.lastSeed {
          Text("seed: \(String(seed))").font(.caption).monospacedDigit().textSelection(.enabled)
          Button("Reuse") { Task { await model.generate(reuseSeed: true) } }
            .controlSize(.small).disabled(model.isGenerating)
        }
        Spacer()
        Button("Save…") { model.save() }
          .disabled(model.imageData == nil)
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
