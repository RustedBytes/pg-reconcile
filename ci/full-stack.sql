\set ON_ERROR_STOP on

CREATE EXTENSION pg_money;
CREATE EXTENSION pg_cryptocurrency;
CREATE EXTENSION pg_fx;
CREATE EXTENSION pg_ledger;
CREATE EXTENSION pg_reconcile;

-- Bank: exact reference, missing ledger posting, and missing external item.
SELECT ledger_create_account('full:bank:source', 'USD', 'ANY') AS bank_source \gset
SELECT ledger_create_account('full:bank:mapped', 'USD', 'ANY') AS bank_mapped \gset
SELECT reconcile_create_account(
    'full-bank', :'bank_mapped', 'USD', 'full-bank-provider', 'bank-1',
    'BANK', 'BOOK', 0, NULL, interval '5 minutes'
) AS bank_reconcile \gset
SELECT ledger_transfer(
    :'bank_source', :'bank_mapped', 'USD 100.00', 'bank:deposit:1',
    'full:bank:deposit', '2026-08-29 10:00:00+00'
);
SELECT ledger_transfer(
    :'bank_mapped', :'bank_source', 'USD 3.00', 'bank:ledger-only',
    'full:bank:ledger-only', '2026-08-29 10:01:00+00'
);
SELECT reconcile_external_transaction_insert(
    :'bank_reconcile', 'bank-external-1', 'USD 100.00', 'CREDIT',
    '2026-08-29 10:00:00+00', 'SETTLED', '2026-08-30 10:00:00+00',
    NULL, NULL, 'bank:deposit:1'
) AS bank_external \gset
SELECT reconcile_external_transaction_insert(
    :'bank_reconcile', 'bank-external-only', 'USD 7.00', 'CREDIT',
    '2026-08-29 10:02:00+00', 'SETTLED', '2026-08-30 10:00:00+00'
) AS bank_external_only \gset
SELECT count(*) FROM reconcile_transactions(:'bank_reconcile', '2026-08-29 10:10:00+00');
SELECT run_id AS bank_run FROM reconcile_run_summary
WHERE reconcile_account_id = :'bank_reconcile'
ORDER BY completed_at DESC, run_id DESC LIMIT 1 \gset
SELECT set_config('full.bank_run', :'bank_run', false);
SELECT set_config('full.bank_external', :'bank_external', false);
SELECT set_config('full.bank_external_only', :'bank_external_only', false);

DO $body$
BEGIN
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE run_id = current_setting('full.bank_run')::uuid
          AND external_transaction_id = current_setting('full.bank_external')::uuid
          AND status = 'EXACT' AND reason->>'strategy' = 'explicit_reference'
    );
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE run_id = current_setting('full.bank_run')::uuid
          AND external_transaction_id = current_setting('full.bank_external_only')::uuid
          AND status = 'UNMATCHED_EXTERNAL'
    );
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE run_id = current_setting('full.bank_run')::uuid
          AND status = 'UNMATCHED_LEDGER'
          AND reason->>'units' = '-300'
    );
END
$body$;

-- Balance comparison is anchored to the selected observation time, not the
-- later run time. The second posting must therefore not affect this result.
SELECT ledger_create_account('full:observed:source', 'USD', 'ANY') AS observed_source \gset
SELECT ledger_create_account('full:observed:mapped', 'USD', 'ANY') AS observed_mapped \gset
SELECT reconcile_create_account(
    'full-observation-time', :'observed_mapped', 'USD', 'observation-provider',
    'observed-1', 'BANK', 'BOOK'
) AS observed_reconcile \gset
SELECT ledger_transfer(
    :'observed_source', :'observed_mapped', 'USD 10.00', 'observed:initial',
    'full:observed:initial', '2026-08-29 10:00:00+00'
);
SELECT reconcile_balance_insert(
    :'observed_reconcile', 'USD 10.00', '2026-08-29 10:00:00+00',
    'observed:balance', NULL, '2026-08-30 10:00:00+00'
);
SELECT ledger_transfer(
    :'observed_source', :'observed_mapped', 'USD 2.00', 'observed:later',
    'full:observed:later', '2026-08-29 10:30:00+00'
);
SELECT (reconcile_balance(
    :'observed_reconcile', '2026-08-29 11:00:00+00'
)).id AS observed_result \gset
SELECT set_config('full.observed_result', :'observed_result', false);

DO $body$
BEGIN
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_balance_results
        WHERE id = current_setting('full.observed_result')::uuid
          AND status = 'MATCHED'
          AND ledger_balance_units = 1000
          AND external_balance_units = 1000
          AND ledger_boundary ? 'through_created_at'
          AND (ledger_boundary->>'as_of')::timestamptz = '2026-08-29 10:00:00+00'
    );
END
$body$;

