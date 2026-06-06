import Foundation
import Hummingbird
import XCTest

@testable import dht_server

/// Pure-function tests on `ServerConfig.parse`. No server, no engine.
/// We rely on the cwd having `/tmp` to satisfy the models-dir existence
/// check that's not the point of these tests.
final class ServerConfigTests: XCTestCase {
  private let dummyModelsDir = "/tmp"

  func testPrivateDefaults() {
    let c = ServerConfig.parse(["dht-server", "--models-dir", dummyModelsDir])
    XCTAssertNotNil(c)
    XCTAssertEqual(c?.scope, .private)
    XCTAssertEqual(c?.port, 7766)
    XCTAssertNil(c?.token)
    XCTAssertEqual(c?.logLevel, .info)
    XCTAssertNil(c?.maxActiveRuns)
    XCTAssertFalse(c?.readOnly ?? true)
    XCTAssertTrue(c?.isPrivate ?? false)
  }

  func testPublicWithoutTokenIsRefused() {
    let c = ServerConfig.parse([
      "dht-server", "--models-dir", dummyModelsDir, "--bind", "public",
    ])
    XCTAssertNil(c, "A public bind without --token must refuse to start")
  }

  func testPublicWithTokenIsAccepted() {
    let c = ServerConfig.parse([
      "dht-server", "--models-dir", dummyModelsDir, "--bind", "public",
      "--token", "secret",
    ])
    XCTAssertNotNil(c)
    XCTAssertEqual(c?.scope, .public)
    XCTAssertFalse(c?.isPrivate ?? true)
    XCTAssertEqual(c?.token, "secret")
  }

  func testGarbageBindScopeIsRefused() {
    let c = ServerConfig.parse([
      "dht-server", "--models-dir", dummyModelsDir, "--bind", "0.0.0.0",
    ])
    XCTAssertNil(c, "--bind only accepts 'private' or 'public'")
  }

  func testBindScopeBindHosts() {
    XCTAssertEqual(BindScope.private.bindHosts, ["127.0.0.1", "::1"])
    XCTAssertEqual(BindScope.public.bindHosts, ["0.0.0.0", "::"])
  }

  func testGarbageLogLevelIsRefused() {
    let c = ServerConfig.parse([
      "dht-server", "--models-dir", dummyModelsDir, "--log-level", "garbage",
    ])
    XCTAssertNil(c)
  }

  func testZeroMaxActiveRunsIsRefused() {
    let c = ServerConfig.parse([
      "dht-server", "--models-dir", dummyModelsDir, "--max-active-runs", "0",
    ])
    XCTAssertNil(c)
  }

  func testReadOnlyFlagFlips() {
    let c = ServerConfig.parse([
      "dht-server", "--models-dir", dummyModelsDir, "--read-only",
    ])
    XCTAssertEqual(c?.readOnly, true)
  }

  func testConstantTimeEqualsBehavior() {
    XCTAssertTrue(BearerAuthMiddleware<BasicRequestContext>.constantTimeEquals("a", "a"))
    XCTAssertFalse(BearerAuthMiddleware<BasicRequestContext>.constantTimeEquals("a", "b"))
    XCTAssertFalse(
      BearerAuthMiddleware<BasicRequestContext>.constantTimeEquals("short", "longer"))
    XCTAssertTrue(BearerAuthMiddleware<BasicRequestContext>.constantTimeEquals("", ""))
  }
}
