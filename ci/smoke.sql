\set ON_ERROR_STOP on

CREATE EXTENSION pg_ledger;
CREATE EXTENSION pg_reconcile;

DO $body$
BEGIN
    ASSERT reconcile_asset('usd') = 'USD';
    ASSERT reconcile_asset('btc') = 'BTC@bitcoin';
    ASSERT reconcile_asset('USDT@ethereum') <> reconcile_asset('USDT@tron');
    ASSERT reconcile_amount_units('USD 12.34') = 1234;
    ASSERT reconcile_format_amount(1234, 'USD') = '12.34 USD';
END
$body$;

SELECT ledger_create_account('reconcile:bank:source', 'USD', 'ANY') AS source_id \gset
SELECT ledger_create_account('reconcile:bank:mapped', 'USD', 'ANY') AS mapped_id \gset

SELECT reconcile_create_account(
    'treasury-bank-usd', :'mapped_id', 'USD', 'test-bank', 'account-123',
    'BANK', 'BOOK', 'USD 0.01', '{"purpose":"smoke"}', interval '5 minutes'
) AS reconcile_id \gset
SELECT set_config('smoke.reconcile_id', :'reconcile_id', false);

SELECT ledger_transfer(
    :'source_id', :'mapped_id', 'USD 100.00', 'bank:deposit:1', 'ledger:deposit:1',
    '2026-08-31 12:00:00+00'
) AS first_ledger_transaction \gset

SELECT reconcile_balance_insert(
    :'reconcile_id', 'USD 100.00', '2026-08-31 12:00:00+00',
    'statement:12', '12', '2026-08-31 12:00:01+00',
    '{"source":"fixture"}', 'balance:12'
) AS first_observation \gset
SELECT set_config('smoke.first_observation', :'first_observation', false);

DO $body$
DECLARE
    result reconcile_balance_results;
BEGIN
    result := reconcile_balance(current_setting('smoke.reconcile_id')::uuid,
                                '2026-08-31 12:30:00+00');
    ASSERT result.status = 'MATCHED';
    ASSERT result.ledger_balance_units = 10000;
    ASSERT result.external_balance_units = 10000;
    ASSERT result.difference_units = 0;
END
$body$;

-- A later posting must not affect a historical reconciliation snapshot.
SELECT ledger_transfer(
    :'source_id', :'mapped_id', 'USD 20.00', 'ledger-only:20', 'ledger:deposit:2',
    '2026-08-31 13:00:00+00'
) AS second_ledger_transaction \gset

DO $body$
DECLARE
    result reconcile_balance_results;
BEGIN
    result := reconcile_balance(current_setting('smoke.reconcile_id')::uuid,
                                '2026-08-31 12:30:00+00');
    ASSERT result.status = 'MATCHED';
    ASSERT result.ledger_balance_units = 10000;
END
$body$;

SELECT reconcile_balance_insert(
    :'reconcile_id', 'USD 119.99', '2026-08-31 13:30:00+00',
    'statement:1330', NULL, '2026-08-31 13:30:01+00', NULL, 'balance:1330'
) AS tolerance_observation \gset

DO $body$
DECLARE
    result reconcile_balance_results;
BEGIN
    result := reconcile_balance(current_setting('smoke.reconcile_id')::uuid,
                                '2026-08-31 13:45:00+00');
    ASSERT result.status = 'WITHIN_TOLERANCE';
    ASSERT result.difference_units = -1;
END
$body$;

SELECT reconcile_balance_insert(
    :'reconcile_id', 'USD 119.00', '2026-08-31 14:00:00+00',
    'statement:14', NULL, '2026-08-31 14:00:01+00', NULL, 'balance:14'
) AS mismatch_observation \gset
SELECT set_config('smoke.mismatch_observation', :'mismatch_observation', false);

DO $body$
DECLARE
    result reconcile_balance_results;
    retry_id uuid;
BEGIN
    result := reconcile_balance(current_setting('smoke.reconcile_id')::uuid,
                                '2026-08-31 14:05:00+00');
    ASSERT result.status = 'MISMATCH';
    ASSERT result.difference_units = -100;
    retry_id := reconcile_balance_insert(
        current_setting('smoke.reconcile_id')::uuid, 'USD 119.00', '2026-08-31 14:00:00+00',
        'statement:14', NULL, '2026-08-31 14:00:01+00', NULL, 'balance:14'
    );
    ASSERT retry_id = current_setting('smoke.mismatch_observation')::uuid;
    BEGIN
        PERFORM reconcile_balance_insert(
            current_setting('smoke.reconcile_id')::uuid, 'USD 118.00', '2026-08-31 14:00:00+00',
            'statement:14', NULL, '2026-08-31 14:00:01+00', NULL, 'balance:14'
        );
        ASSERT false, 'conflicting retry should fail';
    EXCEPTION WHEN SQLSTATE 'PGR04' THEN
        NULL;
    END;
