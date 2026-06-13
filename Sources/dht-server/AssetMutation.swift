import Foundation
import ModelZoo
import _MediaGenerationKit

// MARK: - Install request schema

enum InstallSource: Sendable {
  case catalog(model: String)
  case localFile(type: AssetType, path: String, name: String?, architecture: Architecture?)
}

struct InstallAssetRequest: Decodable, Sendable {
  let source: InstallSource
  /// When the resolved install footprint exceeds the server's "large"
  /// threshold (default 5 GB) the install is gated by `412
  /// LARGE_MODEL_DOWNLOAD` unless this flag is `true`. The flag is an
  /// explicit "yes I've seen the size and want to proceed" — typically
  /// set after the agent has read `install_size_bytes` from
  /// `/v1/assets/{id}`. Ignored for installs below the threshold.
  let confirmLargeDownload: Bool?

  private enum CodingKeys: String, CodingKey {
    case source
    case confirmLargeDownload = "confirm_large_download"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.source = try c.decode(InstallSource.self, forKey: .source)
    self.confirmLargeDownload = try c.decodeIfPresent(Bool.self, forKey: .confirmLargeDownload)
  }
}

extension InstallSource: Decodable {
  private enum DiscriminatorKey: String, CodingKey { case type }
  private enum SourceKind: String, Decodable { case catalog, localFile = "local_file" }

  private enum CatalogKeys: String, CodingKey { case model }
  private enum LocalFileKeys: String, CodingKey {
    case assetType = "asset_type"
    case path, name, architecture
  }

  init(from decoder: Decoder) throws {
    let kindContainer = try decoder.container(keyedBy: DiscriminatorKey.self)
    let kind = try kindContainer.decode(SourceKind.self, forKey: .type)
    switch kind {
    case .catalog:
      let c = try decoder.container(keyedBy: CatalogKeys.self)
      self = .catalog(model: try c.decode(String.self, forKey: .model))
    case .localFile:
      let c = try decoder.container(keyedBy: LocalFileKeys.self)
      self = .localFile(
        type: try c.decode(AssetType.self, forKey: .assetType),
        path: try c.decode(String.self, forKey: .path),
        name: try c.decodeIfPresent(String.self, forKey: .name),
        architecture: try c.decodeIfPresent(Architecture.self, forKey: .architecture)
      )
    }
  }
}

// MARK: - Mutation errors → TypedError

enum AssetMutationError: Error {
  case notFound(id: String)
  case forbidden(path: String)
  case engineMisconfigured(String)
  case alreadyInstalled(id: String)
  case catalogNotFound(model: String)
  case downloadFailed(detail: String)
  case hashMismatch(file: String)
  case insufficientStorage
  case localFileNotFound(path: String)
  case localFileTypeNotSupported(type: AssetType)
  case importFailed(detail: String)
  case validationFailed(detail: String)
  /// The install footprint would exceed the server's threshold and the
  /// caller did not pass `confirm_large_download: true`. Surfaces as
  /// 412 `LARGE_MODEL_DOWNLOAD`; the detail includes the byte count.
  case largeDownloadNotConfirmed(bytes: Int64, thresholdBytes: Int64)
}

