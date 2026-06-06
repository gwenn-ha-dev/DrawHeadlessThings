import Foundation

/// Mirrors the server's `GET /v1/runs` JSON. The menu-bar app does not link
/// the dht-server module, so these DTOs are declared independently.
struct RunSummary: Codable, Identifiable {
  let runId: String
  let kind: String
  let prompt: String
  let width: Int
  let height: Int
  let steps: Int
  let startedAt: String
  let currentStep: Int
  let totalSteps: Int

  var id: String { runId }

  enum CodingKeys: String, CodingKey {
    case runId = "run_id"
    case kind, prompt, width, height, steps
    case startedAt = "started_at"
    case currentStep = "current_step"
    case totalSteps = "total_steps"
  }
}

struct RunListResponse: Codable {
  let runs: [RunSummary]
}

/// Subset of `GET /v1/runs/{id}` — only the fields the job panel needs.
struct RunDetail: Codable {
  let runId: String
  let currentStep: Int
  let totalSteps: Int
  let previewPngBase64: String?

  enum CodingKeys: String, CodingKey {
    case runId = "run_id"
    case currentStep = "current_step"
    case totalSteps = "total_steps"
    case previewPngBase64 = "preview_png_base64"
  }
}

extension RunSummary {
  /// Seconds since the run started, from the ISO-8601 `started_at`.
  private var elapsedSeconds: Double? {
    guard let started = ISO8601DateFormatter().date(from: startedAt) else { return nil }
    return max(0, Date().timeIntervalSince(started))
  }

  /// Average wall-clock seconds per diffusion step so far.
  var secondsPerStep: Double? {
    guard currentStep > 0, let elapsed = elapsedSeconds, elapsed > 0 else { return nil }
    return elapsed / Double(currentStep)
  }

  /// Estimated seconds remaining, from the running sec/step average.
  var etaSeconds: Double? {
    guard totalSteps > 0, currentStep > 0, currentStep < totalSteps,
      let perStep = secondsPerStep
    else { return nil }
    return Double(totalSteps - currentStep) * perStep
  }

  /// One-line pace summary for the job panel — e.g. "1.8 s/step · ETA 0:24".
  /// `nil` until the first step lands and a rate can be derived.
  var paceDescription: String? {
    guard let perStep = secondsPerStep else { return nil }
    let rate =
      perStep >= 1
      ? String(format: "%.1f s/step", perStep)
      : String(format: "%.0f ms/step", perStep * 1000)
    guard let eta = etaSeconds else { return rate }
    let total = Int(eta.rounded())
    return "\(rate) · ETA \(total / 60):\(String(format: "%02d", total % 60))"
  }
}