-- BTC: the blockchain txid in metadata is a strong deterministic reference.
SELECT ledger_create_account('full:btc:source', 'BTC', 'ANY') AS btc_source \gset
SELECT ledger_create_account('full:btc:mapped', 'BTC', 'ANY') AS btc_mapped \gset
SELECT reconcile_create_account(
    'full-btc', :'btc_mapped', 'BTC@bitcoin', 'bitcoin-indexer', 'bc1q-test',
    'BLOCKCHAIN_WALLET', 'TOTAL'
) AS btc_reconcile \gset
SELECT ledger_transfer(
    :'btc_source', :'btc_mapped', '0.5 BTC', NULL, 'full:btc:deposit',
    '2026-08-29 11:00:00+00', '{"txid":"btc-hash-001","output_index":1}'
);
SELECT reconcile_external_transaction_insert(
    :'btc_reconcile', 'bitcoin-observation-1', '0.5 BTC'::crypto_amount,
    'CREDIT', '2026-08-29 11:00:00+00', 'SETTLED',
    '2026-08-30 11:00:00+00', NULL, NULL, NULL,
    '{"network":"bitcoin","txid":"btc-hash-001","output_index":1}'
) AS btc_external \gset
SELECT count(*) FROM reconcile_transactions(:'btc_reconcile', '2026-08-29 11:01:00+00');
SELECT run_id AS btc_run FROM reconcile_run_summary
WHERE reconcile_account_id = :'btc_reconcile'
ORDER BY completed_at DESC, run_id DESC LIMIT 1 \gset
SELECT set_config('full.btc_run', :'btc_run', false);
SELECT set_config('full.btc_external', :'btc_external', false);

DO $body$
BEGIN
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE run_id = current_setting('full.btc_run')::uuid
          AND external_transaction_id = current_setting('full.btc_external')::uuid
          AND status = 'EXACT' AND reason->>'strategy' = 'explicit_reference'
    );
END
$body$;

-- A hash shared by multiple blockchain outputs is disambiguated by its
-- output index; the raw txid alone must not make both candidates eligible.
SELECT ledger_transfer(
    :'btc_source', :'btc_mapped', '0.1 BTC', NULL, 'full:btc:multi-output:0',
    '2026-08-29 11:10:00+00', '{"txid":"btc-hash-multi","output_index":0}'
) AS btc_output_zero \gset
SELECT ledger_transfer(
    :'btc_source', :'btc_mapped', '0.1 BTC', NULL, 'full:btc:multi-output:1',
    '2026-08-29 11:10:00+00', '{"txid":"btc-hash-multi","output_index":1}'
) AS btc_output_one \gset
SELECT reconcile_external_transaction_insert(
    :'btc_reconcile', 'bitcoin-observation-multi-1', '0.1 BTC'::crypto_amount,
    'CREDIT', '2026-08-29 11:10:00+00', 'SETTLED',
    '2026-08-30 11:10:00+00', NULL, NULL, NULL,
    '{"network":"bitcoin","txid":"btc-hash-multi","output_index":1}'
) AS btc_multi_external \gset
SELECT count(*) FROM reconcile_transactions(:'btc_reconcile', '2026-08-29 11:11:00+00');
SELECT run_id AS btc_multi_run FROM reconcile_run_summary
WHERE reconcile_account_id = :'btc_reconcile'
ORDER BY completed_at DESC, run_id DESC LIMIT 1 \gset
SELECT set_config('full.btc_multi_run', :'btc_multi_run', false);
SELECT set_config('full.btc_multi_external', :'btc_multi_external', false);
SELECT set_config('full.btc_output_one', :'btc_output_one', false);

DO $body$
BEGIN
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE run_id = current_setting('full.btc_multi_run')::uuid
          AND external_transaction_id = current_setting('full.btc_multi_external')::uuid
          AND ledger_transaction_id = current_setting('full.btc_output_one')::uuid
          AND status = 'EXACT' AND reason->>'strategy' = 'explicit_reference'
    );
    ASSERT NOT EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE run_id = current_setting('full.btc_multi_run')::uuid
          AND external_transaction_id = current_setting('full.btc_multi_external')::uuid
          AND status = 'AMBIGUOUS'
    );
END
$body$;

