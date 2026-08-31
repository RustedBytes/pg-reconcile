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
test_port=55818
test_root="$(mktemp -d /tmp/pg-reconcile-full-stack.XXXXXX)"

cleanup() {
    "$pg_bindir/pg_ctl" -D "$test_root/data" -m immediate stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

for extension_name in pg_money pg_cryptocurrency pg_fx pg_ledger pg_reconcile; do
    test -e "$pg_sharedir/extension/${extension_name}.control"
done

"$pg_bindir/initdb" -D "$test_root/data" --no-locale --encoding=UTF8 >/dev/null
"$pg_bindir/pg_ctl" -D "$test_root/data" -o "-F -p $test_port -k $test_root" -w start >/dev/null
"$pg_bindir/createdb" -h "$test_root" -p "$test_port" pg_reconcile_full_stack
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_reconcile_full_stack -f "$project_dir/ci/full-stack.sql"

