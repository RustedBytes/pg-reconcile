# pg_reconcile

`pg_reconcile` is a Rust/pgrx PostgreSQL extension for comparing an exact,
historical `pg_ledger` state with append-only balances and transactions
reported by banks, payment providers, custodians, and blockchains.

It performs no network access and never changes ledger history. Applications
collect external data and submit it to the extension.

## Build and install

PostgreSQL 14–18, Rust 1.96+, and cargo-pgrx 0.19.2 are supported.

```bash
cargo install cargo-pgrx --version 0.19.2 --locked
cargo pgrx init --pg18=/path/to/pg_config
./install.sh --pg-config /path/to/pg_config
```

```sql
CREATE EXTENSION pg_ledger;
CREATE EXTENSION pg_reconcile;
```

If `pg_ledger`, `pg_money`, or `pg_cryptocurrency` is installed later, enable
its adapter explicitly:

```sql
SELECT reconcile_enable_pg_ledger();
SELECT reconcile_enable_pg_money();
SELECT reconcile_enable_pg_cryptocurrency();
```

## Basic use

```sql
SELECT reconcile_create_account(
    name                => 'treasury-bank-usd',
    ledger_account_id   => '...'::uuid,
    asset               => 'USD',
    external_system     => 'bank',
    external_account_id => 'account-123',
    account_kind        => 'BANK',
    balance_mode        => 'BOOK',
    tolerance           => 1
);

SELECT reconcile_balance_insert(
    reconcile_account_id => '...'::uuid,
    balance              => 'USD 1004199.83',
    observed_at          => '2026-08-31T12:00:00Z',
    external_reference   => 'statement:2026-08-31:12:00'
);

SELECT * FROM reconcile_balance('...'::uuid, '2026-08-31T12:00:00Z');
SELECT * FROM reconcile_transactions('...'::uuid, clock_timestamp());
SELECT * FROM reconcile_full('...'::uuid, clock_timestamp());
```

Amounts are parsed exactly into smallest-unit integers. `USDT@ethereum` and
`USDT@tron` are distinct identities and can never match one another. Unknown
network assets declare a scale explicitly, for example
`TOK@private-chain/8`.

All table and function privileges are revoked from `PUBLIC`. See
[the API](docs/API.md), [security model](docs/SECURITY.md), and
[architecture](docs/ARCHITECTURE.md).

## Development

```bash
cargo fmt --all -- --check
cargo clippy --all-targets --no-default-features --features pg18 -- \
  -D warnings -W clippy::pedantic
./ci/test-upgrade.sh
./ci/test-extension.sh "$(cargo pgrx info pg-config 18)"
./ci/test-interoperability.sh "$(cargo pgrx info pg-config 18)"
./ci/test-highload.sh "$(cargo pgrx info pg-config 18)"
```

The high-load smoke defaults to 10,000 rows. `bench/run.sh` defaults to the
specified 1M/10M datasets, exact-reference and amount/time matching, and
1/4/16/64 balance workers. Dataset sizes, strategies, and workers can be
overridden with `PG_RECONCILE_BENCH_DATASETS`,
`PG_RECONCILE_BENCH_STRATEGIES`, and `PG_RECONCILE_BENCH_WORKERS`.
