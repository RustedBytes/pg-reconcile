DO $body$
DECLARE
    extension_oid oid;
    object_row record;
BEGIN
    SELECT oid INTO extension_oid FROM pg_extension WHERE extname = 'pg_reconcile';

    FOR object_row IN
        SELECT c.oid, c.relkind
        FROM pg_class c
        JOIN pg_depend d ON d.classid = 'pg_class'::regclass AND d.objid = c.oid
        WHERE d.refclassid = 'pg_extension'::regclass
          AND d.refobjid = extension_oid AND d.deptype = 'e'
          AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
    LOOP
        EXECUTE format('REVOKE ALL ON %s %s FROM PUBLIC',
            CASE WHEN object_row.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END,
            object_row.oid::regclass);
    END LOOP;

    FOR object_row IN
        SELECT p.oid
        FROM pg_proc p
        JOIN pg_depend d ON d.classid = 'pg_proc'::regclass AND d.objid = p.oid
        WHERE d.refclassid = 'pg_extension'::regclass
          AND d.refobjid = extension_oid AND d.deptype = 'e'
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', object_row.oid::regprocedure);
    END LOOP;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reconcile_reader') THEN
        GRANT SELECT ON reconcile_accounts_view, reconcile_latest_balances,
            reconcile_latest_results, reconcile_unmatched_external,
            reconcile_unmatched_ledger, reconcile_ambiguous,
            reconcile_issues, reconcile_run_summary TO reconcile_reader;
        GRANT EXECUTE ON FUNCTION reconcile_run(uuid), reconcile_results(uuid)
            TO reconcile_reader;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reconcile_ingestor') THEN
        GRANT EXECUTE ON FUNCTION reconcile_balance_insert(
            uuid, text, timestamptz, text, text, timestamptz, jsonb, text
        ) TO reconcile_ingestor;
        GRANT EXECUTE ON FUNCTION reconcile_external_transaction_insert(
            uuid, text, text, reconcile_direction, timestamptz,
            reconcile_external_status, timestamptz, text, text, text,
            jsonb, text, uuid, uuid
        ) TO reconcile_ingestor;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reconcile_operator') THEN
        GRANT SELECT ON reconcile_accounts_view, reconcile_latest_balances,
            reconcile_latest_results, reconcile_unmatched_external,
            reconcile_unmatched_ledger, reconcile_ambiguous,
            reconcile_issues, reconcile_run_summary TO reconcile_operator;
        GRANT EXECUTE ON FUNCTION reconcile_balance(uuid, timestamptz),
            reconcile_transactions(uuid, timestamptz),
            reconcile_full(uuid, timestamptz),
            reconcile_all(text, timestamptz),
            reconcile_all_enabled(timestamptz),
            reconcile_match_manual(uuid, uuid, text, text),
            reconcile_mark_external_unmatched(uuid, text, text),
            reconcile_run(uuid), reconcile_results(uuid), reconcile_validate()
            TO reconcile_operator;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reconcile_admin') THEN
        GRANT SELECT, UPDATE ON reconcile_accounts TO reconcile_admin;
        GRANT SELECT ON reconcile_accounts_view, reconcile_latest_balances,
            reconcile_latest_results, reconcile_unmatched_external,
            reconcile_unmatched_ledger, reconcile_ambiguous,
            reconcile_issues, reconcile_run_summary TO reconcile_admin;
        GRANT EXECUTE ON FUNCTION reconcile_create_account(
            text, uuid, text, text, text, reconcile_account_kind,
            reconcile_balance_mode, numeric, jsonb, interval, boolean, integer
        ), reconcile_create_account(
            text, uuid, text, text, text, reconcile_account_kind,
            reconcile_balance_mode, text, jsonb, interval, boolean, integer
        ), reconcile_enable_pg_ledger(), reconcile_enable_pg_money(),
           reconcile_enable_pg_cryptocurrency(), reconcile_validate()
        TO reconcile_admin;
    END IF;
END
$body$;
