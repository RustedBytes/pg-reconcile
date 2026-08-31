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
    ASSERT 9 = (
        SELECT count(*)
        FROM unnest(ARRAY[
            'reconcile_asset(money_with_currency)'::regprocedure,
            'reconcile_balance_insert(uuid,money_with_currency,timestamptz,text,text,timestamptz,jsonb,text)'::regprocedure,
            'reconcile_external_transaction_insert(uuid,text,money_with_currency,reconcile_direction,timestamptz,reconcile_external_status,timestamptz,text,text,text,jsonb,text,uuid,uuid)'::regprocedure,
            'reconcile_asset(money_minor)'::regprocedure,
            'reconcile_balance_insert(uuid,money_minor,timestamptz,text,text,timestamptz,jsonb,text)'::regprocedure,
            'reconcile_external_transaction_insert(uuid,text,money_minor,reconcile_direction,timestamptz,reconcile_external_status,timestamptz,text,text,text,jsonb,text,uuid,uuid)'::regprocedure,
            'reconcile_asset(crypto_asset)'::regprocedure,
            'reconcile_balance_insert(uuid,crypto_amount,timestamptz,text,text,timestamptz,jsonb,text)'::regprocedure,
            'reconcile_external_transaction_insert(uuid,text,crypto_amount,reconcile_direction,timestamptz,reconcile_external_status,timestamptz,text,text,text,jsonb,text,uuid,uuid)'::regprocedure
        ]) function_oid
        JOIN pg_depend d
          ON d.classid = 'pg_proc'::regclass
         AND d.objid = function_oid::oid
         AND d.refclassid = 'pg_extension'::regclass
         AND d.deptype = 'e'
        JOIN pg_extension e ON e.oid = d.refobjid
        WHERE e.extname = 'pg_reconcile'
    );
END
$body$;

DROP EXTENSION pg_reconcile;

DO $body$
BEGIN
    ASSERT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_money');
    ASSERT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cryptocurrency');
    ASSERT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_ledger');
    ASSERT to_regprocedure(
        'reconcile_balance_insert(uuid,money_minor,timestamptz,text,text,timestamptz,jsonb,text)'
    ) IS NULL;
    ASSERT to_regprocedure(
        'reconcile_balance_insert(uuid,crypto_amount,timestamptz,text,text,timestamptz,jsonb,text)'
    ) IS NULL;
END
$body$;
