#!/usr/bin/env bash
#
# Fetches a just-published asset back the way a client would and asserts the
# bytes match what we built. "gh release create exited 0" and "a phone can
# retrieve this file" are different claims, and the pointer must never name
# something clients cannot fetch.
#
# Deliberately uses the public redirect chain (github.com -> release-assets...)
# with no credentials, because that is the path clients take. It must NEVER use
# api.github.com: that endpoint is rate limited to 60 requests/hour, and reaching
# for it here would normalise a call the clients must never make.
#
# Usage: verify_published.sh <owner/repo> <tag> <version> <expected-sha256> <expected-bytes>
set -euo pipefail
SLUG="${1:?}"; TAG="${2:?}"; VERSION="${3:?}"; WANT_SHA="${4:?}"; WANT_BYTES="${5:?}"

URL="https://github.com/$SLUG/releases/download/$TAG/cycle_parking-$VERSION.sqlite.gz"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

echo "Fetching $URL"
for attempt in 1 2 3; do
  if curl --fail --location --silent --show-error -o "$TMP" "$URL"; then break; fi
  echo "  attempt $attempt failed; a new asset can take a moment to become readable"
  [ "$attempt" -lt 3 ] || { echo "[FAIL] asset not retrievable after 3 attempts" >&2; exit 1; }
  sleep 10
done

GOT_BYTES="$(wc -c < "$TMP" | tr -d ' ')"
GOT_SHA="$(sha256sum "$TMP" | cut -d' ' -f1)"

[ "$GOT_BYTES" = "$WANT_BYTES" ] || {
  echo "[FAIL] size mismatch: published $GOT_BYTES, built $WANT_BYTES" >&2; exit 1; }
[ "$GOT_SHA" = "$WANT_SHA" ] || {
  echo "[FAIL] sha256 mismatch:
       published $GOT_SHA
       built     $WANT_SHA" >&2; exit 1; }

# The client inflates this itself; confirm it is actually gzip and actually a
# database before the pointer starts advertising it.
gunzip -t "$TMP" || { echo "[FAIL] published asset is not valid gzip" >&2; exit 1; }
gunzip -c "$TMP" > "$TMP.db"
head -c 15 "$TMP.db" | grep -q 'SQLite format 3' || {
  echo "[FAIL] inflated payload is not a SQLite database" >&2; rm -f "$TMP.db"; exit 1; }
rm -f "$TMP.db"

echo "[OK] published asset verified: $GOT_BYTES bytes, sha256 $GOT_SHA"
