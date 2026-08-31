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
bench_port="$((55800 + pg_major))"
bench_root="$(mktemp -d "/tmp/pg-reconcile-bench-pg${pg_major}.XXXXXX")"
datasets="${PG_RECONCILE_BENCH_DATASETS:-1000000 10000000}"
worker_levels="${PG_RECONCILE_BENCH_WORKERS:-1 4 16 64}"
strategies="${PG_RECONCILE_BENCH_STRATEGIES:-exact_reference amount_time}"

cleanup() {
    "$pg_bindir/pg_ctl" -D "$bench_root/data" -m immediate stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$pg_bindir/initdb" -D "$bench_root/data" --no-locale --encoding=UTF8 >/dev/null
"$pg_bindir/pg_ctl" -D "$bench_root/data" \
    -o "-F -p $bench_port -k $bench_root -c max_connections=128" -w start >/dev/null

for row_count in $datasets; do
    if [[ ! "$row_count" =~ ^[1-9][0-9]*$ ]]; then
        echo "benchmark dataset sizes must be positive integers" >&2
        exit 2
    fi
    for strategy in $strategies; do
        if [[ "$strategy" != "exact_reference" && "$strategy" != "amount_time" ]]; then
            echo "benchmark strategies must be exact_reference or amount_time" >&2
            exit 2
        fi
        database="pg_reconcile_bench_${row_count}_${strategy}"
        "$pg_bindir/createdb" -h "$bench_root" -p "$bench_port" "$database"
        echo "dataset=$row_count strategy=$strategy ledger_entries=$((row_count < 1000000 ? row_count : 1000000))"
        "$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$bench_root" -p "$bench_port" \
            -d "$database" -v row_count="$row_count" -v match_strategy="$strategy" \
            -f "$project_dir/bench/setup.sql"

        for workers in $worker_levels; do
            if [[ ! "$workers" =~ ^[1-9][0-9]*$ || "$workers" -gt 64 ]]; then
                echo "benchmark worker levels must be integers from 1 through 64" >&2
                exit 2
            fi
            jobs="$workers"
            if [[ "$jobs" -gt 16 ]]; then jobs=16; fi
            echo "dataset=$row_count strategy=$strategy balance_workers=$workers"
            "$pg_bindir/pgbench" -n -h "$bench_root" -p "$bench_port" \
                -c "$workers" -j "$jobs" -t 1 -f "$project_dir/bench/balance.sql" "$database"
        done

        "$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$bench_root" -p "$bench_port" \
            -d "$database" -f "$project_dir/bench/verify.sql"
    done
done

echo "benchmark_cluster=$bench_root"
