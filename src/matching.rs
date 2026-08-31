use pgrx::prelude::*;

#[pg_extern(immutable, strict, parallel_safe)]
pub fn reconcile_timestamp_score(delta_milliseconds: i64) -> i32 {
    match delta_milliseconds.unsigned_abs() {
        0..=2_000 => 30,
        2_001..=30_000 => 20,
        30_001..=300_000 => 10,
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamp_boundaries_are_deterministic() {
        assert_eq!(reconcile_timestamp_score(-2_000), 30);
        assert_eq!(reconcile_timestamp_score(30_000), 20);
        assert_eq!(reconcile_timestamp_score(300_001), 0);
    }
}
