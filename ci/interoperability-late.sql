\set ON_ERROR_STOP on

CREATE EXTENSION pg_reconcile;
CREATE EXTENSION pg_money;
CREATE EXTENSION pg_cryptocurrency;
CREATE EXTENSION pg_ledger;

DO $body$
BEGIN
    ASSERT reconcile_enable_pg_ledger();
    ASSERT reconcile_enable_pg_money();
    ASSERT reconcile_enable_pg_cryptocurrency();
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
    ASSERT reconcile_asset('USD 1.25'::money_minor) = 'USD';
    ASSERT reconcile_asset('BTC'::crypto_asset) = 'BTC@bitcoin';
    ASSERT reconcile_asset('USDT@ethereum'::crypto_asset) = 'USDT@ethereum';
END
$body$;
