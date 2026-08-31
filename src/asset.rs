use pgrx::prelude::*;

use crate::errors::fail_parameter;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Asset {
    symbol: String,
    network: Option<String>,
    scale: u8,
    explicit_scale: bool,
}

impl Asset {
    pub(crate) fn parse(input: &str) -> Result<Self, String> {
        if input.len() > 128 {
            return Err("asset identity exceeds 128 bytes".to_owned());
        }
        let input = input.trim();
        if input.is_empty() || input.bytes().any(|byte| byte.is_ascii_whitespace()) {
            return Err("asset identity cannot be empty or contain whitespace".to_owned());
        }
        let (identity, explicit_scale) = match input.rsplit_once('/') {
            Some((identity, scale)) => {
                if scale.is_empty() || !scale.bytes().all(|byte| byte.is_ascii_digit()) {
                    return Err("asset scale must be an integer between 0 and 255".to_owned());
                }
                let parsed = scale
                    .parse::<u8>()
                    .map_err(|_| "asset scale must be between 0 and 255".to_owned())?;
                (identity, Some(parsed))
            }
            None => (input, None),
        };
        let (symbol, network) = match identity.split_once('@') {
            Some((symbol, network)) => (symbol, Some(network)),
            None => (identity, None),
        };
        validate_symbol(symbol)?;
        let symbol = symbol.to_ascii_uppercase();
        let network = match network {
            Some(network) => {
                validate_network(network)?;
                Some(network.to_ascii_lowercase())
            }
            None => native_crypto(&symbol).map(|(network, _)| network.to_owned()),
        };

        if let Some(network) = network {
            let known = crypto_scale(&symbol, &network);
            if let (Some(provided), Some(expected)) = (explicit_scale, known)
                && provided != expected
            {
                return Err(format!(
                    "{symbol}@{network} has canonical scale {expected}, not {provided}"
                ));
            }
            let scale = explicit_scale.or(known).ok_or_else(|| {
                format!(
                    "unknown crypto asset {symbol}@{network}; append '/<decimals>' to declare its scale"
                )
            })?;
            return Ok(Self {
                symbol,
                network: Some(network),
                scale,
                explicit_scale: known.is_none(),
            });
        }

        if symbol.len() != 3 || !symbol.bytes().all(|byte| byte.is_ascii_alphabetic()) {
            return Err(
                "fiat assets use a 3-letter code; crypto assets require a network".to_owned(),
            );
        }
        let canonical_scale = fiat_scale(&symbol);
        if explicit_scale.is_some_and(|provided| provided != canonical_scale) {
            return Err(format!(
                "{symbol} has canonical scale {canonical_scale}, not {}",
                explicit_scale.unwrap_or_default()
            ));
        }
        Ok(Self {
            scale: canonical_scale,
            explicit_scale: false,
            symbol,
            network: None,
        })
    }

    pub(crate) fn canonical(&self) -> String {
        match &self.network {
            Some(network) if self.explicit_scale => {
                format!("{}@{network}/{}", self.symbol, self.scale)
            }
            Some(network) => format!("{}@{network}", self.symbol),
            None if self.explicit_scale => format!("{}/{}", self.symbol, self.scale),
            None => self.symbol.clone(),
        }
    }

    pub(crate) const fn scale(&self) -> u8 {
        self.scale
    }
}

fn validate_symbol(symbol: &str) -> Result<(), String> {
    if symbol.is_empty()
        || symbol.len() > 24
        || !symbol
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
    {
        return Err("asset symbol must contain 1-24 ASCII letters, digits, '_' or '-'".to_owned());
    }
    Ok(())
}

fn validate_network(network: &str) -> Result<(), String> {
    if network.is_empty()
        || network.len() > 64
        || !network
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
    {
        return Err(
            "asset network must contain 1-64 ASCII letters, digits, '_', '-' or '.'".to_owned(),
        );
    }
    Ok(())
}

fn native_crypto(symbol: &str) -> Option<(&'static str, u8)> {
    match symbol {
        "BTC" => Some(("bitcoin", 8)),
        "ETH" => Some(("ethereum", 18)),
        "SOL" => Some(("solana", 9)),
        "TRX" => Some(("tron", 6)),
        _ => None,
    }
}

fn crypto_scale(symbol: &str, network: &str) -> Option<u8> {
    native_crypto(symbol)
        .filter(|(canonical_network, _)| *canonical_network == network)
        .map(|(_, scale)| scale)
        .or(match (symbol, network) {
            ("USDT" | "USDC", "ethereum" | "tron" | "solana") => Some(6),
            ("DAI", "ethereum") => Some(18),
            _ => None,
        })
}

fn fiat_scale(symbol: &str) -> u8 {
    match symbol {
        "BHD" | "IQD" | "JOD" | "KWD" | "LYD" | "OMR" | "TND" => 3,
        "BIF" | "CLP" | "DJF" | "GNF" | "ISK" | "JPY" | "KMF" | "KRW" | "PYG" | "RWF" | "UGX"
        | "UYI" | "VND" | "VUV" | "XAF" | "XOF" | "XPF" => 0,
        _ => 2,
    }
}

fn parse(input: &str) -> Asset {
    Asset::parse(input).unwrap_or_else(|reason| {
        fail_parameter(
            "RECONCILE_ASSET_MISMATCH",
            &format!("invalid reconcile asset: {reason}"),
            "Use USD, BTC@bitcoin, USDT@tron, or TOKEN@network/decimals.",
        )
    })
}

#[pg_extern(immutable, strict, parallel_safe)]
pub fn reconcile_asset(input: &str) -> String {
    parse(input).canonical()
}

#[pg_extern(immutable, strict, parallel_safe)]
pub fn reconcile_asset_scale(input: &str) -> i32 {
    i32::from(parse(input).scale())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonicalizes_assets_without_collapsing_networks() {
        assert_eq!(Asset::parse("usd").unwrap().canonical(), "USD");
        assert_eq!(Asset::parse("btc").unwrap().canonical(), "BTC@bitcoin");
        assert_eq!(Asset::parse("usdt@tron").unwrap().canonical(), "USDT@tron");
        assert_ne!(
            Asset::parse("usdt@tron").unwrap().canonical(),
            Asset::parse("usdt@ethereum").unwrap().canonical()
        );
    }
}
