#!/usr/bin/env bash
# Runs every db/tests/NN_*.sql file in its own fresh database:
#   schema.sql + clone_library_version.sql + _helpers.sql + the test file.
# A file passes when psql finishes it without error. Any failed check stops that file.
#
# Usage:  db/tests/run.sh [pattern]      e.g. db/tests/run.sh freeze
# Connects with the usual libpq variables (PGHOST, PGPORT, PGUSER, ...); the role must be able
# to create databases. Needs PostgreSQL 15+ (07_ssp_digest_collation creates an ICU database).
# KEEP_DBS=1 keeps each test database for inspection instead of dropping it.
set -uo pipefail

tests_dir="$(cd "$(dirname "$0")" && pwd)"
db_dir="$(dirname "$tests_dir")"
pattern="${1:-}"
prefix="gapline_test_$$"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

passed=0
failed=0
for file in "$tests_dir"/[0-9][0-9]_*.sql; do
    name="$(basename "$file" .sql)"
    [[ -n "$pattern" && "$name" != *"$pattern"* ]] && continue
    db="${prefix}_${name}"

    # A file may ask for special database options on a line "-- createdb-options: ...".
    read -r -a opts <<< "$(sed -n 's/^-- createdb-options: //p' "$file" | head -n 1)"

    # ${opts[@]+...} keeps an empty array from tripping set -u on bash 3.2 (macOS).
    if ! createdb ${opts[@]+"${opts[@]}"} "$db" > "$log" 2>&1; then
        echo "FAIL $name (could not create database)"
        sed 's/^/     /' "$log"
        failed=$((failed + 1))
        continue
    fi

    if psql -X -q -v ON_ERROR_STOP=1 -d "$db" \
            -f "$db_dir/schema.sql" -f "$db_dir/clone_library_version.sql" \
            -f "$tests_dir/_helpers.sql" -f "$file" > /dev/null 2> "$log"; then
        echo "ok   $name ($(grep -c 'NOTICE:  ok - ' "$log") checks)"
        passed=$((passed + 1))
    else
        echo "FAIL $name"
        grep -v 'NOTICE:  ok - ' "$log" | sed 's/^/     /'
        failed=$((failed + 1))
    fi

    [[ "${KEEP_DBS:-}" == 1 ]] || dropdb "$db" > /dev/null 2>&1
done

echo "$passed passed, $failed failed"
[[ $passed -gt 0 && $failed -eq 0 ]]
