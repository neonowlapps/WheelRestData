#!/usr/bin/env bash
#
# Builds cycle_parking.sqlite from Geofabrik OSM extracts.
#
# Scope: despite the "UK" framing this ingests the ireland-and-northern-ireland
# extract as well, so the output contains roughly 3.9k spots in the Republic of
# Ireland. Only nodes tagged amenity=bicycle_parking are included; racks mapped
# as ways or relations are dropped.
#
# Writes to $BUILD_DIR (default ./build). Does not publish anything — guards.sql,
# churn_guard.sh and the workflow decide whether the result is fit to ship.
#
# Env:
#   BUILD_DIR   output directory                    (default ./build)
#   CACHE_DIR   extract cache, survives between runs (default $TMPDIR/wheelrest-osm-cache)
#   FORCE       "true" relaxes the bbox drop ceiling (guards still run)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
FORCE="${FORCE:-false}"

if [ -n "${CACHE_DIR:-}" ]; then
  CACHE_DIR="${CACHE_DIR%/}"
else
  _tmp="${TMPDIR:-/tmp}"; CACHE_DIR="${_tmp%/}/wheelrest-osm-cache"
fi

# A truncated download is a valid PBF prefix, so osmium happily reads the blocks
# that arrived and the build would otherwise "succeed" with a partial country.
MIN_ROWS=50000

# British Isles, generously bounded. Rows outside are dropped, not tolerated:
# lat/lon transposition is the most likely silent corruption in a jq pipeline.
BBOX_MIN_LAT=49.5 ; BBOX_MAX_LAT=61.0
BBOX_MIN_LON=-11.0; BBOX_MAX_LON=2.0
# More than this many rows outside the box means something structural is wrong,
# not that a handful of nodes are mistagged in OSM.
MAX_BBOX_DROPS=10

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$CACHE_DIR" "$BUILD_DIR"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '\n[FAIL] %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------- disk check
avail_kb="$(df -Pk "$WORKDIR" | awk 'NR==2{print $4}')"
[ "$avail_kb" -gt 8000000 ] || die "only $((avail_kb/1024)) MB free; need ~8 GB for a 2.57 GB working set"

# ------------------------------------------------------------ 1. downloads
#
# Resolve the -latest redirect ONCE and pin the dated URL for both the payload
# and its .md5. Fetching "-latest" twice is racy: Geofabrik can publish a new
# extract between the two requests, and `curl -C -` would then resume a
# different file onto the old bytes, producing a corrupt PBF that still passes
# a checksum against the *new* .md5 only by luck.
resolve() {
  curl --fail --silent --location --head -o /dev/null -w '%{url_effective}' "$1"
}

download_verified() {
  local dated_url="$1" name="$2" dest="$CACHE_DIR/$2"
  log "  → $name  ($(basename "$dated_url"))"
  # --retry-all-errors is load-bearing: plain --retry covers only timeouts and
  # transient statuses, so a mid-transfer "connection reset" (curl 56) would
  # abort the run. Combined with -C - and the cache, a retry resumes.
  curl --fail --location --retry 5 --retry-delay 5 --retry-all-errors \
       -C - -o "$dest" "$dated_url"
  curl --fail --location --silent --retry 3 --retry-all-errors \
       -o "$dest.md5" "$dated_url.md5"

  local expected actual
  expected="$(cut -d' ' -f1 < "$dest.md5")"
  if command -v md5sum >/dev/null 2>&1; then actual="$(md5sum "$dest" | cut -d' ' -f1)"
  else actual="$(md5 -q "$dest")"; fi
  [ "$expected" = "$actual" ] || {
    rm -f "$dest" "$dest.md5"
    die "checksum mismatch for $name (cached copy deleted; re-run to refetch)"
  }
}

# Geofabrik names dated extracts <region>-YYMMDD.osm.pbf.
extract_date() {
  basename "$1" | sed -n 's/.*-\([0-9]\{6\}\)\.osm\.pbf$/\1/p'
}

log "Resolving extract URLs..."
GB_URL="$(resolve https://download.geofabrik.de/europe/great-britain-latest.osm.pbf)"
IE_URL="$(resolve https://download.geofabrik.de/europe/ireland-and-northern-ireland-latest.osm.pbf)"
GB_DATE="$(extract_date "$GB_URL")"; IE_DATE="$(extract_date "$IE_URL")"
[ -n "$GB_DATE" ] && [ -n "$IE_DATE" ] || die "could not parse extract dates from:\n  $GB_URL\n  $IE_URL"

# The dataset is only as fresh as its oldest input, so stamp the older date.
OLDER="$GB_DATE"; [ "$IE_DATE" \< "$OLDER" ] && OLDER="$IE_DATE"
VERSION="20${OLDER}"
log "Extracts: GB=$GB_DATE IE=$IE_DATE → dataset version $VERSION"

log "Downloading (cache: $CACHE_DIR)..."
download_verified "$GB_URL" gb.osm.pbf
download_verified "$IE_URL" ie.osm.pbf

# ------------------------------------------------------------ 2. filter
log "Filtering amenity=bicycle_parking nodes..."
osmium tags-filter "$CACHE_DIR/gb.osm.pbf" n/amenity=bicycle_parking -o "$WORKDIR/gb.pbf"
osmium tags-filter "$CACHE_DIR/ie.osm.pbf" n/amenity=bicycle_parking -o "$WORKDIR/ie.pbf"
osmium merge "$WORKDIR/gb.pbf" "$WORKDIR/ie.pbf" -o "$WORKDIR/all.pbf"

