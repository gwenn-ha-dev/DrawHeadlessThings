import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Serves the human-facing MCP setup page at `GET /mcp/setup` — connection
/// details (endpoint URL + token), per-client instructions, an `mcp-remote`
/// config-file fallback, and a live tool list. The page is generated per
/// request so the endpoint URL reflects however the browser actually reached
/// the server (its `Host` header), whatever the bind address is.
func mountMCPSetupRoute(on router: Router<BasicRequestContext>, config: ServerConfig) {
  router.get("/mcp/setup") { request, _ -> Response in
    // `.host` is unavailable on HTTPField.Name (it's an HTTP/2 pseudo-header);
    // look the field up by name so the page URL tracks however the browser
    // actually reached the server.
    let host =
      HTTPField.Name("Host").flatMap { request.headers[$0] }
      ?? "127.0.0.1:\(config.port)"
    var response = Response(
      status: .ok,
      body: .init(byteBuffer: ByteBuffer(string: mcpSetupHTML(host: host, token: config.token))))
    response.headers[.contentType] = "text/html; charset=utf-8"
    return response
  }
}

/// Minimal HTML escaping for the values interpolated into the page.
private func htmlEscape(_ s: String) -> String {
  var out = s
  out = out.replacingOccurrences(of: "&", with: "&amp;")
  out = out.replacingOccurrences(of: "<", with: "&lt;")
  out = out.replacingOccurrences(of: ">", with: "&gt;")
  out = out.replacingOccurrences(of: "\"", with: "&quot;")
  return out
}

