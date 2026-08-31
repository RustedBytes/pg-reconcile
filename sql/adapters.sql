CREATE FUNCTION reconcile_enable_pg_ledger()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    reconcile_schema name;
    ledger_schema name;
BEGIN
    SELECT n.nspname INTO reconcile_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_reconcile';
    SELECT n.nspname INTO ledger_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_ledger';
    IF reconcile_schema IS NULL OR ledger_schema IS NULL THEN
        RETURN false;
    END IF;
    IF to_regclass(format('%I.ledger_accounts', ledger_schema)) IS NULL OR
       to_regclass(format('%I.ledger_transactions', ledger_schema)) IS NULL OR
       to_regclass(format('%I.ledger_entries', ledger_schema)) IS NULL OR
       to_regprocedure(format('%I.ledger_amount_units(%I.ledger_amount)', ledger_schema, ledger_schema)) IS NULL THEN
        RAISE EXCEPTION 'installed pg_ledger does not expose the required v0.1 API'
            USING ERRCODE = 'PGR09', DETAIL = 'RECONCILE_LEDGER_ADAPTER_MISSING';
    END IF;

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION %1$I._reconcile_ledger_account_info(account_id uuid) '
        'RETURNS TABLE(asset_identity text) LANGUAGE sql STABLE PARALLEL SAFE '
        'SET search_path = %1$I, pg_catalog AS %2$L',
        reconcile_schema,
        format('SELECT %I.reconcile_asset(a.asset::text) FROM %I.ledger_accounts a WHERE a.id = $1',
               reconcile_schema, ledger_schema)
    );

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION %1$I._reconcile_ledger_balance_at(account_id uuid, at_time timestamptz) '
        'RETURNS TABLE(balance_units numeric, boundary jsonb) LANGUAGE sql STABLE PARALLEL RESTRICTED '
        'SET search_path = %1$I, pg_catalog AS %2$L',
        reconcile_schema,
        format(
            'SELECT coalesce(sum(%1$I.ledger_amount_units(e.amount)), 0)::numeric, '
            'jsonb_build_object(''through_event_at'', max(t.event_at), '
            '''through_transaction_id'', max(t.id::text), ''as_of'', $2, '
            '''entry_count'', count(e.id)) '
            'FROM %1$I.ledger_accounts a '
            'LEFT JOIN (%1$I.ledger_entries e JOIN %1$I.ledger_transactions t '
            'ON t.id = e.transaction_id AND t.event_at <= $2) ON e.account_id = a.id '
            'WHERE a.id = $1 GROUP BY a.id',
            ledger_schema
        )
    );

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION %1$I._reconcile_ledger_candidates(account_id uuid, through_time timestamptz) '
        'RETURNS TABLE(ledger_transaction_id uuid, ledger_entry_id uuid, amount_units numeric, '
        'asset_identity text, event_at timestamptz, reference text, metadata jsonb) '
        'LANGUAGE sql STABLE PARALLEL RESTRICTED SET search_path = %1$I, pg_catalog AS %2$L',
        reconcile_schema,
        format(
            'SELECT t.id, e.id, %1$I.ledger_amount_units(e.amount), '
            '%2$I.reconcile_asset(a.asset::text), t.event_at, t.reference, t.metadata '
            'FROM %1$I.ledger_entries e '
            'JOIN %1$I.ledger_transactions t ON t.id = e.transaction_id '
            'JOIN %1$I.ledger_accounts a ON a.id = e.account_id '
            'WHERE e.account_id = $1 AND t.event_at <= $2 '
            'ORDER BY t.event_at, t.id, e.id',
            ledger_schema, reconcile_schema
        )
    );

    INSERT INTO reconcile_integration_state(extension_name, extension_schema)
    VALUES ('pg_ledger', ledger_schema)
    ON CONFLICT (extension_name) DO UPDATE
    SET extension_schema = EXCLUDED.extension_schema, enabled_at = clock_timestamp();
    RETURN true;
