use pgrx::prelude::*;

#[allow(unreachable_code)]
pub(crate) fn fail_parameter(class: &str, reason: &str, hint: &str) -> ! {
    ereport!(
        ERROR,
        PgSqlErrorCode::ERRCODE_INVALID_PARAMETER_VALUE,
        format!("{reason} Hint: {hint}"),
        class.to_owned()
    );
    unreachable!()
}

#[allow(unreachable_code)]
pub(crate) fn fail_internal(reason: &str) -> ! {
    ereport!(
        ERROR,
        PgSqlErrorCode::ERRCODE_INTERNAL_ERROR,
        reason.to_owned(),
        "RECONCILE_INTERNAL_ERROR"
    );
    unreachable!()
}
