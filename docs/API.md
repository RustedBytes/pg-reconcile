# SQL API

## Canonical values

- `reconcile_asset(text) -> text` validates and canonicalizes an identity.
- `reconcile_asset_scale(text) -> integer` returns its smallest-unit scale.
- `reconcile_amount_asset(text) -> text` extracts a canonical asset.
- `reconcile_amount_units(text) -> numeric` returns exact integral units.
- `reconcile_format_amount(numeric, text) -> text` formats exact units.

Accepted amount order is either `USD 12.34` or `12.34 USD`. A value with more
fractional digits than the asset scale is rejected, never rounded.

## Accounts

`reconcile_create_account(...) -> uuid` creates a mapping. `tolerance` is an
absolute, non-negative number of smallest units. `matching_time_window` is zero
by default, which disables amount/time matching. `reconcile_account(uuid)` and
`reconcile_account(text)` read a mapping.

## Ingestion

`reconcile_balance_insert(...) -> uuid` stores balance evidence.

`reconcile_external_transaction_insert(...) -> uuid` stores a positive amount
plus a `CREDIT` or `DEBIT` direction. Status is `PENDING`, `SETTLED`, `REVERSED`,
or `FAILED`. Use `supersedes_id` for a later observation of the same logical
provider transaction and `reverses_external_transaction_id` for a reversal.

Both functions accept `idempotency_key`. The same key and same canonical
payload returns the existing UUID. Reusing it with different data raises
SQLSTATE `PGR04`. Concurrent retries serialize on a transaction-scoped advisory
lock and the unique indexes remain the final constraint. `received_at` records
the first persisted receipt and is not part of the financial-payload hash, so a
retry that uses its default `clock_timestamp()` remains idempotent.

When optional money or cryptocurrency adapters are enabled, both ingestion
functions accept `money_with_currency`, `money_minor`, or `crypto_amount`
directly. `reconcile_asset(...)` also accepts both money types and
`crypto_asset`; cryptocurrency adapters derive the canonical symbol, network,
and decimals through typed accessors rather than parsing the type's wire text.

## Reconciliation

- `reconcile_balance(account_id, as_of) -> reconcile_balance_results`
- `reconcile_transactions(account_id, as_of) -> setof reconcile_matches`
- `reconcile_full(account_id, as_of) -> table(...)`
- `reconcile_all(external_system, as_of) -> table(account_id, run_id)`
- `reconcile_all_enabled(as_of) -> table(account_id, run_id)`

Balance difference is always `external - ledger`. Status is `MATCHED`,
`WITHIN_TOLERANCE`, `MISMATCH`, or `MISSING_EXTERNAL_OBSERVATION`.

Read stored data with `reconcile_run(uuid)`, `reconcile_results(uuid)`, and the
views documented in the schema: `reconcile_latest_balances`,
`reconcile_latest_results`, `reconcile_unmatched_external`,
`reconcile_unmatched_ledger`, `reconcile_ambiguous`, `reconcile_issues`, and
`reconcile_run_summary`.

## Manual decisions

`reconcile_match_manual(external_transaction, ledger_transaction, reason,
actor)` validates account, asset, signed amount, and one-to-one ledger-entry
ownership, then appends a manual decision. `actor` defaults to the authenticated
database `session_user`; passing any different value is rejected. The same rule
applies to `reconcile_mark_external_unmatched(...)`. Later runs apply the newest
decision without changing older results.

## Validation and adapters

`reconcile_validate()` returns named `OK`/`FAIL` checks with violation counts.
Adapter entry points are `reconcile_enable_pg_ledger()`,
`reconcile_enable_pg_money()`, and `reconcile_enable_pg_cryptocurrency()`.

## Stable errors

| SQLSTATE | Detail identifier |
| --- | --- |
| `PGR01` | `RECONCILE_ACCOUNT_NOT_FOUND` |
| `PGR02` | `RECONCILE_ASSET_MISMATCH` |
| `PGR03` | `RECONCILE_EXTERNAL_DUPLICATE` |
| `PGR04` | `RECONCILE_IDEMPOTENCY_CONFLICT` |
| `PGR08` | `RECONCILE_INVALID_MANUAL_MATCH` |
| `PGR09` | `RECONCILE_LEDGER_ADAPTER_MISSING` |
| `22023` | `RECONCILE_MALFORMED_EXTERNAL` or `RECONCILE_INVALID_RUN` |
| `55000` | `RECONCILE_IMMUTABLE_EVIDENCE`, `RECONCILE_IMMUTABLE_ACCOUNT_IDENTITY`, or `RECONCILE_IMMUTABLE_RUN` |
| `XX000` | `RECONCILE_INTERNAL_ERROR` |

Standard SQLSTATE `22023` is used for malformed parameters and `55000` for
attempted mutation of immutable evidence. `PG_EXCEPTION_DETAIL` contains only
the stable identifier shown above (or the corresponding documented identifier
for standard-state failures), so clients do not parse human-readable messages.
