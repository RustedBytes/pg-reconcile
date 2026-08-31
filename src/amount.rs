#![allow(clippy::needless_pass_by_value)]

use num_bigint::BigInt;
use num_traits::Signed;
use pgrx::{AnyNumeric, prelude::*};

use crate::asset::Asset;
use crate::errors::fail_parameter;

fn parse_amount(input: &str) -> Result<(Asset, BigInt), String> {
    if input.len() > 640 {
        return Err("amount input exceeds 640 bytes".to_owned());
    }
    let parts = input.split_ascii_whitespace().collect::<Vec<_>>();
    if parts.len() != 2 {
        return Err("expected '<amount> <asset>' or '<asset> <amount>'".to_owned());
    }
    let first_numeric = looks_numeric(parts[0]);
    let second_numeric = looks_numeric(parts[1]);
    let (number, asset_text) = match (first_numeric, second_numeric) {
        (true, false) => (parts[0], parts[1]),
        (false, true) => (parts[1], parts[0]),
        _ => return Err("expected exactly one decimal amount and one asset".to_owned()),
    };
    let asset = Asset::parse(asset_text)?;
    let units = decimal_to_units(number, asset.scale())?;
    Ok((asset, units))
}

fn parse_or_fail(input: &str) -> (Asset, BigInt) {
    parse_amount(input).unwrap_or_else(|reason| {
        fail_parameter(
            "RECONCILE_ASSET_MISMATCH",
            &format!("invalid reconcile amount: {reason}"),
            "Use 'USD 100.00', '1.25 BTC', or '0.5 USDT@tron'.",
        )
    })
}

fn looks_numeric(input: &str) -> bool {
    let unsigned = input.strip_prefix(['+', '-']).unwrap_or(input);
    !unsigned.is_empty()
        && unsigned
            .bytes()
            .all(|byte| byte.is_ascii_digit() || byte == b'.')
}

fn decimal_to_units(input: &str, scale: u8) -> Result<BigInt, String> {
    let (negative, unsigned) = if let Some(rest) = input.strip_prefix('-') {
        (true, rest)
    } else {
        (false, input.strip_prefix('+').unwrap_or(input))
    };
    let mut pieces = unsigned.split('.');
    let whole = pieces.next().unwrap_or_default();
    let fraction = pieces.next().unwrap_or_default();
    if pieces.next().is_some()
        || whole.is_empty()
        || !whole.bytes().all(|byte| byte.is_ascii_digit())
        || !fraction.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err("amount must be a plain signed decimal".to_owned());
    }
    if fraction.len() > usize::from(scale) {
        return Err(format!(
            "amount has more than {scale} fractional digits for this asset"
        ));
    }
    let mut digits = String::with_capacity(whole.len() + usize::from(scale));
    digits.push_str(whole);
    digits.push_str(fraction);
    digits.extend(std::iter::repeat_n(
        '0',
        usize::from(scale) - fraction.len(),
    ));
    let mut units = BigInt::parse_bytes(digits.as_bytes(), 10)
        .ok_or_else(|| "amount is outside the supported exact integer range".to_owned())?;
    if negative {
        units = -units;
    }
    Ok(units)
}

fn parse_units(input: &AnyNumeric) -> BigInt {
    let text = input.to_string();
    if text.contains('.') {
        fail_parameter(
            "RECONCILE_ASSET_MISMATCH",
            "smallest-unit values must be integers",
            "Pass an integral numeric value.",
        );
    }
    BigInt::parse_bytes(text.as_bytes(), 10).unwrap_or_else(|| {
        fail_parameter(
            "RECONCILE_ASSET_MISMATCH",
            "invalid smallest-unit integer",
            "Pass an integral numeric value.",
        )
    })
}

fn units_to_decimal(units: &BigInt, scale: u8) -> String {
    if scale == 0 {
        return units.to_string();
    }
    let negative = units.is_negative();
    let mut digits = units.abs().to_string();
    let scale = usize::from(scale);
    if digits.len() <= scale {
        digits.insert_str(0, &"0".repeat(scale + 1 - digits.len()));
    }
    let split = digits.len() - scale;
    digits.insert(split, '.');
    while digits.ends_with('0') {
        digits.pop();
    }
    if digits.ends_with('.') {
        digits.pop();
    }
    if negative {
        digits.insert(0, '-');
    }
    digits
}

#[pg_extern(immutable, strict, parallel_safe)]
pub fn reconcile_amount_asset(input: &str) -> String {
    parse_or_fail(input).0.canonical()
}

#[pg_extern(immutable, strict, parallel_safe)]
pub fn reconcile_amount_units(input: &str) -> AnyNumeric {
    let units = parse_or_fail(input).1.to_string();
    AnyNumeric::try_from(units.as_str()).unwrap_or_else(|error| {
        fail_parameter(
            "RECONCILE_ASSET_MISMATCH",
            &format!("could not produce PostgreSQL numeric: {error}"),
            "Pass a valid exact amount.",
        )
    })
}

#[pg_extern(immutable, strict, parallel_safe)]
pub fn reconcile_format_amount(units: AnyNumeric, asset: &str) -> String {
    let asset = Asset::parse(asset).unwrap_or_else(|reason| {
        fail_parameter(
            "RECONCILE_ASSET_MISMATCH",
            &format!("invalid reconcile asset: {reason}"),
            "Pass a canonical asset identity.",
        )
    });
    format!(
        "{} {}",
        units_to_decimal(&parse_units(&units), asset.scale()),
        asset.canonical()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_exact_units() {
        let (asset, units) = parse_amount("USD 12.34").unwrap();
        assert_eq!(asset.canonical(), "USD");
        assert_eq!(units.to_string(), "1234");
        assert_eq!(units_to_decimal(&units, asset.scale()), "12.34");
    }

    #[test]
    fn rejects_fraction_beyond_scale() {
        assert!(parse_amount("USD 1.001").is_err());
    }
}
