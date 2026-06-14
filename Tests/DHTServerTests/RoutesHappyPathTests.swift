import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest

@testable import dht_server

/// Route-level happy-path tests, wired against a `FakeEngine` so they
/// don't need to load any model. Covers what `RoutesIntegrationTests`
/// deliberately skipped: successful generations, SSE wire format,
/// `RunMetadata` propagation, and `/v1/resolve` enrichment fields.
final class RoutesHappyPathTests: XCTestCase {

  private func buildApp(
    fake: FakeEngine = FakeEngine(),
    readOnly: Bool = false, maxActiveRuns: Int? = nil
  ) -> some ApplicationProtocol {
    let assets = AssetManager()
    let registry = RunRegistry()
    let config = ServerConfig(
      scope: .private, port: 0, modelsDirectory: NSTemporaryDirectory(),
      token: nil, logLevel: .error,
      maxActiveRuns: maxActiveRuns, readOnly: readOnly, silent: false)
    let router = makeRouter(
      engine: fake, assets: assets, registry: registry, config: config)
    return Application(router: router)
  }

  private static func composeBody(
    batchSize: Int? = nil, batchCount: Int? = nil, runId: String? = nil
  ) -> String {
    var paramsParts: [String] = ["\"width\":512", "\"height\":512", "\"steps\":1"]
    if let batchSize { paramsParts.append("\"batch_size\":\(batchSize)") }
    if let batchCount { paramsParts.append("\"batch_count\":\(batchCount)") }
    var rootParts: [String] = [
      "\"model\":\"any\"", "\"prompt\":\"a cat\"",
      "\"params\":{\(paramsParts.joined(separator: ","))}",
    ]
    if let runId { rootParts.append("\"run_id\":\"\(runId)\"") }
    return "{" + rootParts.joined(separator: ",") + "}"
  }

  // MARK: compose happy path

  func testComposeHappyPathReturnsImagesAndMetadata() async throws {
    let fake = FakeEngine(.init(seed: 7777))
    fake.update {
      $0.warnings = [
        Diagnostic(
          code: "BATCH_SIZE_MAY_CAP", fieldPath: "batch_size",
          message: "capped")
      ]
      $0.appliedDefaults = [
        AppliedDefault(fieldPath: "cfg_scale", value: .double(7.5))
      ]
    }
    try await buildApp(fake: fake).test(.router) { client in
      try await client.execute(
        uri: "/v1/compose", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: Self.composeBody(batchSize: 2, batchCount: 2))
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let images = json?["images"] as? [String] ?? []
        XCTAssertEqual(images.count, 4, "fake honors batch_size × batch_count")
        XCTAssertEqual(json?["seed"] as? Int, 7777)
        let metadata = json?["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["engine_version"] as? String, "fake-engine")
        XCTAssertEqual(metadata?["effective_seed"] as? Int, 7777)
        let warnings = metadata?["warnings"] as? [[String: Any]] ?? []
        XCTAssertEqual(warnings.first?["code"] as? String, "BATCH_SIZE_MAY_CAP")
        let applied = metadata?["applied_defaults"] as? [[String: Any]] ?? []
        XCTAssertEqual(applied.first?["field_path"] as? String, "cfg_scale")
      }
    }
  }

  func testComposeEchoesClientRunId() async throws {
    let fake = FakeEngine()
    try await buildApp(fake: fake).test(.router) { client in
      try await client.execute(
        uri: "/v1/compose", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: Self.composeBody(runId: "client-supplied-42"))
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let metadata = json?["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["run_id"] as? String, "client-supplied-42")
      }
    }
  }

  // MARK: SSE wire format

