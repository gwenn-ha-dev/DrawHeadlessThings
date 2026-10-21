# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once it
reaches 1.0. Pre-1.0, minor versions may include breaking changes.

## [Unreleased]

## [0.5.0] — 2026-10-21

### Changed

- **Engine bump: draw-things-community `bc3970c` → `6c1dd09`** (2026-08-14 →
  2026-10-20, 184 commits). Brings MiniMax H3, Qwen Image 2.1, FLUX.3 [klein]
  and MOSS Image, plus engine fixes (TCD crash, Krea 2 2K decoding, MoE
  streaming load, Z Image Base with quantized attention, Anima scale-out).
  `GET /v1/info` reports `draw-things-community@6c1dd09`.
- **s4nnc / ccv follow the engine's own pins** (`b5476a7` → ccv `69b1ed1`).
  The re-pin to ccv `0e61707` (Z-Image Turbo blue-blob workaround) is gone;
  `dtc-products.patch` now only exposes the `ModelZoo` and `Downloader`
  products, the importer / encoder facades and a headless preview fallback.

### Added

- `Architecture` values `qwen_image_2.1`, `flux3_5b`, `minimax_h3`,
  `moss_image`; `Modifier` values `fl2va`, `ref2va`.
- Capability-map classes and cells for the new models:
  - `qwenImage21`: txt2img, img2img; edit with modifier `kontext`.
  - `flux3`: txt2img, img2img; edit with modifier `kontext` (what the engine
    importer assigns). `flow_match.resolution_dependent_shift` is a silent
    drop.
  - `mossImage`: txt2img, img2img (the engine has no reference-edit path).
  - `minimaxH3` (video): txt2vid; img2vid with `fl2va` (first frame) and
    `ref2va` (subject reference). The engine also generates an audio track,
    which DHT does not return yet; the last frame, extra references and
    reference audio are not exposed either.

### Fixed

- The new engine decodes live previews through CoreML tiny decoders on macOS
  too, unpacking archives only the Draw Things app bundles: the first preview
  of a generation crashed `dht-server`. `dtc-products.patch` makes a missing
  archive fall back to the latent-to-RGB preview, as before.

## [0.4.2] — 2026-10-10

### Changed

- **The app and the DMG are signed with a Developer ID and notarized.**
  `scripts/notarize.sh` runs `scripts/make-app.sh`, re-signs the app inside
  out with the hardened runtime, then notarizes and staples the app and the
  DMG: DHTServer.app opens with a double click, with no Gatekeeper bypass.
  It also maps the checkout to `.` at compile time, so the binaries carry no
  build path. `make-app.sh` alone still signs ad hoc, for local use.
- README: the hero image is now a real `dht-server` output (the quick-start
  prompt), and the install section drops the Gatekeeper workaround.

### Fixed

- `openapi.yaml` named the install source `AssetSource`, a name the code uses
  for something else; it is `InstallSource`, as in the server.

## [0.4.1]

### Fixed

- **Community-catalog models were listed but not generable.** Installing a
  base model from the community catalog downloaded its files but never
  registered the model's `Specification`, so `/v1/assets` reported it
  `downloaded: true` while `/v1/compose` answered `MODEL_NOT_INSTALLED`
  (generation lookup goes through `ModelZoo.specificationForModel`, which
  never consults the community catalog). Catalog installs now persist the
  community spec via `ModelZoo.appendCustomSpecification` — the mechanism
  the Draw Things GUI uses — and startup sweeps the cached catalog to
  register community models already fully on disk (main file + companions),
  repairing pre-fix installs. Assets keep `source: community`.

- **Z-Image Turbo produced garbage images (dense blue/black square blobs) on
  every generation** since the 0.4.0 engine bump. Root cause: the bump pulled
  ccv `9008b47`, whose four last kernel commits (`Fix RMSNorm sync issue`,
  `Move query offset to runtime parameter`, `IndexSelect kernel`,
  `threadgroupMemory out-of-bounds fix`) break Z-Image's denoising on this
  configuration — 0.3.10 and an A/B rebuild at seed 42 confirm the bisect.
  s4nnc is re-pinned to `5a84c2e` (identical source, one deps-pin behind),
  which pulls the last-known-good ccv `0e61707`; the `dtc-products.patch` now
  also re-pins both inside the engine clone's `Package.swift` so SwiftPM
  resolution stays consistent. Note: upstream's own Bazel build ships the
  affected ccv, so the pin should be revisited at the next engine bump.

## [0.4.0]

