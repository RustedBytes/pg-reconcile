\set ON_ERROR_STOP on

CREATE ROLE reconcile_reader;
CREATE ROLE reconcile_ingestor;
CREATE ROLE reconcile_operator;
CREATE ROLE reconcile_admin;

CREATE EXTENSION pg_ledger;
CREATE EXTENSION pg_reconcile;

SELECT ledger_create_account('security:source', 'USD', 'ANY') AS source_id \gset
SELECT ledger_create_account('security:mapped', 'USD', 'ANY') AS mapped_id \gset
SELECT ledger_transfer(
    :'source_id', :'mapped_id', 'USD 10.00', 'security:deposit',
    'security:ledger:deposit', '2026-08-31 10:00:00+00'
) AS ledger_transaction_id \gset

SET SESSION AUTHORIZATION reconcile_admin;
SELECT reconcile_create_account(
    'security-bank-usd', :'mapped_id', 'USD', 'security-bank', 'account-1',
    'BANK', 'BOOK', 0, NULL, interval '1 minute'
) AS reconcile_id \gset
SELECT (reconcile_account(:'reconcile_id')).name;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION reconcile_ingestor;
SELECT reconcile_balance_insert(
    :'reconcile_id', 'USD 10.00', '2026-08-31 10:00:00+00',
    'security:balance', NULL, '2026-08-31 10:00:01+00'
) AS observation_id \gset
SELECT set_config('security.observation_id', :'observation_id', false);
SELECT reconcile_external_transaction_insert(
    :'reconcile_id', 'security:external:deposit', 'USD 10.00', 'CREDIT',
    '2026-08-31 10:00:00+00', 'SETTLED', '2026-08-31 10:00:01+00',
    NULL, NULL, 'security:deposit', NULL, 'security:external:key'
) AS external_id \gset
DO $body$
BEGIN
    BEGIN
        UPDATE reconcile_balance_observations SET metadata = '{}'
        WHERE id = current_setting('security.observation_id')::uuid;
        ASSERT false, 'ingestor must not update external evidence';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
END
$body$;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION reconcile_operator;
SELECT count(*) FROM reconcile_transactions(:'reconcile_id', '2026-08-31 10:01:00+00');
SELECT run_id FROM reconcile_run_summary
WHERE reconcile_account_id = :'reconcile_id'
ORDER BY completed_at DESC, run_id DESC LIMIT 1 \gset
SELECT set_config('security.run_id', :'run_id', false);
SELECT set_config('security.reconcile_id', :'reconcile_id', false);
SELECT set_config('security.external_id', :'external_id', false);
SELECT reconcile_match_manual(
    :'external_id', :'ledger_transaction_id', 'verified by authenticated operator'
) AS manual_decision_id \gset
SELECT set_config('security.manual_decision_id', :'manual_decision_id', false);
DO $body$
BEGIN
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_results(current_setting('security.run_id')::uuid)
        WHERE result_kind = 'match'
    );
    ASSERT NOT EXISTS (SELECT 1 FROM reconcile_validate() WHERE status <> 'OK');
    BEGIN
        PERFORM reconcile_mark_external_unmatched(
            current_setting('security.external_id')::uuid,
            'forged actor attempt', 'somebody_else'
        );
        ASSERT false, 'manual actor spoofing must fail';
    EXCEPTION WHEN SQLSTATE 'PGR08' THEN
        NULL;
    END;
    BEGIN
        PERFORM _reconcile_start_run(
            current_setting('security.reconcile_id')::uuid,
            'TRANSACTIONS', clock_timestamp()
        );
        ASSERT false, 'operator must not execute internal mutation functions';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        DELETE FROM reconcile_matches;
        ASSERT false, 'operator must not modify historical matches';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
END
$body$;
RESET SESSION AUTHORIZATION;

DO $body$
BEGIN
    ASSERT (SELECT actor FROM reconcile_manual_decisions
            WHERE id = current_setting('security.manual_decision_id')::uuid)
           = 'reconcile_operator';
END
$body$;

SET SESSION AUTHORIZATION reconcile_reader;
DO $body$
BEGIN
    ASSERT (reconcile_run(current_setting('security.run_id')::uuid)).status = 'COMPLETED';
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_results(current_setting('security.run_id')::uuid)
    );
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_run_summary
        WHERE run_id = current_setting('security.run_id')::uuid
    );
    BEGIN
        PERFORM 1 FROM reconcile_runs LIMIT 1;
        ASSERT false, 'reader must not read raw run tables';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        PERFORM reconcile_balance(
            current_setting('security.reconcile_id')::uuid, clock_timestamp()
        );
        ASSERT false, 'reader must not execute reconciliation';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
END
$body$;
RESET SESSION AUTHORIZATION;
