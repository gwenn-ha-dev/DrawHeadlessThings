# Contributing to DrawHeadlessThings

Thanks for your interest. This is a small, focused project — a stateless REST
+ MCP server around the [`draw-things-community`](https://github.com/drawthingsai/draw-things-community)
engine. Contributions are welcome; please read this first.

## Ground rules

- **Apple Silicon only.** The engine wraps Metal kernels. There is no x86_64
  or Linux build to support — don't add portability shims for platforms that
  can't run the engine.
- **The OpenAPI spec is the reference.** `Sources/dht-server/Resources/openapi.yaml`
  is the canonical description of the REST surface. Any change to a request or
  response shape, status code, or error code **must** update the spec in the
  same change. Validate it before pushing:
  ```bash
  ruby -ryaml -e "YAML.load_file('Sources/dht-server/Resources/openapi.yaml')"
  ```
- **MCP mirrors REST.** The MCP tool catalog (`Sources/dht-server/MCPServer.swift`)
  is kept at parity with the REST routes. If you add or change a route, keep the
  matching tool — and its recipe/run/capability behaviour — in step.
- **Tests stay green.** New behaviour ships with tests. The suite runs offline
  against a `FakeEngine`, so you don't need a GPU or any model installed.

## Getting set up

The build depends on a local sibling clone of `draw-things-community`, pinned to
a known SHA and patched additively. `scripts/setup-dev.sh` clones and patches it
(idempotent — safe to re-run):

```bash
./scripts/setup-dev.sh   # one-time: clone + patch ../draw-things-community
swift build
swift test
```

End-to-end smoke test against a running server with a real base model installed:

```bash
DHT_MODELS_DIR=/path/to/Models ./scripts/smoke-test.sh
```

## Submitting changes

1. Fork the repo and create a topic branch.
2. Make your change, with tests and an updated `openapi.yaml` where relevant.
3. Run `swift test` — all tests must pass.
4. Open a pull request describing the change and why. Keep PRs focused.

By contributing, you agree your contributions are licensed under the project's
**GPL-3.0-or-later** license (required because the engine is GPL-3.0).

## Reporting bugs and security issues

- Functional bugs: open a GitHub issue using the templates.
- Security vulnerabilities: **do not** open a public issue — see
  [SECURITY.md](SECURITY.md).
