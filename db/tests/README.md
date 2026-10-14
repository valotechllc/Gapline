# Database tests

Each `NN_*.sql` file runs in its own fresh database, after `schema.sql`, `clone_library_version.sql` and `_helpers.sql`.

```sh
db/tests/run.sh            # all files
db/tests/run.sh freeze     # only files whose name contains "freeze"
KEEP_DBS=1 db/tests/run.sh # keep each test database for inspection
```

The runner exits non-zero if any file fails, so it can run as-is in CI.

## Requirements

- `psql`, `createdb` and `dropdb` on the `PATH`.
- A role that can create databases. Connection settings come from the usual libpq variables (`PGHOST`, `PGPORT`, `PGUSER`, ...).
- PostgreSQL 15 or later, with ICU. `07_ssp_digest_collation` creates an ICU `en-US` database.

## Writing checks

`_helpers.sql` defines three assertions. Each prints `ok - <label>`; a failure raises `FAIL - <label>: ...` and stops the file.

| Helper | Passes when |
|---|---|
| `t_ok(label, sql)` | `sql` succeeds |
| `t_raises(label, sql, fragment)` | `sql` fails with an error message containing `fragment` (plain substring) |
| `t_eq(label, actual, expected)` | `actual IS NOT DISTINCT FROM expected` |

Statements passed as text run in a subtransaction, so one expected to fail leaves no trace. Use `$$ ... $$` quoting for them. Plain statements in a test file act as fixtures; if a fixture fails, the file fails at that line.

A file can request database options with a first line like `-- createdb-options: --locale-provider=icu ...`.

## Files

| File | Covers |
|---|---|
| `01_scoring_view` | `requirement_status`: partial reviews stay `unreviewed`; no requirement drops out of the view |
| `02_integrity_checks` | Weights, reviewer and model attribution, signer, evidence hashes and raw bytes, evidence pinned to its assessment, append-only evidence |
| `03_library_versioning` | `(library_version, id)` keys, cross-version references, filling in `library_version`, the example seed |
| `04_signed_assessment` | Result locks, signed → superseded only, no signed inserts, deletes or TRUNCATE |
| `05_library_freeze` | Every library table frozen by a signed or superseded assessment; other versions stay editable |
| `06_ssp_snapshot` | Snapshot at signing, per-section and whole-SSP SHA-256 against values from `sha256sum`, tamper resistance |
| `07_ssp_digest_collation` | The digest uses byte order regardless of the database collation |
| `08_clone_library_version` | Exact copies, version-local references, defaults and overrides, rollback, newly added columns |

The expected hashes in `06` and `07` were computed with `sha256sum`, outside Postgres. The commands are in each file's header comment, so the tests check the documented format rather than the database agreeing with itself.
