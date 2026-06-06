import Foundation
import ModelZoo

/// Resolves the install footprint (bytes) of a base-model asset — every
/// companion file counted (checkpoint + text encoder + autoencoder +
/// CLIP encoder + …). Two paths share the same return shape, so the
/// public API field carries one semantic ("bytes the install consumes
/// on disk, or would consume"):
///
/// - **Downloaded files** → `FileManager.attributesOfItem` (cheap, exact).
/// - **Not-downloaded files** → `HEAD https://static.libnnc.org/{file}`
///   and read `Content-Length`. The CDN is the SDK's canonical download
///   source (see `MediaGenerationEnvironment+Ensure.swift:202`), so we
///   read sizes from the same place ensure() reads bytes from.
///
/// Sizes are cached per filename for the lifetime of the process — model
/// checkpoint files are immutable artifacts, the cache never goes stale.
/// Keying by filename (rather than by model id) lets us reuse sizes
/// across model variants that share companion files (e.g. every Qwen
/// variant shares `qwen_2.5_vl_7b_q8p.ckpt`).
actor ModelSizeResolver {
  /// Cache value of `nil` means "resolution was attempted and failed
  /// (CDN unreachable, file not served, etc.)". Absence of the key
  /// means "never tried". This split prevents re-paying the 2s HEAD
  /// timeout on every request for files that don't exist on the CDN
  /// (e.g. user-renamed local files or specs whose companions aren't
  /// CDN-hosted).
  private var fileSizeCache: [String: Int64?] = [:]
  private let urlSession: URLSession
  private let cdnBaseURL: String
  private let timeout: TimeInterval
  private let offlineMode: Bool

  init(
    urlSession: URLSession = .shared,
    cdnBaseURL: String = "https://static.libnnc.org",
    timeout: TimeInterval = 2.0,
    offlineMode: Bool = false
  ) {
    self.urlSession = urlSession
    self.cdnBaseURL = cdnBaseURL
    self.timeout = timeout
    self.offlineMode = offlineMode
  }

  /// Sum of every companion file's size for `spec`. Returns nil if the
  /// total can't be computed honestly (one or more companion files
  /// resolve neither on disk nor via the CDN). Partial totals would
  /// be misleading, so we'd rather report "unknown" than under-count.
  func installSize(forBaseModel spec: ModelZoo.Specification) async -> Int64? {
    let companions = ModelZoo.filesToDownload(spec).map(\.file)
    guard !companions.isEmpty else {
      // Spec without companion enumeration (e.g. remote-api spec). Fall
      // back to the headline file alone.
      return await resolveOne(file: spec.file)
    }

    // Resolve every companion in parallel — cold first-listing case
    // benefits hugely from concurrent HEADs.
    let resolved = await withTaskGroup(of: (String, Int64?).self) { group in
      for file in companions {
        group.addTask {
          (file, await self.resolveOne(file: file))
        }
      }
      var collected: [String: Int64?] = [:]
      for await pair in group {
        collected[pair.0] = pair.1
      }
      return collected
    }

    var total: Int64 = 0
    for file in companions {
      guard let optional = resolved[file], let size = optional else {
        return nil  // honest "unknown" instead of misleading partial
      }
      total += size
    }
    return total
  }

  /// Single-file resolution with cache. Tries filesystem first, then CDN
  /// HEAD. Returns nil if neither path produces a number; the nil is
  /// itself cached so we don't repeat the 2s HEAD timeout on every
  /// request for unresolvable files.
  ///
  /// `fileSizeCache[file]` returns `Int64??`: `.none` for "never tried",
  /// `.some(.none)` for "tried and failed", `.some(.some(n))` for the
  /// resolved size. The outer `if let` distinguishes the first case
  /// from the others.
  private func resolveOne(file: String) async -> Int64? {
    if let cached = fileSizeCache[file] {
      return cached  // value is Int64?: either the size, or nil for known-failed
    }
    if let onDisk = filesystemSize(of: file) {
      fileSizeCache[file] = onDisk
      return onDisk
    }
    if !offlineMode, let remote = await headCDN(file: file) {
      fileSizeCache[file] = remote
      return remote
    }
    fileSizeCache[file] = .some(nil)  // remember the failure
    return nil
  }

  private func filesystemSize(of file: String) -> Int64? {
    guard ModelZoo.isModelDownloaded(file) else { return nil }
    let path = ModelZoo.filePathForModelDownloaded(file)
    let fm = FileManager.default
    let main = (try? fm.attributesOfItem(atPath: path)[.size]) as? Int64 ?? 0
    // The engine creates a sibling `{path}-tensordata` file after
    // install for large checkpoints (most weights are moved to the
    // external store, leaving a thin manifest in `.ckpt`). Small
    // companions (VAEs, small encoders) keep all bytes in the .ckpt
    // and have no tensordata sibling. We sum both when present.
    let tensordataPath = path + "-tensordata"
    let tensordata =
      (try? fm.attributesOfItem(atPath: tensordataPath)[.size]) as? Int64 ?? 0
    let total = main + tensordata
    return total > 0 ? total : nil
  }

  private func headCDN(file: String) async -> Int64? {
    guard let url = URL(string: "\(cdnBaseURL)/\(file)") else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.timeoutInterval = timeout
    do {
      let (_, response) = try await urlSession.data(for: request)
      guard let http = response as? HTTPURLResponse,
        (200...299).contains(http.statusCode)
      else { return nil }
      if let raw = http.value(forHTTPHeaderField: "Content-Length"),
        let bytes = Int64(raw)
      {
        return bytes
      }
      return nil
    } catch {
      return nil
    }
  }
}