  func testComposeStreamEmitsProgressThenDone() async throws {
    let fake = FakeEngine()
    fake.update { $0.progressTotalSteps = 3 }
    try await buildApp(fake: fake).test(.router) { client in
      try await client.execute(
        uri: "/v1/compose?stream=true", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: Self.composeBody())
      ) { response in
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(
          response.headers[.contentType], "text/event-stream")
        let body = String(buffer: response.body)
        let progressEvents = body.components(separatedBy: "event: progress").count - 1
        let doneEvents = body.components(separatedBy: "event: done").count - 1
        let errorEvents = body.components(separatedBy: "event: error").count - 1
        XCTAssertEqual(progressEvents, 3)
        XCTAssertEqual(doneEvents, 1)
        XCTAssertEqual(errorEvents, 0)
        XCTAssertTrue(
          body.contains("\"step\":3"),
          "expected last progress payload to carry step=3, got:\n\(body)")
      }
    }
  }

  func testComposeStreamEmitsErrorOnEngineFailure() async throws {
    struct CannedError: Error {}
    let fake = FakeEngine()
    fake.update { $0.error = CannedError() }
    try await buildApp(fake: fake).test(.router) { client in
      try await client.execute(
        uri: "/v1/compose?stream=true", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: Self.composeBody())
      ) { response in
        // SSE response is always 200 once headers are flushed; failure
        // shows up via `event: error`.
        XCTAssertEqual(response.status, .ok)
        let body = String(buffer: response.body)
        XCTAssertTrue(body.contains("event: error"))
        XCTAssertTrue(body.contains("ENGINE_INTERNAL_ERROR"))
      }
    }
  }

  // MARK: resolve enrichment

  func testResolveComposeForwardsWarningsErrorsAndAppliedDefaults() async throws {
    let fake = FakeEngine()
    fake.update {
      $0.warnings = [
        Diagnostic(
          code: "BATCH_SIZE_MAY_CAP", fieldPath: "batch_size", message: "may cap"),
        Diagnostic(
          code: "EDITING_MODEL_DETECTED", fieldPath: "base_model_id",
          message: "editing model"),
      ]
      $0.appliedDefaults = [
        AppliedDefault(fieldPath: "sampler", value: .string("euler_a"))
      ]
      $0.estimatedComputeUnits = 1234
    }
    try await buildApp(fake: fake).test(.router) { client in
      try await client.execute(
        uri: "/v1/resolve/compose", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: Self.composeBody())
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["estimated_compute_units"] as? Int, 1234)
        let warnings = json?["warnings"] as? [[String: Any]] ?? []
        XCTAssertEqual(warnings.count, 2)
        XCTAssertEqual(
          Set(warnings.compactMap { $0["code"] as? String }),
          ["BATCH_SIZE_MAY_CAP", "EDITING_MODEL_DETECTED"])
        let applied = json?["applied_defaults"] as? [[String: Any]] ?? []
        XCTAssertEqual(applied.first?["field_path"] as? String, "sampler")
        XCTAssertEqual(applied.first?["value"] as? String, "euler_a")
      }
    }
  }

  // MARK: compose (video model) happy path

  func testComposeOnVideoModelReturnsVideos() async throws {
    let fake = FakeEngine()
    try await buildApp(fake: fake).test(.router) { client in
      let body = """
        {"model":"wan","prompt":"a wave","params":{
        "width":256,"height":256,"steps":1,"batch_count":2,
        "video":{"num_frames":16,"fps":24,"video_format":"mp4_h264"}}}
        """
      try await client.execute(
        uri: "/v1/compose", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let videos = json?["videos"] as? [[String: Any]] ?? []
        XCTAssertEqual(videos.count, 2)
        XCTAssertEqual(videos.first?["format"] as? String, "mp4_h264")
        XCTAssertEqual(videos.first?["num_frames"] as? Int, 16)
        XCTAssertEqual(videos.first?["fps"] as? Int, 24)
      }
    }
  }

  // MARK: edit happy path

  func testEditHappyPathReturnsImage() async throws {
    let fake = FakeEngine(.init(seed: 9090))
    try await buildApp(fake: fake).test(.router) { client in
      let body = """
        {"model":"any","from":{"image":"ZmFrZS1pbWFnZQ=="},
        "instruction":"change the background to red",
        "params":{"width":512,"height":512,"steps":1}}
        """
      try await client.execute(
        uri: "/v1/edit", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let data = Data(buffer: response.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let images = json?["images"] as? [String] ?? []
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(json?["seed"] as? Int, 9090)
      }
    }
  }

  func testEditRejectsBodyWithoutFrom() async throws {
    try await buildApp().test(.router) { client in
      // No `from` — required field, decode must fail.
      let body = """
        {"model":"any","instruction":"x",
        "params":{"width":512,"height":512,"steps":1}}
        """
      try await client.execute(
        uri: "/v1/edit", method: .post,
        headers: HTTPFields([.init(name: .contentType, value: "application/json")]),
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertNotEqual(
          response.status, .ok, "missing required `from` must not 200")
      }
    }
  }
}