/// Builds the standalone setup page. `host` is the `host:port` the browser
/// used; `token` is the bearer token, or `nil` on a loopback (no-auth) bind.
func mcpSetupHTML(host: String, token: String?) -> String {
  let endpoint = "http://\(host)/mcp"
  let safeEndpoint = htmlEscape(endpoint)

  // `mcp-remote` fallback config block — bridges a stdio client to this HTTP
  // endpoint, and copes with plain http:// LAN addresses some connector UIs
  // reject. Encoded with JSONSerialization so quoting is always correct.
  var mcpRemoteArgs: [String] = ["-y", "mcp-remote", endpoint]
  if let token { mcpRemoteArgs += ["--header", "Authorization: Bearer \(token)"] }
  let mcpRemoteConfig: [String: Any] = [
    "mcpServers": ["dht-server": ["command": "npx", "args": mcpRemoteArgs]]
  ]
  let mcpRemoteJSON =
    (try? JSONSerialization.data(
      withJSONObject: mcpRemoteConfig, options: [.prettyPrinted, .withoutEscapingSlashes]))
    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

  let tokenSection: String
  if let token {
    tokenSection = """
        <h2>Token</h2>
        <p>This server requires bearer authentication. Supply the token as the
        HTTP header <code>Authorization: Bearer &lt;token&gt;</code>.</p>
        <div class="field"><code id="token">\(htmlEscape(token))</code><button data-copy="token">Copy</button></div>
      """
  } else {
    tokenSection = """
        <h2>Token</h2>
        <p>This server is on a loopback bind — <b>no token required</b>. Bind to
        a non-loopback address with <code>--token</code> to expose it on a LAN.</p>
      """
  }

  let authNote =
    token != nil
    ? " and, under authentication, the bearer token"
    : ""

  // JS-embedded values: JSON-encoded so they are safe string literals.
  let jsEndpoint = jsonString(endpoint)
  let jsToken = token.map(jsonString) ?? "null"

  return """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>dht-server — MCP setup</title>
    <style>
      :root { color-scheme: light dark; }
      body { font: 15px/1.55 -apple-system, system-ui, sans-serif; margin: 0;
             background: Canvas; color: CanvasText; }
      main { max-width: 760px; margin: 0 auto; padding: 2rem 1.25rem 4rem; }
      h1 { font-size: 1.5rem; }
      h2 { font-size: 1.05rem; margin: 2rem 0 .5rem; }
      p { margin: .5rem 0; }
      code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
      .field { display: flex; gap: .5rem; align-items: flex-start; margin: .6rem 0; }
      .field code, .field pre { flex: 1; margin: 0; padding: .6rem .7rem;
        background: rgba(127,127,127,.14); border-radius: 6px; overflow-x: auto;
        white-space: pre-wrap; word-break: break-all; }
      button { font: inherit; padding: .45rem .8rem; border-radius: 6px;
        border: 1px solid rgba(127,127,127,.4); background: transparent;
        color: inherit; cursor: pointer; white-space: nowrap; }
      button:active { background: rgba(127,127,127,.2); }
      .note { font-size: .9rem; opacity: .8; }
      ul#tools { padding-left: 1.1rem; }
      ul#tools li { margin: .35rem 0; }
      ul#tools code { font-weight: 600; }
    </style>
    </head>
    <body>
    <main>
      <h1>Connect an AI client via MCP</h1>
      <p>This server exposes a Model Context Protocol endpoint (Streamable HTTP,
      spec 2025-11-25). Point any MCP-capable client at the endpoint below.</p>

      <section>
        <h2>Endpoint</h2>
        <div class="field"><code id="endpoint">\(safeEndpoint)</code><button data-copy="endpoint">Copy</button></div>
      </section>

      <section>
      \(tokenSection)
      </section>

      <section>
        <h2>Claude Desktop / claude.ai</h2>
        <p>Settings → Connectors → <b>Add custom connector</b>, then paste the
        endpoint URL\(authNote).</p>
        <p class="note">If the connector UI rejects an <code>http://</code> URL
        (some require HTTPS), use the config-file fallback below.</p>
      </section>

      <section>
        <h2>Config-file fallback (mcp-remote)</h2>
        <p>Add this to <code>claude_desktop_config.json</code>. It bridges a
        local stdio client to this HTTP endpoint and works with plain
        <code>http://</code> LAN addresses. Requires Node (<code>npx</code>).</p>
        <div class="field"><pre id="mcpremote">\(htmlEscape(mcpRemoteJSON))</pre><button data-copy="mcpremote">Copy</button></div>
      </section>

      <section>
        <h2>ChatGPT / Cursor</h2>
        <p>Add a remote MCP server / connector with the endpoint URL\(authNote).
        The exact UI varies by client.</p>
      </section>

      <section>
        <h2>Tools</h2>
        <ul id="tools"><li class="note">Loading…</li></ul>
      </section>
    </main>
    <script>
      const ENDPOINT = \(jsEndpoint), TOKEN = \(jsToken);
      for (const b of document.querySelectorAll('[data-copy]')) {
        b.addEventListener('click', () => {
          const el = document.getElementById(b.dataset.copy);
          navigator.clipboard.writeText(el.textContent).then(() => {
            const t = b.textContent; b.textContent = 'Copied'; b.disabled = true;
            setTimeout(() => { b.textContent = t; b.disabled = false; }, 1200);
          });
        });
      }
      const headers = { 'Content-Type': 'application/json' };
      if (TOKEN) headers['Authorization'] = 'Bearer ' + TOKEN;
      fetch(ENDPOINT, {
        method: 'POST', headers,
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' })
      })
        .then(r => r.json())
        .then(d => {
          const tools = (d.result && d.result.tools) || [];
          const ul = document.getElementById('tools');
          ul.innerHTML = '';
          for (const t of tools) {
            const li = document.createElement('li');
            const code = document.createElement('code');
            code.textContent = t.name;
            li.appendChild(code);
            li.appendChild(document.createTextNode(' — ' + (t.description || '')));
            ul.appendChild(li);
          }
        })
        .catch(() => {
          document.getElementById('tools').innerHTML =
            '<li class="note">Could not load the tool list.</li>';
        });
    </script>
    </body>
    </html>
    """
}

/// Encodes a string as a JSON string literal (with surrounding quotes), for
/// safe embedding into the page's inline script.
private func jsonString(_ s: String) -> String {
  (try? JSONSerialization.data(withJSONObject: [s]))
    .flatMap { String(data: $0, encoding: .utf8) }
    .map { String($0.dropFirst().dropLast()) }  // strip the array brackets
    ?? "\"\""
}
