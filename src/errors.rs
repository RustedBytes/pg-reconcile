use pgrx::prelude::*;

#[allow(unreachable_code)]
pub(crate) fn fail_parameter(class: &str, reason: &str, hint: &str) -> ! {
    ereport!(
        ERROR,
        PgSqlErrorCode::ERRCODE_INVALID_PARAMETER_VALUE,
        reason.to_owned(),
        format!("{class}: {hint}")
    );
    unreachable!()
}

#[allow(unreachable_code)]
pub(crate) fn fail_internal(reason: &str) -> ! {
    ereport!(
        ERROR,
        PgSqlErrorCode::ERRCODE_INTERNAL_ERROR,
        reason.to_owned()
    );
    unreachable!()
}
