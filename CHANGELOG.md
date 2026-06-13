# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once it
reaches 1.0. Pre-1.0, minor versions may include breaking changes.

## [0.3.1]

### Added

- **Local base-model import** — `POST /v1/assets/install` with
  `source.type=local_file` and `asset_type=base_model` now imports a base-model
  checkpoint (`.safetensors` / `.ckpt`) from the server filesystem: the
  architecture is auto-detected, the weights are written as an **f16** `.ckpt`
  (+ `-tensordata`) into the models directory, and the inferred spec is
  registered in `custom.json`. The model's standard text encoder / VAE are
  referenced by the spec and fetched on demand at generate time. Output is f16
  only (no quantization); a >5 GB import is gated by `LARGE_MODEL_DOWNLOAD`
  unless `confirm_large_download: true`. Previously `local_file` installs
  covered LoRA only.

## [0.3.0] — First public release

The initial public release: a stateless REST + MCP server wrapping the
[`draw-things-community`](https://github.com/drawthingsai/draw-things-community)
engine on Apple Silicon.

### Added

- **Semantic REST API** (OpenAPI 3.1) — three verbs `compose` / `edit` /
  `restore`, a `/v1/pipeline` for chaining them, and per-verb `/v1/resolve`
  dry-runs that surface applied defaults and engine-quirk warnings without
  touching the GPU.
- **`X-DHT-Recipe`** on every successful generation — the canonical,
  re-postable recipe (inline images redacted to `sha256:…` digest references),
  for reproducibility with no server state.
- **MCP endpoint** (Model Context Protocol, Streamable HTTP) at `/mcp`, at full
  parity with the REST surface: the verbs and their resolves, `pipeline`,
  `get_capabilities`, run introspection (`list_runs` / `get_run`), the asset
  tools, recipe blocks on results, and cancellation via `notifications/cancelled`.
- **Asset management** — list/get/install/delete models, LoRAs, ControlNets,
  embeddings, upscalers, and face-restoration assets; catalog-driven installs
  with a large-download gate.
- **Capability map** — `GET /v1/capabilities/{model_id}` reports which
  operations and params a model accepts, drops, or refuses.
- **`GET /health`** — auth-exempt liveness probe for supervisors and monitors.
- **Run registry** — `GET /v1/runs`, `GET /v1/runs/{id}` (with live preview),
  `DELETE /v1/runs/{id}`, and an optional `--max-active-runs` concurrency cap.
- **Bearer auth** on public binds (constant-time token compare), dual-stack
  IPv4 + IPv6 listeners, and a `--read-only` mode.
- **`DHTServer.app`** — an optional menu-bar agent that supervises the server
  (status, start/stop, log window, settings).
- **Distribution** — vendored Swagger UI at `/docs`, and a tagged release
  workflow that publishes `DHTServer.app` (with the engine embedded) as a DMG.
  Ad-hoc signed; notarization is pending a paid Apple Developer account.

[0.3.1]: https://github.com/gwenn-ha-dev/DrawHeadlessThings/releases/tag/v0.3.1
[0.3.0]: https://github.com/gwenn-ha-dev/DrawHeadlessThings/releases/tag/v0.3.0
