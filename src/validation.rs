use pgrx::prelude::*;

use crate::errors::fail_internal;

const CHECKS: [(&str, &str); 11] = [
    (
        "account_mapping",
        "SELECT count(*)::bigint FROM reconcile_accounts a WHERE a.enabled AND NOT EXISTS (SELECT 1 FROM _reconcile_ledger_account_info(a.ledger_account_id))",
    ),
    (
        "asset_consistency",
        "SELECT count(*)::bigint FROM reconcile_accounts a CROSS JOIN LATERAL _reconcile_ledger_account_info(a.ledger_account_id) l WHERE l.asset_identity IS DISTINCT FROM a.asset_identity",
    ),
    (
        "external_identity_uniqueness",
        "SELECT count(*)::bigint FROM (SELECT reconcile_account_id, external_transaction_id FROM reconcile_external_transactions WHERE supersedes_id IS NULL GROUP BY 1, 2 HAVING count(*) > 1) duplicates",
    ),
    (
        "external_integrity",
        "SELECT count(*)::bigint FROM reconcile_external_transactions e WHERE e.amount_units <= 0 OR e.asset_identity <> (SELECT asset_identity FROM reconcile_accounts WHERE id = e.reconcile_account_id) OR (e.supersedes_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM reconcile_external_transactions p WHERE p.id = e.supersedes_id AND p.reconcile_account_id = e.reconcile_account_id AND p.external_transaction_id = e.external_transaction_id AND p.asset_identity = e.asset_identity AND p.event_at <= e.event_at AND p.received_at <= e.received_at)) OR (e.reverses_external_transaction_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM reconcile_external_transactions p WHERE p.id = e.reverses_external_transaction_id AND p.reconcile_account_id = e.reconcile_account_id AND p.asset_identity = e.asset_identity AND p.amount_units = e.amount_units AND p.direction <> e.direction AND p.event_at <= e.event_at AND e.status = 'REVERSED'))",
    ),
    (
        "match_consistency",
        "WITH candidates AS MATERIALIZED (SELECT a.id AS reconcile_account_id, c.* FROM reconcile_accounts a CROSS JOIN LATERAL _reconcile_ledger_candidates(a.ledger_account_id, 'infinity'::timestamptz, 'infinity'::timestamptz) c) SELECT count(*)::bigint FROM reconcile_matches m JOIN reconcile_runs r ON r.id = m.run_id JOIN reconcile_accounts a ON a.id = r.reconcile_account_id LEFT JOIN reconcile_external_transactions e ON e.id = m.external_transaction_id LEFT JOIN candidates c ON c.reconcile_account_id = a.id AND c.ledger_entry_id = m.ledger_entry_id WHERE (e.id IS NOT NULL AND e.reconcile_account_id <> a.id) OR (m.status IN ('EXACT', 'PROBABLE', 'AMBIGUOUS') AND (e.id IS NULL OR c.ledger_entry_id IS NULL OR c.asset_identity <> e.asset_identity OR c.amount_units <> CASE e.direction WHEN 'CREDIT' THEN e.amount_units ELSE -e.amount_units END)) OR (m.status = 'UNMATCHED_LEDGER' AND c.ledger_entry_id IS NULL)",
    ),
    (
        "manual_consistency",
        "WITH candidates AS MATERIALIZED (SELECT a.id AS reconcile_account_id, c.* FROM reconcile_accounts a CROSS JOIN LATERAL _reconcile_ledger_candidates(a.ledger_account_id, 'infinity'::timestamptz, 'infinity'::timestamptz) c) SELECT count(*)::bigint FROM reconcile_manual_decisions d LEFT JOIN reconcile_external_transactions e ON e.id = d.external_transaction_id LEFT JOIN candidates c ON c.reconcile_account_id = e.reconcile_account_id AND c.ledger_transaction_id = d.ledger_transaction_id AND c.ledger_entry_id = d.ledger_entry_id WHERE e.id IS NULL OR (d.decision = 'MATCH' AND (c.ledger_entry_id IS NULL OR c.asset_identity <> e.asset_identity OR c.amount_units <> CASE e.direction WHEN 'CREDIT' THEN e.amount_units ELSE -e.amount_units END))",
    ),
    (
        "manual_mapping_uniqueness",
        "WITH active AS (SELECT DISTINCT ON (external_transaction_id) external_transaction_id, ledger_entry_id, decision FROM reconcile_manual_decisions ORDER BY external_transaction_id, created_at DESC, id DESC) SELECT count(*)::bigint FROM (SELECT ledger_entry_id FROM active WHERE decision = 'MATCH' GROUP BY ledger_entry_id HAVING count(*) > 1) duplicates",
    ),
    (
        "exact_mapping_uniqueness",
        "SELECT count(*)::bigint FROM (SELECT run_id, external_transaction_id FROM reconcile_matches WHERE status IN ('EXACT', 'PROBABLE') GROUP BY 1, 2 HAVING external_transaction_id IS NOT NULL AND count(*) > 1 UNION ALL SELECT run_id, ledger_entry_id FROM reconcile_matches WHERE status IN ('EXACT', 'PROBABLE') GROUP BY 1, 2 HAVING ledger_entry_id IS NOT NULL AND count(*) > 1) duplicates",
    ),
    (
        "external_reference_conflicts",
        "SELECT count(*)::bigint FROM (SELECT reconcile_account_id, external_reference FROM reconcile_external_transactions WHERE external_reference IS NOT NULL AND supersedes_id IS NULL GROUP BY 1, 2 HAVING count(DISTINCT payload_hash) > 1) conflicts",
    ),
    (
        "run_completeness",
        "SELECT count(*)::bigint FROM reconcile_runs r WHERE r.status = 'COMPLETED' AND r.completed_at IS NULL OR (r.status = 'COMPLETED' AND r.reconciliation_type IN ('BALANCE', 'FULL') AND NOT EXISTS (SELECT 1 FROM reconcile_balance_results b WHERE b.run_id = r.id))",
    ),
    (
        "balance_math",
        "SELECT count(*)::bigint FROM reconcile_balance_results WHERE external_balance_units IS NOT NULL AND difference_units IS DISTINCT FROM external_balance_units - ledger_balance_units OR (status = 'MATCHED' AND difference_units <> 0) OR (status = 'WITHIN_TOLERANCE' AND (difference_units = 0 OR abs(difference_units) > tolerance_units)) OR (status = 'MISMATCH' AND abs(difference_units) <= tolerance_units)",
    ),
];

#[pg_extern(stable, parallel_restricted)]
pub fn _reconcile_validate_rust() -> TableIterator<
    'static,
    (
        name!(check_name, String),
        name!(status, String),
        name!(violations, i64),
    ),
> {
    let mut results = Spi::connect(|client| {
        CHECKS
            .into_iter()
            .map(|(name, query)| {
                let rows = client.select(query, Some(1), &[]).unwrap_or_else(|error| {
                    fail_internal(&format!(
                        "could not run {name} reconciliation validation: {error}"
                    ))
                });
                let violations = rows
                    .first()
                    .get_one::<i64>()
                    .unwrap_or_else(|error| {
                        fail_internal(&format!("could not read {name} validation: {error}"))
                    })
                    .unwrap_or_else(|| fail_internal(&format!("{name} validation returned NULL")));
                (
                    name.to_owned(),
                    if violations == 0 { "OK" } else { "FAIL" }.to_owned(),
                    violations,
                )
            })
            .collect::<Vec<_>>()
    });
    results.sort_by(|left, right| left.0.cmp(&right.0));
    TableIterator::new(results)
}
