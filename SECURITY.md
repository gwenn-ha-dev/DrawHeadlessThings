# Security Policy

## Reporting a vulnerability

Please report security issues **privately**, not as a public GitHub issue.

Use GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
("Report a vulnerability" under the Security tab) and include details and,
ideally, a reproduction.

You'll get an acknowledgement as soon as practical. This is a personal
open-source project with no SLA, but security reports are taken seriously and
triaged ahead of feature work.

## Security model — what to assume

DrawHeadlessThings is a local inference server. Understand its trust boundaries
before exposing it:

- **Default bind is loopback, no auth.** `dht-server` (or `--bind private`)
  listens only on `127.0.0.1` / `::1` and requires no token. This assumes the
  local machine is trusted. Anything that can reach loopback can drive the GPU
  and read/write the models directory.
- **Public bind requires a token.** `--bind public` exposes the server on the
  LAN and refuses to start without `--token`. The token is checked in constant
  time. There is no TLS — terminate it behind a reverse proxy if you need
  transport encryption, and treat the token as the only access control.
- **`GET /health` is intentionally unauthenticated**, even on a public bind. It
  returns only `{"status":"ok"}` — liveness, nothing sensitive.
- **Asset installs reach the network.** `POST /v1/assets/install` downloads
  model files from the engine's catalog. Run with `--read-only` to refuse all
  asset mutations (install and delete) if that surface concerns you.
- **Path-shortcut inputs read local files.** The MCP `from_image_path` /
  `mask_path` conveniences read files from the server's filesystem. Only expose
  MCP to clients you trust with that filesystem access.
- **The engine is statically linked (GPL-3.0).** Vulnerabilities in the wrapped
  engine are upstream in [`draw-things-community`](https://github.com/drawthingsai/draw-things-community);
  report those there. Issues in this wrapper's HTTP/MCP surface belong here.

## Supported versions

Pre-1.0: only the latest release receives fixes.
