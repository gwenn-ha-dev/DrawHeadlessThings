import Foundation
import Hummingbird
import Logging
import ModelZoo
import NNC
import _MediaGenerationKit

/// Single source of truth for the API version reported by `/v1/info`,
/// the MCP `initialize` reply, and `--help`. Keep in sync with
/// `info.version` in `Resources/openapi.yaml`.
let dhtAPIVersion = "0.3.2"

@main
struct DHTServer {
  static func main() async throws {
    let args = CommandLine.arguments
    if args.contains("--help") || args.contains("-h") {
      print(helpText)
      return
    }
    // Line-buffer stdout: when it is a pipe (e.g. captured by the
    // DHTServer.app menu-bar supervisor) rather than a TTY, the C library
    // block-buffers it and log lines never surface until ~4 KB accumulates.
    // Line buffering flushes every newline-terminated line immediately.
    setvbuf(stdout, nil, _IOLBF, 0)

    guard let config = ServerConfig.parse(args) else {
      exit(1)
    }

    // Secret mode: swallow every swift-log Logger process-wide before any
    // logger is created — server, engine, MCP, Hummingbird internals, and
    // the request-log middleware all route through this no-op backend, so
    // nothing is emitted. (stdout/stderr are additionally sent to /dev/null
    // by the menu-bar supervisor; here we also skip the startup banner.)
    if config.silent {
      LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }
    }

    // Match what the DT GUI app does at startup: copy tensor data into an
    // MTLBuffer and munmap immediately, rather than wrap the live mmap in a
    // file-backed MTLBuffer. Without this flag the SDK keeps each model
    // tensor mmap'd for the lifetime of its MTLBuffer; mappings accumulate
    // across requests and a long-running server eventually hits the
    // `aligned_ptr == bufptr` assert in ccv_nnc_mps.m when a new mmap fails.
    // DT GUI (observed via vmmap) keeps only ~8 small (≤38 MB) tensordata
    // mappings alive at steady state — that's what this flag buys us.
    DynamicGraph.flags.insert(.disableMmapMTLBuffer)

    // Point both ModelZoo (for asset catalog lookups) and the shared
    // MediaGenerationEnvironment (used by the pipeline) at the models dir.
    // MediaGenerationEnvironment internally propagates externalUrls to ModelZoo,
    // but isExternalUrlsPreferred must be set explicitly so isDownloaded checks
    // resolve against the external dir before the bundled-default location.
    let url = URL(fileURLWithPath: config.modelsDirectory, isDirectory: true)
    MediaGenerationEnvironment.default.externalUrls = [url]
    ModelZoo.isExternalUrlsPreferred = true

    var logger = Logger(label: "dht-server")
    logger.logLevel = config.logLevel

    var engineLogger = Logger(label: "dht-engine")
    engineLogger.logLevel = config.logLevel
    let engine = DrawThingsEngine(
      modelsDirectory: config.modelsDirectory, logger: engineLogger)
    let assets = AssetManager()
    let registry = RunRegistry()
    let router = makeRouter(
      engine: engine, assets: assets, registry: registry, config: config)
    // Dual-stack: one listener per family (IPv4 + IPv6), sharing the router.
    // A single socket can't cover loopback over both families, so the
    // server always opens two — the user picks reachability, not a family.
    let apps = config.scope.bindHosts.map { host in
      Application(
        router: router,
        configuration: .init(
          address: .hostname(host, port: config.port),
          serverName: "dht-server"
        ),
        logger: logger
      )
    }

    let authNote = config.isPrivate ? "private (no auth)" : "public (token required)"
    let readOnlyNote = config.readOnly ? " [read-only]" : ""
    let maxRunsNote = config.maxActiveRuns.map { " [max_active_runs=\($0)]" } ?? ""
    let bound = config.scope.bindHosts
      .map { $0.contains(":") ? "[\($0)]:\(config.port)" : "\($0):\(config.port)" }
      .joined(separator: ", ")
    if !config.silent {
      print(
        "dht-server listening on \(bound) "
        + "(models: \(config.modelsDirectory)) — \(authNote)\(readOnlyNote)\(maxRunsNote)")
    }

    // Run both listeners concurrently; when one stops (shutdown signal or
    // failure) tear the other down too.
    try await withThrowingTaskGroup(of: Void.self) { group in
      for app in apps {
        group.addTask { try await app.runService() }
      }
      try await group.next()
      group.cancelAll()
    }
  }

  private static let helpText: String = """
    dht-server \(dhtAPIVersion) — REST + MCP server around the Draw Things engine.

    USAGE:
      dht-server [flags]              Start the server
      dht-server --help               Show this message

    FLAGS:
      --bind <scope>          Reachability — 'private' (loopback only, no
                              auth) or 'public' (LAN, requires --token).
                              Default: private. Always dual-stack (IPv4+IPv6).
      --port <n>              Listening port (default: 7766).
      --token <secret>        Bearer token; required when --host is not loopback.
      --models-dir <path>     Draw Things models directory.
                              Default: ~/Library/Containers/com.liuliu.draw-things/
                                       Data/Documents/Models
      --log-level <level>     trace|debug|info|notice|warning|error|critical
                              (default: info)
      --max-active-runs <n>   Cap on concurrent generation runs (default: uncapped).
      --read-only             Refuse asset mutations (POST /v1/assets/install,
                              DELETE /v1/assets/{id}) with 403 READ_ONLY_MODE.
      --silent                Secret mode: emit no logs of any kind — no
                              startup banner, no request logs, no engine
                              logs (swift-log is bootstrapped to a no-op).

    EXAMPLES:
      dht-server                                # private (loopback), no auth
      dht-server --port 8080 --read-only        # Custom port, mutations refused
      dht-server --bind public \\
                 --token "$(openssl rand -hex 32)"   # LAN bind, IPv4 + IPv6

    ONCE RUNNING:
      http://localhost:7766/docs              Interactive Swagger UI
      http://localhost:7766/openapi.yaml      Raw OpenAPI 3.1 spec
      http://localhost:7766/mcp               MCP endpoint (Streamable HTTP)
      http://localhost:7766/health            Liveness probe (no auth)
      http://localhost:7766/v1/info           Version probe
    """
}