-- Equal-ticker assets on distinct networks stay isolated. The Ethereum
-- account also demonstrates an exact one-micro-unit balance mismatch.
SELECT ledger_create_account('full:usdt:eth:source', 'USDT@ethereum', 'ANY') AS eth_source \gset
SELECT ledger_create_account('full:usdt:eth:mapped', 'USDT@ethereum', 'ANY') AS eth_mapped \gset
SELECT ledger_create_account('full:usdt:tron:source', 'USDT@tron', 'ANY') AS tron_source \gset
SELECT ledger_create_account('full:usdt:tron:mapped', 'USDT@tron', 'ANY') AS tron_mapped \gset
SELECT reconcile_create_account(
    'full-usdt-ethereum', :'eth_mapped', 'USDT@ethereum', 'ethereum-indexer',
    '0xwallet', 'BLOCKCHAIN_WALLET', 'TOTAL'
) AS eth_reconcile \gset
SELECT ledger_transfer(
    :'eth_source', :'eth_mapped', '1000 USDT@ethereum', 'eth:funding',
    'full:eth:funding', '2026-08-29 12:00:00+00'
);
SELECT ledger_transfer(
    :'tron_source', :'tron_mapped', '2 USDT@tron', 'shared-token-reference',
    'full:tron:deposit', '2026-08-29 12:01:00+00'
);
SELECT reconcile_balance_insert(
    :'eth_reconcile', '999.999999 USDT@ethereum', '2026-08-29 12:05:00+00',
    'ethereum:block:100', NULL, '2026-08-30 12:05:00+00'
);
SELECT reconcile_external_transaction_insert(
    :'eth_reconcile', 'eth-external-isolation', '2 USDT@ethereum', 'CREDIT',
    '2026-08-29 12:01:00+00', 'SETTLED', '2026-08-30 12:01:00+00',
    NULL, NULL, 'shared-token-reference'
) AS eth_external \gset
SELECT (reconcile_balance(:'eth_reconcile', '2026-08-29 12:05:00+00')).id AS eth_balance_result \gset
SELECT count(*) FROM reconcile_transactions(:'eth_reconcile', '2026-08-29 12:05:00+00');
SELECT run_id AS eth_tx_run FROM reconcile_run_summary
WHERE reconcile_account_id = :'eth_reconcile' AND balance_status IS NULL
ORDER BY completed_at DESC, run_id DESC LIMIT 1 \gset
SELECT set_config('full.eth_balance_result', :'eth_balance_result', false);
SELECT set_config('full.eth_tx_run', :'eth_tx_run', false);
SELECT set_config('full.eth_external', :'eth_external', false);

DO $body$
BEGIN
    ASSERT (SELECT status FROM reconcile_balance_results
            WHERE id = current_setting('full.eth_balance_result')::uuid) = 'MISMATCH';
    ASSERT (SELECT difference_units FROM reconcile_balance_results
            WHERE id = current_setting('full.eth_balance_result')::uuid) = -1;
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE run_id = current_setting('full.eth_tx_run')::uuid
          AND external_transaction_id = current_setting('full.eth_external')::uuid
          AND status = 'UNMATCHED_EXTERNAL'
    );
END
$body$;

-- A historical run before late external evidence sees a ledger-only item;
-- the next run at the same as_of includes the newly received immutable row.
SELECT ledger_create_account('full:late:source', 'USD', 'ANY') AS late_source \gset
SELECT ledger_create_account('full:late:mapped', 'USD', 'ANY') AS late_mapped \gset
SELECT reconcile_create_account(
    'full-late', :'late_mapped', 'USD', 'late-provider', 'late-1',
    'BANK', 'BOOK'
) AS late_reconcile \gset
SELECT ledger_transfer(
    :'late_source', :'late_mapped', 'USD 9.00', 'late:transaction:1',
    'full:late:ledger', '2026-08-28 09:00:00+00'
);
SELECT count(*) FROM reconcile_transactions(:'late_reconcile', '2026-08-28 09:01:00+00');
SELECT run_id AS late_first_run FROM reconcile_run_summary
WHERE reconcile_account_id = :'late_reconcile'
ORDER BY completed_at DESC, run_id DESC LIMIT 1 \gset
SELECT reconcile_external_transaction_insert(
    :'late_reconcile', 'late-external-1', 'USD 9.00', 'CREDIT',
    '2026-08-28 09:00:00+00', 'SETTLED', '2026-08-30 09:00:00+00',
    NULL, NULL, 'late:transaction:1'
) AS late_external \gset
SELECT count(*) FROM reconcile_transactions(:'late_reconcile', '2026-08-28 09:01:00+00');
SELECT run_id AS late_second_run FROM reconcile_run_summary
WHERE reconcile_account_id = :'late_reconcile'
ORDER BY completed_at DESC, run_id DESC LIMIT 1 \gset
SELECT set_config('full.late_first_run', :'late_first_run', false);
SELECT set_config('full.late_second_run', :'late_second_run', false);
SELECT set_config('full.late_external', :'late_external', false);
SELECT set_config('full.late_reconcile', :'late_reconcile', false);

DO $body$
BEGIN
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE run_id = current_setting('full.late_first_run')::uuid
          AND status = 'UNMATCHED_LEDGER'
    );
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE run_id = current_setting('full.late_second_run')::uuid
          AND external_transaction_id = current_setting('full.late_external')::uuid
          AND status = 'EXACT'
    );
    ASSERT NOT EXISTS (
        SELECT 1 FROM reconcile_unmatched_ledger m
        JOIN reconcile_runs r ON r.id = m.run_id
        WHERE r.reconcile_account_id = current_setting('full.late_reconcile')::uuid
    );
END
$body$;

SELECT (reconcile_balance(:'late_reconcile', '2026-08-28 09:01:00+00')).status
       AS missing_balance_status \gset

DO $body$
BEGIN
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_balance_results b
        JOIN reconcile_runs r ON r.id = b.run_id
        WHERE r.reconcile_account_id = current_setting('full.late_reconcile')::uuid
          AND b.status = 'MISSING_EXTERNAL_OBSERVATION'
    );
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_issues
        WHERE account = 'full-late' AND issue_type = 'STALE_EXTERNAL_BALANCE'
    );
    ASSERT NOT EXISTS (SELECT 1 FROM reconcile_validate() WHERE status <> 'OK');
END
$body$;