END
$body$;

-- Volatile received_at defaults do not turn an otherwise identical retry into
-- a different canonical payload. The first receipt time remains immutable.
DO $body$
DECLARE
    first_balance uuid;
    retried_balance uuid;
    first_transaction uuid;
    retried_transaction uuid;
BEGIN
    first_balance := reconcile_balance_insert(
        reconcile_account_id => current_setting('smoke.reconcile_id')::uuid,
        balance => 'USD 0.00', observed_at => '2026-08-31 11:00:00+00',
        external_reference => 'statement:default-retry',
        idempotency_key => 'balance:default-retry'
    );
    retried_balance := reconcile_balance_insert(
        reconcile_account_id => current_setting('smoke.reconcile_id')::uuid,
        balance => 'USD 0.00', observed_at => '2026-08-31 11:00:00+00',
        external_reference => 'statement:default-retry',
        idempotency_key => 'balance:default-retry'
    );
    ASSERT first_balance = retried_balance;

    first_transaction := reconcile_external_transaction_insert(
        reconcile_account_id => current_setting('smoke.reconcile_id')::uuid,
        external_transaction_id => 'provider:default-retry',
        amount => 'USD 1.00', direction => 'CREDIT',
        event_at => '2026-08-31 11:00:00+00', status => 'FAILED',
        idempotency_key => 'external:default-retry'
    );
    retried_transaction := reconcile_external_transaction_insert(
        reconcile_account_id => current_setting('smoke.reconcile_id')::uuid,
        external_transaction_id => 'provider:default-retry',
        amount => 'USD 1.00', direction => 'CREDIT',
        event_at => '2026-08-31 11:00:00+00', status => 'FAILED',
        idempotency_key => 'external:default-retry'
    );
    ASSERT first_transaction = retried_transaction;
END
$body$;

SELECT reconcile_external_transaction_insert(
    :'reconcile_id', 'provider:deposit:1', 'USD 100.00', 'CREDIT',
    '2026-08-31 12:00:00+00', 'SETTLED', '2026-08-31 12:00:02+00',
    NULL, NULL, 'bank:deposit:1', '{"channel":"bank"}', 'external:1'
) AS first_external \gset
SELECT set_config('smoke.first_external', :'first_external', false);

DO $body$
DECLARE
    retry_id uuid;
BEGIN
    retry_id := reconcile_external_transaction_insert(
        current_setting('smoke.reconcile_id')::uuid,
        'provider:deposit:1', 'USD 100.00', 'CREDIT',
        '2026-08-31 12:00:00+00', 'SETTLED', '2026-08-31 12:00:02+00',
        NULL, NULL, 'bank:deposit:1', '{"channel":"bank"}', 'external:1'
    );
    ASSERT retry_id = current_setting('smoke.first_external')::uuid;
    BEGIN
        PERFORM reconcile_external_transaction_insert(
            current_setting('smoke.reconcile_id')::uuid,
            'provider:deposit:1', 'USD 99.00', 'CREDIT',
            '2026-08-31 12:00:00+00', 'SETTLED', '2026-08-31 12:00:02+00',
            NULL, NULL, 'bank:deposit:1', '{"channel":"bank"}', 'external:1'
        );
        ASSERT false, 'transaction idempotency conflict should fail';
    EXCEPTION WHEN SQLSTATE 'PGR04' THEN
        NULL;
    END;
    BEGIN
        PERFORM reconcile_external_transaction_insert(
            current_setting('smoke.reconcile_id')::uuid,
            'provider:deposit:1', 'USD 99.00', 'CREDIT',
            '2026-08-31 12:00:00+00', 'SETTLED', '2026-08-31 12:00:02+00',
            NULL, NULL, 'bank:deposit:1', NULL, 'external:duplicate-provider'
        );
        ASSERT false, 'duplicate provider transaction should fail';
    EXCEPTION WHEN SQLSTATE 'PGR03' THEN
        NULL;
    END;
END
$body$;

