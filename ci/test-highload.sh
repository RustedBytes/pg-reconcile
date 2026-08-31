#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/pg_config" >&2
    exit 2
fi

export PG_RECONCILE_BENCH_DATASETS="${PG_RECONCILE_BENCH_DATASETS:-10000}"
export PG_RECONCILE_BENCH_WORKERS="${PG_RECONCILE_BENCH_WORKERS:-1 4}"
export PG_RECONCILE_BENCH_STRATEGIES="${PG_RECONCILE_BENCH_STRATEGIES:-exact_reference amount_time}"
"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bench/run.sh" "$1"
