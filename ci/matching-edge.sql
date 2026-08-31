\set ON_ERROR_STOP on

CREATE EXTENSION pg_ledger;
CREATE EXTENSION pg_reconcile;

SELECT ledger_create_account('edge:source', 'USD', 'ANY') AS source_id \gset
SELECT ledger_create_account('edge:mapped', 'USD', 'ANY') AS mapped_id \gset
SELECT reconcile_create_account(
    'edge-account', :'mapped_id', 'USD', 'edge-provider', 'edge-1',
    'BANK', 'BOOK', 0, NULL, interval '1 minute'
) AS reconcile_id \gset

-- A strong reference cannot silently fall through after its sole candidate
-- was consumed by an earlier external item.
SELECT ledger_transfer(
    :'source_id', :'mapped_id', 'USD 5.00', 'edge:shared-reference',
    'edge:shared-ledger', '2026-08-31 10:00:00+00'
);
SELECT reconcile_external_transaction_insert(
    :'reconcile_id', 'edge:external:reference:1', 'USD 5.00', 'CREDIT',
    '2026-08-31 10:00:00+00', 'SETTLED', '2026-08-31 10:00:01+00',
    NULL, NULL, 'edge:shared-reference'
);
SELECT reconcile_external_transaction_insert(
    :'reconcile_id', 'edge:external:reference:2', 'USD 5.00', 'CREDIT',
    '2026-08-31 10:00:00+00', 'SETTLED', '2026-08-31 10:00:02+00',
    NULL, NULL, 'edge:shared-reference'
);
SELECT count(*) FROM reconcile_transactions(:'reconcile_id', '2026-08-31 10:01:00+00');

DO $body$
DECLARE
    latest_run uuid;
BEGIN
    SELECT r.id INTO latest_run FROM reconcile_runs r
    JOIN reconcile_accounts a ON a.id = r.reconcile_account_id
    WHERE a.name = 'edge-account'
    ORDER BY r.completed_at DESC, r.id DESC LIMIT 1;
    ASSERT 1 = (
        SELECT count(*) FROM reconcile_matches
        WHERE run_id = latest_run AND status = 'EXACT'
    );
    ASSERT 1 = (
        SELECT count(*) FROM reconcile_matches
        WHERE run_id = latest_run AND status = 'CONFLICT'
          AND reason->>'conflict' = 'candidate_already_matched'
    );
    ASSERT NOT EXISTS (
        SELECT 1 FROM reconcile_validate()
        WHERE check_name = 'exact_mapping_uniqueness' AND status <> 'OK'
    );
    ASSERT EXISTS (
        SELECT 1 FROM reconcile_issues
        WHERE account = 'edge-account'
          AND issue_type = 'DUPLICATE_EXTERNAL'
          AND run_id = latest_run
    );
END
$body$;

-- Heuristic matching also consumes a candidate at most once.
SELECT ledger_transfer(
    :'source_id', :'mapped_id', 'USD 6.00', NULL,
    'edge:heuristic-ledger', '2026-08-31 11:00:00+00'
);
SELECT reconcile_external_transaction_insert(
    :'reconcile_id', 'edge:external:heuristic:1', 'USD 6.00', 'CREDIT',
    '2026-08-31 11:00:00+00', 'SETTLED', '2026-08-31 11:00:01+00'
);
SELECT reconcile_external_transaction_insert(
    :'reconcile_id', 'edge:external:heuristic:2', 'USD 6.00', 'CREDIT',
    '2026-08-31 11:00:00+00', 'SETTLED', '2026-08-31 11:00:02+00'
);
SELECT count(*) FROM reconcile_transactions(:'reconcile_id', '2026-08-31 11:01:00+00');

DO $body$
DECLARE
    latest_run uuid;
BEGIN
    SELECT r.id INTO latest_run FROM reconcile_runs r
    JOIN reconcile_accounts a ON a.id = r.reconcile_account_id
    WHERE a.name = 'edge-account'
    ORDER BY r.completed_at DESC, r.id DESC LIMIT 1;
    ASSERT 1 = (
        SELECT count(*) FROM reconcile_matches m
        JOIN reconcile_external_transactions e ON e.id = m.external_transaction_id
        WHERE m.run_id = latest_run AND e.amount_units = 600 AND m.status = 'EXACT'
    );
    ASSERT 1 = (
        SELECT count(*) FROM reconcile_matches m
        JOIN reconcile_external_transactions e ON e.id = m.external_transaction_id
        WHERE m.run_id = latest_run AND e.amount_units = 600
          AND m.status = 'UNMATCHED_EXTERNAL'
    );
END
$body$;
