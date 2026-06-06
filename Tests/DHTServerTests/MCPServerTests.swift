import Foundation
import Logging
import ModelZoo
import XCTest

@testable import dht_server

/// MCP dispatch-core tests. Drives `MCPServer.handle(envelope:)` directly with
/// parsed JSON-RPC envelopes against a `FakeEngine`, asserting on the response
/// envelopes. The HTTP transport (`/mcp`, SSE, parse errors) is covered by
/// `MCPRoutesTests`. Backend swappable thanks to the `GenerationEngine`
/// protocol.
final class MCPServerTests: XCTestCase {

  // MARK: - Harness

  /// Parses each JSON-RPC request string and dispatches it through one
  /// `MCPServer`. Notifications produce no response and don't appear in the
  /// output, matching the wire behaviour.
  private func run(
    requests: [String], fake: FakeEngine = FakeEngine(), readOnly: Bool = false
  ) async -> [[String: Any]] {
    var logger = Logger(label: "test-mcp")
    logger.logLevel = .error
    let server = MCPServer(
      engine: fake, assets: AssetManager(), registry: RunRegistry(),
      readOnly: readOnly, maxActiveRuns: nil, logger: logger)
    var out: [[String: Any]] = []
    for r in requests {
      guard
        let data = r.data(using: .utf8),
        let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      if let response = await server.handle(envelope: envelope) {
        out.append(response)
      }
    }
    return out
  }

  // MARK: - initialize

