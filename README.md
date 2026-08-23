# WheelRestData

Build and distribution pipeline for the cycle parking dataset used by the
**WheelRest** apps on [Android](https://github.com/neonowlapps/WheelRestAndroid)
and [iOS](https://github.com/neonowlapps/WheelRest).

> **Data © OpenStreetMap contributors**, available under the
> [Open Database Licence (ODbL) v1.0](https://www.openstreetmap.org/copyright).
> Derived from [Geofabrik](https://download.geofabrik.de/) extracts of Great
> Britain and of Ireland & Northern Ireland.
> The published database is a **Derivative Database** under ODbL 1.0 — not a
> Produced Work — and is therefore itself licensed under ODbL 1.0. Full text in
> [`LICENSE-ODbL.txt`](LICENSE-ODbL.txt).

## What this repo does

Once a month it rebuilds `cycle_parking.sqlite` from OpenStreetMap, checks it
cannot hurt anyone, and publishes it as a GitHub Release. The apps pick it up on
their next launch. **No app release is involved**, which is the whole point:
data freshness used to be coupled to store review.

```
Geofabrik extracts (2.57 GB)
   → filter amenity=bicycle_parking
   → canonical sort
   → SQLite + R*Tree, ANALYZE, VACUUM, stamp PRAGMA user_version
   → 12 structural guards + churn guard
   → gzip -9 -n
   → GitHub Release  (payload, ~2.25 MB)
   → dataset/v1/pointer.json  (~265 B, committed to main)
```

## How clients use it

1. On app open (throttled to once every 6 h) fetch
   **`https://raw.githubusercontent.com/neonowlapps/WheelRestData/main/dataset/v1/pointer.json`**
2. Compare `pointer.version` with the local database's `PRAGMA user_version`.
   **Act when they differ** — not when the pointer is greater. That is what makes
   rollback work.
3. If they differ, download `pointer.url`, verify `sha256` and `bytes`, validate
   the database, then swap it in atomically.

Clients **must never call `api.github.com`** — it is rate limited to 60
requests/hour per IP, which is shared by everyone behind a carrier NAT. The
release download paths measured ~14,800 requests/hour/IP with no throttling.

### The pointer

```json
{
  "version": 20260814,
  "url": "https://github.com/neonowlapps/WheelRestData/releases/download/data-20260814/cycle_parking-20260814.sqlite.gz",
  "bytes": 2251373,
  "sha256": "…",
  "rows": 61409
}
```

`version` is the date of the **older** of the two source extracts, as `YYYYMMDD`
— the dataset is only as fresh as its oldest input. It is stamped into the file
itself as `PRAGMA user_version`, so the file is self-describing and a client
never has to trust a stored preference about what it has.

### Schema

```sql
CREATE TABLE parking (id INTEGER PRIMARY KEY, lat REAL, lon REAL, capacity INTEGER);
CREATE VIRTUAL TABLE parking_index USING rtree(id, minLat, maxLat, minLon, maxLon);
```

Nodes tagged `amenity=bicycle_parking`, excluding `access=private`. Racks mapped
as ways or relations are not included.

## Publishing is fully automatic

There is **no human approval step**. The guards are the gate:

- every guard passes → publish, nobody is involved;
- any guard fails → the run fails, **nothing is published**, the previous
  dataset stays live, and GitHub emails the failure.

A manual approval gate was considered and rejected. This project has direct
evidence that manual steps do not get done: the iOS app shipped a database that
was three and a half months stale because the old script ended with
*"Remember to copy it into the app"*.

If the extract date has not moved, the build is byte-identical to what is live
and **nothing is published** — no duplicate release, no pointless 2.25 MB
download for every user.

## Guards

`scripts/guards.sql` — 12 structural checks, run against every build:

| Check | Catches |
|---|---|
| Row floor ≥ 50,000 | truncated download (a partial PBF is still a valid PBF) |
| **`count(parking) = count(parking_index)`** | the two tables disagreeing |
| Bounding box over `parking` | lat/lon transposition |
| Bounding box over `parking_index` | a transposed index that passes every other check |
| Index/table agreement within 1e-4 | index built from the wrong columns |
| No triggers, no views | a payload that could be argued to be code |
| Expected schema objects present | wrong or corrupt file |
| `user_version` a plausible `YYYYMMDD` | unstamped or overflowed version |
| `PRAGMA integrity_check` | page, B-tree and R\*Tree corruption |
| Not WAL | a database that ships as three files |
| **London viewport query returns rows** | anything the above missed |
| Capacity populated | a capacity parse regression |

> **The parity check is not optional.** `integrity_check`, `quick_check` **and**
> `rtreecheck()` all return `ok` when `parking` and `parking_index` disagree by
> 500 rows. Measured, not assumed. SQLite validates the R\*Tree against itself,
> never against the table it indexes.

`scripts/churn_guard.sh` adds movement checks against the last published build:
total row count within **4%**, and each region in `regions.tsv` at **≥ 50%** of
its baseline. The regional floor is what catches an extract that silently loses
a country — Wales disappearing moves the national total only 3.7%, comfortably
inside the total-churn ceiling.

Thresholds assume monthly publishing (measured drift: 0.43% per 12 days ≈ 1.1%
per month). **If the cadence changes to fortnightly, drop `MAX_CHURN_PCT` to 2.**

`scripts/test_guards.sh` builds deliberately-broken databases and asserts each
guard fires. Run it after touching `guards.sql`:

```sh
scripts/test_guards.sh path/to/known-good.sqlite
```

## Running it by hand

```sh
scripts/build_dataset.sh                                  # ~25 min, 2.57 GB download
scripts/run_guards.sh   build/cycle_parking-<version>.sqlite
scripts/churn_guard.sh  build/cycle_parking-<version>.sqlite
```

`FORCE=true` relaxes the churn ceiling and the out-of-bbox row limit. Structural
guards always apply and cannot be bypassed.

## Rollback

Re-point the release, then revert the pointer:

```sh
gh release edit data-<bad>  --prerelease --latest=false
gh release edit data-<good> --latest
git revert <pointer commit> && git push
```

Clients heal on their next check, because the version test is `!=` rather than
`>`. Both `github.com` redirect hops send `cache-control: no-cache`, so there is
nothing to purge. Note that re-pointing does not un-apply bad data already on a
device — only the next successful download does that, and the apps keep a
bundled copy as a permanent offline floor regardless.

## Cost

Zero, and structurally so. Public repositories get unmetered Actions minutes,
and GitHub documents no bandwidth or total-size limit on release assets (2 GiB
per file; the payload is 2.25 MB).

There are exactly two ways to make this cost money, both guarded against:
committing build artifacts into git history (see `.gitignore`), or using Git
LFS, which has a hard 1 GB free quota and metered bandwidth. Don't.

## Layout

```
scripts/build_dataset.sh     download → filter → sort → build → stamp → compress
scripts/guards.sql           12 structural checks
scripts/run_guards.sh        runs them, fails on any FAIL
scripts/test_guards.sh       negative tests: proves each guard actually fires
scripts/churn_guard.sh       movement checks vs the last published build
scripts/make_pointer.sh      emits dataset/v1/pointer.json
scripts/verify_published.sh  re-fetches the published asset as a client would
regions.tsv                  region boxes for the churn guard
dataset-state.json           last published version, baselines, heartbeat
dataset/v1/pointer.json      what clients read
```
