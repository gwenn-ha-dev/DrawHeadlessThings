import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest

@testable import dht_server

/// `/v1/pipeline` route + MCP `pipeline` tool tests. The route layer is
/// exercised against `FakeEngine`, whose `pipeline` impl is a deterministic
/// stub (returns the configured `imageBytes` under each named key). Recipe
/// resolution semantics — `from.via` execution, `$ref` lookup, error paths —
/// live in `RecipeResolutionTests`, driven through the real `DrawThingsEngine`
/// because the fake skips that resolution path on purpose.
final class PipelineTests: XCTestCase {

  private func buildApp(fake: FakeEngine = FakeEngine()) -> some ApplicationProtocol {
    let config = ServerConfig(
      scope: .private, port: 0, modelsDirectory: NSTemporaryDirectory(),
      token: nil, logLevel: .error, maxActiveRuns: nil, readOnly: false, silent: false)
    let router = makeRouter(
      engine: fake, assets: AssetManager(), registry: RunRegistry(), config: config)
    return Application(router: router)
  }

  // MARK: - /v1/pipeline route (FakeEngine)

  func testPipelineDefaultsToLastStepOutputUnderResultKey() async throws {
    let fake = FakeEngine(.init(imageBytes: Data("STEP-BYTES".utf8)))
    try await buildApp(fake: fake).test(.router) { client in
      let body = #"""
        {
          "steps": [
            {"via":"compose","model":"any","prompt":"a cat",
             "params":{"width":512,"height":512,"steps":1}},
            {"via":"edit","model":"any","from":"$result",
             "instruction":"make it red",
             "params":{"width":512,"height":512,"steps":1}}
          ]
        }
        """#
      try await client.execute(
        uri: "/v1/pipeline", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let outputs = json?["outputs"] as? [String: String] ?? [:]
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs["result"], Data("STEP-BYTES".utf8).base64EncodedString())
      }
    }
  }

  func testPipelineReturnsNamedSteps() async throws {
    let fake = FakeEngine(.init(imageBytes: Data("RGB".utf8)))
    try await buildApp(fake: fake).test(.router) { client in
      let body = #"""
        {
          "steps": [
            {"as":"base","via":"compose","model":"any","prompt":"cat",
             "params":{"width":512,"height":512,"steps":1}},
            {"as":"edited","via":"edit","model":"any","from":"$base",
             "instruction":"red",
             "params":{"width":512,"height":512,"steps":1}}
          ],
          "return": ["base","edited"]
        }
        """#
      try await client.execute(
        uri: "/v1/pipeline", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let outputs = json?["outputs"] as? [String: String] ?? [:]
        XCTAssertEqual(Set(outputs.keys), ["base", "edited"])
      }
    }
  }

  // MARK: - MCP pipeline tool (FakeEngine)

  func testMCPPipelineToolReturnsImageBlocksAndSummary() async throws {
    let fake = FakeEngine(.init(imageBytes: Data("MCP-PIPE".utf8)))
    try await buildApp(fake: fake).test(.router) { client in
      let body = #"""
        {"jsonrpc":"2.0","id":99,"method":"tools/call","params":{
          "name":"pipeline",
          "arguments":{
            "steps":[
              {"as":"first","via":"compose","model":"any","prompt":"x",
               "params":{"width":256,"height":256,"steps":1}}
            ]
          }
        }}
        """#
      try await client.execute(
        uri: "/mcp", method: .post,
        headers: HTTPFields([
          .init(name: .contentType, value: "application/json"),
        ]),
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body))
          as? [String: Any]
        let result = json?["result"] as? [String: Any] ?? [:]
        let content = result["content"] as? [[String: Any]] ?? []
        // 1 image block + 1 label text + 1 summary text + 1 recipe text
        XCTAssertEqual(content.count, 4)
        XCTAssertEqual(content[0]["type"] as? String, "image")
        XCTAssertEqual(content[0]["mimeType"] as? String, "image/png")
        let summary = content[2]["text"] as? String ?? ""
        XCTAssertTrue(summary.contains("Pipeline completed"))
        XCTAssertTrue(summary.contains("first"))
        // REST `X-DHT-Recipe` parity: the pipeline result carries the full
        // re-postable PipelineRequest as a final recipe block.
        let recipe = content[3]["text"] as? String ?? ""
        XCTAssertTrue(recipe.contains("Recipe"), "expected a recipe block, got: \(recipe)")
        XCTAssertTrue(recipe.contains("\"steps\":["), "recipe must carry the pipeline steps")
      }
    }
  }
}

/// Recipe / `$ref` resolution error paths. Driven through the real
/// `DrawThingsEngine` because `FakeEngine` deliberately skips resolution
/// (its `compose/edit/restore` produce canned bytes regardless of `from`).
/// Only the error paths that fire BEFORE model loading are exercised here —
/// nominal recipe execution requires actually installed models and is
/// integration-tested manually.
final class RecipeResolutionTests: XCTestCase {

  private func buildApp() -> some ApplicationProtocol {
    let modelsDir = NSTemporaryDirectory()
    let engine = DrawThingsEngine(modelsDirectory: modelsDir)
    let config = ServerConfig(
      scope: .private, port: 0, modelsDirectory: modelsDir,
      token: nil, logLevel: .error, maxActiveRuns: nil, readOnly: false, silent: false)
    let router = makeRouter(
      engine: engine, assets: AssetManager(), registry: RunRegistry(), config: config)
    return Application(router: router)
  }

  func testComposeRejectsRefOutsidePipeline() async throws {
    try await buildApp().test(.router) { client in
      let body = #"""
        {"model":"any","prompt":"x","from":"$nonexistent",
         "params":{"width":256,"height":256,"steps":1}}
        """#
      try await client.execute(
        uri: "/v1/compose", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .badRequest)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["error_code"] as? String, "PIPELINE_STEP_NOT_FOUND")
      }
    }
  }

  func testEditRejectsRefOutsidePipeline() async throws {
    try await buildApp().test(.router) { client in
      let body = #"""
        {"model":"any","from":"$missing","instruction":"x",
         "params":{"width":256,"height":256,"steps":1}}
        """#
      try await client.execute(
        uri: "/v1/edit", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .badRequest)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["error_code"] as? String, "PIPELINE_STEP_NOT_FOUND")
      }
    }
  }

  func testPipelineEmptyStepsReturnsTypedError() async throws {
    try await buildApp().test(.router) { client in
      try await client.execute(
        uri: "/v1/pipeline", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: #"{"steps":[]}"#)
      ) { response in
        XCTAssertEqual(response.status, .badRequest)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["error_code"] as? String, "PIPELINE_EMPTY")
      }
    }
  }

  func testPipelineReturnReferencesUnknownStepName() async throws {
    // Bug-shape: caller asks for an output name no step labelled. We expect
    // PIPELINE_RETURN_UNKNOWN_STEP. The first step targets an unknown model
    // so it would also fail with MODEL_NOT_INSTALLED — but that's later in
    // the engine path, after pipeline scaffolding. Use a single
    // model-installed step? We have no installed model in the temp dir.
    //
    // Workaround: use an edit step whose `from` is `$nonexistent`. The
    // pipeline executor runs the step, the step fails first with
    // PIPELINE_STEP_NOT_FOUND, and we never reach the return validation.
    // So this test path is harder to exercise without an installed model.
    // Document the gap and skip until integration coverage lands.
    throw XCTSkip("PIPELINE_RETURN_UNKNOWN_STEP needs an installed model to exercise — covered by manual integration.")
  }
}
