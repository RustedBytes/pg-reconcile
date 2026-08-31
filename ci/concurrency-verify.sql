\set ON_ERROR_STOP on

DO $body$
BEGIN
    ASSERT 1 = (
        SELECT count(*) FROM reconcile_external_transactions
        WHERE external_transaction_id = 'race:external:1'
    );
    ASSERT 1 = (
        SELECT count(DISTINCT id) FROM reconcile_external_transactions
        WHERE idempotency_key = 'race:external:idempotency'
    );
    ASSERT 100 = (
        SELECT count(*) FROM reconcile_runs WHERE reconciliation_type = 'BALANCE'
    );
    ASSERT 81 = (
        SELECT count(*) FROM reconcile_runs WHERE reconciliation_type = 'TRANSACTIONS'
    );
    ASSERT 1 = (
        SELECT count(*) FROM reconcile_manual_decisions d
        JOIN reconcile_external_transactions e ON e.id = d.external_transaction_id
        WHERE e.external_transaction_id = 'race:manual:external'
    );
    ASSERT 1 = (
        SELECT count(*) FROM reconcile_matches m
        JOIN reconcile_runs r ON r.id = m.run_id
        JOIN reconcile_external_transactions e ON e.id = m.external_transaction_id
        WHERE e.external_transaction_id = 'race:manual:external'
          AND r.as_of = '2026-08-31 15:01:00+00'
          AND m.status IN ('EXACT', 'UNMATCHED_EXTERNAL')
    );
    ASSERT NOT EXISTS (SELECT 1 FROM reconcile_validate() WHERE status <> 'OK');
END
$body$;