END
$body$;

CREATE FUNCTION reconcile_enable_pg_money()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    reconcile_schema name;
    money_schema name;
    money_type regtype;
BEGIN
    SELECT n.nspname INTO reconcile_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_reconcile';
    SELECT n.nspname INTO money_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_money';
    IF reconcile_schema IS NULL OR money_schema IS NULL THEN RETURN false; END IF;
    IF to_regtype(format('%I.money_with_currency', money_schema)) IS NULL AND
       to_regtype(format('%I.money_minor', money_schema)) IS NULL THEN
        RETURN false;
    END IF;
    FOR money_type IN
        SELECT DISTINCT candidate
        FROM (VALUES
            (to_regtype(format('%I.money_with_currency', money_schema))),
            (to_regtype(format('%I.money_minor', money_schema)))
        ) AS available(candidate)
        WHERE candidate IS NOT NULL
    LOOP
        EXECUTE format(
            'CREATE OR REPLACE FUNCTION %1$I.reconcile_asset(value %2$s) RETURNS text '
            'LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE '
            'SET search_path = %1$I, pg_catalog AS %3$L',
            reconcile_schema, money_type::text,
            format('SELECT %I.reconcile_amount_asset($1::text)', reconcile_schema)
        );
        EXECUTE format(
            'CREATE OR REPLACE FUNCTION %1$I.reconcile_balance_insert('
            'reconcile_account_id uuid, balance %2$s, observed_at timestamptz, '
            'external_reference text DEFAULT NULL, source_sequence text DEFAULT NULL, '
            'received_at timestamptz DEFAULT clock_timestamp(), metadata jsonb DEFAULT NULL, '
            'idempotency_key text DEFAULT NULL) RETURNS uuid '
            'LANGUAGE sql SECURITY DEFINER SET search_path = %1$I, pg_catalog, pg_temp AS %3$L',
            reconcile_schema, money_type::text,
            format('SELECT %I.reconcile_balance_insert($1, $2::text, $3, $4, $5, $6, $7, $8)',
                   reconcile_schema)
        );
        EXECUTE format(
            'CREATE OR REPLACE FUNCTION %1$I.reconcile_external_transaction_insert('
            'reconcile_account_id uuid, external_transaction_id text, amount %2$s, '
            'direction %1$I.reconcile_direction, event_at timestamptz, status %1$I.reconcile_external_status, '
            'received_at timestamptz DEFAULT clock_timestamp(), counterparty text DEFAULT NULL, '
            'description text DEFAULT NULL, external_reference text DEFAULT NULL, metadata jsonb DEFAULT NULL, '
            'idempotency_key text DEFAULT NULL, reverses_external_transaction_id uuid DEFAULT NULL, '
            'supersedes_id uuid DEFAULT NULL) RETURNS uuid LANGUAGE sql SECURITY DEFINER '
            'SET search_path = %1$I, pg_catalog, pg_temp AS %3$L',
            reconcile_schema, money_type::text,
            format('SELECT %I.reconcile_external_transaction_insert($1, $2, $3::text, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)',
                   reconcile_schema)
        );
        EXECUTE format(
            'REVOKE ALL ON FUNCTION %I.reconcile_asset(%s) FROM PUBLIC',
            reconcile_schema, money_type::text
        );
        EXECUTE format(
            'REVOKE ALL ON FUNCTION %I.reconcile_balance_insert(uuid, %s, timestamptz, text, text, timestamptz, jsonb, text) FROM PUBLIC',
            reconcile_schema, money_type::text
        );
        EXECUTE format(
            'REVOKE ALL ON FUNCTION %I.reconcile_external_transaction_insert(uuid, text, %s, %I.reconcile_direction, timestamptz, %I.reconcile_external_status, timestamptz, text, text, text, jsonb, text, uuid, uuid) FROM PUBLIC',
            reconcile_schema, money_type::text, reconcile_schema, reconcile_schema
        );
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reconcile_ingestor') THEN
            EXECUTE format(
                'GRANT EXECUTE ON FUNCTION %I.reconcile_balance_insert(uuid, %s, timestamptz, text, text, timestamptz, jsonb, text) TO reconcile_ingestor',
                reconcile_schema, money_type::text
            );
            EXECUTE format(
                'GRANT EXECUTE ON FUNCTION %I.reconcile_external_transaction_insert(uuid, text, %s, %I.reconcile_direction, timestamptz, %I.reconcile_external_status, timestamptz, text, text, text, jsonb, text, uuid, uuid) TO reconcile_ingestor',
                reconcile_schema, money_type::text, reconcile_schema, reconcile_schema
            );
        END IF;
    END LOOP;
    INSERT INTO reconcile_integration_state(extension_name, extension_schema)
    VALUES ('pg_money', money_schema)
    ON CONFLICT (extension_name) DO UPDATE
    SET extension_schema = EXCLUDED.extension_schema, enabled_at = clock_timestamp();
    RETURN true;
