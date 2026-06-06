import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest

@testable import dht_server

/// `GET /health` behaviour and the single-source-of-truth version contract:
/// the runtime `dhtAPIVersion` constant, the `/v1/info` payload, and the
/// served `openapi.yaml` must all agree — a bump in one without the others is
/// caught here rather than shipping a spec that lies about its own version.
final class HealthAndVersionTests: XCTestCase {

  private func buildApp(
    scope: BindScope = .private, token: String? = nil
  ) -> some ApplicationProtocol {
    let config = ServerConfig(
      scope: scope, port: 0, modelsDirectory: NSTemporaryDirectory(),
      token: token, logLevel: .error, maxActiveRuns: nil, readOnly: false)
    let router = makeRouter(
      engine: FakeEngine(), assets: AssetManager(), registry: RunRegistry(),
      config: config)
    return Application(router: router)
  }

  // MARK: - /health

  func testHealthReturnsOk() async throws {
    try await buildApp().test(.router) { client in
      try await client.execute(uri: "/health", method: .get) { response in
        XCTAssertEqual(response.status, .ok)
        let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body))
          as? [String: Any]
        XCTAssertEqual(json?["status"] as? String, "ok")
      }
    }
  }

  /// On a public (token-required) bind, `/health` is reachable without a token
  /// while a normal route is not — proving the auth exemption is real and
  /// scoped to `/health` alone.
  func testHealthIsAuthExemptButOtherRoutesAreNot() async throws {
    try await buildApp(scope: .public, token: "secret").test(.router) { client in
      try await client.execute(uri: "/health", method: .get) { response in
        XCTAssertEqual(response.status, .ok, "/health must be reachable without a token")
      }
      try await client.execute(uri: "/v1/info", method: .get) { response in
        XCTAssertEqual(response.status, .unauthorized, "/v1/info must still require a token")
      }
    }
  }

  // MARK: - version sync

  func testInfoReportsRuntimeVersion() async throws {
    try await buildApp().test(.router) { client in
      try await client.execute(uri: "/v1/info", method: .get) { response in
        let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body))
          as? [String: Any]
        XCTAssertEqual(json?["api_version"] as? String, dhtAPIVersion)
      }
    }
  }

  func testServedOpenAPIVersionMatchesRuntimeVersion() async throws {
    try await buildApp().test(.router) { client in
      try await client.execute(uri: "/openapi.yaml", method: .get) { response in
        XCTAssertEqual(response.status, .ok)
        let yaml = String(buffer: response.body)
        // The single `info.version` line is the only key at exactly two-space
        // indent named `version:` — schema/engine version fields sit deeper.
        let infoVersion = yaml.split(separator: "\n")
          .first { $0.hasPrefix("  version:") && !$0.hasPrefix("   ") }
          .map { $0.replacingOccurrences(of: "  version:", with: "").trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(
          infoVersion, dhtAPIVersion,
          "openapi.yaml info.version must match the runtime dhtAPIVersion")
      }
    }
  }
}
