import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest

@testable import dht_server

/// `X-DHT-Recipe` header tests.
///
/// Every generation response carries the recipe (base64-encoded JSON) that
/// produced it, with the `via` discriminator injected and applied defaults
/// folded into `params`. The recipe is re-postable: sending it back to
/// `/v1/<verb>` (or `/v1/pipeline` for pipeline) should yield the same bytes
/// given the same seed. This file exercises the WIRE shape against the
/// FakeEngine; byte-level reproducibility is integration-tested manually.
final class RecipeHeaderTests: XCTestCase {

  private func buildApp(fake: FakeEngine = FakeEngine()) -> some ApplicationProtocol {
    let config = ServerConfig(
      scope: .private, port: 0, modelsDirectory: NSTemporaryDirectory(),
      token: nil, logLevel: .error, maxActiveRuns: nil, readOnly: false, silent: false)
    let router = makeRouter(
      engine: fake, assets: AssetManager(), registry: RunRegistry(), config: config)
    return Application(router: router)
  }

  private static let jsonHeader = HTTPFields([
    .init(name: .contentType, value: "application/json")
  ])

  private func recipeDictFromResponse(_ response: TestResponse) throws -> [String: Any] {
    let raw = try XCTUnwrap(
      response.headers[HTTPField.Name("X-DHT-Recipe")!],
      "expected X-DHT-Recipe header on the response")
    let data = try XCTUnwrap(Data(base64Encoded: raw))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return json
  }

  // MARK: - compose

