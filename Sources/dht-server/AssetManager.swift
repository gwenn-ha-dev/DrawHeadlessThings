import Downloader
import Foundation
import ModelZoo

/// Classifies catalog entries by origin for the `source` field. Built once
/// per `list()` call — the community catalogs are in-memory arrays (loaded
/// from the on-disk cache the `Downloader` fetch maintains), so this is a
/// handful of Set constructions, no I/O beyond the small custom_lora.json.
private struct SourceIndex {
  /// Full (unfiltered) community catalogs per Zoo — membership survives
  /// install, so a downloaded community model keeps `source: community`.
  private let communityBaseModels: Set<String>
  private let communityLoRAs: Set<String>
  private let communityControlNets: Set<String>
  private let communityEmbeddings: Set<String>
  /// LoRAs registered in the models dir's custom_lora.json (local imports).
  private let customLoRAs: Set<String>

  init() {
    communityBaseModels = Set(ModelZoo.communityOnDisk.map(\.file))
    communityLoRAs = Set(LoRAZoo.communityOnDisk.map(\.file))
    communityControlNets = Set(ControlNetZoo.communityOnDisk.map(\.file))
    communityEmbeddings = Set(TextualInversionZoo.communityOnDisk.map(\.file))
    customLoRAs = Self.customRegistryFiles("custom_lora.json")
  }

  private static func customRegistryFiles(_ registryName: String) -> Set<String> {
    guard let externalUrl = ModelZoo.externalUrls.first else { return [] }
    let jsonURL = externalUrl.appendingPathComponent(registryName)
    guard let data = try? Data(contentsOf: jsonURL),
      let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return Set(entries.compactMap { $0["file"] as? String })
  }

  func baseModel(_ file: String) -> AssetSource {
    if communityBaseModels.contains(file) { return .community }
    return ModelZoo.isBuiltinModel(file) ? .official : .custom
  }

  func lora(_ file: String) -> AssetSource {
    if communityLoRAs.contains(file) { return .community }
    return customLoRAs.contains(file) ? .custom : .official
  }

  // ControlNets and embeddings have no DHT-managed custom registry, so
  // anything outside the community catalog is official.
  func controlnet(_ file: String) -> AssetSource {
    communityControlNets.contains(file) ? .community : .official
  }

  func embedding(_ file: String) -> AssetSource {
    communityEmbeddings.contains(file) ? .community : .official
  }
}

