# DrawHeadlessThings

<p align="center">
  <img src="docs/screenshots/hero.png" alt="DrawHeadlessThings" width="512">
</p>

<p align="center">
  <a href="https://github.com/gwenn-ha-dev/DrawHeadlessThings/actions/workflows/ci.yml"><img src="https://github.com/gwenn-ha-dev/DrawHeadlessThings/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg" alt="License: GPL-3.0-or-later"></a>
  <img src="https://img.shields.io/badge/platform-macOS%20%C2%B7%20Apple%20Silicon-lightgrey.svg" alt="Platform: macOS Apple Silicon">
</p>

A headless macOS server around the
[`draw-things-community`](https://github.com/drawthingsai/draw-things-community)
image-generation engine. One process exposes the engine two ways:

- a **REST API** (OpenAPI 3.1) — three semantic verbs: `compose`, `edit`, `restore`
- an **MCP endpoint** (Model Context Protocol, Streamable HTTP) for AI clients

`DHTServer.app` is an optional menu-bar agent that supervises the server.

> **Apple Silicon only.** The engine wraps Metal kernels; an x86_64 build
> would fall over at the first generate call.
>
> **Status — work in progress.** Interfaces may still change before 1.0.

## What it's for

A small project with a narrow goal: drive the Draw Things engine entirely over
an HTTP API, so image and video generation can be built as workflows — and so
AI agents can do the same at scale over MCP. That's the whole idea.

- **Full-API workflows.** The engine's capabilities reachable as plain HTTP:
  `compose` / `edit` / `restore`, chained into pipelines, with a
  side-effect-free `resolve` dry-run to inspect a request before it runs.
- **MCP for AI.** The same surface over the Model Context Protocol — letting AI
  agents generate, edit, and chain images programmatically, at scale, is the
  main reason this exists.
- **Stateless and reproducible.** No sessions, no server-side gallery. Every
  response carries an `X-DHT-Recipe` — the canonical, re-postable recipe that
  produced the bytes. Same recipe + same seed → same bytes.
- **Self-describing.** A capability map and the `resolve` dry-run report what a
  given model accepts before you spend GPU time.

## Install

Download the latest `DHTServer-<version>.dmg` from the
[Releases](https://github.com/gwenn-ha-dev/DrawHeadlessThings/releases)
page, open it, and drag **DHTServer.app** into **Applications**.

The app is signed ad-hoc but **not notarized** (no paid Apple Developer
account), so on first launch macOS Gatekeeper will block it. Open it once —
right-click the app → **Open** (macOS 14), or **System Settings → Privacy &
Security → Open Anyway** (macOS 15+). Or clear the quarantine flag from a
terminal:

```bash
xattr -dr com.apple.quarantine /Applications/DHTServer.app
```

After that it launches normally. DHTServer.app is a menu-bar agent that runs
the embedded `dht-server` (REST + MCP). Point it at your Draw Things models
directory in **Settings** and it starts serving on `localhost:7766` — the server
can also install models on demand via `POST /v1/assets/install`.

Prefer headless, no GUI? Build `dht-server` from source ([below](#build-from-source)),
or run the binary embedded in the app directly:
`DHTServer.app/Contents/Resources/dht-server --models-dir <path>`.

## Quick start

Once the server is up on `localhost:7766`, ask it to compose an image:

```bash
curl -X POST http://localhost:7766/v1/compose \
  -H 'content-type: application/json' \
  -d '{
        "model": "z_image_turbo_1.0_q8p.ckpt",
        "prompt": "a misty forest at dawn, cinematic",
        "params": { "width": 1024, "height": 1024, "steps": 8 }
      }' \
  | jq -r '.images[0]' | base64 -D > forest.png
```

The JSON response also carries `seed`, `generation_time_ms`, and a full
`metadata` envelope (warnings, applied defaults). The same body, posted
to `/v1/resolve/compose`, runs as a dry-run that surfaces those defaults
and any engine-quirk warnings without touching the GPU.

## API surface

| Route | Purpose |
|---|---|
| `POST /v1/compose` · `edit` · `restore` | Generate (image or video, per the model's domain) |
| `POST /v1/resolve/{verb}` | Side-effect-free dry-run: defaults, warnings, compute estimate |
| `POST /v1/pipeline` | Chain verbs; step outputs feed later steps via `$<name>` refs |
| `GET /v1/capabilities/{model_id}` | What a model accepts, silently drops, or refuses |
| `GET /v1/assets` · `GET/DELETE /v1/assets/{id}` · `POST /v1/assets/install` | Model/asset management (catalog-driven installs) |
| `GET /v1/runs` · `GET/DELETE /v1/runs/{id}` | In-flight run list, detail (live preview), cancel |
| `GET /v1/info` | API + engine version |
| `GET /health` | Liveness probe — **no auth**, for supervisors and monitors |
| `POST /mcp` | MCP (Streamable HTTP); tools mirror the routes above |
| `GET /docs` · `GET /openapi.yaml` | Swagger UI and the raw spec |

Add `?stream=true` to a generation route for an SSE progress stream. Set
`Accept: image/png` (etc.) to get raw bytes instead of the JSON envelope.

## Security model

- **Default bind is loopback, no auth** — `::1` / `127.0.0.1` only. Assumes a
  trusted local machine.
- **`--bind public`** exposes the server on the LAN and **requires `--token`**
  (constant-time compared). No TLS — front it with a reverse proxy if you need
  one. `GET /health` stays unauthenticated by design.
- **`--read-only`** refuses all asset mutations (install/delete) with `403`.
- **`--max-active-runs N`** caps concurrent generations.

See [SECURITY.md](SECURITY.md) for the full trust-boundary notes and how to
report vulnerabilities.

## MCP

The MCP endpoint mounts on the same process and sits behind the same auth. Its
tool catalog mirrors the REST surface one-for-one — the verbs and their
resolves, `pipeline`, `get_capabilities`, `list_runs` / `get_run`, the asset
tools — and generation results carry the same canonical recipe as the REST
`X-DHT-Recipe` header. Cancellation uses the standard `notifications/cancelled`.

- Setup page (connection details): `http://localhost:7766/mcp/setup`
- Tools are self-describing via `tools/list`.

## Menu-bar app (optional)

`DHTServer.app` is a pure-SwiftUI menu-bar agent that supervises the
`dht-server` process — status, start/stop, a live log window, and a settings
panel (models directory, port, bind). It links no engine code; it just spawns
and watches the binary. Build it with `scripts/make-app.sh` (ad-hoc signed —
fine for your own machines; notarize it before distributing to others).

## Reference

The OpenAPI spec is the canonical reference — keep it open beside this
README, not as a substitute for it:

- REST — `Sources/dht-server/Resources/openapi.yaml`, or the live
  Swagger UI at `http://localhost:7766/docs`
- MCP — the setup page at `http://localhost:7766/mcp/setup`; tools are
  self-describing via `tools/list`

## Build from source

The build depends on a local sibling clone of `draw-things-community`,
pinned to a known SHA and patched additively to vend the `ModelZoo`
catalog as a library product. `scripts/setup-dev.sh` clones and patches
it; it is idempotent, so re-running it is safe and a no-op once set up.

```bash
./scripts/setup-dev.sh   # one-time: clone + patch ../draw-things-community
swift build
swift test
```

Plain `swift build` without the setup step will fail — the engine clone
won't exist. See `scripts/dtc-products.patch` for the exact
(additive-only) patch.

End-to-end smoke test against a running server with a real base model
installed:

```bash
DHT_MODELS_DIR=/path/to/Models ./scripts/smoke-test.sh
```

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Credits

Essentially all of the substance — the diffusion engine, the Metal kernels,
the model catalog — is the work of Liu Liu and the Draw Things community in
[`draw-things-community`](https://github.com/drawthingsai/draw-things-community).
This project is a thin server on top. See [CITATION.cff](CITATION.cff).

## License

DrawHeadlessThings is licensed under the **GNU General Public License
v3.0 or later** — required because it statically links the GPL-3.0
`draw-things-community` engine. See [LICENSE](LICENSE) for the full
text and [NOTICE](NOTICE) for third-party attributions.
