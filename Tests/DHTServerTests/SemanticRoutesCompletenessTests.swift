import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest

@testable import dht_server

/// Coverage gaps that the R3-R5 ports left open, closed in R8.
///
/// What this file adds on top of `BinaryResponseTests` / `RoutesHappyPathTests`
/// / `MCPServerTests` / `RecipeHeaderTests`:
/// 1. **Recipe byte-level round-trip** — POST a body, base64-decode the
///    `X-DHT-Recipe` header, POST that JSON back, assert the response bytes
///    match. The header was already verified to *decode* as a `ComposeRequest`
///    in `RecipeHeaderTests`; this asserts it actually drives the engine.
/// 2. **`/v1/restore` happy path** through the route.
/// 3. **`/v1/resolve/edit` and `/v1/resolve/restore`** — only `resolve/compose`
///    had a happy-path test (in `RoutesHappyPathTests`).
/// 4. **Edit on the inpaint path** — only the instruction-edit branch had a
///    test (`RoutesHappyPathTests.testEditHappyPathReturnsImage`).
final class SemanticRoutesCompletenessTests: XCTestCase {

  private func buildApp(fake: FakeEngine = FakeEngine()) -> some ApplicationProtocol {
    let config = ServerConfig(
      scope: .private, port: 0, modelsDirectory: NSTemporaryDirectory(),
      token: nil, logLevel: .error, maxActiveRuns: nil, readOnly: false, silent: false)
    let router = makeRouter(
      engine: fake, assets: AssetManager(), registry: RunRegistry(), config: config)
    return Application(router: router)
  }

  /// Real-engine variant for tests that exercise validation paths
  /// `FakeEngine` deliberately skips (mask base64 decoding, the
  /// `PARAMS_REQUIRED` diagnostic in resolve, etc.). The real engine
  /// emits those diagnostics before any model loading, so it runs fine
  /// against an empty models directory.
  private func buildRealEngineApp() -> some ApplicationProtocol {
    let modelsDir = NSTemporaryDirectory()
    let engine = DrawThingsEngine(modelsDirectory: modelsDir)
    let config = ServerConfig(
      scope: .private, port: 0, modelsDirectory: modelsDir,
      token: nil, logLevel: .error, maxActiveRuns: nil, readOnly: false, silent: false)
    let router = makeRouter(
      engine: engine, assets: AssetManager(), registry: RunRegistry(), config: config)
    return Application(router: router)
  }

  private static let jsonHeader = HTTPFields([
    .init(name: .contentType, value: "application/json")
  ])

  // MARK: - 1. Byte-level recipe round-trip

