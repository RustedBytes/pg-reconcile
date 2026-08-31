# Reconciliation operations

Ingest provider data first, preserving the provider's `observed_at`/`event_at`
and your system's `received_at`. Use stable idempotency keys derived from the
provider and account.

Balance reconciliation chooses the latest observation whose `observed_at` is
at or before `as_of` and whose `received_at` is at or before run start. It asks
the ledger adapter to sum entries belonging to ledger transactions whose
`event_at` is at or before `as_of`. It never uses the current cached ledger
balance for a historical comparison.

`reconcile_full` persists the balance result and transaction matches in one
database transaction, then finalizes one immutable `FULL` run. Any error rolls
the entire call back. Batch functions invoke it account by account so provider
batches do not hold locks across every mapping.

No automatic cleanup is performed. Retention and archival are application or
deployment policy because external evidence may have regulatory retention
requirements.