extension TypedError {
  static func from(mutationError: AssetMutationError) -> TypedError {
    switch mutationError {
    case .notFound(let id):
      return TypedError(
        status: .notFound, errorCode: "MODEL_NOT_INSTALLED",
        title: "Asset not found", detail: "no asset with id '\(id)'")
    case .forbidden(let path):
      return TypedError(
        status: .forbidden, errorCode: "FORBIDDEN",
        title: "Refusing to act on a path outside the models directory",
        detail: "resolved path '\(path)' is not inside any configured external URL")
    case .engineMisconfigured(let msg):
      return TypedError(
        status: .internalServerError, errorCode: "ENGINE_INTERNAL_ERROR",
        title: "Engine misconfigured", detail: msg)
    case .alreadyInstalled(let id):
      return TypedError(
        status: .conflict, errorCode: "ASSET_ALREADY_INSTALLED",
        title: "Asset already installed", detail: "id '\(id)' is already present")
    case .catalogNotFound(let model):
      return TypedError(
        status: .notFound, errorCode: "CATALOG_MODEL_NOT_FOUND",
        title: "Catalog model not found",
        detail: "no catalog entry matches '\(model)'")
    case .downloadFailed(let detail):
      return TypedError(
        status: .badGateway, errorCode: "ASSET_DOWNLOAD_FAILED",
        title: "Asset download failed", detail: detail)
    case .hashMismatch(let file):
      return TypedError(
        status: .badGateway, errorCode: "ASSET_HASH_MISMATCH",
        title: "Downloaded file failed checksum verification", detail: file)
    case .insufficientStorage:
      return TypedError(
        status: .init(code: 507, reasonPhrase: "Insufficient Storage"),
        errorCode: "INSUFFICIENT_STORAGE",
        title: "Insufficient storage to complete install", detail: nil)
    case .localFileNotFound(let path):
      return TypedError(
        status: .badRequest, errorCode: "VALIDATION_FAILED",
        title: "Local source file not found", detail: path)
    case .localFileTypeNotSupported(let type):
      return TypedError(
        status: .badRequest, errorCode: "INSTALL_NOT_SUPPORTED_FOR_TYPE",
        title: "local_file install not supported for this asset type",
        detail:
          "local_file install supports types 'lora' and 'base_model'; got '\(type.rawValue)'")
    case .importFailed(let detail):
      return TypedError(
        status: .unprocessableContent, errorCode: "ASSET_IMPORT_FAILED",
        title: "Failed to import local asset", detail: detail)
    case .validationFailed(let detail):
      return TypedError(
        status: .badRequest, errorCode: "VALIDATION_FAILED",
        title: "Request validation failed", detail: detail)
    case .largeDownloadNotConfirmed(let bytes, let thresholdBytes):
      return TypedError(
        status: .init(code: 412, reasonPhrase: "Precondition Failed"),
        errorCode: "LARGE_MODEL_DOWNLOAD",
        title: "Install would consume \(formatBytes(bytes)) of disk",
        detail:
          "Install footprint (\(formatBytes(bytes))) exceeds the server's "
          + "large-download threshold (\(formatBytes(thresholdBytes))). The "
          + "size is also reported as `install_size_bytes` on "
          + "GET /v1/assets/{id}. Re-submit with `confirm_large_download: "
          + "true` in the request body to proceed.")
    }
  }
}

/// Friendly "12.4 GB" / "356 MB" formatter for error-message bytes.
/// Binary multiples (1024) — agents typically display disk usage this
/// way and the catalog values are easier to read in GiB/MiB.
private func formatBytes(_ bytes: Int64) -> String {
  let kb: Double = 1024
  let mb = kb * 1024
  let gb = mb * 1024
  let v = Double(bytes)
  if v >= gb { return String(format: "%.2f GB", v / gb) }
  if v >= mb { return String(format: "%.1f MB", v / mb) }
  if v >= kb { return String(format: "%.0f KB", v / kb) }
  return "\(bytes) B"
}

// MARK: - AssetManager mutation

extension AssetManager {
  func delete(id: String) async throws {
    guard let asset = await self.get(id: id) else {
      throw AssetMutationError.notFound(id: id)
    }
    let externalUrls = ModelZoo.externalUrls
    guard !externalUrls.isEmpty else {
      throw AssetMutationError.engineMisconfigured("no external models directory configured")
    }

    let candidateFiles = Self.filesForAsset(asset)
    let kept = Self.filesUsedByOtherAssets(excludingType: asset.type, excludingFile: asset.id)

    let fm = FileManager.default
    let normalizedExternal = externalUrls.map { $0.standardizedFileURL.path }

    for file in candidateFiles {
      if kept.contains(file) { continue }
      let path = ModelZoo.filePathForModelDownloaded(file)
      let resolvedPath = URL(fileURLWithPath: path).standardizedFileURL.path
      let inside = normalizedExternal.contains { resolvedPath.hasPrefix($0 + "/") }
      guard inside else { throw AssetMutationError.forbidden(path: resolvedPath) }
      if fm.fileExists(atPath: path) {
        try fm.removeItem(atPath: path)
      }
      let companion = path + "-tensordata"
      if fm.fileExists(atPath: companion) {
        try fm.removeItem(atPath: companion)
      }
    }

    // Clean custom-registry entries so re-install of the same id is clean.
    Self.removeFromCustomRegistryIfPresent(file: asset.id, assetType: asset.type)
  }

  func install(_ request: InstallAssetRequest) async throws -> Asset {
    return try await install(request, onState: nil)
  }