SELECT reconcile_external_transaction_insert(
    :'reconcile_id', 'provider:deposit:2', 'USD 20.00', 'CREDIT',
    '2026-08-31 13:00:01+00', 'PENDING', '2026-08-31 13:00:02+00',
    NULL, NULL, 'bank:deposit:2', NULL, 'external:2:pending'
) AS pending_external \gset
SELECT set_config('smoke.pending_external', :'pending_external', false);

SELECT reconcile_external_transaction_insert(
    :'reconcile_id', 'provider:deposit:2', 'USD 20.00', 'CREDIT',
    '2026-08-31 13:00:01+00', 'SETTLED', '2026-08-31 13:01:00+00',
    NULL, NULL, 'bank:deposit:2', NULL, 'external:2:settled', NULL, :'pending_external'
) AS settled_external \gset
SELECT set_config('smoke.settled_external', :'settled_external', false);

SELECT count(*) AS transaction_result_count
FROM reconcile_transactions(:'reconcile_id', '2026-08-31 14:10:00+00');

DO $body$
DECLARE
    latest_run uuid;
BEGIN
    SELECT id INTO latest_run FROM reconcile_runs
    WHERE reconciliation_type = 'TRANSACTIONS' ORDER BY started_at DESC, id DESC LIMIT 1;
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE run_id = latest_run
          AND external_transaction_id = current_setting('smoke.first_external')::uuid
          AND status = 'EXACT'
          AND reason->>'strategy' = 'explicit_reference'
    );
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE run_id = latest_run
          AND external_transaction_id = current_setting('smoke.settled_external')::uuid
          AND status = 'EXACT'
          AND reason->>'strategy' = 'exact_amount_time'
    );
    ASSERT NOT EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE run_id = latest_run
          AND external_transaction_id = current_setting('smoke.pending_external')::uuid
    );
END
$body$;

-- A successor whose event is after as_of must not hide the qualifying prior
-- observation merely because it was received before the run started.
SELECT reconcile_external_transaction_insert(
    :'reconcile_id', 'provider:future-progression', 'USD 11.00', 'CREDIT',
    '2026-08-31 18:00:00+00', 'PENDING', '2026-08-31 14:00:00+00',
    NULL, NULL, NULL, NULL, 'external:future:pending'
) AS future_pending \gset
SELECT reconcile_external_transaction_insert(
    :'reconcile_id', 'provider:future-progression', 'USD 11.00', 'CREDIT',
    '2026-08-31 20:00:00+00', 'SETTLED', '2026-08-31 14:01:00+00',
    NULL, NULL, NULL, NULL, 'external:future:settled', NULL, :'future_pending'
) AS future_settled \gset
SELECT count(*) FROM reconcile_transactions(:'reconcile_id', '2026-08-31 18:30:00+00');
SELECT set_config('smoke.future_pending', :'future_pending', false);
SELECT set_config('smoke.future_settled', :'future_settled', false);

DO $body$
DECLARE
    latest_run uuid;
BEGIN
    SELECT id INTO latest_run FROM reconcile_runs
    WHERE reconciliation_type = 'TRANSACTIONS' ORDER BY started_at DESC, id DESC LIMIT 1;
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE run_id = latest_run
          AND external_transaction_id = current_setting('smoke.future_pending')::uuid
          AND status = 'UNMATCHED_EXTERNAL'
    );
    ASSERT NOT EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE run_id = latest_run
          AND external_transaction_id = current_setting('smoke.future_settled')::uuid
    );
END
$body$;

-- Linked external and ledger reversals are preserved as new evidence and can
-- match deterministically. A strong reference with a wrong amount is a
-- conflict and must not fall through to amount/time matching.
SELECT ledger_reverse(
    :'first_ledger_transaction', 'bank:deposit:1:reversal', 'ledger:reversal:1',
    '2026-08-31 14:30:00+00'
) AS reversal_ledger \gset
SELECT reconcile_external_transaction_insert(
    :'reconcile_id', 'provider:deposit:1:reversal', 'USD 100.00', 'DEBIT',
    '2026-08-31 14:30:00+00', 'REVERSED', '2026-08-31 14:30:01+00',
    NULL, NULL, 'bank:deposit:1:reversal', NULL, 'external:reversal:1',
    :'first_external'
) AS reversal_external \gset
SELECT set_config('smoke.reversal_external', :'reversal_external', false);

