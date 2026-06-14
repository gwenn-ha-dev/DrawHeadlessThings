import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest

@testable import dht_server

/// Reads a custom `X-DHT-*` response header by raw name.
private func header(_ response: TestResponse, _ name: String) -> String? {
  response.headers[HTTPField.Name(name)!]
}

/// Covers binary content negotiation on the generation routes: an `Accept`
/// of `image/*` / `video/*` yields a raw body + `X-DHT-*` metadata headers
/// for single-result requests, a 406 for multi-result ones, and the JSON
/// envelope stays the default when no binary `Accept` is sent.
final class BinaryResponseTests: XCTestCase {

  private func buildApp(fake: FakeEngine = FakeEngine()) -> some ApplicationProtocol {
    let config = ServerConfig(
      scope: .private, port: 0, modelsDirectory: NSTemporaryDirectory(),
      token: nil, logLevel: .error, maxActiveRuns: nil, readOnly: false, silent: false)
    let router = makeRouter(
      engine: fake, assets: AssetManager(), registry: RunRegistry(), config: config)
    return Application(router: router)
  }

  private static func composeBody(batchCount: Int? = nil) -> String {
    var paramsParts = ["\"width\":512", "\"height\":512", "\"steps\":1"]
    if let batchCount { paramsParts.append("\"batch_count\":\(batchCount)") }
    return """
      {"model":"any","prompt":"a cat","params":{\(paramsParts.joined(separator: ","))}}
      """
  }

  private static let jsonHeader = HTTPFields([
    .init(name: .contentType, value: "application/json")
  ])

  // MARK: image — binary happy path

  func testBinaryAcceptReturnsRawImageBytesAndHeaders() async throws {
    let fake = FakeEngine(.init(imageBytes: Data("PNGBYTES".utf8), seed: 7777))
    try await buildApp(fake: fake).test(.router) { client in
      try await client.execute(
        uri: "/v1/compose", method: .post,
        headers: HTTPFields([
          .init(name: .contentType, value: "application/json"),
          .init(name: .accept, value: "image/png"),
        ]),
        body: ByteBuffer(string: Self.composeBody())
      ) { response in
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.headers[.contentType], "image/png")
        XCTAssertEqual(Data(buffer: response.body), Data("PNGBYTES".utf8))
        XCTAssertEqual(header(response, "X-DHT-Seed"), "7777")
        XCTAssertEqual(header(response, "X-DHT-Engine-Version"), "fake-engine")
        XCTAssertNotNil(header(response, "X-DHT-Run-Id"))
        XCTAssertNotNil(header(response, "X-DHT-Generation-Time-Ms"))
      }
    }
  }

  func testBinaryAcceptCarriesWarningsAsBase64JSONHeader() async throws {
    let fake = FakeEngine()
    fake.update {
      $0.warnings = [
        Diagnostic(code: "BATCH_SIZE_MAY_CAP", fieldPath: "batch_size", message: "capped — détail")
      ]
    }
    try await buildApp(fake: fake).test(.router) { client in
      try await client.execute(
        uri: "/v1/compose", method: .post,
        headers: HTTPFields([
          .init(name: .contentType, value: "application/json"),
          .init(name: .accept, value: "image/png"),
        ]),
        body: ByteBuffer(string: Self.composeBody())
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let raw = try XCTUnwrap(header(response, "X-DHT-Warnings"))
        let json = try XCTUnwrap(Data(base64Encoded: raw))
        let decoded = try JSONDecoder().decode([Diagnostic].self, from: json)
        XCTAssertEqual(decoded.first?.code, "BATCH_SIZE_MAY_CAP")
      }
    }
  }

  // MARK: image — multi-result is 406

  func testBinaryAcceptOnMultiResultIs406() async throws {
    try await buildApp().test(.router) { client in
      try await client.execute(
        uri: "/v1/compose", method: .post,
        headers: HTTPFields([
          .init(name: .contentType, value: "application/json"),
          .init(name: .accept, value: "image/png"),
        ]),
        body: ByteBuffer(string: Self.composeBody(batchCount: 2))
      ) { response in
        XCTAssertEqual(response.status, .notAcceptable)
        let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body))
          as? [String: Any]
        XCTAssertEqual(
          json?["error_code"] as? String, "BINARY_RESPONSE_IS_SINGLE_RESULT_ONLY")
      }
    }
  }

  // MARK: JSON stays the default

  func testNoBinaryAcceptStillReturnsJSONEnvelope() async throws {
    try await buildApp().test(.router) { client in
      try await client.execute(
        uri: "/v1/compose", method: .post,
        headers: Self.jsonHeader,
        body: ByteBuffer(string: Self.composeBody())
      ) { response in
        XCTAssertEqual(response.status, .ok)
        let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body))
          as? [String: Any]
        XCTAssertNotNil(json?["images"], "expected the JSON envelope, not a raw body")
      }
    }
  }

  // MARK: video — binary happy path

  func testVideoBinaryAcceptReturnsRawVideoBytesAndHeaders() async throws {
    let fake = FakeEngine(.init(videoBytes: Data("MP4BYTES".utf8)))
    try await buildApp(fake: fake).test(.router) { client in
      let body = """
        {"model":"wan","prompt":"a wave","params":{
        "width":256,"height":256,"steps":1,
        "video":{"num_frames":16,"fps":24,"video_format":"mp4_h264"}}}
        """
      try await client.execute(
        uri: "/v1/compose", method: .post,
        headers: HTTPFields([
          .init(name: .contentType, value: "application/json"),
          .init(name: .accept, value: "video/mp4"),
        ]),
        body: ByteBuffer(string: body)
      ) { response in
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.headers[.contentType], "video/mp4")
        XCTAssertEqual(Data(buffer: response.body), Data("MP4BYTES".utf8))
        XCTAssertEqual(header(response, "X-DHT-Num-Frames"), "16")
        XCTAssertEqual(header(response, "X-DHT-Fps"), "24")
        XCTAssertEqual(header(response, "X-DHT-Width"), "256")
      }
    }
  }
}
