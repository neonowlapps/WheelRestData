#!/usr/bin/env bash
#
# Emits dataset/v1/pointer.json — the ~200-byte file every client fetches on
# app open. It is the entire change-detection mechanism: clients compare
# .version against their database's own PRAGMA user_version and act when the
# two DIFFER (not when the pointer is greater), which is what makes rollback by
# re-publishing an older dataset work.
#
# .url is absolute because the release tag is not derivable client-side. That
# makes the pointer an open redirect if a client follows it blindly, so both
# clients validate scheme/host/path-prefix against values compiled into the
# binary before opening it.
#
# Usage: make_pointer.sh <build.env> <owner/repo> <tag>
set -euo pipefail
ENV_FILE="${1:?usage: make_pointer.sh <build.env> <owner/repo> <tag>}"
SLUG="${2:?missing owner/repo}"
TAG="${3:?missing tag}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
: "${version:?}" "${rows:?}" "${bytes:?}" "${sha256:?}"

OUT="$REPO_ROOT/dataset/v1/pointer.json"
mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<JSON
{
  "version": $version,
  "url": "https://github.com/$SLUG/releases/download/$TAG/cycle_parking-$version.sqlite.gz",
  "bytes": $bytes,
  "sha256": "$sha256",
  "rows": $rows
}
JSON

jq empty "$OUT" || { echo "[FAIL] generated pointer is not valid JSON" >&2; exit 1; }
echo "[OK] $(wc -c < "$OUT" | tr -d ' ') bytes:"
cat "$OUT" | sed 's/^/  /'