  /// Variant that forwards SDK `EnsureState` ticks (resolving, verifying,
  /// per-file byte progress) to `onState`. Used by the SSE install route
  /// so the agent can show a download bar instead of curling at a blank
  /// stare for 10 minutes. The non-streaming path passes `nil`.
  func install(
    _ request: InstallAssetRequest,
    onState: (@Sendable (MediaGenerationEnvironment.EnsureState) -> Void)?
  ) async throws -> Asset {
    // Idempotency: a model already on disk doesn't need a download —
    // surface ASSET_ALREADY_INSTALLED (409) rather than gating the
    // (zero-byte) re-install behind LARGE_MODEL_DOWNLOAD. This makes
    // re-running a script after a successful install a clean 409
    // instead of a 412 confirm-dance.
    if case .catalog(let model) = request.source,
      let spec = ModelZoo.specificationForModel(model),
      ModelZoo.isModelDownloaded(spec)
    {
      throw AssetMutationError.alreadyInstalled(id: model)
    }

    // Size gate: refuse silent multi-GB downloads when the agent
    // hasn't acknowledged the cost. Best-effort — unknown sizes don't
    // gate (the agent is expected to have read `install_size_bytes`
    // from GET /v1/assets/{id} upfront).
    if request.confirmLargeDownload != true,
      let estimated = await estimatedInstallSize(for: request.source),
      estimated > largeDownloadThresholdBytes
    {
      throw AssetMutationError.largeDownloadNotConfirmed(
        bytes: estimated, thresholdBytes: largeDownloadThresholdBytes)
    }

    switch request.source {
    case .catalog(let model):
      return try await installFromCatalog(model: model, onState: onState)
    case .localFile(let type, let path, let name, let architecture):
      // Local-file install is a one-shot importer call. LoRA conversion is
      // near-instant; base-model conversion is heavy (minutes for a 9B) but
      // still synchronous — no EnsureState ticks to forward, so neither path
      // streams progress.
      switch type {
      case .baseModel:
        return try await installBaseModelFromLocalFile(path: path, name: name)
      default:
        return try await installFromLocalFile(
          type: type, path: path, name: name, architecture: architecture)
      }
    }
  }

  // MARK: - Catalog install (base models only — ensure() does not cover LoRA/CN/etc.)

  private func installFromCatalog(
    model: String,
    onState: (@Sendable (MediaGenerationEnvironment.EnsureState) -> Void)? = nil
  ) async throws -> Asset {
    if let spec = ModelZoo.specificationForModel(model), ModelZoo.isModelDownloaded(spec) {
      throw AssetMutationError.alreadyInstalled(id: model)
    }
    do {
      let resolved = try await MediaGenerationEnvironment.default.ensure(
        model, stateHandler: onState)
      guard let asset = await self.get(id: resolved.file) else {
        throw AssetMutationError.engineMisconfigured(
          "post-install lookup failed for '\(resolved.file)'")
      }
      return asset
    } catch let error as MediaGenerationKitError {
      throw Self.translateMGKError(error)
    } catch {
      throw AssetMutationError.downloadFailed(detail: "\(error)")
    }
  }

  // MARK: - Local file install (LoRA only in phase B)

  private func installFromLocalFile(
    type: AssetType, path: String, name: String?, architecture: Architecture?
  ) async throws -> Asset {
    guard type == .lora else {
      throw AssetMutationError.localFileTypeNotSupported(type: type)
    }
    let sourceURL = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      throw AssetMutationError.localFileNotFound(path: path)
    }
    guard let externalUrl = ModelZoo.externalUrls.first else {
      throw AssetMutationError.engineMisconfigured("no external models directory configured")
    }

    let baseName = name ?? sourceURL.deletingPathExtension().lastPathComponent
    let sanitized = Self.sanitizeFileName(baseName)
    guard !sanitized.isEmpty else {
      throw AssetMutationError.validationFailed(detail: "derived asset name is empty")
    }
    let destinationFile = "\(sanitized)_lora_f16.ckpt"
    let destinationURL = externalUrl.appendingPathComponent(destinationFile)

    if FileManager.default.fileExists(atPath: destinationURL.path) {
      throw AssetMutationError.alreadyInstalled(id: destinationFile)
    }

    var importer = _MediaGenerationKit.LoRAImporter(file: sourceURL)
    // If the client specified an architecture, steal a matching ModelVersion from any spec
    // (we cannot construct ModelVersion directly without importing Diffusion).
    if let architecture {
      let templateVersion = ModelZoo.availableSpecifications.first {
        Architecture(rawValue: $0.version.rawValue) == architecture
      }?.version
      if let templateVersion {
        importer.version = templateVersion
      }
    }

