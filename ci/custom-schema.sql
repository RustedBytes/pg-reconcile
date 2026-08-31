\set ON_ERROR_STOP on

CREATE SCHEMA accounting;
CREATE SCHEMA reconciliation;
CREATE EXTENSION pg_ledger SCHEMA accounting;
CREATE EXTENSION pg_reconcile SCHEMA reconciliation;
SET search_path = reconciliation, accounting, pg_catalog;

SELECT ledger_create_account('custom:source', 'USD', 'ANY') AS source_id \gset
SELECT ledger_create_account('custom:mapped', 'USD', 'ANY') AS mapped_id \gset
SELECT reconcile_create_account(
    'custom-bank', :'mapped_id', 'USD', 'custom-provider', 'custom-account',
    'BANK', 'BOOK', 0
) AS reconcile_id \gset
SELECT set_config('smoke.custom_reconcile_id', :'reconcile_id', false);

SELECT ledger_transfer(
    :'source_id', :'mapped_id', 'USD 1.00', 'custom:deposit', NULL,
    '2026-08-31 12:00:00+00'
);
SELECT reconcile_balance_insert(
    :'reconcile_id', 'USD 1.00', '2026-08-31 12:00:00+00', 'custom:balance'
);

DO $body$
DECLARE
    result reconciliation.reconcile_balance_results;
BEGIN
    result := reconciliation.reconcile_balance(
        current_setting('smoke.custom_reconcile_id')::uuid,
        '2026-08-31 12:01:00+00'
    );
    ASSERT result.status = 'MATCHED';
    ASSERT EXISTS (
        SELECT 1 FROM reconciliation.reconcile_integration_state
        WHERE extension_name = 'pg_ledger' AND extension_schema = 'accounting'
    );
    ASSERT NOT EXISTS (
        SELECT 1 FROM reconciliation.reconcile_validate() WHERE status <> 'OK'
    );
END
$body$;
