#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/pg_config" >&2
    exit 2
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pg_config="$1"
pg_bindir="$($pg_config --bindir)"
pg_major="$($pg_config --version | sed -n 's/.* \([0-9][0-9]*\).*/\1/p')"
test_port="$((55600 + pg_major))"
test_root="$(mktemp -d "/tmp/pg-reconcile-pg${pg_major}.XXXXXX")"

cleanup() {
    "$pg_bindir/pg_ctl" -D "$test_root/data" -m immediate stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

cd "$project_dir"
cargo pgrx install --pg-config "$pg_config" --no-default-features --features "pg${pg_major}"
"$pg_bindir/initdb" -D "$test_root/data" --no-locale --encoding=UTF8 >/dev/null
"$pg_bindir/pg_ctl" -D "$test_root/data" \
    -o "-F -p $test_port -k $test_root -c max_connections=128" -w start >/dev/null
"$pg_bindir/createdb" -h "$test_root" -p "$test_port" pg_reconcile_test
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_reconcile_test -f "$project_dir/ci/smoke.sql"
"$pg_bindir/createdb" -h "$test_root" -p "$test_port" pg_reconcile_security
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_reconcile_security -f "$project_dir/ci/security.sql"
"$pg_bindir/createdb" -h "$test_root" -p "$test_port" pg_reconcile_matching_edge
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_reconcile_matching_edge -f "$project_dir/ci/matching-edge.sql"
"$pg_bindir/createdb" -h "$test_root" -p "$test_port" pg_reconcile_schema_test
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_reconcile_schema_test -f "$project_dir/ci/custom-schema.sql"

"$pg_bindir/createdb" -h "$test_root" -p "$test_port" pg_reconcile_concurrency
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_reconcile_concurrency -f "$project_dir/ci/concurrency-setup.sql"
"$pg_bindir/pgbench" -n -h "$test_root" -p "$test_port" \
    -c 100 -j 8 -t 1 -f "$project_dir/ci/concurrency-duplicate.sql" pg_reconcile_concurrency
"$pg_bindir/pgbench" -n -h "$test_root" -p "$test_port" \
    -c 20 -j 8 -t 5 -f "$project_dir/ci/concurrency-balance.sql" pg_reconcile_concurrency
"$pg_bindir/pgbench" -n -h "$test_root" -p "$test_port" \
    -c 16 -j 8 -t 5 -f "$project_dir/ci/concurrency-transactions.sql" pg_reconcile_concurrency
"$pg_bindir/pgbench" -n -h "$test_root" -p "$test_port" \
    -c 2 -j 2 -t 1 -f "$project_dir/ci/concurrency-manual.sql" pg_reconcile_concurrency
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_reconcile_concurrency -f "$project_dir/ci/concurrency-verify.sql"