  /// Submit a compose, read back the recipe header, POST it again — the
  /// fake's deterministic seed + canned bytes mean equality is exact.
  func testComposeRecipeRoundTripProducesSameBytes() async throws {
    let fake = FakeEngine(.init(imageBytes: Data("ROUND-TRIP".utf8), seed: 1234))
    try await buildApp(fake: fake).test(.router) { client in
      let originalBody = #"""
        {"model":"sdxl","prompt":"a fox",
         "params":{"width":512,"height":512,"steps":1,"seed":1234}}
        """#

      // First POST: capture the recipe header value + the response bytes.
      let (firstRecipe, firstSeed): (String, Int) = try await client.execute(
        uri: "/v1/compose", method: .post,
        headers: Self.jsonHeader, body: ByteBuffer(string: originalBody)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let recipe = try XCTUnwrap(response.headers[HTTPField.Name("X-DHT-Recipe")!])
        let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body))
          as? [String: Any]
        let seed = try XCTUnwrap(json?["seed"] as? Int)
        return (recipe, seed)
      }

      // Decode the recipe header → JSON body, POST it back.
      let recipeData = try XCTUnwrap(Data(base64Encoded: firstRecipe))
      try await client.execute(
        uri: "/v1/compose", method: .post,
        headers: Self.jsonHeader, body: ByteBuffer(bytes: Array(recipeData))
      ) { response in
        XCTAssertEqual(response.status, .ok)
        // Same recipe back: same seed, same canned bytes.
        let secondRecipe = try XCTUnwrap(
          response.headers[HTTPField.Name("X-DHT-Recipe")!])
        XCTAssertEqual(secondRecipe, firstRecipe,
          "round-tripping the recipe must yield the same recipe header")
        let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body))
          as? [String: Any]
        let secondSeed = try XCTUnwrap(json?["seed"] as? Int)
        XCTAssertEqual(secondSeed, firstSeed,
          "round-tripping the recipe must produce the same seed (\(firstSeed))")
        let images = json?["images"] as? [String] ?? []
        XCTAssertEqual(
          images.first, Data("ROUND-TRIP".utf8).base64EncodedString(),
          "round-tripping the recipe must produce the same image bytes")
      }
    }
  }

  // MARK: - 2. /v1/restore happy path

  func testRestoreHappyPathReturnsImageAndCarriesRecipe() async throws {
    let fake = FakeEngine(.init(imageBytes: Data("RESTORED".utf8), seed: 99))
    try await buildApp(fake: fake).test(.router) { client in
      let body = #"""
        {"model":"seedvr2_3b",
         "from":{"image":"PFNPVVJDRT4="},
         "params":{"width":1024,"height":1024,"steps":1}}
        """#
      try await client.execute(
        uri: "/v1/restore", method: .post,
        headers: Self.jsonHeader, body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body))
          as? [String: Any]
        let images = json?["images"] as? [String] ?? []
        XCTAssertEqual(images.first, Data("RESTORED".utf8).base64EncodedString())
        XCTAssertEqual(json?["seed"] as? Int, 99)
        XCTAssertNotNil(response.headers[HTTPField.Name("X-DHT-Recipe")!])
      }
    }
  }

  // MARK: - 3. resolve_edit / resolve_restore

  func testResolveEditForwardsWarningsAndAppliedDefaults() async throws {
    let fake = FakeEngine()
    fake.update {
      $0.appliedDefaults = [
        AppliedDefault(fieldPath: "cfg_scale", value: .double(7.5))
      ]
      $0.estimatedComputeUnits = 42
    }
    try await buildApp(fake: fake).test(.router) { client in
      let body = #"""
        {"model":"flux_kontext_dev",
         "from":{"image":"AAA="},
         "instruction":"x",
         "params":{"width":512,"height":512,"steps":1}}
        """#
      try await client.execute(
        uri: "/v1/resolve/edit", method: .post,
        headers: Self.jsonHeader, body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body))
          as? [String: Any]
        XCTAssertEqual(json?["estimated_compute_units"] as? Int, 42)
        let applied = json?["applied_defaults"] as? [[String: Any]] ?? []
        XCTAssertEqual(applied.first?["field_path"] as? String, "cfg_scale")
      }
    }
  }

  func testResolveRestoreForwardsWarnings() async throws {
    let fake = FakeEngine()
    fake.update {
      $0.warnings = [
        Diagnostic(code: "BATCH_SIZE_MAY_CAP", fieldPath: "batch_size", message: "demo")
      ]
    }
    try await buildApp(fake: fake).test(.router) { client in
      let body = #"""
        {"model":"seedvr2_3b",
         "from":{"image":"AAA="},
         "params":{"width":512,"height":512,"steps":1}}
        """#
      try await client.execute(
        uri: "/v1/resolve/restore", method: .post,
        headers: Self.jsonHeader, body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body))
          as? [String: Any]
        let warnings = json?["warnings"] as? [[String: Any]] ?? []
        XCTAssertEqual(warnings.first?["code"] as? String, "BATCH_SIZE_MAY_CAP")
      }
    }
  }

  func testResolveComposeReturnsPARAMS_REQUIREDWhenParamsBlockMissing() async throws {
    try await buildRealEngineApp().test(.router) { client in
      // Body without `params` block — resolve must return 200 with the
      // diagnostic in errors[], not throw.
      let body = #"""
        {"model":"any","prompt":"x"}
        """#
      try await client.execute(
        uri: "/v1/resolve/compose", method: .post,
        headers: Self.jsonHeader, body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body))
          as? [String: Any]
        let errors = json?["errors"] as? [[String: Any]] ?? []
        XCTAssertEqual(errors.first?["code"] as? String, "PARAMS_REQUIRED")
        XCTAssertNil(
          json?["resolved_request"] as? [String: Any],
          "resolved_request must be null when materialization was refused")
      }
    }
  }

  // MARK: - 4. Edit on the inpaint path (mask present)

  func testEditWithMaskHitsInpaintPathAndReturnsImage() async throws {
    let fake = FakeEngine(.init(imageBytes: Data("INPAINTED".utf8), seed: 7))
    try await buildApp(fake: fake).test(.router) { client in
      let body = #"""
        {"model":"sdxl-inpainting",
         "from":{"image":"PFNSQz4="},
         "mask":"PE1BU0s+",
         "instruction":"a wooden bench in the empty area",
         "params":{"width":1024,"height":1024,"steps":1,"denoising_strength":0.85}}
        """#
      try await client.execute(
        uri: "/v1/edit", method: .post,
        headers: Self.jsonHeader, body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body))
          as? [String: Any]
        let images = json?["images"] as? [String] ?? []
        XCTAssertEqual(images.first, Data("INPAINTED".utf8).base64EncodedString())
        XCTAssertEqual(json?["seed"] as? Int, 7)
        // The recipe round-trips as an edit; the mask is stripped to a digest
        // reference (`sha256:<hex>;bytes=<n>`) so the header stays bounded.
        // "PE1BU0s+" decodes to the 6 bytes "<MASK>".
        let recipe = try XCTUnwrap(response.headers[HTTPField.Name("X-DHT-Recipe")!])
        let data = try XCTUnwrap(Data(base64Encoded: recipe))
        let decoded = try JSONDecoder().decode(Recipe.self, from: data)
        guard case .edit(let req) = decoded else {
          return XCTFail("expected Recipe.edit, got \(decoded)")
        }
        XCTAssertEqual(req.mask?.hasSuffix(";bytes=6"), true,
          "mask should be a digest reference, got \(String(describing: req.mask))")
      }
    }
  }

  func testEditWithInvalidBase64MaskReturns400() async throws {
    try await buildRealEngineApp().test(.router) { client in
      let body = #"""
        {"model":"sdxl-inpainting",
         "from":{"image":"PFNSQz4="},
         "mask":"!!!not-base64!!!",
         "instruction":"x",
         "params":{"width":512,"height":512,"steps":1}}
        """#
      try await client.execute(
        uri: "/v1/edit", method: .post,
        headers: Self.jsonHeader, body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .badRequest)
        let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body))
          as? [String: Any]
        XCTAssertEqual(json?["error_code"] as? String, "INVALID_MASK_DATA")
      }
    }
  }
}