SELECT ledger_transfer(
    :'source_id', :'mapped_id', 'USD 3.00', 'bank:wrong:amount', 'ledger:wrong:amount',
    '2026-08-31 14:40:00+00'
) AS wrong_amount_ledger \gset
SELECT reconcile_external_transaction_insert(
    :'reconcile_id', 'provider:wrong:amount', 'USD 4.00', 'CREDIT',
    '2026-08-31 14:40:00+00', 'SETTLED', '2026-08-31 14:40:01+00',
    NULL, NULL, 'bank:wrong:amount', NULL, 'external:wrong:amount'
) AS wrong_amount_external \gset
SELECT set_config('smoke.wrong_amount_external', :'wrong_amount_external', false);

SELECT count(*) FROM reconcile_transactions(:'reconcile_id', '2026-08-31 14:50:00+00');
DO $body$
DECLARE
    latest_run uuid;
BEGIN
    SELECT id INTO latest_run FROM reconcile_runs
    WHERE reconciliation_type = 'TRANSACTIONS' ORDER BY started_at DESC, id DESC LIMIT 1;
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE run_id = latest_run
          AND external_transaction_id = current_setting('smoke.reversal_external')::uuid
          AND status = 'EXACT' AND reason->>'strategy' = 'linked_reversal'
    );
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE run_id = latest_run
          AND external_transaction_id = current_setting('smoke.wrong_amount_external')::uuid
          AND status = 'CONFLICT' AND reason->>'strategy' = 'explicit_reference'
    );
END
$body$;

-- Missing observations are stored as a result rather than compared to a
-- current balance or silently omitted.
SELECT reconcile_create_account(
    'treasury-bank-usd-empty', :'mapped_id', 'USD', 'test-bank', 'account-empty',
    'BANK', 'BOOK', 0
) AS empty_reconcile_id \gset

-- An observation after as_of is not eligible, even if it was already received.
SELECT reconcile_balance_insert(
    :'empty_reconcile_id', 'USD 120.00', '2026-08-31 13:00:00+00',
    'statement:future', NULL, '2026-08-31 13:00:01+00', NULL, 'balance:future'
) AS future_balance_observation \gset

SELECT (reconcile_balance(:'empty_reconcile_id', '2026-08-31 12:30:00+00')).status
       AS empty_balance_status \gset
SELECT set_config('smoke.empty_balance_status', :'empty_balance_status', false);

DO $body$
BEGIN
    ASSERT current_setting('smoke.empty_balance_status') = 'MISSING_EXTERNAL_OBSERVATION';
    BEGIN
        PERFORM reconcile_balance_insert(
            current_setting('smoke.reconcile_id')::uuid, 'BTC 1.0',
            '2026-08-31 14:01:00+00', 'wrong-asset'
        );
        ASSERT false, 'asset mismatch should fail';
    EXCEPTION WHEN SQLSTATE 'PGR02' THEN
        NULL;
    END;
END
$body$;

-- Two exact amount/time candidates remain ambiguous; no fuzzy tie-break is
-- allowed.
SELECT ledger_transfer(
    :'source_id', :'mapped_id', 'USD 5.00', NULL, 'ledger:ambiguous:1',
    '2026-08-31 15:00:00+00'
) AS ambiguous_ledger_one \gset
SELECT ledger_transfer(
    :'source_id', :'mapped_id', 'USD 5.00', NULL, 'ledger:ambiguous:2',
    '2026-08-31 15:00:00+00'
) AS ambiguous_ledger_two \gset
SELECT reconcile_external_transaction_insert(
    :'reconcile_id', 'provider:ambiguous', 'USD 5.00', 'CREDIT',
    '2026-08-31 15:00:00+00', 'SETTLED', '2026-08-31 15:00:01+00',
    NULL, NULL, NULL, NULL, 'external:ambiguous'
) AS ambiguous_external \gset
SELECT set_config('smoke.ambiguous_external', :'ambiguous_external', false);

SELECT count(*) FROM reconcile_transactions(:'reconcile_id', '2026-08-31 15:10:00+00');
DO $body$
BEGIN
    ASSERT 2 = (
        SELECT count(*) FROM reconcile_matches
        WHERE external_transaction_id = current_setting('smoke.ambiguous_external')::uuid
          AND status = 'AMBIGUOUS'
    );
END
$body$;

