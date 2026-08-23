Cycle parking dataset for the UK and Ireland — **__ROWS__ rows**.

Consumed automatically by the WheelRest apps for Android and iOS. Clients read
`dataset/v1/pointer.json` on the default branch and compare its `version`
against their local database's `PRAGMA user_version`.

| | |
|---|---|
| Dataset version | `__VERSION__` |
| Rows | __ROWS__ |
| Schema | `parking(id, lat, lon, capacity)` + `parking_index` R\*Tree |

**Attribution.** Data © OpenStreetMap contributors, available under the
[Open Database Licence (ODbL) v1.0](https://www.openstreetmap.org/copyright).
Derived from Geofabrik extracts. This file is a Derivative Database under ODbL
1.0 and is itself licensed under ODbL 1.0.
