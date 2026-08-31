#![allow(clippy::needless_pass_by_value)]

use pgrx::{JsonB, prelude::*};
use sha2::{Digest, Sha256};

use crate::errors::fail_internal;

const HEX: &[u8; 16] = b"0123456789abcdef";

#[pg_extern(immutable, strict, parallel_safe)]
pub fn reconcile_payload_hash(payload: JsonB) -> String {
    let bytes = serde_json::to_vec(&payload.0)
        .unwrap_or_else(|error| fail_internal(&format!("could not serialize payload: {error}")));
    let digest = Sha256::digest(bytes);
    let mut output = String::with_capacity(digest.len() * 2);
    for byte in digest {
        output.push(char::from(HEX[usize::from(byte >> 4)]));
        output.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_is_stable_for_json_object_order() {
        let left = reconcile_payload_hash(JsonB(serde_json::json!({"a": 1, "b": 2})));
        let right = reconcile_payload_hash(JsonB(serde_json::json!({"b": 2, "a": 1})));
        assert_eq!(left, right);
    }
}
