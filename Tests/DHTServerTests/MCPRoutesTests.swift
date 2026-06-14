import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest

@testable import dht_server

/// HTTP-transport tests for the MCP endpoint (`POST/GET /mcp`, Streamable
/// HTTP). Wired against a `FakeEngine` via `makeRouter`, so they exercise the
/// real route — JSON vs SSE branching, 202 for notifications, parse errors —
/// without loading a model. Dispatch semantics are covered by `MCPServerTests`.
final class MCPRoutesTests: XCTestCase {

  private func buildApp(fake: FakeEngine = FakeEngine()) -> some ApplicationProtocol {
    let config = ServerConfig(
      scope: .private, port: 0, modelsDirectory: NSTemporaryDirectory(),
      token: nil, logLevel: .error, maxActiveRuns: nil, readOnly: false, silent: false)
    let router = makeRouter(
      engine: fake, assets: AssetManager(), registry: RunRegistry(), config: config)
    return Application(router: router)
  }

  private static func jsonHeaders(accept: String? = nil) -> HTTPFields {
    var fields = HTTPFields([.init(name: .contentType, value: "application/json")])
    if let accept { fields.append(.init(name: .accept, value: accept)) }
    return fields
  }

  private func post(
    _ app: some ApplicationProtocol, body: String, accept: String? = nil,
    _ check: @escaping @Sendable (TestResponse) throws -> Void
  ) async throws {
    try await app.test(.router) { client in
      try await client.execute(
        uri: "/mcp", method: .post,
        headers: Self.jsonHeaders(accept: accept),
        body: ByteBuffer(string: body),
        testCallback: check)
    }
  }

  // MARK: - initialize

  func testInitializeOverHTTPReturnsJSON() async throws {
    try await post(
      buildApp(),
      body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}"#
    ) { response in
      XCTAssertEqual(response.status, .ok)
      XCTAssertEqual(response.headers[.contentType], "application/json")
      let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
      let result = json?["result"] as? [String: Any]
      XCTAssertEqual(result?["protocolVersion"] as? String, "2025-11-25")
    }
  }

  // MARK: - notifications

  func testNotificationReturns202() async throws {
    try await post(
      buildApp(),
      body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
    ) { response in
      XCTAssertEqual(response.status, .accepted)
      XCTAssertEqual(response.body.readableBytes, 0)
    }
  }

  // MARK: - parse errors

  func testMalformedJSONReturns400ParseError() async throws {
    try await post(buildApp(), body: "not-json-at-all") { response in
      XCTAssertEqual(response.status, .badRequest)
      let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
      let err = json?["error"] as? [String: Any]
      XCTAssertEqual(err?["code"] as? Int, -32700)
    }
  }

  // MARK: - tools/call (non-streaming)

  func testGenerateImageNonStreamingReturnsJSON() async throws {
    let fake = FakeEngine()
    fake.update { $0.seed = 99 }
    try await post(
      buildApp(fake: fake),
      body: #"""
        {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"compose","arguments":{"model":"any","prompt":"x","params":{"width":256,"height":256,"steps":1}}}}
        """#
    ) { response in
      XCTAssertEqual(response.status, .ok)
      XCTAssertEqual(response.headers[.contentType], "application/json")
      let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
      let result = json?["result"] as? [String: Any]
      XCTAssertEqual(result?["isError"] as? Bool, false)
      let content = result?["content"] as? [[String: Any]] ?? []
      XCTAssertEqual(content.first?["type"] as? String, "image")
    }
  }

  // MARK: - tools/call (streaming)

  func testGenerateImageStreamsProgressThenResponse() async throws {
    let fake = FakeEngine()
    fake.update { $0.progressTotalSteps = 3 }
    try await post(
      buildApp(fake: fake),
      body: #"""
        {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"compose","arguments":{"model":"any","prompt":"x","params":{"width":256,"height":256,"steps":1}},"_meta":{"progressToken":"p1"}}}
        """#,
      accept: "text/event-stream"
    ) { response in
      XCTAssertEqual(response.status, .ok)
      XCTAssertEqual(response.headers[.contentType], "text/event-stream")
      let body = String(buffer: response.body)
      let progressEvents = body.components(separatedBy: "notifications/progress").count - 1
      XCTAssertEqual(progressEvents, 3, "expected one progress notification per step")
      XCTAssertTrue(body.contains(#""progressToken":"p1""#))
      XCTAssertTrue(body.contains(#""result""#), "final frame must carry the JSON-RPC response")
      XCTAssertTrue(body.contains(#""id":5"#))
    }
  }

  // MARK: - GET

  func testGetMcpReturns405() async throws {
    try await buildApp().test(.router) { client in
      try await client.execute(uri: "/mcp", method: .get) { response in
        XCTAssertEqual(response.status, .methodNotAllowed)
      }
    }
  }

  // MARK: - setup page

  func testSetupPageServesHTMLWithEndpoint() async throws {
    try await buildApp().test(.router) { client in
      try await client.execute(uri: "/mcp/setup", method: .get) { response in
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.headers[.contentType], "text/html; charset=utf-8")
        let body = String(buffer: response.body)
        XCTAssertTrue(body.contains("/mcp"), "page must show the endpoint URL")
        XCTAssertTrue(body.contains("mcp-remote"), "page must show the fallback config")
      }
    }
  }
}
