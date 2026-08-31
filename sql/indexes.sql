CREATE INDEX reconcile_balance_observations_account_time_idx
    ON reconcile_balance_observations (reconcile_account_id, observed_at DESC, received_at DESC, id DESC);

CREATE UNIQUE INDEX reconcile_balance_observations_idempotency_idx
    ON reconcile_balance_observations (reconcile_account_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE UNIQUE INDEX reconcile_balance_observations_reference_idx
    ON reconcile_balance_observations (reconcile_account_id, external_reference)
    WHERE external_reference IS NOT NULL;

CREATE INDEX reconcile_external_transactions_account_time_idx
    ON reconcile_external_transactions (reconcile_account_id, event_at, id);

CREATE INDEX reconcile_external_transactions_provider_id_idx
    ON reconcile_external_transactions (external_transaction_id);

CREATE UNIQUE INDEX reconcile_external_transactions_root_provider_idx
    ON reconcile_external_transactions (reconcile_account_id, external_transaction_id)
    WHERE supersedes_id IS NULL;

CREATE UNIQUE INDEX reconcile_external_transactions_idempotency_idx
    ON reconcile_external_transactions (reconcile_account_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE INDEX reconcile_external_transactions_reference_idx
    ON reconcile_external_transactions (reconcile_account_id, external_reference)
    WHERE external_reference IS NOT NULL;

CREATE INDEX reconcile_external_transactions_reversal_idx
    ON reconcile_external_transactions (reverses_external_transaction_id)
    WHERE reverses_external_transaction_id IS NOT NULL;

CREATE INDEX reconcile_runs_account_started_idx
    ON reconcile_runs (reconcile_account_id, started_at DESC, id DESC);

CREATE INDEX reconcile_matches_external_idx
    ON reconcile_matches (external_transaction_id)
    WHERE external_transaction_id IS NOT NULL;

CREATE INDEX reconcile_matches_ledger_transaction_idx
    ON reconcile_matches (ledger_transaction_id)
    WHERE ledger_transaction_id IS NOT NULL;

CREATE INDEX reconcile_matches_status_idx
    ON reconcile_matches (status);

CREATE INDEX reconcile_matches_run_ledger_entry_idx
    ON reconcile_matches (run_id, ledger_entry_id, status)
    WHERE ledger_entry_id IS NOT NULL;

CREATE INDEX reconcile_matches_unresolved_idx
    ON reconcile_matches (run_id, status)
    WHERE status IN ('AMBIGUOUS', 'UNMATCHED_EXTERNAL', 'UNMATCHED_LEDGER', 'CONFLICT');

CREATE INDEX reconcile_manual_decisions_external_idx
    ON reconcile_manual_decisions (external_transaction_id, created_at DESC, id DESC);
