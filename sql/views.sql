CREATE VIEW reconcile_accounts_view AS
SELECT id, name, ledger_account_id, asset_identity, external_system,
       external_account_id, account_kind, balance_mode, tolerance_units,
       matching_time_window, allow_probable_matches, minimum_probable_score,
       enabled, created_at, updated_at
FROM reconcile_accounts;

CREATE VIEW reconcile_latest_balances AS
SELECT DISTINCT ON (a.id)
       a.id AS reconcile_account_id, a.name AS account, a.asset_identity,
       o.id AS observation_id, o.balance_units, o.observed_at, o.received_at,
       o.external_reference
FROM reconcile_accounts a
LEFT JOIN reconcile_balance_observations o ON o.reconcile_account_id = a.id
ORDER BY a.id, o.observed_at DESC, o.received_at DESC, o.id DESC;

CREATE VIEW reconcile_latest_results AS
SELECT DISTINCT ON (r.reconcile_account_id)
       r.reconcile_account_id, r.id AS run_id, r.reconciliation_type,
       r.as_of, r.completed_at, b.status AS balance_status,
       b.ledger_balance_units, b.external_balance_units, b.difference_units,
       b.tolerance_units
FROM reconcile_runs r
LEFT JOIN reconcile_balance_results b ON b.run_id = r.id
WHERE r.status = 'COMPLETED'
ORDER BY r.reconcile_account_id, r.completed_at DESC, r.id DESC;

CREATE VIEW reconcile_unmatched_external AS
SELECT m.*, e.reconcile_account_id, e.external_transaction_id AS provider_transaction_id,
       e.amount_units, e.asset_identity, e.direction, e.event_at, e.external_reference
FROM reconcile_matches m
JOIN reconcile_external_transactions e ON e.id = m.external_transaction_id
WHERE m.status = 'UNMATCHED_EXTERNAL'
  AND m.run_id = (
      SELECT latest.id FROM reconcile_runs latest
      WHERE latest.reconcile_account_id = e.reconcile_account_id
        AND latest.reconciliation_type IN ('TRANSACTIONS', 'FULL')
        AND latest.status = 'COMPLETED'
      ORDER BY latest.completed_at DESC, latest.id DESC LIMIT 1
  );

CREATE VIEW reconcile_unmatched_ledger AS
SELECT m.*
FROM reconcile_matches m
JOIN reconcile_runs r ON r.id = m.run_id
WHERE m.status = 'UNMATCHED_LEDGER'
  AND m.run_id = (
      SELECT latest.id FROM reconcile_runs latest
      WHERE latest.reconcile_account_id = r.reconcile_account_id
        AND latest.reconciliation_type IN ('TRANSACTIONS', 'FULL')
        AND latest.status = 'COMPLETED'
      ORDER BY latest.completed_at DESC, latest.id DESC LIMIT 1
  );

CREATE VIEW reconcile_ambiguous AS
SELECT m.*, e.reconcile_account_id, e.external_transaction_id AS provider_transaction_id,
       e.amount_units, e.asset_identity, e.direction, e.event_at, e.external_reference
FROM reconcile_matches m
JOIN reconcile_external_transactions e ON e.id = m.external_transaction_id
WHERE m.status = 'AMBIGUOUS'
  AND m.run_id = (
      SELECT latest.id FROM reconcile_runs latest
      WHERE latest.reconcile_account_id = e.reconcile_account_id
        AND latest.reconciliation_type IN ('TRANSACTIONS', 'FULL')
        AND latest.status = 'COMPLETED'
      ORDER BY latest.completed_at DESC, latest.id DESC LIMIT 1
  );

CREATE VIEW reconcile_issues AS
SELECT a.name AS account,
       CASE b.status
         WHEN 'MISMATCH' THEN 'BALANCE_MISMATCH'
         WHEN 'MISSING_EXTERNAL_OBSERVATION' THEN 'STALE_EXTERNAL_BALANCE'
       END::text AS issue_type,
       a.asset_identity AS asset, abs(b.difference_units) AS amount,
       o.external_reference, clock_timestamp() - coalesce(o.observed_at, r.as_of) AS age,
       'ERROR'::text AS severity, r.id AS run_id
