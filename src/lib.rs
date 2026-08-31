mod amount;
mod asset;
mod errors;
mod idempotency;
mod matching;
mod validation;

use pgrx::prelude::*;

pgrx::pg_module_magic!();

#[derive(Debug, Clone, Copy, PartialEq, Eq, PostgresEnum)]
#[allow(non_camel_case_types)]
pub enum reconcile_account_kind {
    BANK,
    BLOCKCHAIN_WALLET,
    CUSTODIAN,
    PAYMENT_PROVIDER,
    LIQUIDITY_PROVIDER,
    CASH,
    OTHER,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PostgresEnum)]
#[allow(non_camel_case_types)]
pub enum reconcile_balance_mode {
    BOOK,
    AVAILABLE,
    SETTLED,
    TOTAL,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PostgresEnum)]
#[allow(non_camel_case_types)]
pub enum reconcile_direction {
    CREDIT,
    DEBIT,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PostgresEnum)]
#[allow(non_camel_case_types)]
pub enum reconcile_external_status {
    PENDING,
    SETTLED,
    REVERSED,
    FAILED,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PostgresEnum)]
#[allow(non_camel_case_types)]
pub enum reconcile_run_type {
    BALANCE,
    TRANSACTIONS,
    FULL,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PostgresEnum)]
#[allow(non_camel_case_types)]
pub enum reconcile_run_status {
    RUNNING,
    COMPLETED,
    FAILED,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PostgresEnum)]
#[allow(non_camel_case_types)]
pub enum reconcile_balance_status {
    MATCHED,
    WITHIN_TOLERANCE,
    MISMATCH,
    MISSING_EXTERNAL_OBSERVATION,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PostgresEnum)]
#[allow(non_camel_case_types)]
pub enum reconcile_match_status {
    EXACT,
    PROBABLE,
    AMBIGUOUS,
    UNMATCHED_EXTERNAL,
    UNMATCHED_LEDGER,
    CONFLICT,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PostgresEnum)]
#[allow(non_camel_case_types)]
pub enum reconcile_manual_decision {
    MATCH,
    MARK_UNMATCHED_EXTERNAL,
}

#[pg_extern(volatile, parallel_unsafe)]
fn reconcile_uuidv7() -> pgrx::Uuid {
    pgrx::Uuid::from_bytes(*uuid::Uuid::now_v7().as_bytes())
}

extension_sql_file!(
    "../sql/schema.sql",
    name = "reconcile_schema",
    requires = [
        reconcile_account_kind,
        reconcile_balance_mode,
        reconcile_direction,
        reconcile_external_status,
        reconcile_run_type,
        reconcile_run_status,
        reconcile_balance_status,
        reconcile_match_status,
        reconcile_manual_decision,
        reconcile_uuidv7,
        asset::reconcile_asset,
        asset::reconcile_asset_scale,
        amount::reconcile_amount_asset,
        amount::reconcile_amount_units,
        amount::reconcile_format_amount,
        idempotency::reconcile_payload_hash,
        matching::reconcile_timestamp_score,
        validation::_reconcile_validate_rust
    ]
);

extension_sql_file!(
    "../sql/indexes.sql",
    name = "reconcile_indexes",
    requires = ["reconcile_schema"]
);

extension_sql_file!(
    "../sql/views.sql",
    name = "reconcile_views",
    requires = ["reconcile_indexes"]
);

extension_sql_file!(
    "../sql/adapters.sql",
    name = "reconcile_adapters",
    requires = ["reconcile_views"]
);

extension_sql_file!(
    "../sql/permissions.sql",
    name = "reconcile_permissions",
    requires = ["reconcile_adapters"],
    finalize
);

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    #[pg_test]
    fn canonical_asset_keeps_networks_distinct() {
        assert_eq!(
            Spi::get_one::<String>("SELECT reconcile_asset('usdt@tron')").unwrap(),
            Some("USDT@tron".to_owned())
        );
        assert_ne!(
            Spi::get_one::<String>("SELECT reconcile_asset('USDT@tron')").unwrap(),
            Spi::get_one::<String>("SELECT reconcile_asset('USDT@ethereum')").unwrap()
        );
    }
}

#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        Vec::new()
    }
}
