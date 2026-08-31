#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/pg_config" >&2
    exit 2
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pg_config="$1"
pg_bindir="$($pg_config --bindir)"
pg_sharedir="$($pg_config --sharedir)"
pg_major="$($pg_config --version | sed -n 's/.* \([0-9][0-9]*\).*/\1/p')"
test_port="$((55700 + pg_major))"
test_root="$(mktemp -d "/tmp/pg-reconcile-interop-pg${pg_major}.XXXXXX")"

cleanup() {
    "$pg_bindir/pg_ctl" -D "$test_root/data" -m immediate stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

for extension_name in pg_money pg_cryptocurrency; do
    control="$pg_sharedir/extension/${extension_name}.control"
    sql="$pg_sharedir/extension/${extension_name}--0.0.1.sql"
    if [[ ! -e "$control" ]]; then
        cp "$project_dir/ci/fixtures/${extension_name}.control" "$control"
        cp "$project_dir/ci/fixtures/${extension_name}--0.0.1.sql" "$sql"
    fi
done

"$pg_bindir/initdb" -D "$test_root/data" --no-locale --encoding=UTF8 >/dev/null
"$pg_bindir/pg_ctl" -D "$test_root/data" -o "-F -p $test_port -k $test_root" -w start >/dev/null
"$pg_bindir/createdb" -h "$test_root" -p "$test_port" pg_reconcile_interop
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_reconcile_interop -f "$project_dir/ci/interoperability.sql"
"$pg_bindir/createdb" -h "$test_root" -p "$test_port" pg_reconcile_interop_late
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_reconcile_interop_late -f "$project_dir/ci/interoperability-late.sql"
