import Foundation
import HTTPTypes
import Hummingbird

/// Bearer-token authentication. Enforces `Authorization: Bearer <token>` on
/// every request. Only installed when the server is bound to a non-loopback
/// interface (`ServerConfig.parse` refuses to start in that mode without a
/// token, so this middleware never has a nil token to compare against).
struct BearerAuthMiddleware<Context: RequestContext>: RouterMiddleware {
  let token: String

  func handle(
    _ request: Request,
    context: Context,
    next: (Request, Context) async throws -> Response
  ) async throws -> Response {
    // `GET /health` is auth-exempt: a liveness probe a supervisor or uptime
    // monitor can hit without credentials. It reveals only that the process is
    // up — which a bare TCP connect already does — so there is nothing to gate.
    if request.method == .get && request.uri.path == "/health" {
      return try await next(request, context)
    }
    guard let header = request.headers[.authorization] else {
      throw TypedError(
        status: .unauthorized,
        errorCode: "UNAUTHENTICATED",
        title: "Missing Authorization header",
        detail: "Expected: 'Authorization: Bearer <token>'."
      )
    }
    let prefix = "Bearer "
    guard header.hasPrefix(prefix) else {
      throw TypedError(
        status: .unauthorized,
        errorCode: "UNAUTHENTICATED",
        title: "Malformed Authorization header",
        detail: "Expected 'Bearer <token>'."
      )
    }
    let presented = String(header.dropFirst(prefix.count))
    guard Self.constantTimeEquals(presented, token) else {
      throw TypedError(
        status: .unauthorized,
        errorCode: "UNAUTHENTICATED",
        title: "Invalid token",
        detail: nil
      )
    }
    return try await next(request, context)
  }

  /// Length-leaking but value-constant compare: returns the same number of
  /// XOR operations whatever the byte position of the first divergence is.
  /// Lengths must match (different lengths → false immediately, since
  /// length is not a sensitive value here — the token's length is public
  /// in the sense that anyone can probe it with a 1-byte presentation).
  static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let aBytes = Array(a.utf8)
    let bBytes = Array(b.utf8)
    guard aBytes.count == bBytes.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<aBytes.count {
      diff |= aBytes[i] ^ bBytes[i]
    }
    return diff == 0
  }
}