  func testComposeJSONResponseCarriesRecipeHeader() async throws {
    try await buildApp().test(.router) { client in
      let body = #"""
        {"model":"any","prompt":"a cat",
         "params":{"width":512,"height":512,"steps":1}}
        """#
      try await client.execute(
        uri: "/v1/compose", method: .post,
        headers: Self.jsonHeader, body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let recipe = try self.recipeDictFromResponse(response)
        XCTAssertEqual(recipe["via"] as? String, "compose")
        XCTAssertEqual(recipe["model"] as? String, "any")
        XCTAssertEqual(recipe["prompt"] as? String, "a cat")
      }
    }
  }

  func testComposeBinaryResponseAlsoCarriesRecipeHeader() async throws {
    try await buildApp().test(.router) { client in
      let body = #"""
        {"model":"any","prompt":"x",
         "params":{"width":512,"height":512,"steps":1}}
        """#
      try await client.execute(
        uri: "/v1/compose", method: .post,
        headers: HTTPFields([
          .init(name: .contentType, value: "application/json"),
          .init(name: .accept, value: "image/png"),
        ]),
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.headers[.contentType], "image/png")
        let recipe = try self.recipeDictFromResponse(response)
        XCTAssertEqual(recipe["via"] as? String, "compose")
      }
    }
  }

  func testComposeRecipeFoldsAppliedDefaultsIntoParams() async throws {
    let fake = FakeEngine()
    fake.update {
      $0.appliedDefaults = [
        AppliedDefault(fieldPath: "cfg_scale", value: .double(7.5)),
        AppliedDefault(fieldPath: "sampler", value: .string("euler_a")),
      ]
    }
    try await buildApp(fake: fake).test(.router) { client in
      let body = #"""
        {"model":"any","prompt":"x",
         "params":{"width":512,"height":512,"steps":1}}
        """#
      try await client.execute(
        uri: "/v1/compose", method: .post,
        headers: Self.jsonHeader, body: ByteBuffer(string: body)
      ) { response in
        let recipe = try self.recipeDictFromResponse(response)
        let params = try XCTUnwrap(recipe["params"] as? [String: Any])
        XCTAssertEqual(params["cfg_scale"] as? Double, 7.5)
        XCTAssertEqual(params["sampler"] as? String, "euler_a")
        // Original keys remain.
        XCTAssertEqual(params["width"] as? Int, 512)
      }
    }
  }

  // MARK: - edit / restore

  func testEditCarriesRecipeHeaderWithViaEdit() async throws {
    try await buildApp().test(.router) { client in
      // "ZmFrZQ==" decodes to the 4 bytes "fake".
      let body = #"""
        {"model":"any","from":{"image":"ZmFrZQ=="},"instruction":"x",
         "params":{"width":256,"height":256,"steps":1}}
        """#
      try await client.execute(
        uri: "/v1/edit", method: .post,
        headers: Self.jsonHeader, body: ByteBuffer(string: body)
      ) { response in
        let recipe = try self.recipeDictFromResponse(response)
        XCTAssertEqual(recipe["via"] as? String, "edit")
        XCTAssertEqual(recipe["instruction"] as? String, "x")
        // Inline image stripped to a `sha256:<hex>;bytes=<n>` digest reference
        // so the header can't exceed the HTTP header-line limit.
        let from = try XCTUnwrap(recipe["from"] as? [String: Any])
        let image = try XCTUnwrap(from["image"] as? String)
        XCTAssertTrue(image.hasPrefix("sha256:"), "expected digest reference, got \(image)")
        XCTAssertTrue(image.hasSuffix(";bytes=4"), "expected decoded byte count, got \(image)")
        XCTAssertNotEqual(image, "ZmFrZQ==", "raw base64 must not survive into the header")
      }
    }
  }

  /// A megabyte-scale inline image must not produce a megabyte-scale header:
  /// redaction keeps `X-DHT-Recipe` small regardless of input image size, which
  /// is the whole point — an un-redacted header tripped clients with
  /// `LineTooLong: got more than 65536 bytes when reading header line`.
  func testLargeInlineImageKeepsRecipeHeaderBounded() async throws {
    try await buildApp().test(.router) { client in
      let bigImage = Data(repeating: 0xAB, count: 1_000_000).base64EncodedString()
      let body = #"""
        {"model":"any","from":{"image":"\#(bigImage)"},"instruction":"x",
         "params":{"width":256,"height":256,"steps":1}}
        """#
      try await client.execute(
        uri: "/v1/edit", method: .post,
        headers: Self.jsonHeader, body: ByteBuffer(string: body)
      ) { response in
        let raw = try XCTUnwrap(
          response.headers[HTTPField.Name("X-DHT-Recipe")!],
          "expected the recipe header to survive a large inline image")
        XCTAssertLessThan(
          raw.utf8.count, 65536,
          "recipe header must stay under the 64 KB header-line limit")
        let recipe = try self.recipeDictFromResponse(response)
        let from = try XCTUnwrap(recipe["from"] as? [String: Any])
        let image = try XCTUnwrap(from["image"] as? String)
        XCTAssertTrue(image.hasSuffix(";bytes=1000000"), "got \(image)")
      }
    }
  }

  func testRestoreCarriesRecipeHeaderWithViaRestore() async throws {
    try await buildApp().test(.router) { client in
      let body = #"""
        {"model":"any","from":{"image":"AA=="},
         "params":{"width":256,"height":256,"steps":1}}
        """#
      try await client.execute(
        uri: "/v1/restore", method: .post,
        headers: Self.jsonHeader, body: ByteBuffer(string: body)
      ) { response in
        let recipe = try self.recipeDictFromResponse(response)
        XCTAssertEqual(recipe["via"] as? String, "restore")
      }
    }
  }

  // MARK: - pipeline

  func testPipelineCarriesRecipeHeaderWithFullSteps() async throws {
    try await buildApp().test(.router) { client in
      let body = #"""
        {"steps":[
          {"as":"a","via":"compose","model":"any","prompt":"x",
           "params":{"width":256,"height":256,"steps":1}}
        ]}
        """#
      try await client.execute(
        uri: "/v1/pipeline", method: .post,
        headers: Self.jsonHeader, body: ByteBuffer(string: body)
      ) { response in
        let recipe = try self.recipeDictFromResponse(response)
        let steps = try XCTUnwrap(recipe["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0]["via"] as? String, "compose")
        XCTAssertEqual(steps[0]["as"] as? String, "a")
      }
    }
  }

  // MARK: - re-postability

  /// A recipe header from a compose response must decode back into a valid
  /// `ComposeRequest`. This is the round-trip guarantee — the recipe is the
  /// reproducibility unit, not just an opaque blob.
  func testRecipeFromComposeRoundTripsAsComposeRequest() async throws {
    try await buildApp().test(.router) { client in
      let body = #"""
        {"model":"sdxl","prompt":"a fox","negative_prompt":"blurry",
         "params":{"width":1024,"height":1024,"steps":30}}
        """#
      try await client.execute(
        uri: "/v1/compose", method: .post,
        headers: Self.jsonHeader, body: ByteBuffer(string: body)
      ) { response in
        let raw = try XCTUnwrap(response.headers[HTTPField.Name("X-DHT-Recipe")!])
        let data = try XCTUnwrap(Data(base64Encoded: raw))
        // Recipe decodes via the polymorphic Recipe enum (`via` discriminator).
        let recipe = try JSONDecoder().decode(Recipe.self, from: data)
        guard case .compose(let decoded) = recipe else {
          return XCTFail("expected .compose, got \(recipe)")
        }
        XCTAssertEqual(decoded.model, "sdxl")
        XCTAssertEqual(decoded.prompt, "a fox")
        XCTAssertEqual(decoded.negativePrompt, "blurry")
        XCTAssertEqual(decoded.params?.width, 1024)
        XCTAssertEqual(decoded.params?.steps, 30)
      }
    }
  }
}
