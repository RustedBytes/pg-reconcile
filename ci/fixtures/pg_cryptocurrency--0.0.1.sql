CREATE DOMAIN crypto_amount AS text;
CREATE DOMAIN crypto_asset AS text;

CREATE FUNCTION crypto_amount_value(value crypto_amount)
RETURNS numeric LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS 'SELECT split_part(value::text, '' '', 1)::numeric';

CREATE FUNCTION crypto_amount_symbol(value crypto_amount)
RETURNS text LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS 'SELECT split_part(split_part(value::text, '' '', 2), ''@'', 1)';

CREATE FUNCTION crypto_amount_network(value crypto_amount)
RETURNS text LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $body$
    SELECT CASE
        WHEN split_part(value::text, ' ', 2) LIKE '%@%'
            THEN split_part(split_part(value::text, ' ', 2), '@', 2)
        WHEN crypto_amount_symbol(value) = 'BTC' THEN 'bitcoin'
        WHEN crypto_amount_symbol(value) = 'ETH' THEN 'ethereum'
        ELSE 'unknown'
    END
$body$;

CREATE FUNCTION crypto_amount_decimals(value crypto_amount)
RETURNS integer LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $body$
    SELECT CASE crypto_amount_symbol(value)
        WHEN 'BTC' THEN 8 WHEN 'ETH' THEN 18 WHEN 'USDT' THEN 6 ELSE 8
    END
$body$;

CREATE FUNCTION crypto_asset_symbol(value crypto_asset)
RETURNS text LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS 'SELECT split_part(value::text, ''@'', 1)';

CREATE FUNCTION crypto_asset_network(value crypto_asset)
RETURNS text LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $body$
    SELECT CASE
        WHEN value::text LIKE '%@%' THEN split_part(value::text, '@', 2)
        WHEN crypto_asset_symbol(value) = 'BTC' THEN 'bitcoin'
        WHEN crypto_asset_symbol(value) = 'ETH' THEN 'ethereum'
        ELSE 'unknown'
    END
$body$;

CREATE FUNCTION crypto_asset_decimals(value crypto_asset)
RETURNS integer LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $body$
    SELECT CASE crypto_asset_symbol(value)
        WHEN 'BTC' THEN 8 WHEN 'ETH' THEN 18 WHEN 'USDT' THEN 6 ELSE 8
    END
$body$;