-- Manual decisions are append-only inputs to later runs.
SELECT ledger_transfer(
    :'source_id', :'mapped_id', 'USD 7.00', NULL, 'ledger:manual',
    '2026-08-31 16:00:00+00'
) AS manual_ledger \gset
SELECT reconcile_external_transaction_insert(
    :'reconcile_id', 'provider:manual', 'USD 7.00', 'CREDIT',
    '2026-08-31 18:00:00+00', 'SETTLED', '2026-08-31 14:00:01+00',
    NULL, NULL, NULL, NULL, 'external:manual'
) AS manual_external \gset
SELECT set_config('smoke.manual_external', :'manual_external', false);
SELECT reconcile_match_manual(:'manual_external', :'manual_ledger', 'operator verified statement');
SELECT reconcile_external_transaction_insert(
    :'reconcile_id', 'provider:manual:collision', 'USD 7.00', 'CREDIT',
    '2026-08-31 18:00:01+00', 'SETTLED', '2026-08-31 14:00:02+00',
    NULL, NULL, NULL, NULL, 'external:manual:collision'
) AS manual_collision_external \gset
SELECT set_config('smoke.manual_collision_external', :'manual_collision_external', false);
SELECT set_config('smoke.manual_ledger', :'manual_ledger', false);
DO $body$
BEGIN
    BEGIN
        PERFORM reconcile_match_manual(
            current_setting('smoke.manual_collision_external')::uuid,
            current_setting('smoke.manual_ledger')::uuid,
            'must not reuse ledger entry'
        );
        ASSERT false, 'one ledger entry must not be manually assigned to two external items';
    EXCEPTION WHEN SQLSTATE 'PGR08' THEN
        NULL;
    END;
END
$body$;
SELECT count(*) FROM reconcile_transactions(:'reconcile_id', '2026-08-31 18:10:00+00');

DO $body$
DECLARE
    latest_run uuid;
BEGIN
    SELECT id INTO latest_run FROM reconcile_runs
    WHERE reconciliation_type = 'TRANSACTIONS' ORDER BY started_at DESC, id DESC LIMIT 1;
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE run_id = latest_run
          AND external_transaction_id = current_setting('smoke.manual_external')::uuid
          AND status = 'EXACT' AND reason->>'strategy' = 'manual'
    );
END
$body$;

-- A full run writes balance and transaction evidence under one run ID.
SELECT * FROM reconcile_full(:'reconcile_id', '2026-08-31 18:10:00+00');
DO $body$
BEGIN
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_runs r
        WHERE r.reconciliation_type = 'FULL' AND r.status = 'COMPLETED'
          AND EXISTS (SELECT 1 FROM reconcile_balance_results b WHERE b.run_id = r.id)
          AND EXISTS (SELECT 1 FROM reconcile_matches m WHERE m.run_id = r.id)
    );
END
$body$;

DO $body$
BEGIN
    ASSERT 2 = (
        SELECT count(*) FROM reconcile_all('test-bank', '2026-08-31 18:10:00+00')
    );
    ASSERT 2 = (
        SELECT count(*) FROM reconcile_all_enabled('2026-08-31 18:10:00+00')
    );
END
$body$;

-- Immutability is enforced independently of SQL privileges.
DO $body$
BEGIN
    BEGIN
        UPDATE reconcile_balance_observations SET metadata = '{}'
        WHERE id = current_setting('smoke.first_observation')::uuid;
        ASSERT false, 'observation update should fail';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN
        NULL;
    END;
    BEGIN
        DELETE FROM reconcile_matches;
        ASSERT false, 'match delete should fail';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN
        NULL;
    END;
END
$body$;

CREATE ROLE reconcile_smoke_ordinary;
DO $body$
BEGIN
    ASSERT NOT has_table_privilege('reconcile_smoke_ordinary', 'reconcile_accounts', 'SELECT');
    ASSERT NOT has_table_privilege('reconcile_smoke_ordinary', 'reconcile_external_transactions', 'INSERT');
    ASSERT NOT has_function_privilege(
        'reconcile_smoke_ordinary',
        'reconcile_balance_insert(uuid,text,timestamptz,text,text,timestamptz,jsonb,text)',
        'EXECUTE'
    );
END
$body$;

DO $body$
DECLARE
    error_detail text;
BEGIN
    BEGIN
        PERFORM reconcile_asset('invalid asset');
        ASSERT false, 'invalid canonical asset should fail';
    EXCEPTION WHEN invalid_parameter_value THEN
        GET STACKED DIAGNOSTICS error_detail = PG_EXCEPTION_DETAIL;
        ASSERT error_detail = 'RECONCILE_ASSET_MISMATCH';
    END;
    ASSERT NOT EXISTS (SELECT 1 FROM reconcile_validate() WHERE status <> 'OK');
    ASSERT EXISTS (SELECT 1 FROM reconcile_issues WHERE issue_type = 'BALANCE_MISMATCH');
END
$body$;
