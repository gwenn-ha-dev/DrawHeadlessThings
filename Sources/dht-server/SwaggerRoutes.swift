import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Mounts a vendored Swagger UI (`Resources/swagger-ui/`) at `/docs/` and the
/// raw OpenAPI spec at `/openapi.yaml`. `GET /` redirects to `/docs/`.
///
/// Assets are bundled via SPM resources and served from `Bundle.module`, so the
/// binary is self-contained — no network access required to render the UI.
/// Only an explicit allowlist of filenames is served to avoid path traversal.
func mountSwaggerRoutes(on router: Router<BasicRequestContext>) {
  router.get("/") { _, _ -> Response in
    redirect(to: "/docs")
  }
  router.get("/docs") { _, _ -> Response in
    try staticAsset(name: "index.html", subdirectory: "swagger-ui")
  }
  router.get("/docs/:file") { _, context -> Response in
    let file = context.parameters.get("file") ?? ""
    guard swaggerAllowlist.contains(file) else {
      throw HTTPError(.notFound)
    }
    return try staticAsset(name: file, subdirectory: "swagger-ui")
  }
  router.get("/openapi.yaml") { _, _ -> Response in
    try staticAsset(name: "openapi.yaml", subdirectory: nil)
  }
}

private let swaggerAllowlist: Set<String> = [
  "index.html",
  "swagger-ui.css",
  "swagger-ui-bundle.js",
  "swagger-ui-standalone-preset.js",
  "favicon-16x16.png",
  "favicon-32x32.png",
]

private func staticAsset(name: String, subdirectory: String?) throws -> Response {
  let dotIndex = name.lastIndex(of: ".") ?? name.endIndex
  let stem = String(name[..<dotIndex])
  let ext = dotIndex == name.endIndex ? "" : String(name[name.index(after: dotIndex)...])
  let url: URL? = Bundle.module.url(
    forResource: stem, withExtension: ext, subdirectory: subdirectory)
  guard let url, let data = try? Data(contentsOf: url) else {
    throw HTTPError(.notFound)
  }
  var response = Response(
    status: .ok,
    body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
  response.headers[.contentType] = contentType(forExtension: ext)
  return response
}

private func contentType(forExtension ext: String) -> String {
  switch ext.lowercased() {
  case "html": return "text/html; charset=utf-8"
  case "css": return "text/css; charset=utf-8"
  case "js": return "application/javascript; charset=utf-8"
  case "png": return "image/png"
  case "yaml", "yml": return "application/yaml; charset=utf-8"
  default: return "application/octet-stream"
  }
}

private func redirect(to location: String) -> Response {
  var response = Response(
    status: .found, body: ResponseBody(byteBuffer: ByteBuffer()))
  response.headers[.location] = location
  return response
}
