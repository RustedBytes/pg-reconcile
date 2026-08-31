# Reconciliation operations

Ingest provider data first, preserving the provider's `observed_at`/`event_at`
and your system's `received_at`. Use stable idempotency keys derived from the
provider and account.

Balance reconciliation chooses the latest observation whose `observed_at` is
at or before `as_of` and whose `received_at` is at or before run start. It asks
the ledger adapter to sum entries belonging to ledger transactions whose
`event_at` is at or before that observation's `observed_at` and whose
`created_at` is at or before the run-start evidence cutoff. If no observation
exists, the stored missing-observation result records the ledger at `as_of`.
The engine never uses the current cached ledger balance for a historical
comparison. Transaction candidate loading uses run `as_of` and the same
run-start creation cutoff.

Operational unresolved-item and issue views report only each account's latest
completed run of the relevant type. Older immutable results remain available
through `reconcile_run()` and `reconcile_results()` without keeping already
resolved incidents active.

`reconcile_full` persists the balance result and transaction matches in one
database transaction, then finalizes one immutable `FULL` run. Any error rolls
the entire call back. Batch functions invoke it account by account so provider
batches do not hold locks across every mapping.

No automatic cleanup is performed. Retention and archival are application or
deployment policy because external evidence may have regulatory retention
requirements.
