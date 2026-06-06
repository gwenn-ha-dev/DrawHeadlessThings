import Foundation
import Logging

/// Where the server accepts connections. The user picks *reachability*, not
/// a protocol family — each scope binds both an IPv4 and an IPv6 socket
/// (dual-stack), so clients reach the server however they resolve the host.
enum BindScope: String, Sendable {
  /// This machine only — loopback IPv4 (`127.0.0.1`) + IPv6 (`::1`).
  /// No bearer token required.
  case `private`
  /// All interfaces, IPv4 (`0.0.0.0`) + IPv6 (`::`) — reachable from the
  /// LAN. A bearer token is required.
  case `public`

  /// The pair of addresses to bind for this scope. A single socket cannot
  /// cover loopback over both families, so the server always opens two.
  var bindHosts: [String] {
    switch self {
    case .private: return ["127.0.0.1", "::1"]
    case .public: return ["0.0.0.0", "::"]
    }
  }
}

/// Centralized runtime configuration. Built once from `CommandLine.arguments`
/// in `DHTServer.main` and passed read-only to every subsystem.
struct ServerConfig: Sendable {
  let scope: BindScope
  let port: Int
  let modelsDirectory: String
  /// Required bearer token for a `public` bind. `nil` is only valid for a
  /// `private` bind; the parser enforces this.
  let token: String?
  let logLevel: Logger.Level
  /// Cap on concurrent generation runs. `nil` means uncapped.
  let maxActiveRuns: Int?
  /// When true, the asset-mutation routes (`POST /v1/assets/install`,
  /// `DELETE /v1/assets/{id}`) return 403 FORBIDDEN.
  let readOnly: Bool

  var isPrivate: Bool { scope == .private }

  /// Parses argv. Returns nil and writes a usage string on stderr for any
  /// validation failure (missing models dir, public without --token,
  /// unknown log level). The caller exits with code 1 on nil.
  static func parse(_ args: [String]) -> ServerConfig? {
    let modelsDir = argValue(args, name: "--models-dir") ?? defaultModelsDir()
    let port = argValue(args, name: "--port").flatMap(Int.init) ?? 7766
    let bindRaw = (argValue(args, name: "--bind") ?? "private").lowercased()
    let token = argValue(args, name: "--token")
    let logLevelRaw = argValue(args, name: "--log-level") ?? "info"
    let maxActiveRuns = argValue(args, name: "--max-active-runs").flatMap(Int.init)
    let readOnly = args.contains("--read-only")

    guard FileManager.default.fileExists(atPath: modelsDir) else {
      stderr("error: models directory does not exist: \(modelsDir)")
      return nil
    }
    guard let scope = BindScope(rawValue: bindRaw) else {
      stderr("error: --bind must be 'private' or 'public', got '\(bindRaw)'")
      return nil
    }
    guard let level = parseLogLevel(logLevelRaw) else {
      stderr(
        "error: --log-level must be one of trace|debug|info|notice|warning|error|critical, "
        + "got '\(logLevelRaw)'")
      return nil
    }
    if let mar = maxActiveRuns, mar < 1 {
      stderr("error: --max-active-runs must be >= 1, got \(mar)")
      return nil
    }
    // The point of the security rule: refuse to expose the server on the
    // LAN without a token. Done at startup, not per-request, so the
    // mistake can't ship silently.
    if scope == .public && (token == nil || token!.isEmpty) {
      stderr(
        "error: --bind public exposes the server on the LAN; --token is required. "
        + "Pass --token <secret> or use --bind private.")
      return nil
    }

    return ServerConfig(
      scope: scope,
      port: port,
      modelsDirectory: modelsDir,
      token: token,
      logLevel: level,
      maxActiveRuns: maxActiveRuns,
      readOnly: readOnly
    )
  }

  private static func argValue(_ args: [String], name: String) -> String? {
    guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
    return args[idx + 1]
  }

  private static func defaultModelsDir() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appending(
      path: "Library/Containers/com.liuliu.draw-things/Data/Documents/Models"
    ).path
  }

  private static func parseLogLevel(_ raw: String) -> Logger.Level? {
    Logger.Level(rawValue: raw.lowercased())
  }

  private static func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }
}
