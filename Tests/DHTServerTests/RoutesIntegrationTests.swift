import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import ModelZoo
import XCTest

@testable import dht_server

/// In-process integration tests for the HTTP surface. Uses Hummingbird's
/// `.router` test framework — no port binding, no real HTTP transport.
/// Tests that need an actually-installed model are skipped with
/// `throw XCTSkip(...)` because we can't assume any catalog state.
final class RoutesIntegrationTests: XCTestCase {
  private func buildApp(
    readOnly: Bool = false, maxActiveRuns: Int? = nil
  ) -> some ApplicationProtocol {
    let modelsDir = NSTemporaryDirectory()
    let engine = DrawThingsEngine(modelsDirectory: modelsDir)
    let assets = AssetManager()
    let registry = RunRegistry()
    let config = ServerConfig(
      scope: .private, port: 0, modelsDirectory: modelsDir,
      token: nil, logLevel: .error,
      maxActiveRuns: maxActiveRuns, readOnly: readOnly)
    let router = makeRouter(
      engine: engine, assets: assets, registry: registry, config: config)
    return Application(router: router)
  }

  func testInfoReturnsVersion() async throws {
    try await buildApp().test(.router) { client in
      try await client.execute(uri: "/v1/info", method: .get) { response in
        XCTAssertEqual(response.status, .ok)
        let body = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["api_version"] as? String, dhtAPIVersion)
        XCTAssertNotNil(json?["engine_version"] as? String)
      }
    }
  }

  func testResolveComposeWithUnknownModelReturns200WithErrors() async throws {
    let body = #"""
      {"model":"definitely-does-not-exist","prompt":"x",
       "params":{"width":512,"height":512,"steps":1}}
      """#
    try await buildApp().test(.router) { client in
      try await client.execute(
        uri: "/v1/resolve/compose", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let errors = json?["errors"] as? [[String: Any]] ?? []
        XCTAssertFalse(errors.isEmpty, "expected at least one error")
        XCTAssertEqual(errors.first?["code"] as? String, "MODEL_NOT_INSTALLED")
      }
    }
  }

  func testComposeWithUnknownModelReturns400() async throws {
    let body = #"""
      {"model":"definitely-does-not-exist","prompt":"x",
       "params":{"width":512,"height":512,"steps":1}}
      """#
    try await buildApp().test(.router) { client in
      try await client.execute(
        uri: "/v1/compose", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .badRequest)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["error_code"] as? String, "MODEL_NOT_INSTALLED")
      }
    }
  }

  func testDeleteUnknownRunReturns404() async throws {
    try await buildApp().test(.router) { client in
      try await client.execute(uri: "/v1/runs/never-existed", method: .delete) {
        response in
        XCTAssertEqual(response.status, .notFound)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["error_code"] as? String, "RUN_NOT_FOUND")
      }
    }
  }

  func testReadOnlyRejectsStreamingInstall() async throws {
    // The read-only gate must fire BEFORE we commit to the SSE response
    // shape — otherwise a read-only server would respond 200 + a
    // text/event-stream body containing READ_ONLY_MODE, which is
    // worse UX than the plain 403 the non-streaming path returns.
    let body = #"{"source":{"type":"catalog","model":"x"}}"#
    try await buildApp(readOnly: true).test(.router) { client in
      try await client.execute(
        uri: "/v1/assets/install?stream=true", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .forbidden)
        // Plain Problem Details JSON, NOT text/event-stream
        XCTAssertNotEqual(
          response.headers[.contentType], "text/event-stream")
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["error_code"] as? String, "READ_ONLY_MODE")
      }
    }
  }

  func testReadOnlyRejectsInstall() async throws {
    let body = #"{"source":{"type":"catalog","model":"x"}}"#
    try await buildApp(readOnly: true).test(.router) { client in
      try await client.execute(
        uri: "/v1/assets/install", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .forbidden)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["error_code"] as? String, "READ_ONLY_MODE")
      }
    }
  }

  func testReadOnlyRejectsDelete() async throws {
    try await buildApp(readOnly: true).test(.router) { client in
      try await client.execute(uri: "/v1/assets/anything", method: .delete) {
        response in
        XCTAssertEqual(response.status, .forbidden)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["error_code"] as? String, "READ_ONLY_MODE")
      }
    }
  }

  func testValidationFailedOnBadWidth() async throws {
    let body = #"""
      {"model":"x","prompt":"x","params":{"width":100,"height":512,"steps":1}}
      """#
    try await buildApp().test(.router) { client in
      try await client.execute(
        uri: "/v1/compose", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .badRequest)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["error_code"] as? String, "VALIDATION_FAILED")
        XCTAssertTrue((json?["detail"] as? String ?? "").contains("width"))
      }
    }
  }

  func testRootRedirectsToDocs() async throws {
    try await buildApp().test(.router) { client in
      try await client.execute(uri: "/", method: .get) { response in
        XCTAssertEqual(response.status, .found)
        XCTAssertEqual(response.headers[.location], "/docs")
      }
    }
  }

  func testDocsServesSwaggerUIIndex() async throws {
    try await buildApp().test(.router) { client in
      try await client.execute(uri: "/docs", method: .get) { response in
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.headers[.contentType], "text/html; charset=utf-8")
        let body = String(buffer: response.body)
        XCTAssertTrue(body.contains("SwaggerUIBundle"),
          "index.html should boot the Swagger UI JS bundle")
        XCTAssertTrue(body.contains("/openapi.yaml"),
          "index.html should point Swagger UI at /openapi.yaml")
      }
    }
  }

  func testDocsAssetIsServed() async throws {
    try await buildApp().test(.router) { client in
      try await client.execute(uri: "/docs/swagger-ui.css", method: .get) { response in
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.headers[.contentType], "text/css; charset=utf-8")
        XCTAssertGreaterThan(response.body.readableBytes, 1000)
      }
    }
  }

  func testDocsRejectsUnknownAsset() async throws {
    // The allowlist must reject anything we did not vendor — including
    // path-traversal-shaped names — rather than touching the filesystem.
    try await buildApp().test(.router) { client in
      try await client.execute(uri: "/docs/totally-not-vendored.js", method: .get) {
        response in
        XCTAssertEqual(response.status, .notFound)
      }
    }
  }

  // MARK: - /v1/capabilities/{model_id}

  func testCapabilitiesUnknownModelReturns404() async throws {
    try await buildApp().test(.router) { client in
      try await client.execute(
        uri: "/v1/capabilities/definitely-does-not-exist", method: .get
      ) { response in
        XCTAssertEqual(response.status, .notFound)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["error_code"] as? String, "MODEL_NOT_INSTALLED")
      }
    }
  }

  func testCapabilitiesKnownModelReturnsOperations() async throws {
    guard let spec = ModelZoo.availableSpecifications.first(where: {
      guard let arch = Architecture(rawValue: $0.version.rawValue),
        let cls = arch.behaviorClass
      else { return false }
      let modifier = Modifier.from(rawValue: $0.modifier?.rawValue)
      return !CapabilityMap.contracts(behaviorClass: cls, modifier: modifier).isEmpty
    }) else {
      throw XCTSkip("no catalog spec maps to a non-empty capability cell")
    }
    let path = "/v1/capabilities/\(spec.file)"
    try await buildApp().test(.router) { client in
      try await client.execute(uri: path, method: .get) { response in
        XCTAssertEqual(response.status, .ok)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["model_id"] as? String, spec.file)
        XCTAssertNotNil(json?["engine_version"] as? String)
        XCTAssertEqual(json?["architecture"] as? String, spec.version.rawValue)
        XCTAssertNotNil(json?["behavior_class"])
        XCTAssertNotNil(json?["modifier"] as? String)
        let ops = json?["operations"] as? [[String: Any]] ?? []
        XCTAssertFalse(ops.isEmpty, "expected at least one operation")
        // Each contract must carry the agreed snake_case keys
        let first = ops[0]
        XCTAssertEqual(first["model_id"] as? String, spec.file)
        XCTAssertNotNil(first["operation"] as? String)
        XCTAssertNotNil(first["engine_version"] as? String)
        XCTAssertNotNil(first["accepted"] as? [String: Any])
        XCTAssertNotNil(first["silent_drops"] as? [[String: Any]])
        XCTAssertNotNil(first["refused"] as? [[String: Any]])
        XCTAssertNotNil(first["notes"] as? [Any])
      }
    }
  }

  func testCapabilitiesRefinerReturnsEmptyOperations() async throws {
    // Find a catalog spec whose architecture is a non-callable stage
    // (BehaviorClass == nil): SDXL refiner or Stable Cascade decoder.
    guard let spec = ModelZoo.availableSpecifications.first(where: {
      guard let arch = Architecture(rawValue: $0.version.rawValue) else { return false }
      return arch.behaviorClass == nil
    }) else {
      throw XCTSkip("no non-callable-stage spec in the catalog (refiner / decoder)")
    }
    let path = "/v1/capabilities/\(spec.file)"
    try await buildApp().test(.router) { client in
      try await client.execute(uri: path, method: .get) { response in
        XCTAssertEqual(response.status, .ok)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json?.keys.contains("behavior_class"))
        XCTAssertNil(
          json?["behavior_class"] as? String,
          "non-callable stage must serialize behavior_class as null")
        let ops = json?["operations"] as? [[String: Any]] ?? [["sentinel": "present"]]
        XCTAssertTrue(ops.isEmpty, "non-callable stage must return operations: []")
        let notes = json?["notes"] as? [String] ?? []
        XCTAssertFalse(notes.isEmpty, "expected a notes line explaining the empty ops")
      }
    }
  }

  func testOpenAPISpecIsServed() async throws {
    try await buildApp().test(.router) { client in
      try await client.execute(uri: "/openapi.yaml", method: .get) { response in
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.headers[.contentType], "application/yaml; charset=utf-8")
        let body = String(buffer: response.body)
        XCTAssertTrue(body.contains("openapi: 3.1.0"))
        XCTAssertTrue(body.contains("DrawHeadlessThings API"))
      }
    }
  }
}
