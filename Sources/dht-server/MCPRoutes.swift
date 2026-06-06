import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Streamable HTTP transport (MCP spec 2025-11-25) for the embedded MCP
/// server. Mounts `POST /mcp` and a `GET /mcp` that returns 405 — we send no
/// unsolicited server→client traffic, which the spec permits.
///
/// `/mcp` sits behind the same router-wide `BearerAuthMiddleware` as the REST
/// API, so a non-loopback bind requires `Authorization: Bearer <token>` here
/// too. One `MCPServer` shares the `GenerationEngine` + `AssetManager` with
/// the REST routes — single backend, single process.
///
/// Response shape: a `tools/call` that carries a `_meta.progressToken` and
/// whose caller accepts `text/event-stream` is answered as an SSE stream —
/// `notifications/progress` events first, then the JSON-RPC response as the
/// final event. Every other request is answered as one `application/json`
/// body. Notifications (no `id`) are acknowledged with `202 Accepted`.
func mountMCPRoutes(on router: Router<BasicRequestContext>, server: MCPServer) {
  router.post("/mcp") { request, _ -> Response in
    let buffer = try await request.body.collect(upTo: 64 * 1024 * 1024)
    let data = Data(buffer: buffer)

    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let envelope = object as? [String: Any]
    else {
      return mcpJSONResponse(
        status: .badRequest,
        object: MCPServer.parseErrorEnvelope(message: "Body is not a JSON-RPC object"))
    }

    // A notification carries no `id`; acknowledge with 202 and no body.
    let id = envelope["id"]
    if id == nil || id is NSNull {
      _ = await server.handle(envelope: envelope)
      return Response(status: .accepted)
    }

    if shouldStream(envelope: envelope, request: request) {
      return mcpStreamingResponse(server: server, requestData: data)
    }
    let response = await server.handle(envelope: envelope) ?? [:]
    return mcpJSONResponse(status: .ok, object: response)
  }

  router.get("/mcp") { _, _ -> Response in
    // No unsolicited server→client messages — the spec permits 405 here.
    Response(status: .methodNotAllowed)
  }
}

/// Streams only when the client opted into progress (`_meta.progressToken` on
/// a `tools/call`) AND accepts an event stream. Otherwise a single JSON body
/// is simpler and just as correct — the client merely waits for the response.
private func shouldStream(envelope: [String: Any], request: Request) -> Bool {
  guard (envelope["method"] as? String) == "tools/call" else { return false }
  guard
    let params = envelope["params"] as? [String: Any],
    let meta = params["_meta"] as? [String: Any],
    meta["progressToken"] != nil
  else { return false }
  return (request.headers[.accept] ?? "").contains("text/event-stream")
}

/// Runs the request on a background task, streaming `notifications/progress`
/// as they arrive and the JSON-RPC response as the final SSE event. The
/// request `Data` (not the parsed dictionary) is captured so nothing
/// non-`Sendable` crosses into the task.
private func mcpStreamingResponse(server: MCPServer, requestData: Data) -> Response {
  let (events, continuation) = AsyncStream<ByteBuffer>.makeStream()

  let sink: MCPServer.NotificationSink = { payload in
    continuation.yield(sseFrame(payload))
  }

  Task<Void, Never> {
    let envelope =
      (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any] ?? [:]
    let response = await server.handle(envelope: envelope, emit: sink) ?? [:]
    if let data = try? JSONSerialization.data(
      withJSONObject: response, options: [.withoutEscapingSlashes])
    {
      continuation.yield(sseFrame(data))
    }
    continuation.finish()
  }

  var headers = HTTPFields()
  headers[.contentType] = "text/event-stream"
  headers[.cacheControl] = "no-store"
  return Response(status: .ok, headers: headers, body: .init(asyncSequence: events))
}

/// One SSE event carrying a JSON-RPC message: `data: <json>\n\n`. MCP's
/// Streamable HTTP transport puts the JSON-RPC payload straight in `data:`
/// with no named `event:` field.
private func sseFrame(_ payload: Data) -> ByteBuffer {
  var buf = ByteBuffer()
  buf.writeString("data: ")
  buf.writeBytes(payload)
  buf.writeString("\n\n")
  return buf
}

private func mcpJSONResponse(status: HTTPResponse.Status, object: [String: Any]) -> Response {
  let data =
    (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))
    ?? Data("{}".utf8)
  var headers = HTTPFields()
  headers[.contentType] = "application/json"
  return Response(
    status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(data: data)))
}
