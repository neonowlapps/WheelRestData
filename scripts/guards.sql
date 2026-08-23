-- Structural guards for a freshly built cycle_parking.sqlite.
--
-- Emits one "PASS <name>" or "FAIL <name>: detail" line per check.
-- run_guards.sh fails the build if any FAIL appears, so adding a check here
-- needs no wiring elsewhere.
--
-- Every check below exists because something specific gets past the others.
-- In particular: integrity_check, quick_check AND rtreecheck all return "ok"
-- when parking and parking_index disagree on row count (measured, 2026-08-20),
-- so the PARITY check is the only thing standing between a half-indexed
-- database and users.

.mode list
.headers off
.bail on

-- 1. Row floor. A truncated PBF is a valid PBF prefix, so osmium reads what
--    arrived and the build "succeeds" with a partial country.
SELECT CASE WHEN count(*) >= 50000
            THEN 'PASS row-floor'
            ELSE 'FAIL row-floor: only ' || count(*) || ' rows, floor is 50000'
       END FROM parking;

-- 2. Table/index parity. THE critical check — see header.
SELECT CASE WHEN p = i
            THEN 'PASS table-index-parity'
            ELSE 'FAIL table-index-parity: parking=' || p || ' parking_index=' || i
       END
FROM (SELECT (SELECT count(*) FROM parking) AS p,
             (SELECT count(*) FROM parking_index) AS i);

-- 3. Bounding box over the TABLE.
SELECT CASE WHEN count(*) = 0
            THEN 'PASS bbox-table'
            ELSE 'FAIL bbox-table: ' || count(*) || ' rows outside the British Isles'
       END
FROM parking
WHERE lat NOT BETWEEN 49.5 AND 61.0 OR lon NOT BETWEEN -11.0 AND 2.0;

-- 4. Bounding box over the INDEX, separately. A transposed R*Tree passes
--    parity, integrity_check and a table-only bbox check while returning zero
--    rows for every real viewport query. Float32 rounding in the R*Tree means
--    the bounds must be widened slightly versus check 3.
SELECT CASE WHEN count(*) = 0
            THEN 'PASS bbox-index'
            ELSE 'FAIL bbox-index: ' || count(*) || ' index entries outside the British Isles'
       END
FROM parking_index
WHERE minLat NOT BETWEEN 49.4 AND 61.1 OR minLon NOT BETWEEN -11.1 AND 2.1;

-- 5. Index agrees with the table, per row, within float32 tolerance.
--    R*Tree coordinates are float32, so EVERY row differs slightly from the
--    REAL column: measured max delta 7.63e-06 degrees. An equality test would
--    reject every correct build; 1e-4 catches transposition and gross skew.
SELECT CASE WHEN count(*) = 0
            THEN 'PASS index-agreement'
            ELSE 'FAIL index-agreement: ' || count(*) || ' rows where the index disagrees with the table'
       END
FROM parking p JOIN parking_index i ON p.id = i.id
WHERE abs(p.lat - i.minLat) > 1e-4 OR abs(p.lon - i.minLon) > 1e-4;

-- 6. Schema whitelist. The client refuses anything carrying a trigger or a
--    view, so publishing one would brick every update. This is also what lets
--    us say the payload is data and not code.
SELECT CASE WHEN count(*) = 0
            THEN 'PASS no-triggers-or-views'
            ELSE 'FAIL no-triggers-or-views: found ' || group_concat(type || ' ' || name, ', ')
       END
FROM sqlite_master WHERE type IN ('trigger','view');

-- 7. Expected objects are present.
SELECT CASE WHEN count(*) = 2
            THEN 'PASS schema-objects'
            ELSE 'FAIL schema-objects: expected parking + parking_index, found ' || count(*)
       END
FROM sqlite_master
WHERE name IN ('parking','parking_index') AND type IN ('table','virtual table');

-- 8. Version stamp present, plausible, and inside signed int32.
--    user_version is a SIGNED 32-bit field: values >= 2^31 read back as 0.
SELECT CASE WHEN v BETWEEN 20200101 AND 21000101
            THEN 'PASS user-version'
            ELSE 'FAIL user-version: ' || v || ' is not a plausible YYYYMMDD stamp'
       END
FROM (SELECT (SELECT user_version FROM pragma_user_version()) AS v);

-- 9. Page-level integrity. Necessary but nowhere near sufficient — see header.
SELECT CASE WHEN (SELECT integrity_check FROM pragma_integrity_check() LIMIT 1) = 'ok'
            THEN 'PASS integrity-check'
            ELSE 'FAIL integrity-check: ' ||
                 (SELECT integrity_check FROM pragma_integrity_check() LIMIT 1)
       END;

-- 10. Not WAL. A WAL database ships as three files; we publish one.
SELECT CASE WHEN lower(m) <> 'wal'
            THEN 'PASS journal-mode'
            ELSE 'FAIL journal-mode: database is in WAL mode'
       END
FROM (SELECT (SELECT journal_mode FROM pragma_journal_mode()) AS m);

-- 11. The real production query, over central London, through the R*Tree.
--     The last line of defence: everything above can pass while the thing the
--     apps actually run returns nothing.
SELECT CASE WHEN count(*) > 0
            THEN 'PASS london-smoke-query'
            ELSE 'FAIL london-smoke-query: the production viewport query returned no rows'
       END
FROM (SELECT p.id FROM parking p JOIN parking_index idx ON p.id = idx.id
      WHERE idx.minLat >= 51.48 AND idx.maxLat <= 51.54
        AND idx.minLon >= -0.15 AND idx.maxLon <= -0.05
      LIMIT 200);

-- 12. Capacity sanity. Not fatal-looking, but a parse regression here would
--     silently show every rack as "unknown".
SELECT CASE WHEN count(*) > 0
            THEN 'PASS capacity-populated'
            ELSE 'FAIL capacity-populated: every row has capacity 0'
       END
FROM parking WHERE capacity > 0;
