#!/usr/bin/env bash
# Set up the local sibling clone of draw-things-community required by Package.swift.
#
# Usage: ./scripts/setup-dev.sh
#
# This clones drawthingsai/draw-things-community at the pinned SHA into a
# sibling directory (../draw-things-community), and applies the patch in
# scripts/dtc-products.patch which:
#   1. exposes `ModelZoo` as a library product (so we can consume the typed
#      asset catalogs from our server);
#   2. adds a public `MediaGenerationPipeline.Result.encodedData(type:)`
#      method so we don't have to roundtrip through a temp file to encode.
#
# The patch lives only in the local clone — it is never pushed upstream.
# When the pinned SHA is bumped, re-run this script; if Package.swift has
# changed upstream, the patch may need to be regenerated.

set -euo pipefail

PINNED_SHA="9f3f04b7a0729a50384caf58179bed592044d64d"
REPO_URL="https://github.com/drawthingsai/draw-things-community.git"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DHT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SIBLING_DIR="$(cd "$DHT_ROOT/.." && pwd)/draw-things-community"
PATCH_FILE="$SCRIPT_DIR/dtc-products.patch"

if [ ! -d "$SIBLING_DIR" ]; then
  echo "Cloning draw-things-community into $SIBLING_DIR ..."
  git clone "$REPO_URL" "$SIBLING_DIR"
fi

cd "$SIBLING_DIR"

CURRENT_SHA="$(git rev-parse HEAD)"
if [ "$CURRENT_SHA" != "$PINNED_SHA" ]; then
  echo "Checking out pinned SHA $PINNED_SHA (was $CURRENT_SHA) ..."
  git fetch origin "$PINNED_SHA"
  git checkout "$PINNED_SHA"
fi

# Idempotent patch application:
#   - already applied         → reverse-check succeeds, skip;
#   - applies cleanly          → apply;
#   - neither (upstream drift) → fail loud with a pointer, never half-apply.
if git apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
  echo "Patch already applied, skipping."
elif git apply --check "$PATCH_FILE" 2>/dev/null; then
  echo "Applying $PATCH_FILE ..."
  git apply "$PATCH_FILE"
else
  echo "ERROR: $PATCH_FILE does not apply cleanly to $PINNED_SHA." >&2
  echo "       The pinned SHA and the patch have drifted apart — either the" >&2
  echo "       SHA was bumped without regenerating the patch, or the clone" >&2
  echo "       is in an unexpected state. Regenerate the patch against the" >&2
  echo "       pinned SHA, then re-run this script. Nothing was modified." >&2
  exit 1
fi

echo "Done. draw-things-community ready at $SIBLING_DIR @ $PINNED_SHA + dtc-products patch."