  func testInitializeEchoesKnownProtocolVersion() async {
    let responses = await run(requests: [
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}"#
    ])
    XCTAssertEqual(responses.count, 1)
    let r = responses[0]
    XCTAssertEqual(r["jsonrpc"] as? String, "2.0")
    XCTAssertEqual(r["id"] as? Int, 1)
    let result = r["result"] as? [String: Any] ?? [:]
    // 2024-11-05 is a version we recognise — the spec says echo it back.
    XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
    let serverInfo = result["serverInfo"] as? [String: Any] ?? [:]
    XCTAssertEqual(serverInfo["name"] as? String, "dht-server")
    XCTAssertNotNil(result["capabilities"])
  }

  func testInitializeFallsBackToLatestForUnknownVersion() async {
    let responses = await run(requests: [
      #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1.0.0","capabilities":{}}}"#
    ])
    let result = responses[0]["result"] as? [String: Any] ?? [:]
    XCTAssertEqual(result["protocolVersion"] as? String, MCPServer.latestProtocolVersion)
  }

  // MARK: - notifications

  func testInitializedNotificationProducesNoResponse() async {
    let responses = await run(requests: [
      #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
    ])
    XCTAssertTrue(responses.isEmpty)
  }

  // MARK: - tools/list

  func testToolsListReturnsCatalog() async {
    let responses = await run(requests: [
      #"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#
    ])
    XCTAssertEqual(responses.count, 1)
    let result = responses[0]["result"] as? [String: Any] ?? [:]
    let tools = result["tools"] as? [[String: Any]] ?? []
    let names = Set(tools.compactMap { $0["name"] as? String })
    XCTAssertEqual(names, [
      "resolve_compose", "resolve_edit", "resolve_restore",
      "compose", "edit", "restore", "pipeline",
      "get_capabilities", "list_runs", "get_run",
      "list_assets", "get_asset", "install_asset", "delete_asset",
    ])
    // Every tool must declare an inputSchema.
    for t in tools {
      XCTAssertNotNil(t["inputSchema"], "tool \(t["name"] ?? "?") missing inputSchema")
      XCTAssertNotNil(t["description"], "tool \(t["name"] ?? "?") missing description")
    }
  }

  // MARK: - tools/call resolve_compose

  func testToolsCallResolveComposeForwardsToEngine() async {
    let fake = FakeEngine()
    fake.update {
      $0.warnings = [
        Diagnostic(code: "BATCH_SIZE_MAY_CAP", fieldPath: "batch_size", message: "demo")
      ]
      $0.appliedDefaults = [
        AppliedDefault(fieldPath: "cfg_scale", value: .double(7.5))
      ]
      $0.estimatedComputeUnits = 1234
    }
    let req = #"""
      {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"resolve_compose","arguments":{"model":"any","prompt":"x","params":{"width":256,"height":256,"steps":1}}}}
      """#
    let responses = await run(requests: [req], fake: fake)
    XCTAssertEqual(responses.count, 1)
    let content = (responses[0]["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    XCTAssertEqual(content.count, 1)
    let text = content[0]["text"] as? String ?? ""
    XCTAssertTrue(text.contains("ResolveResponse"))
    XCTAssertTrue(text.contains("BATCH_SIZE_MAY_CAP"))
    XCTAssertTrue(text.contains("\"estimated_compute_units\" : 1234"))
    XCTAssertTrue(text.contains("\"field_path\" : \"cfg_scale\""))
  }

  // MARK: - tools/call compose

  func testToolsCallComposeReturnsImageAndSummary() async {
    let fake = FakeEngine()
    fake.update {
      $0.seed = 4242
      $0.imageBytes = Data("synthetic-png-payload".utf8)
    }
    let req = #"""
      {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"compose","arguments":{"model":"any","prompt":"x","params":{"width":256,"height":256,"steps":1,"batch_size":2}}}}
      """#
    let responses = await run(requests: [req], fake: fake)
    let content = (responses[0]["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    XCTAssertEqual(content.count, 4)  // 2 images (batch_size × batch_count=2×1) + summary + recipe
    XCTAssertEqual(content[0]["type"] as? String, "image")
    XCTAssertEqual(content[0]["mimeType"] as? String, "image/png")
    XCTAssertNotNil(content[0]["data"])
    XCTAssertEqual(content[1]["type"] as? String, "image")
    let summary = content[2]["text"] as? String ?? ""
    XCTAssertTrue(summary.contains("Generated 2 image"))
    XCTAssertTrue(summary.contains("seed=4242"))
    // REST `X-DHT-Recipe` parity: the result carries the canonical, re-postable
    // recipe as a final text block, with `via` injected.
    let recipe = content[3]["text"] as? String ?? ""
    XCTAssertTrue(recipe.contains("Recipe"), "expected a recipe block, got: \(recipe)")
    XCTAssertTrue(recipe.contains("\"via\":\"compose\""), "recipe must self-describe its verb")
  }

  func testToolsCallComposeMapsEngineErrorToToolError() async {
    let fake = FakeEngine()
    fake.update { $0.error = EngineError.baseModelNotInstalled(id: "absent") }
    let req = #"""
      {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"compose","arguments":{"model":"absent","prompt":"x","params":{"width":256,"height":256,"steps":1}}}}
      """#
    let responses = await run(requests: [req], fake: fake)
    let result = responses[0]["result"] as? [String: Any] ?? [:]
    XCTAssertEqual(result["isError"] as? Bool, true)
    let content = result["content"] as? [[String: Any]] ?? []
    let text = content.first?["text"] as? String ?? ""
    XCTAssertTrue(text.contains("MODEL_NOT_INSTALLED"))
    XCTAssertTrue(text.contains("'absent'"))
  }

  // MARK: - tools/call edit

  func testToolsCallEditReturnsImageAndSummary() async {
    let fake = FakeEngine()
    fake.update {
      $0.seed = 5151
      $0.imageBytes = Data("edited-png-payload".utf8)
    }
    let req = #"""
      {"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"edit","arguments":{"model":"any","from":{"image":"ZmFrZQ=="},"instruction":"make the sky red","params":{"width":256,"height":256,"steps":1}}}}
      """#
    let responses = await run(requests: [req], fake: fake)
    let content = (responses[0]["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    XCTAssertEqual(content.count, 3)  // 1 edited image + summary + recipe
    XCTAssertEqual(content[0]["type"] as? String, "image")
    XCTAssertEqual(content[0]["mimeType"] as? String, "image/png")
    let summary = content[1]["text"] as? String ?? ""
    XCTAssertTrue(summary.contains("seed=5151"))
    // Recipe parity, and the inline `from.image` must be redacted to a digest
    // reference (never the raw base64) — exactly as the REST header does.
    let recipe = content[2]["text"] as? String ?? ""
    XCTAssertTrue(recipe.contains("\"via\":\"edit\""))
    XCTAssertTrue(recipe.contains("sha256:"), "inline image must be a digest ref, got: \(recipe)")
    XCTAssertFalse(recipe.contains("ZmFrZQ=="), "raw base64 must not survive into the recipe")
  }

  // MARK: - tools/call install_asset / delete_asset

  func testDeleteAssetUnknownIdReturnsToolError() async {
    let req = #"""
      {"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"delete_asset","arguments":{"id":"does-not-exist"}}}
      """#
    let responses = await run(requests: [req])
    let result = responses[0]["result"] as? [String: Any] ?? [:]
    XCTAssertEqual(result["isError"] as? Bool, true)
    let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    XCTAssertTrue(text.contains("MODEL_NOT_INSTALLED"))
  }

  func testInstallAssetRefusedInReadOnlyMode() async {
    let req = #"""
      {"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"install_asset","arguments":{}}}
      """#
    let responses = await run(requests: [req], readOnly: true)
    let result = responses[0]["result"] as? [String: Any] ?? [:]
    XCTAssertEqual(result["isError"] as? Bool, true)
    let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    XCTAssertTrue(text.contains("READ_ONLY_MODE"))
  }

  func testDeleteAssetRefusedInReadOnlyMode() async {
    let req = #"""
      {"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"delete_asset","arguments":{"id":"x"}}}
      """#
    let responses = await run(requests: [req], readOnly: true)
    let result = responses[0]["result"] as? [String: Any] ?? [:]
    XCTAssertEqual(result["isError"] as? Bool, true)
    let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    XCTAssertTrue(text.contains("READ_ONLY_MODE"))
  }

  // MARK: - cancellation

  func testCancelledNotificationForUnknownRunIsHarmless() async {
    let responses = await run(requests: [
      #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":999}}"#
    ])
    XCTAssertTrue(responses.isEmpty)
  }

  func testCancelledNotificationCancelsInFlightGeneration() async {
    var logger = Logger(label: "test-mcp")
    logger.logLevel = .error
    let fake = FakeEngine()
    fake.update { $0.blockUntilCancelled = true }
    let registry = RunRegistry()
    let server = MCPServer(
      engine: fake, assets: AssetManager(), registry: registry,
      readOnly: false, maxActiveRuns: nil, logger: logger)

    let call: [String: Any] = [
      "jsonrpc": "2.0", "id": 5, "method": "tools/call",
      "params": [
        "name": "compose",
        "arguments": [
          "model": "any", "prompt": "x",
          "params": ["width": 256, "height": 256, "steps": 1],
        ],
      ],
    ]
    let callTask = Task { await server.handle(envelope: call) }

    // Wait until the run registers, then cancel it by request id.
    var registered = false
    for _ in 0..<300 where !registered {
      if await registry.activeCount() > 0 { registered = true; break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(registered, "generation must register in the RunRegistry")

    _ = await server.handle(envelope: [
      "jsonrpc": "2.0", "method": "notifications/cancelled",
      "params": ["requestId": 5],
    ])

    let response = await callTask.value
    let result = response?["result"] as? [String: Any] ?? [:]
    XCTAssertEqual(result["isError"] as? Bool, true)
    let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    XCTAssertTrue(text.contains("RUN_CANCELLED"), "got: \(text)")
    let stillActive = await registry.activeCount()
    XCTAssertEqual(stillActive, 0, "run must be unregistered after cancellation")
  }

  // MARK: - initialize carries engine version (parity with REST /v1/info)

  func testInitializeReportsEngineVersion() async {
    let responses = await run(requests: [
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}"#
    ])
    let serverInfo = (responses[0]["result"] as? [String: Any])?["serverInfo"] as? [String: Any] ?? [:]
    XCTAssertEqual(serverInfo["engineVersion"] as? String, dhtEngineVersion)
  }

  // MARK: - tools/call get_capabilities

  func testGetCapabilitiesUnknownModelReturnsToolError() async {
    let req = #"""
      {"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"get_capabilities","arguments":{"model_id":"definitely-does-not-exist"}}}
      """#
    let responses = await run(requests: [req])
    let result = responses[0]["result"] as? [String: Any] ?? [:]
    XCTAssertEqual(result["isError"] as? Bool, true)
    let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    XCTAssertTrue(text.contains("definitely-does-not-exist"))
  }

  func testGetCapabilitiesKnownModelReturnsContract() async throws {
    guard let spec = ModelZoo.availableSpecifications.first(where: {
      guard let arch = Architecture(rawValue: $0.version.rawValue),
        let cls = arch.behaviorClass
      else { return false }
      let modifier = Modifier.from(rawValue: $0.modifier?.rawValue)
      return !CapabilityMap.contracts(behaviorClass: cls, modifier: modifier).isEmpty
    }) else {
      throw XCTSkip("no catalog spec maps to a non-empty capability cell")
    }
    let req = """
      {"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"get_capabilities","arguments":{"model_id":"\(spec.file)"}}}
      """
    let responses = await run(requests: [req])
    let result = responses[0]["result"] as? [String: Any] ?? [:]
    XCTAssertNotEqual(result["isError"] as? Bool, true, "known model must not be a tool error")
    let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    XCTAssertTrue(text.contains("CapabilitiesResponse"))
    XCTAssertTrue(text.contains(spec.file))
    XCTAssertTrue(text.contains("\"operations\""))
  }

  // MARK: - tools/call list_runs / get_run

  func testListRunsEmptyWhenNothingInFlight() async {
    let req = #"""
      {"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"list_runs","arguments":{}}}
      """#
    let responses = await run(requests: [req])
    let text = ((responses[0]["result"] as? [String: Any])?["content"] as? [[String: Any]])?
      .first?["text"] as? String ?? ""
    XCTAssertTrue(text.contains("RunListResponse"))
    XCTAssertTrue(text.contains("\"runs\" : ["), "expected a runs array, got: \(text)")
  }

  func testGetRunUnknownIdReturnsToolError() async {
    let req = #"""
      {"jsonrpc":"2.0","id":33,"method":"tools/call","params":{"name":"get_run","arguments":{"run_id":"nope"}}}
      """#
    let responses = await run(requests: [req])
    let result = responses[0]["result"] as? [String: Any] ?? [:]
    XCTAssertEqual(result["isError"] as? Bool, true)
    let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    XCTAssertTrue(text.contains("nope"))
  }

  func testGetRunReturnsInFlightRunDetail() async throws {
    var logger = Logger(label: "test-mcp")
    logger.logLevel = .error
    let fake = FakeEngine()
    fake.update { $0.blockUntilCancelled = true }
    let registry = RunRegistry()
    let server = MCPServer(
      engine: fake, assets: AssetManager(), registry: registry,
      readOnly: false, maxActiveRuns: nil, logger: logger)

    let call: [String: Any] = [
      "jsonrpc": "2.0", "id": 40, "method": "tools/call",
      "params": [
        "name": "compose",
        "arguments": [
          "model": "any", "prompt": "x",
          "params": ["width": 256, "height": 256, "steps": 1],
        ],
      ],
    ]
    let callTask = Task { await server.handle(envelope: call) }

    var registered = false
    for _ in 0..<300 where !registered {
      if await registry.activeCount() > 0 { registered = true; break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(registered)

    // The MCP run id derives from the JSON-RPC id as `mcp-<id>`.
    let detail = await server.handle(envelope: [
      "jsonrpc": "2.0", "id": 41, "method": "tools/call",
      "params": ["name": "get_run", "arguments": ["run_id": "mcp-40"]],
    ])
    let text = ((detail?["result"] as? [String: Any])?["content"] as? [[String: Any]])?
      .first?["text"] as? String ?? ""
    XCTAssertTrue(text.contains("RunDetailResponse"))
    XCTAssertTrue(text.contains("mcp-40"))

    // Clean up the in-flight run.
    _ = await server.handle(envelope: [
      "jsonrpc": "2.0", "method": "notifications/cancelled",
      "params": ["requestId": 40],
    ])
    _ = await callTask.value
  }

  // MARK: - error envelopes

  func testUnknownMethodReturnsMethodNotFound() async {
    let responses = await run(requests: [
      #"{"jsonrpc":"2.0","id":9,"method":"does/not/exist"}"#
    ])
    let err = responses[0]["error"] as? [String: Any] ?? [:]
    XCTAssertEqual(err["code"] as? Int, -32601)
    XCTAssertTrue((err["message"] as? String ?? "").contains("does/not/exist"))
  }

  func testUnknownToolReturnsInvalidParams() async {
    let req = #"""
      {"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"nonexistent","arguments":{}}}
      """#
    let responses = await run(requests: [req])
    let err = responses[0]["error"] as? [String: Any] ?? [:]
    XCTAssertEqual(err["code"] as? Int, -32602)
    XCTAssertTrue((err["message"] as? String ?? "").contains("nonexistent"))
  }
}
