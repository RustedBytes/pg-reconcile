# Architecture

`pg_reconcile` sits between application-owned collectors and `pg_ledger`.
Collectors retain provider identifiers, timestamps, raw metadata, and exact
amounts. The extension stores that evidence, freezes a reconciliation policy
in each run, reads ledger history, and persists comparison results.

The Rust layer owns canonical asset parsing, exact decimal-to-unit conversion,
SHA-256 canonical payload hashes, strong reference-key normalization (including
blockchain txid/output and transaction-hash/log pairs), deterministic timestamp
scoring, UUIDv7 generation, invariant validation, and the transactional run
lifecycle. PostgreSQL performs the set-based strategy queries coordinated by
Rust and owns evidence tables, foreign keys, uniqueness, MVCC, indexes,
privileges, and append-only triggers.

Rust matching primitives implement a common `MatchStrategy` interface. The
v0.1 `ReferenceMatch` and `ExactAmountTimeMatch` strategies supply the
normalization and deterministic score used by the set-based PostgreSQL engine;
future strategies can extend that interface without provider-specific logic in
the core.

There is deliberately no Rust dependency on any sibling extension. SQL
adapter installers locate extension schemas through `pg_extension` and replace
stable native-type helper functions. Overloads created after installation are
attached to `pg_reconcile`, so extension drop/upgrade lifecycle remains clean.
Installation order is therefore flexible.

## Reproducible run boundary

Every run freezes:

- `as_of` for external evidence selection and transaction reconciliation;
- `evidence_received_cutoff`, captured at run start;
- the algorithm version;
- tolerance and matching configuration;
- the ledger transaction boundary used by a balance result.

Balance reconciliation reads ledger history at the selected external
observation's `observed_at` (or at run `as_of` when the observation is missing).
The ledger adapter also applies the run-start cutoff to ledger transaction
`created_at`. This prevents a backdated ledger posting created after a run from
appearing in that run's evidence set. The recorded boundary includes the latest
`(event_at, created_at, transaction_id)` position and the cutoff.

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