### Added

- **Community model catalog.** Asset listings now include the
  [drawthingsai/community-models](https://github.com/drawthingsai/community-models)
  catalog (base models, LoRAs, ControlNets, embeddings) as installable
  suggestions, fetched from `models.drawthings.ai` at startup — disable with
  `--no-community-models`; offline runs degrade silently to the last cached
  lists. Every base-model / LoRA / ControlNet / embedding asset now carries a
  `source` field (`official` / `community` / `custom`), and a community model
  keeps `source: community` after install. Install-size resolution now reads
  the cached CDN `file_sizes_metadata.json` first and only falls back to
  per-file HEAD requests when the metadata doesn't cover a file. The
  `dtc-products.patch` additionally exposes the engine's `Downloader` library
  and its `communityOnDisk` catalogs.

### Changed

- **Engine bump: draw-things-community `9f3f04b` → `bc3970c`** (2026-05-18 →
  2026-08-14, 133 commits). Brings four new architectures — **Krea 2**
  (raw/turbo, LoRA + tiled diffusion), **Ideogram 4** (LoRA + tiled
  diffusion), **HiDream-O1**, and **LongCat Video Avatar 1.5** (audio-driven
  avatar i2v; audio input not exposed by the API in v0) — plus upstream fixes
  (aspect-ratio loss, TCD-trailing cfg, Krea text-encoder with cfg disabled)
  and Xcode 26.6/Swift 6.3.3 toolchain compatibility. The `Architecture` /
  `BehaviorClass` mirrors, the capability map, the OpenAPI enums and the
  batch-size-cap table are extended accordingly; s4nnc is re-pinned to the
  revision the new engine resolves (`349a4d9`). The `dtc-products.patch`
  `BaseModelImporter` import-scale table is realigned with upstream
  (LongCat → 12, PixArt 512-variant → 8).

## [0.3.10]

### Changed

- **Generate panel — Save… defaults to JPEG (quality 0.9)**, smaller and easy
  to share; PNG stays selectable for a lossless copy. The server still returns
  lossless PNG bytes — JPEG is a one-shot re-encode at save time, and choosing
  `.png` writes the raw bytes untouched.

## [0.3.9]

### Changed

- **Menu-bar menu — clearer and more useful.** Reorganised into sections with an
  enriched status line and a live "N in flight · M waiting" line while busy;
  added **Copy Endpoint** and **Copy API Token** (public scope); a contextual
  hint replaces the silently-greyed Generate/Docs/MCP items; ⌘G/⌘,/⌘Q shortcuts.
  The icon stays monochrome but its four states are now distinct by shape, and
  the pulse also covers the start/stop transitions.
- **Generate panel — single-button flow and a cleaner layout.** The
  "Resolve → Generate" two-step is gone: defaults resolve automatically in the
  background and one **Generate** button generates. Model/format/import moved to
  a header bar (format as an aspect-ratio segmented control); LoRAs are now an
  add-on-demand list (max 3) instead of three fixed empty slots; the result
  image is larger and cross-fades in; errors show as a banner and quick actions
  confirm via transient toasts (⌘S save, ⌘. stop).

### Fixed

- **Generate panel swallowed I/O and transport errors.** Saving an image, the
  "Open" temp-file write, and the asset-list fetch no longer fail silently — a
  failed save/open surfaces an error, and an unreachable server is no longer
  indistinguishable from an empty catalogue. The in-flight generation is now
  tracked too, so **Stop** (and closing the window) aborts the client request
  rather than waiting out the timeout if the server ignores the cancel.

## [0.3.8]

### Fixed

- **Server crash on `cfg_scale > 1` with FLUX.2 edit models.** A `POST /v1/edit`
  against a guidance-distilled FLUX.2 Klein/Kontext model (`flux2_4b`) with an
  explicit `cfg_scale > 1` crashed the engine at `ccv_cnnp_concat_build`: these
  models have no unconditional branch, so an explicit CFG builds an asymmetric
  cond/uncond concat. The compatibility guard only recognised the FLUX.1 family
  (catalog `guidance_embed = true`); FLUX.2's catalog entry omits that flag, so
  the request slipped through. The guard now also keys on the
  `kontext`/`kontext_kv` modifier, covering FLUX.1 and FLUX.2 while leaving
  Qwen-Image-Edit (real CFG) untouched. The request is rejected up front with
  `CFG_SCALE_UNSUPPORTED_FOR_DISTILLED_EDIT` (400) on both `/v1/edit` and
  `/v1/resolve/edit`.

## [0.3.7]

### Added

- **Generate panel — Import Model….** Side-load a local base-model checkpoint
  (`.safetensors` / `.ckpt`) straight from the panel via
  `POST /v1/assets/install` (`local_file` / `base_model`); the architecture is
  auto-detected. On success the model list refreshes and the new model is
  selected. The button is available even with an empty catalog, so a first
  model can be imported without leaving the panel.

## [0.3.6]

### Changed

- **Generate panel — live progress, preview & Stop.** Generations run under a
  client-supplied run id; the result area shows a step X/Y bar and the engine's
  live preview frames, with a **Stop** button (cancels via
  `DELETE /v1/runs/{id}`).
- **Generate panel — per-LoRA weight band.** Each slot's weight slider is
  bounded by the LoRA's catalog `weight_range` and seeds its recommended weight
  on selection (was a fixed 0–1.5 / default 1.0).
- **Generate panel — finish.** Resolve warnings shown verbatim (not just a
  count); an empty-state when no base model is installed; a prominent primary
  button; result actions **Copy / Open / Save**; and trackpad **pinch-to-zoom
  + pan** (double-click to reset) on the result image.

## [0.3.5]

### Changed

- **Generate panel — chain up to 3 LoRAs.** Three independently configurable
  LoRA slots (each its own selection + weight), all filtered to the selected
  model's architecture.
- **Generate panel — two-stage button.** It reads **Resolve** first; clicking
  it validates the request and fills the per-model defaults (surfacing any
  errors/warnings), and only then becomes **Generate**. Changing the model,
  format, or a LoRA reverts it to Resolve; prompt / negative / advanced edits
  do not, so re-resolving never clobbers a manual override.

## [0.3.4]

### Changed

- **`params.steps` is now optional** — omit it to use the chosen model's
  default step count (filled from the model config, reported in
  `applied_defaults`, and folded into the recipe), exactly like `cfg_scale` /
  `sampler`. Previously `steps` was required, so omitting it returned `400`.
  The Generate panel relies on this: `resolve` now pre-fills the right step
  count per model (e.g. a Turbo model's low default instead of a fixed 20).

## [0.3.3]

### Added

- **Generate panel** — a minimal txt2img UI in the menu-bar app (the
  "Generate…" menu item): a visual builder for `POST /v1/compose` plus a view
  of the result. Model / single LoRA (+ weight) / prompt / negative-prompt /
  format dropdowns; `steps`, `cfg`, and `sampler` are pre-filled from
  `/v1/resolve/compose` and editable under an Advanced section. The image is
  fetched as raw bytes (`Accept: image/png`) and held in memory — it reaches
  disk only via **Save…**. The seed used is shown with a **Reuse** button, and
  **Copy as curl** yields the exact equivalent command.

## [0.3.2]

### Added

- **Secret mode** — a settings toggle (also a `dht-server --silent` flag) that
  produces **no logs of any kind**: swift-log is bootstrapped to a no-op
  backend (server, engine, MCP, Hummingbird, request log), the startup banner
  is suppressed, and the menu-bar app discards the child's stdout/stderr and
  keeps no in-memory tail — the activity window shows a "logging is disabled"
  notice. Toggling it restarts the server.

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

[0.3.9]: https://github.com/gwenn-ha-dev/DrawHeadlessThings/releases/tag/v0.3.9
[0.3.8]: https://github.com/gwenn-ha-dev/DrawHeadlessThings/releases/tag/v0.3.8
[0.3.7]: https://github.com/gwenn-ha-dev/DrawHeadlessThings/releases/tag/v0.3.7
[0.3.6]: https://github.com/gwenn-ha-dev/DrawHeadlessThings/releases/tag/v0.3.6
[0.3.5]: https://github.com/gwenn-ha-dev/DrawHeadlessThings/releases/tag/v0.3.5
[0.3.4]: https://github.com/gwenn-ha-dev/DrawHeadlessThings/releases/tag/v0.3.4
[0.3.3]: https://github.com/gwenn-ha-dev/DrawHeadlessThings/releases/tag/v0.3.3
[0.3.2]: https://github.com/gwenn-ha-dev/DrawHeadlessThings/releases/tag/v0.3.2
[0.3.1]: https://github.com/gwenn-ha-dev/DrawHeadlessThings/releases/tag/v0.3.1
[0.3.0]: https://github.com/gwenn-ha-dev/DrawHeadlessThings/releases/tag/v0.3.0
