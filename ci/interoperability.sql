\set ON_ERROR_STOP on

CREATE EXTENSION pg_money;
CREATE EXTENSION pg_cryptocurrency;
CREATE EXTENSION pg_ledger;
CREATE EXTENSION pg_reconcile;

DO $body$
BEGIN
    ASSERT to_regprocedure(
        'reconcile_balance_insert(uuid,money_with_currency,timestamptz,text,text,timestamptz,jsonb,text)'
    ) IS NOT NULL;
    ASSERT to_regprocedure(
        'reconcile_balance_insert(uuid,money_minor,timestamptz,text,text,timestamptz,jsonb,text)'
    ) IS NOT NULL;
    ASSERT to_regprocedure(
        'reconcile_balance_insert(uuid,crypto_amount,timestamptz,text,text,timestamptz,jsonb,text)'
    ) IS NOT NULL;
    ASSERT to_regprocedure(
        'reconcile_external_transaction_insert(uuid,text,money_with_currency,reconcile_direction,timestamptz,reconcile_external_status,timestamptz,text,text,text,jsonb,text,uuid,uuid)'
    ) IS NOT NULL;
    ASSERT to_regprocedure(
        'reconcile_external_transaction_insert(uuid,text,money_minor,reconcile_direction,timestamptz,reconcile_external_status,timestamptz,text,text,text,jsonb,text,uuid,uuid)'
    ) IS NOT NULL;
    ASSERT to_regprocedure(
        'reconcile_external_transaction_insert(uuid,text,crypto_amount,reconcile_direction,timestamptz,reconcile_external_status,timestamptz,text,text,text,jsonb,text,uuid,uuid)'
    ) IS NOT NULL;
    ASSERT EXISTS (SELECT 1 FROM reconcile_integration_state WHERE extension_name = 'pg_money');
    ASSERT EXISTS (SELECT 1 FROM reconcile_integration_state WHERE extension_name = 'pg_cryptocurrency');
    ASSERT reconcile_asset('USD 1.25'::money_minor) = 'USD';
    ASSERT reconcile_asset('BTC'::crypto_asset) = 'BTC@bitcoin';
    ASSERT reconcile_asset('USDT@ethereum'::crypto_asset) = 'USDT@ethereum';
END
$body$;

SELECT ledger_create_account('interop:usd:source', 'USD', 'ANY') AS usd_source \gset
SELECT ledger_create_account('interop:usd:mapped', 'USD', 'ANY') AS usd_mapped \gset
SELECT reconcile_create_account(
    'interop-usd', :'usd_mapped', 'USD', 'fixture-money', 'usd-account', 'BANK', 'BOOK'
) AS usd_reconcile \gset
SELECT ledger_transfer(:'usd_source', :'usd_mapped', 'USD 1.25', NULL, NULL,
                       '2026-08-31 12:00:00+00');
SELECT reconcile_balance_insert(
    :'usd_reconcile', 'USD 1.25'::money_with_currency,
    '2026-08-31 12:00:00+00', 'money:balance'
);
SELECT reconcile_external_transaction_insert(
    :'usd_reconcile', 'money:transaction', 'USD 1.25'::money_with_currency,
    'CREDIT', '2026-08-31 12:00:00+00', 'SETTLED', '2026-08-31 12:00:01+00'
);
SELECT reconcile_balance_insert(
    :'usd_reconcile', 'USD 1.25'::money_minor,
    '2026-08-31 12:00:00+00', 'money:minor:balance'
);

SELECT ledger_create_account('interop:btc:source', 'BTC', 'ANY') AS btc_source \gset
SELECT ledger_create_account('interop:btc:mapped', 'BTC', 'ANY') AS btc_mapped \gset
SELECT reconcile_create_account(
    'interop-btc', :'btc_mapped', 'BTC@bitcoin', 'fixture-crypto', 'btc-wallet',
    'BLOCKCHAIN_WALLET', 'TOTAL'
) AS btc_reconcile \gset
SELECT ledger_transfer(:'btc_source', :'btc_mapped', '1 BTC', NULL, NULL,
                       '2026-08-31 12:00:00+00');
SELECT reconcile_balance_insert(
    :'btc_reconcile', '1 BTC'::crypto_amount,
    '2026-08-31 12:00:00+00', 'bitcoin:block:1'
);
SELECT reconcile_external_transaction_insert(
    :'btc_reconcile', 'crypto:transaction', '1 BTC'::crypto_amount,
    'CREDIT', '2026-08-31 12:00:00+00', 'SETTLED', '2026-08-31 12:00:01+00'
);

-- Token crypto_amount text is versioned by pg_cryptocurrency. The adapter must
-- use typed accessors so the canonical network identity remains stable.
SELECT ledger_create_account('interop:usdt:source', 'USDT@ethereum', 'ANY') AS usdt_source \gset
SELECT ledger_create_account('interop:usdt:mapped', 'USDT@ethereum', 'ANY') AS usdt_mapped \gset
SELECT reconcile_create_account(
    'interop-usdt', :'usdt_mapped', 'USDT@ethereum', 'fixture-crypto', 'usdt-wallet',
    'BLOCKCHAIN_WALLET', 'TOTAL'
) AS usdt_reconcile \gset
SELECT ledger_transfer(:'usdt_source', :'usdt_mapped', '1 USDT@ethereum', NULL, NULL,
                       '2026-08-31 12:00:00+00');
SELECT reconcile_balance_insert(
    :'usdt_reconcile', '1 USDT@ethereum'::crypto_amount,
    '2026-08-31 12:00:00+00', 'ethereum:block:1'
);

DO $body$
DECLARE
    usd_result reconcile_balance_results;
    btc_result reconcile_balance_results;
    usdt_result reconcile_balance_results;
BEGIN
    SELECT b.* INTO usd_result FROM reconcile_accounts a
    CROSS JOIN LATERAL reconcile_balance(a.id, '2026-08-31 12:01:00+00') b
    WHERE a.name = 'interop-usd';
    SELECT b.* INTO btc_result FROM reconcile_accounts a
    CROSS JOIN LATERAL reconcile_balance(a.id, '2026-08-31 12:01:00+00') b
    WHERE a.name = 'interop-btc';
    SELECT b.* INTO usdt_result FROM reconcile_accounts a
    CROSS JOIN LATERAL reconcile_balance(a.id, '2026-08-31 12:01:00+00') b
    WHERE a.name = 'interop-usdt';
    ASSERT usd_result.status = 'MATCHED';
    ASSERT btc_result.status = 'MATCHED';
    ASSERT usdt_result.status = 'MATCHED';
    ASSERT NOT EXISTS (SELECT 1 FROM reconcile_validate() WHERE status <> 'OK');
END
$body$;
