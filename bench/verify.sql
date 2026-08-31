\set ON_ERROR_STOP on

DO $body$
BEGIN
    IF EXISTS (SELECT 1 FROM reconcile_validate() WHERE status <> 'OK') THEN
        RAISE EXCEPTION 'post-benchmark invariant validation failed';
    END IF;
    IF EXISTS (
        SELECT 1 FROM reconcile_balance_results
        WHERE status <> 'MATCHED' OR difference_units <> 0
    ) THEN
        RAISE EXCEPTION 'balance benchmark produced an incorrect result';
    END IF;
END
$body$;

SELECT count(*) AS external_transactions FROM reconcile_external_transactions;
SELECT status, count(*) FROM reconcile_matches GROUP BY status ORDER BY status;
SELECT count(*) AS completed_runs FROM reconcile_runs WHERE status = 'COMPLETED';
SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size;
