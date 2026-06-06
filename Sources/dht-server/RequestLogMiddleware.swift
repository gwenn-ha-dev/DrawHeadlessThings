import HTTPTypes
import Hummingbird

/// Logs each HTTP request at `.info` so a supervisor — the DHTServer.app log
/// window, or a plain `dht-server` terminal — shows real activity.
///
/// Polling and static-UI endpoints are deliberately skipped: a client (or
/// the menu-bar app) checking `/v1/info` and `/v1/runs` on a 1 s timer would
/// otherwise produce a few lines per second and bury actual generation work.
struct RequestLogMiddleware<Context: RequestContext>: RouterMiddleware {
  func handle(
    _ request: Request,
    context: Context,
    next: (Request, Context) async throws -> Response
  ) async throws -> Response {
    do {
      let response = try await next(request, context)
      log(request, context, outcome: "\(response.status.code)")
      return response
    } catch {
      // Surface the typed error code so a failed request is diagnosable
      // from the tail, not just flagged as "error".
      let code = (error as? TypedError)?.errorCode
      log(request, context, outcome: code.map { "error \($0)" } ?? "error")
      throw error
    }
  }

  private func log(_ request: Request, _ context: Context, outcome: String) {
    guard !isPolling(request) else { return }
    context.logger.info("\(request.method.rawValue) \(request.uri.path) → \(outcome)")
  }

  /// True for endpoints that get polled on a timer or are static UI assets.
  private func isPolling(_ request: Request) -> Bool {
    guard request.method == .get else { return false }
    let path = request.uri.path
    return path == "/v1/info" || path == "/health"
      || path == "/v1/runs" || path.hasPrefix("/v1/runs/")
      || path == "/" || path == "/openapi.yaml" || path.hasPrefix("/docs")
      || path == "/mcp/setup"
  }
}