FROM reconcile_balance_results b
JOIN reconcile_runs r ON r.id = b.run_id
JOIN reconcile_accounts a ON a.id = r.reconcile_account_id
LEFT JOIN reconcile_balance_observations o ON o.id = b.external_observation_id
WHERE b.status IN ('MISMATCH', 'MISSING_EXTERNAL_OBSERVATION')
  AND r.id = (
      SELECT latest.id FROM reconcile_runs latest
      WHERE latest.reconcile_account_id = r.reconcile_account_id
        AND latest.reconciliation_type IN ('BALANCE', 'FULL')
        AND latest.status = 'COMPLETED'
      ORDER BY latest.completed_at DESC, latest.id DESC LIMIT 1
  )
UNION ALL
SELECT a.name,
       'DUPLICATE_EXTERNAL'::text,
       a.asset_identity,
       NULL::numeric,
       e.external_reference,
       clock_timestamp() - max(e.event_at),
       'ERROR'::text,
       latest.id
FROM reconcile_external_transactions e
JOIN reconcile_accounts a ON a.id = e.reconcile_account_id
JOIN LATERAL (
    SELECT r.id
    FROM reconcile_runs r
    WHERE r.reconcile_account_id = e.reconcile_account_id
      AND r.reconciliation_type IN ('TRANSACTIONS', 'FULL')
      AND r.status = 'COMPLETED'
    ORDER BY r.completed_at DESC, r.id DESC
    LIMIT 1
) latest ON true
WHERE e.external_reference IS NOT NULL
  AND e.supersedes_id IS NULL
GROUP BY a.id, a.name, a.asset_identity, e.external_reference, latest.id
HAVING count(DISTINCT e.payload_hash) > 1
UNION ALL
SELECT a.name,
       CASE m.status
         WHEN 'UNMATCHED_EXTERNAL' THEN 'EXTERNAL_UNMATCHED'
         WHEN 'UNMATCHED_LEDGER' THEN 'LEDGER_UNMATCHED'
         WHEN 'AMBIGUOUS' THEN 'AMBIGUOUS_MATCH'
         WHEN 'CONFLICT' THEN 'CONFLICTING_REFERENCE'
       END,
       a.asset_identity,
       e.amount_units,
       e.external_reference,
       clock_timestamp() - coalesce(e.event_at, m.created_at),
       CASE WHEN m.status = 'CONFLICT' THEN 'ERROR' ELSE 'WARNING' END,
       r.id
FROM reconcile_matches m
JOIN reconcile_runs r ON r.id = m.run_id
JOIN reconcile_accounts a ON a.id = r.reconcile_account_id
LEFT JOIN reconcile_external_transactions e ON e.id = m.external_transaction_id
WHERE m.status IN ('UNMATCHED_EXTERNAL', 'UNMATCHED_LEDGER', 'AMBIGUOUS', 'CONFLICT')
  AND r.id = (
      SELECT latest.id FROM reconcile_runs latest
      WHERE latest.reconcile_account_id = r.reconcile_account_id
        AND latest.reconciliation_type IN ('TRANSACTIONS', 'FULL')
        AND latest.status = 'COMPLETED'
      ORDER BY latest.completed_at DESC, latest.id DESC LIMIT 1
  );

CREATE VIEW reconcile_run_summary AS
SELECT r.id AS run_id, r.reconcile_account_id, a.name AS account,
       b.status AS balance_status,
       count(DISTINCT m.external_transaction_id) FILTER (WHERE m.external_transaction_id IS NOT NULL)
           AS external_transactions,
       count(*) FILTER (WHERE m.status = 'EXACT') AS matched_exact,
       count(*) FILTER (WHERE m.status = 'PROBABLE') AS matched_probable,
       count(*) FILTER (WHERE m.status = 'AMBIGUOUS') AS ambiguous,
       count(*) FILTER (WHERE m.status = 'UNMATCHED_EXTERNAL') AS unmatched_external,
       count(*) FILTER (WHERE m.status = 'UNMATCHED_LEDGER') AS unmatched_ledger,
       count(*) FILTER (WHERE m.status = 'CONFLICT') AS conflicts,
       r.started_at, r.completed_at
FROM reconcile_runs r
JOIN reconcile_accounts a ON a.id = r.reconcile_account_id
LEFT JOIN reconcile_balance_results b ON b.run_id = r.id
LEFT JOIN reconcile_matches m ON m.run_id = r.id
GROUP BY r.id, r.reconcile_account_id, a.name, b.status, r.started_at, r.completed_at;