END
$body$;

CREATE FUNCTION reconcile_enable_pg_cryptocurrency()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    reconcile_schema name;
    crypto_schema name;
BEGIN
    SELECT n.nspname INTO reconcile_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_reconcile';
    SELECT n.nspname INTO crypto_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_cryptocurrency';
    IF reconcile_schema IS NULL OR crypto_schema IS NULL OR
       to_regtype(format('%I.crypto_amount', crypto_schema)) IS NULL OR
       to_regtype(format('%I.crypto_asset', crypto_schema)) IS NULL OR
       to_regprocedure(format('%I.crypto_amount_value(%I.crypto_amount)', crypto_schema, crypto_schema)) IS NULL OR
       to_regprocedure(format('%I.crypto_amount_symbol(%I.crypto_amount)', crypto_schema, crypto_schema)) IS NULL OR
       to_regprocedure(format('%I.crypto_amount_network(%I.crypto_amount)', crypto_schema, crypto_schema)) IS NULL OR
       to_regprocedure(format('%I.crypto_amount_decimals(%I.crypto_amount)', crypto_schema, crypto_schema)) IS NULL OR
       to_regprocedure(format('%I.crypto_asset_symbol(%I.crypto_asset)', crypto_schema, crypto_schema)) IS NULL OR
       to_regprocedure(format('%I.crypto_asset_network(%I.crypto_asset)', crypto_schema, crypto_schema)) IS NULL OR
       to_regprocedure(format('%I.crypto_asset_decimals(%I.crypto_asset)', crypto_schema, crypto_schema)) IS NULL THEN
        RETURN false;
    END IF;
    EXECUTE format(
        'CREATE OR REPLACE FUNCTION %1$I.reconcile_asset(value %2$I.crypto_asset) RETURNS text '
        'LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE '
        'SET search_path = %1$I, pg_catalog AS %3$L',
        reconcile_schema, crypto_schema,
        format(
            'SELECT %1$I.reconcile_asset(format(''%%s@%%s/%%s'', '
            '%2$I.crypto_asset_symbol($1), %2$I.crypto_asset_network($1), '
            '%2$I.crypto_asset_decimals($1)))',
            reconcile_schema, crypto_schema
        )
    );
    EXECUTE format(
        'CREATE OR REPLACE FUNCTION %1$I.reconcile_balance_insert('
        'reconcile_account_id uuid, balance %2$I.crypto_amount, observed_at timestamptz, '
        'external_reference text DEFAULT NULL, source_sequence text DEFAULT NULL, '
        'received_at timestamptz DEFAULT clock_timestamp(), metadata jsonb DEFAULT NULL, '
        'idempotency_key text DEFAULT NULL) RETURNS uuid '
        'LANGUAGE sql SECURITY DEFINER SET search_path = %1$I, pg_catalog, pg_temp AS %3$L',
        reconcile_schema, crypto_schema,
        format(
            'SELECT %1$I.reconcile_balance_insert($1, format(''%%s %%s@%%s/%%s'', '
            '%2$I.crypto_amount_value($2), %2$I.crypto_amount_symbol($2), '
            '%2$I.crypto_amount_network($2), %2$I.crypto_amount_decimals($2)), '
            '$3, $4, $5, $6, $7, $8)',
            reconcile_schema, crypto_schema
        )
    );
    EXECUTE format(
        'REVOKE ALL ON FUNCTION %I.reconcile_balance_insert(uuid, %I.crypto_amount, timestamptz, text, text, timestamptz, jsonb, text) FROM PUBLIC',
        reconcile_schema, crypto_schema
    );
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reconcile_ingestor') THEN
        EXECUTE format(
            'GRANT EXECUTE ON FUNCTION %I.reconcile_balance_insert(uuid, %I.crypto_amount, timestamptz, text, text, timestamptz, jsonb, text) TO reconcile_ingestor',
            reconcile_schema, crypto_schema
        );
    END IF;
    EXECUTE format(
        'CREATE OR REPLACE FUNCTION %1$I.reconcile_external_transaction_insert('
        'reconcile_account_id uuid, external_transaction_id text, amount %2$I.crypto_amount, '
        'direction %1$I.reconcile_direction, event_at timestamptz, status %1$I.reconcile_external_status, '
        'received_at timestamptz DEFAULT clock_timestamp(), counterparty text DEFAULT NULL, '
        'description text DEFAULT NULL, external_reference text DEFAULT NULL, metadata jsonb DEFAULT NULL, '
        'idempotency_key text DEFAULT NULL, reverses_external_transaction_id uuid DEFAULT NULL, '
        'supersedes_id uuid DEFAULT NULL) RETURNS uuid LANGUAGE sql SECURITY DEFINER '
        'SET search_path = %1$I, pg_catalog, pg_temp AS %3$L',
        reconcile_schema, crypto_schema,
        format(
            'SELECT %1$I.reconcile_external_transaction_insert($1, $2, '
            'format(''%%s %%s@%%s/%%s'', %2$I.crypto_amount_value($3), '
            '%2$I.crypto_amount_symbol($3), %2$I.crypto_amount_network($3), '
            '%2$I.crypto_amount_decimals($3)), '
            '$4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)',
            reconcile_schema, crypto_schema
        )
    );
    EXECUTE format(
        'REVOKE ALL ON FUNCTION %I.reconcile_asset(%I.crypto_asset) FROM PUBLIC',
        reconcile_schema, crypto_schema
    );
    EXECUTE format(
        'REVOKE ALL ON FUNCTION %1$I.reconcile_external_transaction_insert(uuid, text, %2$I.crypto_amount, %1$I.reconcile_direction, timestamptz, %1$I.reconcile_external_status, timestamptz, text, text, text, jsonb, text, uuid, uuid) FROM PUBLIC',
        reconcile_schema, crypto_schema
    );
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reconcile_ingestor') THEN
        EXECUTE format(
            'GRANT EXECUTE ON FUNCTION %1$I.reconcile_external_transaction_insert(uuid, text, %2$I.crypto_amount, %1$I.reconcile_direction, timestamptz, %1$I.reconcile_external_status, timestamptz, text, text, text, jsonb, text, uuid, uuid) TO reconcile_ingestor',
            reconcile_schema, crypto_schema
        );
    END IF;
    INSERT INTO reconcile_integration_state(extension_name, extension_schema)
    VALUES ('pg_cryptocurrency', crypto_schema)
    ON CONFLICT (extension_name) DO UPDATE
    SET extension_schema = EXCLUDED.extension_schema, enabled_at = clock_timestamp();
    RETURN true;
END
$body$;

DO $body$
BEGIN
    PERFORM reconcile_enable_pg_ledger();
    PERFORM reconcile_enable_pg_money();
    PERFORM reconcile_enable_pg_cryptocurrency();
END
$body$;
