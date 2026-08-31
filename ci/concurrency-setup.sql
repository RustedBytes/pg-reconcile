\set ON_ERROR_STOP on

CREATE EXTENSION pg_ledger;
CREATE EXTENSION pg_reconcile;

SELECT ledger_create_account('concurrency:source', 'USD', 'ANY') AS source_id \gset
SELECT ledger_create_account('concurrency:mapped', 'USD', 'ANY') AS mapped_id \gset
SELECT reconcile_create_account(
    'concurrency-account', :'mapped_id', 'USD', 'race-provider', 'race-account',
    'BANK', 'BOOK', 0, NULL, interval '5 minutes'
) AS reconcile_id \gset
SELECT ledger_transfer(
    :'source_id', :'mapped_id', 'USD 10.00', 'race:transaction', 'race:ledger:1',
    '2026-08-31 12:00:00+00'
) AS ledger_transaction_id \gset
SELECT reconcile_balance_insert(
    :'reconcile_id', 'USD 10.00', '2026-08-31 12:00:00+00',
    'race:balance', NULL, '2026-08-31 12:00:01+00', NULL, 'race:balance:1'
);

CREATE FUNCTION reconcile_concurrent_duplicate(client_number integer)
RETURNS uuid
LANGUAGE sql
AS $body$
    SELECT reconcile_external_transaction_insert(
        (SELECT id FROM reconcile_accounts WHERE name = 'concurrency-account'),
        'race:external:1', 'USD 10.00', 'CREDIT', '2026-08-31 12:00:00+00',
        'SETTLED', '2026-08-31 12:00:02+00', NULL, NULL,
        'race:transaction', jsonb_build_object('fixture', 'same'),
        'race:external:idempotency'
    )
$body$;

CREATE FUNCTION reconcile_concurrent_balance(client_number integer)
RETURNS uuid
LANGUAGE sql
AS $body$
    SELECT (reconcile_balance(
        (SELECT id FROM reconcile_accounts WHERE name = 'concurrency-account'),
        '2026-08-31 12:01:00+00'
    )).run_id
$body$;

CREATE FUNCTION reconcile_concurrent_transactions(client_number integer)
RETURNS bigint
LANGUAGE sql
AS $body$
    SELECT count(*) FROM reconcile_transactions(
        (SELECT id FROM reconcile_accounts WHERE name = 'concurrency-account'),
        '2026-08-31 12:01:00+00'
    )
$body$;

SELECT ledger_transfer(
    :'source_id', :'mapped_id', 'USD 11.00', NULL, 'race:manual:ledger',
    '2026-08-31 13:00:00+00'
) AS manual_ledger_transaction_id \gset
SELECT reconcile_external_transaction_insert(
    :'reconcile_id', 'race:manual:external', 'USD 11.00', 'CREDIT',
    '2026-08-31 15:00:00+00', 'SETTLED', '2026-08-31 15:00:01+00',
    NULL, NULL, NULL, NULL, 'race:manual:external:key'
) AS manual_external_transaction_id \gset

CREATE FUNCTION reconcile_concurrent_manual(client_number integer)
RETURNS text
LANGUAGE plpgsql
AS $body$
BEGIN
    IF client_number % 2 = 0 THEN
        PERFORM reconcile_match_manual(
            (SELECT id FROM reconcile_external_transactions
             WHERE external_transaction_id = 'race:manual:external'),
            (SELECT id FROM ledger_transactions
             WHERE idempotency_key = 'race:manual:ledger'),
            'concurrent operator decision'
        );
        RETURN 'manual';
    END IF;
    PERFORM count(*) FROM reconcile_transactions(
        (SELECT id FROM reconcile_accounts WHERE name = 'concurrency-account'),
        '2026-08-31 15:01:00+00'
    );
    RETURN 'automatic';
END
$body$;
