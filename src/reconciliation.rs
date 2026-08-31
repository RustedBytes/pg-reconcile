use pgrx::prelude::*;

use crate::errors::{fail_internal, fail_parameter};

fn spi_failure(context: &str, error: &pgrx::spi::Error) -> ! {
    fail_internal(&format!("{context}: {error}"))
}

#[pg_extern(volatile, parallel_unsafe)]
pub fn _reconcile_execute_run_rust(
    account_id: pgrx::Uuid,
    run_type: &str,
    as_of: TimestampWithTimeZone,
) -> pgrx::Uuid {
    let (include_balance, include_transactions) = match run_type {
        "BALANCE" => (true, false),
        "TRANSACTIONS" => (false, true),
        "FULL" => (true, true),
        _ => fail_parameter(
            "RECONCILE_INVALID_RUN",
            "unknown reconciliation run type",
            "Use BALANCE, TRANSACTIONS, or FULL.",
        ),
    };

    Spi::connect_mut(|client| {
        let rows = client
            .update(
                "SELECT _reconcile_start_run($1, $2::reconcile_run_type, $3)",
                Some(1),
                &[account_id.into(), run_type.into(), as_of.into()],
            )
            .unwrap_or_else(|error| spi_failure("could not start reconciliation run", &error));
        let run_id = rows
            .first()
            .get_one::<pgrx::Uuid>()
            .unwrap_or_else(|error| spi_failure("could not read reconciliation run id", &error))
            .unwrap_or_else(|| fail_internal("reconciliation run id is NULL"));

        if include_balance {
            client
                .update(
                    "SELECT _reconcile_balance_into_run($1)",
                    Some(1),
                    &[run_id.into()],
                )
                .unwrap_or_else(|error| {
                    spi_failure("could not reconcile balance into run", &error)
                });
        }
        if include_transactions {
            client
                .update(
                    "SELECT _reconcile_transactions_into_run($1)",
                    Some(1),
                    &[run_id.into()],
                )
                .unwrap_or_else(|error| {
                    spi_failure("could not reconcile transactions into run", &error)
                });
        }
        client
            .update(
                "SELECT _reconcile_finish_run($1)",
                Some(1),
                &[run_id.into()],
            )
            .unwrap_or_else(|error| spi_failure("could not finish reconciliation run", &error));
        run_id
    })
}