log "Exporting GeoJSON..."
osmium export "$WORKDIR/all.pbf" -o "$WORKDIR/all.geojson" --geometry-types=point

log "Access-tag census:"
jq -r '.features[].properties.access // "untagged"' "$WORKDIR/all.geojson" \
  | sort | uniq -c | sort -rn | sed 's/^/    /'

# ------------------------------------------------------------ 3. CSV
log "Converting to CSV..."
jq -r '
  .features[]
  | select(.properties.access != "private")
  | [ .geometry.coordinates[1], .geometry.coordinates[0], (.properties.capacity // "0") ]
  | @csv
' "$WORKDIR/all.geojson" > "$WORKDIR/unsorted.csv"

# Canonical order. Two reasons, both load-bearing:
#   1. it makes the build independent of osmium's export order, which is not a
#      documented stability guarantee;
#   2. sorting by position clusters nearby rows, which compresses ~6% better.
# LC_ALL=C so the collation cannot shift under a runner locale change.
log "Applying canonical sort..."
LC_ALL=C sort -t, -k1,1g -k2,2g -k3,3n "$WORKDIR/unsorted.csv" > "$WORKDIR/rows.csv"
ROWS_CSV="$(wc -l < "$WORKDIR/rows.csv" | tr -d ' ')"
log "  $ROWS_CSV rows"
[ "$ROWS_CSV" -ge "$MIN_ROWS" ] || die "only $ROWS_CSV rows in CSV (floor $MIN_ROWS) — truncated download?"

# ------------------------------------------------------------ 4. build
log "Building SQLite with R*Tree..."
DB="$WORKDIR/build.sqlite"
# -bail: sqlite3 otherwise continues past errors and reports only via exit code,
# so a failed .import would leave empty tables behind.
sqlite3 -bail "$DB" <<SQL
PRAGMA journal_mode=DELETE;

CREATE TABLE parking (
    id INTEGER PRIMARY KEY,
    lat REAL NOT NULL,
    lon REAL NOT NULL,
    capacity INTEGER NOT NULL DEFAULT 0
);

-- Staging is all TEXT so the import cannot fail on a type mismatch.
CREATE TABLE staging (lat TEXT, lon TEXT, capacity TEXT);
.mode csv
.import '$WORKDIR/rows.csv' staging

INSERT INTO parking (lat, lon, capacity)
SELECT CAST(lat AS REAL), CAST(lon AS REAL),
       CASE WHEN capacity GLOB '[0-9]*' THEN CAST(capacity AS INTEGER) ELSE 0 END
FROM staging;
DROP TABLE staging;

-- Drop anything outside the British Isles before the index is built, so the
-- R*Tree can never disagree with the table about which rows exist.
DELETE FROM parking
 WHERE lat NOT BETWEEN $BBOX_MIN_LAT AND $BBOX_MAX_LAT
    OR lon NOT BETWEEN $BBOX_MIN_LON AND $BBOX_MAX_LON;

CREATE VIRTUAL TABLE parking_index USING rtree(
    id,       -- must match parking.id
    minLat, maxLat,
    minLon, maxLon
);
INSERT INTO parking_index(id, minLat, maxLat, minLon, maxLon)
SELECT id, lat, lat, lon, lon FROM parking;

-- No index on capacity: neither app filters or orders by it, and it cost ~568 KB.
ANALYZE;
VACUUM;
PRAGMA user_version = $VERSION;
SQL

ROWS="$(sqlite3 "$DB" 'SELECT count(*) FROM parking;')"
DROPPED=$(( ROWS_CSV - ROWS ))
log "  $ROWS rows kept, $DROPPED dropped as out-of-bbox"
if [ "$DROPPED" -gt "$MAX_BBOX_DROPS" ] && [ "$FORCE" != "true" ]; then
  die "$DROPPED rows fell outside the British Isles (ceiling $MAX_BBOX_DROPS).
     This is what lat/lon transposition looks like. Re-run with FORCE=true only
     if you have confirmed the data is genuinely correct."
fi

# ------------------------------------------------------------ 5. compress
# -n is load-bearing: without it gzip embeds the mtime AND the input filename,
# so an unchanged dataset would produce a different .gz every run, changing the
# published hash and pushing a needless download to every user.
log "Compressing..."
OUT_DB="$BUILD_DIR/cycle_parking-$VERSION.sqlite"
OUT_GZ="$OUT_DB.gz"
mv -f "$DB" "$OUT_DB"
gzip -9 -n -c "$OUT_DB" > "$OUT_GZ"

# ------------------------------------------------------------ 6. metadata
if command -v sha256sum >/dev/null 2>&1; then SHA="$(sha256sum "$OUT_GZ" | cut -d' ' -f1)"
else SHA="$(shasum -a 256 "$OUT_GZ" | cut -d' ' -f1)"; fi
BYTES="$(wc -c < "$OUT_GZ" | tr -d ' ')"

{
  echo "version=$VERSION"
  echo "rows=$ROWS"
  echo "bytes=$BYTES"
  echo "sha256=$SHA"
  echo "gb_extract=$GB_DATE"
  echo "ie_extract=$IE_DATE"
} > "$BUILD_DIR/build.env"

log "Done."
log "  version $VERSION | $ROWS rows | $(wc -c < "$OUT_DB" | tr -d ' ') B raw | $BYTES B gz"
log "  sha256 $SHA"
