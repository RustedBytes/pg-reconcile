# Support matrix

`pg_reconcile` 0.1 targets PostgreSQL 14, 15, 16, 17, and 18, Rust 1.96 or
newer, and pgrx/cargo-pgrx 0.19.2. The default build feature is `pg18`; select
exactly one `pg14`–`pg18` feature for another server.

The core extension installs without `pg_ledger`, `pg_money`,
`pg_cryptocurrency`, or `pg_fx`. Balance and transaction reconciliation need
the `pg_ledger` adapter. Money and cryptocurrency adapters are optional input
overloads. `pg_fx` is intentionally unrelated to per-asset reconciliation.
