# Architecture

`pg_reconcile` sits between application-owned collectors and `pg_ledger`.
Collectors retain provider identifiers, timestamps, raw metadata, and exact
amounts. The extension stores that evidence, freezes a reconciliation policy
in each run, reads ledger history, and persists comparison results.

The Rust layer owns canonical asset parsing, exact decimal-to-unit conversion,
SHA-256 canonical payload hashes, deterministic timestamp scoring, UUIDv7
generation, and invariant validation. PostgreSQL owns evidence tables, foreign
keys, uniqueness, MVCC, indexes, privileges, and append-only triggers.

There is deliberately no Rust dependency on any sibling extension. SQL
adapter installers locate extension schemas through `pg_extension` and replace
stable native-type helper functions. Installation order is therefore flexible.

## Reproducible run boundary

Every run freezes:

- `as_of` for external event and ledger history selection;
- `evidence_received_cutoff`, captured at run start;
- the algorithm version;
- tolerance and matching configuration;
- the ledger transaction boundary used by a balance result.

Callers needing a snapshot shared with additional application reads should run
at `REPEATABLE READ`. A single extension function is already one PostgreSQL
transaction and one statement snapshot.

## Immutability

Balance observations, transaction observations, results, matches, and manual
decisions reject updates and deletes. A run permits only the engine's one-way
`RUNNING` to `COMPLETED`/`FAILED` transition. Account identity fields cannot be
changed; a changed mapping is represented by a new account.

Pending and settled provider states are separate external rows connected by
`supersedes_id`. Reversals are separate rows connected by
`reverses_external_transaction_id`.
