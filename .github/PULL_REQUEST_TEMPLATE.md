<!-- Keep PRs focused. Describe the change and why, not just what. -->

## What and why

<!-- One or two sentences. Link any related issue. -->

## Checklist

- [ ] `swift test` passes (offline suite, no GPU/model needed)
- [ ] `openapi.yaml` updated if the REST surface changed, and validates
      (`ruby -ryaml -e "YAML.load_file('Sources/dht-server/Resources/openapi.yaml')"`)
- [ ] MCP tool catalog kept in parity if a route changed
- [ ] Tests added or updated for the new behaviour
