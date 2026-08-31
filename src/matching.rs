use pgrx::{JsonB, prelude::*};

trait MatchStrategy<Input> {
    type Output;

    fn evaluate(&self, input: Input) -> Self::Output;
}

struct ReferenceMatch;

struct ReferenceEvidence<'a> {
    external_transaction_id: &'a str,
    external_reference: Option<&'a str>,
    metadata: Option<&'a serde_json::Value>,
}

impl MatchStrategy<ReferenceEvidence<'_>> for ReferenceMatch {
    type Output = Vec<String>;

    fn evaluate(&self, input: ReferenceEvidence<'_>) -> Self::Output {
        let ReferenceEvidence {
            external_transaction_id,
            external_reference,
            metadata,
        } = input;
        let mut keys = vec![external_transaction_id.to_owned()];
        if let Some(reference) = external_reference.filter(|value| !value.is_empty()) {
            keys.push(reference.to_owned());
        }
        if let Some(value) = metadata {
            let has_output_index = value
                .get("output_index")
                .and_then(serde_json::Value::as_i64)
                .is_some();
            let has_log_index = value
                .get("log_index")
                .and_then(serde_json::Value::as_i64)
                .is_some();
            for field in [
                "external_transaction_id",
                "external_reference",
                "provider_reference",
                "txid",
                "tx_hash",
            ] {
                if (field == "txid" && has_output_index) || (field == "tx_hash" && has_log_index) {
                    continue;
                }
                if let Some(reference) = value.get(field).and_then(serde_json::Value::as_str)
                    && !reference.is_empty()
                {
                    keys.push(reference.to_owned());
                }
            }
            for (reference_field, index_field) in
                [("txid", "output_index"), ("tx_hash", "log_index")]
            {
                if let (Some(reference), Some(index)) = (
                    value
                        .get(reference_field)
                        .and_then(serde_json::Value::as_str),
                    value.get(index_field).and_then(serde_json::Value::as_i64),
                ) {
                    keys.push(format!("{reference}:{index}"));
                }
            }
        }
        keys.sort_unstable();
        keys.dedup();
        keys
    }
}

struct ExactAmountTimeMatch;

impl MatchStrategy<i64> for ExactAmountTimeMatch {
    type Output = i32;

    fn evaluate(&self, delta_milliseconds: i64) -> Self::Output {
        match delta_milliseconds.unsigned_abs() {
            0..=2_000 => 30,
            2_001..=30_000 => 20,
            30_001..=300_000 => 10,
            _ => 0,
        }
    }
}

fn external_reference_keys(
    external_transaction_id: &str,
    external_reference: Option<&str>,
    metadata: Option<&serde_json::Value>,
) -> Vec<String> {
    ReferenceMatch.evaluate(ReferenceEvidence {
        external_transaction_id,
        external_reference,
        metadata,
    })
}

#[pg_extern(immutable, parallel_safe)]
#[allow(clippy::needless_pass_by_value)]
pub fn reconcile_external_reference_keys(
    external_transaction_id: &str,
    external_reference: Option<&str>,
    metadata: Option<JsonB>,
) -> Vec<String> {
    external_reference_keys(
        external_transaction_id,
        external_reference,
        metadata.as_ref().map(|JsonB(value)| value),
    )
}

fn timestamp_score(delta_milliseconds: i64) -> i32 {
    ExactAmountTimeMatch.evaluate(delta_milliseconds)
}

#[pg_extern(immutable, strict, parallel_safe)]
pub fn reconcile_timestamp_score(delta_milliseconds: i64) -> i32 {
    timestamp_score(delta_milliseconds)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamp_boundaries_are_deterministic() {
        assert_eq!(timestamp_score(-2_000), 30);
        assert_eq!(timestamp_score(30_000), 20);
        assert_eq!(timestamp_score(300_001), 0);
    }

    #[test]
    fn reference_keys_include_blockchain_evidence() {
        let metadata = serde_json::json!({
            "txid": "abc",
            "output_index": 2
        });
        let keys = external_reference_keys("provider-id", None, Some(&metadata));
        assert!(!keys.contains(&"abc".to_owned()));
        assert!(keys.contains(&"abc:2".to_owned()));
    }
}