/// Read-only asset catalog. Each filter dispatches to the right Zoo and produces
/// strongly-typed `Asset` variants — no flat-with-optionals soup.
///
/// Wrapped in an actor so future install/delete operations can serialize safely.
actor AssetManager {
  struct Filter: Sendable {
    var type: AssetType?
    var architecture: Architecture?
    var domain: Domain?
    var controlnetTask: ControlNetTask?
    var downloadedOnly: Bool = true
  }

  private let sizeResolver: ModelSizeResolver
  /// Installs whose estimated footprint exceeds this number of bytes
  /// require `confirm_large_download: true` in the request. 5 GB is a
  /// conservative default — most Mac users have 256-512 GB SSDs where
  /// 5 GB is "I should know about this". Configurable to allow tests
  /// to use a low threshold.
  let largeDownloadThresholdBytes: Int64

  init(
    sizeResolver: ModelSizeResolver = ModelSizeResolver(),
    largeDownloadThresholdBytes: Int64 = 5 * 1024 * 1024 * 1024
  ) {
    self.sizeResolver = sizeResolver
    self.largeDownloadThresholdBytes = largeDownloadThresholdBytes
  }

  /// Best-effort size estimate for an install request. Used by the
  /// `LARGE_MODEL_DOWNLOAD` gate. Returns `nil` when the size can't be
  /// determined (e.g. CDN unreachable for a catalog install) — the
  /// gate then lets the install proceed rather than refusing on
  /// uncertainty.
  func estimatedInstallSize(for source: InstallSource) async -> Int64? {
    switch source {
    case .catalog(let model):
      // Community suggestions are not in availableSpecifications — fall
      // back to the cached community catalog so the LARGE_MODEL_DOWNLOAD
      // gate covers them too.
      guard
        let spec = ModelZoo.specificationForModel(model)
          ?? ModelZoo.communityOnDisk.first(where: { $0.file == model })
      else { return nil }
      return await sizeResolver.installSize(forBaseModel: spec)
    case .localFile(_, let path, _, _):
      let attrs = try? FileManager.default.attributesOfItem(atPath: path)
      return attrs?[.size] as? Int64
    }
  }

  func list(filter: Filter = Filter()) async -> [Asset] {
    var all: [Asset] = []
    let sources = SourceIndex()
    // Community specs the size-enricher can fall back on — suggestions are
    // not in `ModelZoo.availableSpecifications`, so `specificationForModel`
    // can't resolve them.
    var communityBaseSpecs: [String: ModelZoo.Specification] = [:]

    if filter.type == nil || filter.type == .baseModel {
      all.append(
        contentsOf: ModelZoo.availableSpecifications.map {
          .baseModel(BaseModelAsset($0, source: sources.baseModel($0.file)))
        })
      // Community suggestions: not-downloaded catalog entries from
      // models.drawthings.ai. `ModelZoo.community` already excludes
      // downloaded models; the id guard drops entries that shadow a
      // catalog spec (and downloads that happened after the last
      // community refresh).
      let listed = Set(ModelZoo.availableSpecifications.map(\.file))
      for spec in ModelZoo.community where !listed.contains(spec.file) {
        communityBaseSpecs[spec.file] = spec
        all.append(.baseModel(BaseModelAsset(spec, source: .community)))
      }
    }
    if filter.type == nil || filter.type == .lora {
      all.append(
        contentsOf: LoRAZoo.availableSpecifications.map {
          .lora(LoRAAsset($0, source: sources.lora($0.file)))
        })
      let listed = Set(LoRAZoo.availableSpecifications.map(\.file))
      for spec in LoRAZoo.community where !listed.contains(spec.file) {
        all.append(.lora(LoRAAsset(spec, source: .community)))
      }
    }
    if filter.type == nil || filter.type == .controlnet {
      all.append(
        contentsOf: ControlNetZoo.availableSpecifications.map {
          .controlnet(ControlNetAsset($0, source: sources.controlnet($0.file)))
        })
      let listed = Set(ControlNetZoo.availableSpecifications.map(\.file))
      for spec in ControlNetZoo.community where !listed.contains(spec.file) {
        all.append(.controlnet(ControlNetAsset(spec, source: .community)))
      }
    }
    if filter.type == nil || filter.type == .embedding {
      all.append(
        contentsOf: TextualInversionZoo.availableSpecifications.map {
          .embedding(EmbeddingAsset($0, source: sources.embedding($0.file)))
        })
      let listed = Set(TextualInversionZoo.availableSpecifications.map(\.file))
      for spec in TextualInversionZoo.community where !listed.contains(spec.file) {
        all.append(.embedding(EmbeddingAsset(spec, source: .community)))
      }
    }
    if filter.type == nil || filter.type == .upscaler {
      all.append(contentsOf: UpscalerZoo.availableSpecifications.map { .upscaler(UpscalerAsset($0)) })
    }
    if filter.type == nil || filter.type == .faceRestoration {
      all.append(
        contentsOf: EverythingZoo.availableSpecifications.map { .faceRestoration(FaceRestorationAsset($0)) })
    }

    if filter.downloadedOnly {
      all = all.filter { $0.downloaded }
    }
    if let architecture = filter.architecture {
      all = all.filter { $0.architecture == architecture }
    }
    if let domain = filter.domain {
      all = all.filter { $0.domain == domain }
    }
    if let task = filter.controlnetTask {
      all = all.filter { asset in
        if case .controlnet(let cn) = asset { return cn.task == task }
        return false
      }
    }

    // Filters applied first so we only HEAD CDN URLs for assets that
    // actually survive — avoids wasted network on hidden-by-filter
    // catalog entries.
    return await enrichBaseModelSizes(all, communitySpecs: communityBaseSpecs)
  }

  func get(id: String) async -> Asset? {
    await list(filter: Filter(downloadedOnly: false)).first { $0.id == id }
  }

  /// Resolves `install_size_bytes` for every base model in `assets` in
  /// parallel. Non-base-model entries pass through unchanged. Filesystem
  /// resolution is sub-millisecond; CDN HEAD takes ~100ms cold but the
  /// `ModelSizeResolver` cache means subsequent calls in the same
  /// server process are instant.
  private func enrichBaseModelSizes(
    _ assets: [Asset],
    communitySpecs: [String: ModelZoo.Specification] = [:]
  ) async -> [Asset] {
    let baseSpecs: [(Int, ModelZoo.Specification)] = assets.enumerated().compactMap {
      (offset, asset) in
      guard case .baseModel(let bm) = asset,
        let spec = ModelZoo.specificationForModel(bm.id) ?? communitySpecs[bm.id]
      else { return nil }
      return (offset, spec)
    }
    if baseSpecs.isEmpty { return assets }

    let resolver = self.sizeResolver
    let sizes: [Int: Int64?] = await withTaskGroup(of: (Int, Int64?).self) { group in
      for (offset, spec) in baseSpecs {
        group.addTask { (offset, await resolver.installSize(forBaseModel: spec)) }
      }
      var collected: [Int: Int64?] = [:]
      for await pair in group { collected[pair.0] = pair.1 }
      return collected
    }

    var result = assets
    for (offset, _) in baseSpecs {
      if case .baseModel(let bm) = result[offset] {
        let size = sizes[offset] ?? nil
        result[offset] = .baseModel(bm.withInstallSize(size))
      }
    }
    return result
  }
}
