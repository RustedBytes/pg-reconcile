\set ON_ERROR_STOP on
\timing on

CREATE EXTENSION pg_ledger;
CREATE EXTENSION pg_reconcile;
SELECT set_config('bench.row_count', :'row_count', false);
SELECT least(:row_count::bigint, 1000000::bigint) AS ledger_count \gset
SELECT set_config('bench.ledger_count', :'ledger_count', false);
SELECT set_config('bench.match_strategy', :'match_strategy', false);

SELECT ledger_create_account('bench:source', 'USD', 'ANY') AS source_id \gset
SELECT ledger_create_account('bench:mapped', 'USD', 'ANY') AS mapped_id \gset
SELECT reconcile_create_account(
    'bench-account', :'mapped_id', 'USD', 'benchmark', 'bench-external',
    'BANK', 'BOOK', 0, NULL,
    CASE WHEN :'match_strategy' = 'amount_time' THEN interval '1 microsecond'
         ELSE interval '0 seconds' END
) AS reconcile_id \gset

SELECT count(ledger_transfer(
    :'source_id', :'mapped_id', reconcile_format_amount(item, 'USD')::ledger_amount,
    CASE WHEN :'match_strategy' = 'exact_reference' THEN format('bench:%s', item) END,
    format('bench:ledger:%s', item),
    '2026-01-01 00:00:00+00'::timestamptz + item * interval '1 microsecond'
)) AS ledger_transactions_inserted
FROM generate_series(1, :ledger_count) item;

SELECT count(reconcile_external_transaction_insert(
    :'reconcile_id', format('bench:external:%s', item),
    reconcile_format_amount(item, 'USD'), 'CREDIT',
    '2026-01-01 00:00:00+00'::timestamptz + item * interval '1 microsecond',
    'SETTLED', '2026-01-01 00:01:00+00', NULL, NULL,
    CASE WHEN :'match_strategy' = 'exact_reference' THEN format('bench:%s', item) END,
    NULL, format('bench:external:key:%s', item)
)) AS external_transactions_inserted
FROM generate_series(1, :row_count) item;

SELECT reconcile_balance_insert(
    :'reconcile_id', reconcile_format_amount(
        ((:ledger_count::bigint * (:ledger_count::bigint + 1)) / 2)::numeric, 'USD'
    ),
    '2026-01-02 00:00:00+00', 'bench:balance', NULL,
    '2026-01-02 00:00:01+00', NULL, 'bench:balance:key'
);

VACUUM ANALYZE ledger_transactions;
VACUUM ANALYZE ledger_entries;
VACUUM ANALYZE reconcile_external_transactions;

SELECT count(*) AS matching_results
FROM reconcile_transactions(:'reconcile_id', '2026-01-02 00:00:00+00');

SELECT pg_size_pretty(pg_total_relation_size('reconcile_external_transactions')) AS external_storage,
       round(pg_total_relation_size('reconcile_external_transactions')::numeric /
             nullif((SELECT count(*) FROM reconcile_external_transactions), 0), 2)
           AS external_bytes_per_row,
       pg_size_pretty(pg_total_relation_size('reconcile_matches')) AS match_storage,
       round(pg_total_relation_size('reconcile_matches')::numeric /
             nullif((SELECT count(*) FROM reconcile_matches), 0), 2)
           AS match_bytes_per_row;

DO $body$
BEGIN
    IF (SELECT count(*) FROM reconcile_external_transactions) <>
       current_setting('bench.row_count')::bigint THEN
        RAISE EXCEPTION 'external benchmark row count mismatch';
    END IF;
    IF (SELECT count(*) FROM reconcile_matches WHERE status = 'EXACT') <>
       current_setting('bench.ledger_count')::bigint THEN
        RAISE EXCEPTION 'exact reference benchmark match count mismatch';
    END IF;
    IF (SELECT count(*) FROM reconcile_matches WHERE status = 'UNMATCHED_EXTERNAL') <>
       current_setting('bench.row_count')::bigint -
       current_setting('bench.ledger_count')::bigint THEN
        RAISE EXCEPTION 'unmatched external benchmark count mismatch';
    END IF;
    IF current_setting('bench.match_strategy') = 'exact_reference' AND EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE status = 'EXACT' AND reason->>'strategy' <> 'explicit_reference'
    ) THEN
        RAISE EXCEPTION 'reference benchmark used the wrong strategy';
    END IF;
    IF current_setting('bench.match_strategy') = 'amount_time' AND EXISTS (
        SELECT 1 FROM reconcile_matches
        WHERE status = 'EXACT' AND reason->>'strategy' <> 'exact_amount_time'
    ) THEN
        RAISE EXCEPTION 'amount/time benchmark used the wrong strategy';
    END IF;
    IF EXISTS (SELECT 1 FROM reconcile_validate() WHERE status <> 'OK') THEN
        RAISE EXCEPTION 'benchmark invariant validation failed';
    END IF;
END
$body$;

CREATE FUNCTION reconcile_benchmark_balance(client_number integer)
RETURNS uuid
LANGUAGE sql
AS $body$
    SELECT (reconcile_balance(
        (SELECT id FROM reconcile_accounts WHERE name = 'bench-account'),
        '2026-01-02 00:00:00+00'
    )).run_id
$body$;