    do {
      try importer.import(to: destinationURL)
    } catch let error as LoRAConvertError {
      if case .versionDetectionFailed = error {
        throw AssetMutationError.validationFailed(
          detail:
            "could not auto-detect LoRA architecture; pass 'architecture' in the request body")
      }
      throw AssetMutationError.importFailed(detail: error.localizedDescription)
    } catch {
      throw AssetMutationError.importFailed(detail: "\(error)")
    }

    guard let detectedVersion = importer.version else {
      throw AssetMutationError.importFailed(
        detail: "LoRAImporter did not report a detected version")
    }

    let displayName = name ?? sourceURL.deletingPathExtension().lastPathComponent
    let spec = LoRAZoo.Specification(
      name: displayName, file: destinationFile, prefix: "", version: detectedVersion)
    await MainActor.run {
      LoRAZoo.appendCustomSpecification(spec)
    }

    guard let asset = await self.get(id: destinationFile) else {
      throw AssetMutationError.engineMisconfigured(
        "post-install lookup failed for '\(destinationFile)'")
    }
    return asset
  }

  // MARK: - Base-model local file install (safetensors/ckpt → f16 ckpt)

  /// Imports a local base-model checkpoint via the `BaseModelImporter` facade
  /// (`ModelOp.ModelImporter` under the hood): auto-detects the architecture,
  /// writes an f16 `.ckpt` (+ `-tensordata`) into the external models
  /// directory, and registers the inferred spec in `custom.json`.
  ///
  /// Quantization is out of scope — the importer serializes weights at f16.
  /// The model's standard text encoder / VAE are referenced by the spec but
  /// not produced here; the engine fetches them on demand at generate time.
  private func installBaseModelFromLocalFile(
    path: String, name: String?
  ) async throws -> Asset {
    let sourceURL = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      throw AssetMutationError.localFileNotFound(path: path)
    }
    guard let externalUrl = ModelZoo.externalUrls.first else {
      throw AssetMutationError.engineMisconfigured("no external models directory configured")
    }

    let baseName = name ?? sourceURL.deletingPathExtension().lastPathComponent
    let sanitized = Self.sanitizeFileName(baseName)
    guard !sanitized.isEmpty else {
      throw AssetMutationError.validationFailed(detail: "derived asset name is empty")
    }
    // The importer writes `<internalName>_f16.ckpt` into the external dir;
    // this matches `specification.file` produced by inferModelSpecification.
    let destinationFile = "\(sanitized)_f16.ckpt"
    let destinationURL = externalUrl.appendingPathComponent(destinationFile)
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      throw AssetMutationError.alreadyInstalled(id: destinationFile)
    }

    let importer = BaseModelImporter(
      file: sourceURL, internalName: sanitized, displayName: baseName)

    let result: BaseModelImporter.ImportResult
    do {
      result = try importer.import()
    } catch {
      // A failed conversion can leave a partial/stub `.ckpt` (+ `-tensordata`)
      // behind. Remove it so a retry isn't blocked by a misleading
      // ASSET_ALREADY_INSTALLED (409) on the next attempt.
      try? FileManager.default.removeItem(atPath: destinationURL.path)
      try? FileManager.default.removeItem(atPath: destinationURL.path + "-tensordata")
      if let convertError = error as? BaseModelConvertError {
        if case .versionDetectionFailed = convertError {
          throw AssetMutationError.validationFailed(
            detail:
              "could not auto-detect the model architecture from "
              + "'\(sourceURL.lastPathComponent)' — is this a supported base-model checkpoint?")
        }
        throw AssetMutationError.importFailed(detail: convertError.localizedDescription)
      }
      throw AssetMutationError.importFailed(detail: "\(error)")
    }

    // Only register architectures this server's API surface knows about.
    // The importer may detect an engine version we don't expose; refuse it
    // rather than write a spec the rest of the API can't describe. Best-effort
    // cleanup of the file the importer just wrote.
    guard Architecture(rawValue: result.version.rawValue) != nil else {
      try? FileManager.default.removeItem(atPath: destinationURL.path)
      try? FileManager.default.removeItem(atPath: destinationURL.path + "-tensordata")
      throw AssetMutationError.validationFailed(
        detail:
          "imported model architecture '\(result.version.rawValue)' is not supported by this server")
    }

    await MainActor.run {
      ModelZoo.appendCustomSpecification(result.specification)
    }

    guard let asset = await self.get(id: result.specification.file) else {
      throw AssetMutationError.engineMisconfigured(
        "post-install lookup failed for '\(result.specification.file)'")
    }
    return asset
  }

  // MARK: - Static helpers

  private static func filesForAsset(_ asset: Asset) -> [String] {
    switch asset {
    case .baseModel(let a):
      guard let spec = ModelZoo.specificationForModel(a.id) else { return [a.id] }
      return ModelZoo.filesToDownload(spec).map(\.file)
    case .lora(let a):
      guard let spec = LoRAZoo.availableSpecifications.first(where: { $0.file == a.id }) else {
        return [a.id]
      }
      return LoRAZoo.filesToDownload(spec).map(\.file)
    case .controlnet(let a):
      guard
        let spec = ControlNetZoo.availableSpecifications.first(where: { $0.file == a.id })
      else { return [a.id] }
      return ControlNetZoo.filesToDownload(spec).map(\.file)
    case .embedding(let a): return [a.id]
    case .upscaler(let a): return [a.id]
    case .faceRestoration(let a): return [a.id]
    }
  }

  /// Files needed by any other downloaded asset. We must not delete these.
  private static func filesUsedByOtherAssets(
    excludingType type: AssetType, excludingFile file: String
  ) -> Set<String> {
    var kept = Set<String>()
    // Own zoo: exclude only the spec we are deleting.
    switch type {
    case .baseModel: kept.formUnion(ModelZoo.availableFiles(excluding: file))
    case .lora: kept.formUnion(LoRAZoo.availableFiles(excluding: file))
    case .controlnet: kept.formUnion(ControlNetZoo.availableFiles(excluding: file))
    case .embedding: kept.formUnion(TextualInversionZoo.availableFiles(excluding: file))
    case .upscaler: kept.formUnion(UpscalerZoo.availableFiles(excluding: file))
    case .faceRestoration: kept.formUnion(EverythingZoo.availableFiles(excluding: file))
    }
    // All other zoos contribute fully.
    if type != .baseModel { kept.formUnion(ModelZoo.availableFiles(excluding: nil)) }
    if type != .lora { kept.formUnion(LoRAZoo.availableFiles(excluding: nil)) }
    if type != .controlnet { kept.formUnion(ControlNetZoo.availableFiles(excluding: nil)) }
    if type != .embedding { kept.formUnion(TextualInversionZoo.availableFiles(excluding: nil)) }
    if type != .upscaler { kept.formUnion(UpscalerZoo.availableFiles(excluding: nil)) }
    if type != .faceRestoration { kept.formUnion(EverythingZoo.availableFiles(excluding: nil)) }
    return kept
  }

  /// Removes a custom spec entry from custom.json / custom_lora.json so re-install is clean.
  /// Best-effort: silently no-ops if the file is built-in (not present in the JSON).
  private static func removeFromCustomRegistryIfPresent(file: String, assetType: AssetType) {
    guard let externalUrl = ModelZoo.externalUrls.first else { return }
    let registryName: String
    switch assetType {
    case .baseModel: registryName = "custom.json"
    case .lora: registryName = "custom_lora.json"
    default: return  // other zoos don't have custom registries we manage in phase B
    }
    let jsonURL = externalUrl.appendingPathComponent(registryName)
    guard let data = try? Data(contentsOf: jsonURL),
      var entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return }
    let originalCount = entries.count
    entries.removeAll { ($0["file"] as? String) == file }
    guard entries.count != originalCount else { return }
    let newData = try? JSONSerialization.data(
      withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
    if let newData {
      try? newData.write(to: jsonURL, options: .atomic)
    }
    // Best-effort in-memory cleanup so the asset disappears from listings without a restart.
    switch assetType {
    case .baseModel:
      ModelZoo.availableSpecifications =
        ModelZoo.availableSpecifications.filter { $0.file != file }
    case .lora:
      LoRAZoo.availableSpecifications =
        LoRAZoo.availableSpecifications.filter { $0.file != file }
    default: break
    }
  }

  private static func sanitizeFileName(_ raw: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
    let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    return String(scalars)
  }

  private static func translateMGKError(_ error: MediaGenerationKitError) -> AssetMutationError {
    switch error {
    case .unresolvedModelReference(let query, _):
      return .catalogNotFound(model: query)
    case .modelNotFoundInCatalog(let m), .modelNotFoundOnRemote(let m):
      return .catalogNotFound(model: m)
    case .hashMismatch(let f):
      return .hashMismatch(file: f)
    case .downloadFailed(let msg):
      return .downloadFailed(detail: msg)
    case .insufficientStorage:
      return .insufficientStorage
    default:
      return .downloadFailed(detail: "\(error)")
    }
  }
}
