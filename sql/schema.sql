CREATE TABLE reconcile_accounts (
    id uuid PRIMARY KEY DEFAULT reconcile_uuidv7(),
    name text NOT NULL UNIQUE CHECK (btrim(name) = name AND name <> ''),
    ledger_account_id uuid NOT NULL,
    asset_identity text NOT NULL CHECK (asset_identity = reconcile_asset(asset_identity)),
    external_system text NOT NULL CHECK (btrim(external_system) = external_system AND external_system <> ''),
    external_account_id text NOT NULL CHECK (btrim(external_account_id) = external_account_id AND external_account_id <> ''),
    account_kind reconcile_account_kind NOT NULL,
    balance_mode reconcile_balance_mode NOT NULL,
    tolerance_units numeric NOT NULL DEFAULT 0 CHECK (tolerance_units >= 0 AND scale(tolerance_units) = 0),
    matching_time_window interval NOT NULL DEFAULT interval '0 seconds'
        CHECK (matching_time_window >= interval '0 seconds'),
    allow_probable_matches boolean NOT NULL DEFAULT false,
    minimum_probable_score integer NOT NULL DEFAULT 100 CHECK (minimum_probable_score >= 0),
    enabled boolean NOT NULL DEFAULT true,
    metadata jsonb,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (external_system, external_account_id, asset_identity)
);

CREATE TABLE reconcile_balance_observations (
    id uuid PRIMARY KEY DEFAULT reconcile_uuidv7(),
    reconcile_account_id uuid NOT NULL REFERENCES reconcile_accounts(id),
    balance_units numeric NOT NULL CHECK (scale(balance_units) = 0),
    asset_identity text NOT NULL,
    observed_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    external_reference text,
    source_sequence text,
    idempotency_key text,
    payload_hash bytea NOT NULL CHECK (octet_length(payload_hash) = 32),
    metadata jsonb,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (external_reference IS NULL OR external_reference <> ''),
    CHECK (idempotency_key IS NULL OR idempotency_key <> '')
);

CREATE TABLE reconcile_external_transactions (
    id uuid PRIMARY KEY DEFAULT reconcile_uuidv7(),
    reconcile_account_id uuid NOT NULL REFERENCES reconcile_accounts(id),
    external_transaction_id text NOT NULL CHECK (external_transaction_id <> ''),
    amount_units numeric NOT NULL CHECK (amount_units > 0 AND scale(amount_units) = 0),
    asset_identity text NOT NULL,
    direction reconcile_direction NOT NULL,
    event_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    status reconcile_external_status NOT NULL,
    counterparty text,
    description text,
    external_reference text,
    idempotency_key text,
    payload_hash bytea NOT NULL CHECK (octet_length(payload_hash) = 32),
    reverses_external_transaction_id uuid REFERENCES reconcile_external_transactions(id),
    supersedes_id uuid UNIQUE REFERENCES reconcile_external_transactions(id),
    metadata jsonb,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (external_reference IS NULL OR external_reference <> ''),
    CHECK (idempotency_key IS NULL OR idempotency_key <> ''),
    CHECK (reverses_external_transaction_id IS NULL OR reverses_external_transaction_id <> id),
    CHECK (supersedes_id IS NULL OR supersedes_id <> id)
);

CREATE TABLE reconcile_runs (
    id uuid PRIMARY KEY DEFAULT reconcile_uuidv7(),
    reconcile_account_id uuid NOT NULL REFERENCES reconcile_accounts(id),
    reconciliation_type reconcile_run_type NOT NULL,
    as_of timestamptz NOT NULL,
    started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_at timestamptz,
    status reconcile_run_status NOT NULL DEFAULT 'RUNNING',
    algorithm_version text NOT NULL,
    tolerance_units numeric NOT NULL CHECK (tolerance_units >= 0 AND scale(tolerance_units) = 0),
    matching_time_window interval NOT NULL,
    allow_probable_matches boolean NOT NULL,
    minimum_probable_score integer NOT NULL,
    evidence_received_cutoff timestamptz NOT NULL,
    metadata jsonb,
    CHECK ((status = 'RUNNING' AND completed_at IS NULL) OR
           (status IN ('COMPLETED', 'FAILED') AND completed_at IS NOT NULL))
);

CREATE TABLE reconcile_balance_results (
    id uuid PRIMARY KEY DEFAULT reconcile_uuidv7(),
    run_id uuid NOT NULL UNIQUE REFERENCES reconcile_runs(id),
    external_observation_id uuid REFERENCES reconcile_balance_observations(id),
    ledger_balance_units numeric NOT NULL CHECK (scale(ledger_balance_units) = 0),
    external_balance_units numeric CHECK (scale(external_balance_units) = 0),
    difference_units numeric CHECK (scale(difference_units) = 0),
    tolerance_units numeric NOT NULL CHECK (tolerance_units >= 0 AND scale(tolerance_units) = 0),
    status reconcile_balance_status NOT NULL,
    ledger_boundary jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK ((status = 'MISSING_EXTERNAL_OBSERVATION' AND external_observation_id IS NULL
            AND external_balance_units IS NULL AND difference_units IS NULL) OR
           (status <> 'MISSING_EXTERNAL_OBSERVATION' AND external_observation_id IS NOT NULL
            AND external_balance_units IS NOT NULL AND difference_units IS NOT NULL)),
    CHECK (difference_units IS NULL OR difference_units = external_balance_units - ledger_balance_units)
);

CREATE TABLE reconcile_matches (
    id uuid PRIMARY KEY DEFAULT reconcile_uuidv7(),
    run_id uuid NOT NULL REFERENCES reconcile_runs(id),
    external_transaction_id uuid REFERENCES reconcile_external_transactions(id),
    ledger_transaction_id uuid,
    ledger_entry_id uuid,
    status reconcile_match_status NOT NULL,
    score integer,
    reason jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (external_transaction_id IS NOT NULL OR ledger_transaction_id IS NOT NULL),
    CHECK ((status = 'UNMATCHED_EXTERNAL' AND external_transaction_id IS NOT NULL) OR
           (status = 'UNMATCHED_LEDGER' AND ledger_transaction_id IS NOT NULL) OR
           status NOT IN ('UNMATCHED_EXTERNAL', 'UNMATCHED_LEDGER'))
);

CREATE TABLE reconcile_manual_decisions (
    id uuid PRIMARY KEY DEFAULT reconcile_uuidv7(),
    external_transaction_id uuid NOT NULL REFERENCES reconcile_external_transactions(id),
    ledger_transaction_id uuid,
    ledger_entry_id uuid,
    decision reconcile_manual_decision NOT NULL,
    reason text NOT NULL CHECK (btrim(reason) = reason AND reason <> ''),
    actor text NOT NULL CHECK (actor <> ''),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK ((decision = 'MATCH' AND ledger_transaction_id IS NOT NULL) OR
           (decision = 'MARK_UNMATCHED_EXTERNAL' AND ledger_transaction_id IS NULL))
);

CREATE TABLE reconcile_integration_state (
    extension_name text PRIMARY KEY,
    extension_schema name NOT NULL,
    enabled_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

COMMENT ON TABLE reconcile_balance_observations IS
    'Append-only external balance evidence; corrections are new observations';
COMMENT ON TABLE reconcile_external_transactions IS
    'Append-only external transaction observations, including pending/settled progression';
COMMENT ON TABLE reconcile_runs IS
    'Reproducible reconciliation snapshots with frozen policy and evidence cutoff';
COMMENT ON TABLE reconcile_manual_decisions IS
    'Append-only operator decisions; automatic matches are never overwritten';

CREATE FUNCTION _reconcile_reject_immutable_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $body$
BEGIN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME
        USING ERRCODE = '55000', DETAIL = 'RECONCILE_IMMUTABLE_EVIDENCE';
END
$body$;

CREATE TRIGGER reconcile_balance_observations_immutable
BEFORE UPDATE OR DELETE ON reconcile_balance_observations
FOR EACH ROW EXECUTE FUNCTION _reconcile_reject_immutable_change();

CREATE TRIGGER reconcile_external_transactions_immutable
BEFORE UPDATE OR DELETE ON reconcile_external_transactions
FOR EACH ROW EXECUTE FUNCTION _reconcile_reject_immutable_change();

CREATE TRIGGER reconcile_balance_results_immutable
BEFORE UPDATE OR DELETE ON reconcile_balance_results
FOR EACH ROW EXECUTE FUNCTION _reconcile_reject_immutable_change();

CREATE TRIGGER reconcile_matches_immutable
BEFORE UPDATE OR DELETE ON reconcile_matches
FOR EACH ROW EXECUTE FUNCTION _reconcile_reject_immutable_change();

CREATE TRIGGER reconcile_manual_decisions_immutable
BEFORE UPDATE OR DELETE ON reconcile_manual_decisions
FOR EACH ROW EXECUTE FUNCTION _reconcile_reject_immutable_change();

CREATE FUNCTION _reconcile_account_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $body$
BEGIN
    IF ROW(NEW.ledger_account_id, NEW.asset_identity, NEW.external_system, NEW.external_account_id)
       IS DISTINCT FROM
       ROW(OLD.ledger_account_id, OLD.asset_identity, OLD.external_system, OLD.external_account_id) THEN
        RAISE EXCEPTION 'reconciliation account identity is immutable; create a new mapping'
            USING ERRCODE = '55000', DETAIL = 'RECONCILE_IMMUTABLE_ACCOUNT_IDENTITY';
    END IF;
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END
$body$;

CREATE TRIGGER reconcile_account_guard
BEFORE UPDATE ON reconcile_accounts
FOR EACH ROW EXECUTE FUNCTION _reconcile_account_guard();

CREATE FUNCTION _reconcile_run_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $body$
BEGIN
    IF current_setting('pg_reconcile.internal_run_update', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'reconciliation runs can only be finalized by the engine'
            USING ERRCODE = '55000', DETAIL = 'RECONCILE_IMMUTABLE_RUN';
    END IF;
    IF OLD.status <> 'RUNNING' OR NEW.status NOT IN ('COMPLETED', 'FAILED') OR
       ROW(NEW.id, NEW.reconcile_account_id, NEW.reconciliation_type, NEW.as_of,
           NEW.started_at, NEW.algorithm_version, NEW.tolerance_units,
           NEW.matching_time_window, NEW.allow_probable_matches,
           NEW.minimum_probable_score, NEW.evidence_received_cutoff)
       IS DISTINCT FROM
       ROW(OLD.id, OLD.reconcile_account_id, OLD.reconciliation_type, OLD.as_of,
           OLD.started_at, OLD.algorithm_version, OLD.tolerance_units,
           OLD.matching_time_window, OLD.allow_probable_matches,
           OLD.minimum_probable_score, OLD.evidence_received_cutoff) THEN
        RAISE EXCEPTION 'invalid reconciliation run transition'
            USING ERRCODE = '55000', DETAIL = 'RECONCILE_IMMUTABLE_RUN';
    END IF;
    RETURN NEW;
END
$body$;

CREATE TRIGGER reconcile_run_guard
BEFORE UPDATE OR DELETE ON reconcile_runs
FOR EACH ROW EXECUTE FUNCTION _reconcile_run_guard();

-- Adapter stubs are replaced dynamically without introducing a Rust dependency.
CREATE FUNCTION _reconcile_ledger_account_info(account_id uuid)
RETURNS TABLE(asset_identity text)
LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = @extschema@, pg_catalog
AS 'SELECT NULL::text WHERE false';

CREATE FUNCTION _reconcile_ledger_balance_at(
    account_id uuid,
    at_time timestamptz,
    evidence_created_cutoff timestamptz
)
RETURNS TABLE(balance_units numeric, boundary jsonb)
LANGUAGE plpgsql STABLE PARALLEL RESTRICTED
SET search_path = @extschema@, pg_catalog
AS $body$
BEGIN
    RAISE EXCEPTION 'pg_ledger adapter is not enabled'
        USING ERRCODE = 'PGR09', DETAIL = 'RECONCILE_LEDGER_ADAPTER_MISSING';
END
$body$;

CREATE FUNCTION _reconcile_ledger_candidates(
    account_id uuid,
    through_time timestamptz,
    evidence_created_cutoff timestamptz
) RETURNS TABLE(
    ledger_transaction_id uuid,
    ledger_entry_id uuid,
    amount_units numeric,
    asset_identity text,
    event_at timestamptz,
    reference text,
    metadata jsonb
)
LANGUAGE plpgsql STABLE PARALLEL RESTRICTED
SET search_path = @extschema@, pg_catalog
AS $body$
BEGIN
    RAISE EXCEPTION 'pg_ledger adapter is not enabled'
        USING ERRCODE = 'PGR09', DETAIL = 'RECONCILE_LEDGER_ADAPTER_MISSING';
END
$body$;

-- Dynamically created optional-adapter overloads must belong to this
-- extension even when the peer extension is installed later. Otherwise they
-- become orphaned objects and prevent DROP EXTENSION pg_reconcile.
CREATE FUNCTION _reconcile_attach_function(function_oid regprocedure)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog
AS $body$
DECLARE
    extension_oid oid;
BEGIN
    IF function_oid IS NULL THEN
        RAISE EXCEPTION 'cannot attach a missing adapter function'
            USING ERRCODE = 'PGR09', DETAIL = 'RECONCILE_LEDGER_ADAPTER_MISSING';
    END IF;
    SELECT oid INTO extension_oid FROM pg_extension WHERE extname = 'pg_reconcile';
    IF NOT EXISTS (
        SELECT 1 FROM pg_depend
        WHERE classid = 'pg_proc'::regclass
          AND objid = function_oid::oid
          AND refclassid = 'pg_extension'::regclass
          AND refobjid = extension_oid
          AND deptype = 'e'
    ) THEN
        EXECUTE format('ALTER EXTENSION pg_reconcile ADD FUNCTION %s', function_oid);
    END IF;
END
$body$;

CREATE FUNCTION reconcile_create_account(
    name text,
    ledger_account_id uuid,
    asset text,
    external_system text,
    external_account_id text,
    account_kind reconcile_account_kind,
    balance_mode reconcile_balance_mode,
    tolerance numeric DEFAULT 0,
    metadata jsonb DEFAULT NULL,
    matching_time_window interval DEFAULT interval '0 seconds',
    allow_probable_matches boolean DEFAULT false,
    minimum_probable_score integer DEFAULT 100
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    canonical_asset text := reconcile_asset(asset);
    ledger_asset text;
    result uuid;
BEGIN
    IF tolerance < 0 OR scale(tolerance) <> 0 THEN
        RAISE EXCEPTION 'tolerance must be a non-negative smallest-unit integer'
            USING ERRCODE = '22023', DETAIL = 'RECONCILE_ASSET_MISMATCH';
    END IF;
    SELECT info.asset_identity INTO ledger_asset
    FROM _reconcile_ledger_account_info(ledger_account_id) info;
    IF EXISTS (SELECT 1 FROM reconcile_integration_state WHERE extension_name = 'pg_ledger') THEN
        IF ledger_asset IS NULL THEN
            RAISE EXCEPTION 'ledger account % does not exist', ledger_account_id
                USING ERRCODE = 'PGR01', DETAIL = 'RECONCILE_ACCOUNT_NOT_FOUND';
        ELSIF reconcile_asset(ledger_asset) <> canonical_asset THEN
            RAISE EXCEPTION 'mapped ledger asset % does not match %', ledger_asset, canonical_asset
                USING ERRCODE = 'PGR02', DETAIL = 'RECONCILE_ASSET_MISMATCH';
        END IF;
    END IF;
    INSERT INTO reconcile_accounts (
        name, ledger_account_id, asset_identity, external_system, external_account_id,
        account_kind, balance_mode, tolerance_units, metadata, matching_time_window,
        allow_probable_matches, minimum_probable_score
    ) VALUES (
        name, ledger_account_id, canonical_asset, external_system, external_account_id,
        account_kind, balance_mode, tolerance, metadata, matching_time_window,
        allow_probable_matches, minimum_probable_score
    ) RETURNING id INTO result;
    RETURN result;
END
$body$;

CREATE FUNCTION reconcile_account(account_id uuid)
RETURNS reconcile_accounts
LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = @extschema@, pg_catalog
AS 'SELECT * FROM reconcile_accounts WHERE id = account_id';

CREATE FUNCTION reconcile_account(account_name text)
RETURNS reconcile_accounts
LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = @extschema@, pg_catalog
AS 'SELECT * FROM reconcile_accounts WHERE name = account_name';

CREATE FUNCTION reconcile_create_account(
    name text,
    ledger_account_id uuid,
    asset text,
    external_system text,
    external_account_id text,
    account_kind reconcile_account_kind,
    balance_mode reconcile_balance_mode,
    tolerance text,
    metadata jsonb DEFAULT NULL,
    matching_time_window interval DEFAULT interval '0 seconds',
    allow_probable_matches boolean DEFAULT false,
    minimum_probable_score integer DEFAULT 100
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    canonical_asset text := reconcile_asset(asset);
BEGIN
    IF reconcile_amount_asset(tolerance) <> canonical_asset THEN
        RAISE EXCEPTION 'tolerance asset does not match reconciliation account asset'
            USING ERRCODE = 'PGR02', DETAIL = 'RECONCILE_ASSET_MISMATCH';
    END IF;
    RETURN reconcile_create_account(
        name, ledger_account_id, canonical_asset, external_system, external_account_id,
        account_kind, balance_mode, reconcile_amount_units(tolerance), metadata,
        matching_time_window, allow_probable_matches, minimum_probable_score
    );
END
$body$;

CREATE FUNCTION reconcile_balance_insert(
    reconcile_account_id uuid,
    balance text,
    observed_at timestamptz,
    external_reference text DEFAULT NULL,
    source_sequence text DEFAULT NULL,
    received_at timestamptz DEFAULT clock_timestamp(),
    metadata jsonb DEFAULT NULL,
    idempotency_key text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    account_asset text;
    amount_asset text := reconcile_amount_asset(balance);
    amount_units numeric := reconcile_amount_units(balance);
    fingerprint bytea;
    existing reconcile_balance_observations%ROWTYPE;
    result uuid;
    lock_key text;
BEGIN
    SELECT asset_identity INTO account_asset
    FROM reconcile_accounts WHERE id = reconcile_account_id AND enabled;
    IF account_asset IS NULL THEN
        RAISE EXCEPTION 'reconciliation account % does not exist or is disabled', reconcile_account_id
            USING ERRCODE = 'PGR01', DETAIL = 'RECONCILE_ACCOUNT_NOT_FOUND';
    END IF;
    IF amount_asset <> account_asset THEN
        RAISE EXCEPTION 'balance asset % does not match account asset %', amount_asset, account_asset
            USING ERRCODE = 'PGR02', DETAIL = 'RECONCILE_ASSET_MISMATCH';
    END IF;
    IF received_at < observed_at - interval '100 years' THEN
        RAISE EXCEPTION 'received_at is implausibly earlier than observed_at'
            USING ERRCODE = '22023', DETAIL = 'RECONCILE_MALFORMED_EXTERNAL';
    END IF;
    fingerprint := decode(reconcile_payload_hash(jsonb_build_object(
        'v', 1, 'kind', 'balance', 'account', reconcile_account_id,
        'units', amount_units::text, 'asset', amount_asset,
        'observed_at', observed_at,
        'external_reference', external_reference, 'source_sequence', source_sequence,
        'metadata', metadata
    )), 'hex');
    lock_key := coalesce(idempotency_key, external_reference);
    IF lock_key IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('pg_reconcile:balance:' ||
            reconcile_account_id::text || ':' || lock_key, 0));
    END IF;
    SELECT * INTO existing
    FROM reconcile_balance_observations o
    WHERE o.reconcile_account_id = reconcile_balance_insert.reconcile_account_id
      AND ((reconcile_balance_insert.idempotency_key IS NOT NULL
            AND o.idempotency_key = reconcile_balance_insert.idempotency_key)
        OR (reconcile_balance_insert.external_reference IS NOT NULL
            AND o.external_reference = reconcile_balance_insert.external_reference))
    ORDER BY o.created_at, o.id
    LIMIT 1;
    IF existing.id IS NOT NULL THEN
        IF existing.payload_hash = fingerprint THEN
            RETURN existing.id;
        END IF;
        RAISE EXCEPTION 'balance idempotency key or external reference was reused with different data'
            USING ERRCODE = 'PGR04', DETAIL = 'RECONCILE_IDEMPOTENCY_CONFLICT';
    END IF;
    INSERT INTO reconcile_balance_observations (
        reconcile_account_id, balance_units, asset_identity, observed_at, received_at,
        external_reference, source_sequence, idempotency_key, payload_hash, metadata
    ) VALUES (
        reconcile_account_id, amount_units, amount_asset, observed_at, received_at,
        external_reference, source_sequence, idempotency_key, fingerprint, metadata
    ) RETURNING id INTO result;
    RETURN result;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'duplicate external balance observation'
        USING ERRCODE = 'PGR03', DETAIL = 'RECONCILE_EXTERNAL_DUPLICATE';
END
$body$;

CREATE FUNCTION reconcile_external_transaction_insert(
    reconcile_account_id uuid,
    external_transaction_id text,
    amount text,
    direction reconcile_direction,
    event_at timestamptz,
    status reconcile_external_status,
    received_at timestamptz DEFAULT clock_timestamp(),
    counterparty text DEFAULT NULL,
    description text DEFAULT NULL,
    external_reference text DEFAULT NULL,
    metadata jsonb DEFAULT NULL,
    idempotency_key text DEFAULT NULL,
    reverses_external_transaction_id uuid DEFAULT NULL,
    supersedes_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    account_asset text;
    amount_asset text := reconcile_amount_asset(amount);
    amount_units numeric := reconcile_amount_units(amount);
    fingerprint bytea;
    existing reconcile_external_transactions%ROWTYPE;
    predecessor reconcile_external_transactions%ROWTYPE;
    result uuid;
BEGIN
    SELECT asset_identity INTO account_asset
    FROM reconcile_accounts WHERE id = reconcile_account_id AND enabled;
    IF account_asset IS NULL THEN
        RAISE EXCEPTION 'reconciliation account % does not exist or is disabled', reconcile_account_id
            USING ERRCODE = 'PGR01', DETAIL = 'RECONCILE_ACCOUNT_NOT_FOUND';
    END IF;
    IF amount_asset <> account_asset THEN
        RAISE EXCEPTION 'transaction asset % does not match account asset %', amount_asset, account_asset
            USING ERRCODE = 'PGR02', DETAIL = 'RECONCILE_ASSET_MISMATCH';
    END IF;
    IF amount_units <= 0 THEN
        RAISE EXCEPTION 'transaction amount must be positive; use direction for its sign'
            USING ERRCODE = '22023', DETAIL = 'RECONCILE_MALFORMED_EXTERNAL';
    END IF;
    IF reconcile_external_transaction_insert.supersedes_id IS NOT NULL THEN
        SELECT * INTO predecessor FROM reconcile_external_transactions
        WHERE id = reconcile_external_transaction_insert.supersedes_id FOR KEY SHARE;
        IF predecessor.id IS NULL OR predecessor.reconcile_account_id <> reconcile_account_id OR
           predecessor.external_transaction_id <> external_transaction_id OR
           predecessor.asset_identity <> amount_asset OR
           predecessor.event_at > event_at OR predecessor.received_at > received_at THEN
            RAISE EXCEPTION 'superseded observation must be the same logical external transaction'
                USING ERRCODE = 'PGR03', DETAIL = 'RECONCILE_EXTERNAL_DUPLICATE';
        END IF;
    END IF;
    IF reconcile_external_transaction_insert.reverses_external_transaction_id IS NOT NULL THEN
        SELECT * INTO predecessor
        FROM reconcile_external_transactions e
        WHERE e.id = reconcile_external_transaction_insert.reverses_external_transaction_id
        FOR KEY SHARE;
        IF predecessor.id IS NULL OR
           predecessor.reconcile_account_id <> reconcile_account_id OR
           predecessor.asset_identity <> amount_asset OR
           predecessor.amount_units <> amount_units OR
           predecessor.direction = direction OR
           predecessor.event_at > event_at OR
           status <> 'REVERSED' THEN
            RAISE EXCEPTION 'reversal must be REVERSED and negate a compatible external transaction'
                USING ERRCODE = '22023', DETAIL = 'RECONCILE_MALFORMED_EXTERNAL';
        END IF;
    END IF;
    fingerprint := decode(reconcile_payload_hash(jsonb_build_object(
        'v', 1, 'kind', 'transaction', 'account', reconcile_account_id,
        'external_transaction_id', external_transaction_id,
        'units', amount_units::text, 'asset', amount_asset, 'direction', direction,
        'event_at', event_at, 'status', status,
        'counterparty', counterparty, 'description', description,
        'external_reference', external_reference, 'metadata', metadata,
        'reverses', reverses_external_transaction_id, 'supersedes', supersedes_id
    )), 'hex');
    PERFORM pg_advisory_xact_lock(hashtextextended('pg_reconcile:transaction:' ||
        reconcile_account_id::text || ':' || coalesce(idempotency_key, external_transaction_id), 0));
    SELECT * INTO existing
    FROM reconcile_external_transactions e
    WHERE e.reconcile_account_id = reconcile_external_transaction_insert.reconcile_account_id
      AND ((reconcile_external_transaction_insert.idempotency_key IS NOT NULL
            AND e.idempotency_key = reconcile_external_transaction_insert.idempotency_key)
        OR (reconcile_external_transaction_insert.supersedes_id IS NULL AND e.supersedes_id IS NULL AND
            e.external_transaction_id = reconcile_external_transaction_insert.external_transaction_id))
    ORDER BY e.created_at, e.id
    LIMIT 1;
    IF existing.id IS NOT NULL THEN
        IF existing.payload_hash = fingerprint THEN
            RETURN existing.id;
        END IF;
        IF idempotency_key IS NOT NULL AND existing.idempotency_key = idempotency_key THEN
            RAISE EXCEPTION 'transaction idempotency key was reused with different data'
                USING ERRCODE = 'PGR04', DETAIL = 'RECONCILE_IDEMPOTENCY_CONFLICT';
        END IF;
        RAISE EXCEPTION 'provider transaction % already has a canonical observation', external_transaction_id
            USING ERRCODE = 'PGR03', DETAIL = 'RECONCILE_EXTERNAL_DUPLICATE';
    END IF;
    INSERT INTO reconcile_external_transactions (
        reconcile_account_id, external_transaction_id, amount_units, asset_identity,
        direction, event_at, received_at, status, counterparty, description,
        external_reference, idempotency_key, payload_hash,
        reverses_external_transaction_id, supersedes_id, metadata
    ) VALUES (
        reconcile_account_id, external_transaction_id, amount_units, amount_asset,
        direction, event_at, received_at, status, counterparty, description,
        external_reference, idempotency_key, fingerprint,
        reverses_external_transaction_id, supersedes_id, metadata
    ) RETURNING id INTO result;
    RETURN result;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'duplicate external transaction observation'
        USING ERRCODE = 'PGR03', DETAIL = 'RECONCILE_EXTERNAL_DUPLICATE';
END
$body$;

CREATE FUNCTION _reconcile_start_run(
    account_id uuid,
    run_type reconcile_run_type,
    as_of timestamptz,
    metadata jsonb DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    account reconcile_accounts%ROWTYPE;
    started timestamptz := clock_timestamp();
    result uuid;
BEGIN
    SELECT * INTO account FROM reconcile_accounts WHERE id = account_id AND enabled;
    IF account.id IS NULL THEN
        RAISE EXCEPTION 'reconciliation account % does not exist or is disabled', account_id
            USING ERRCODE = 'PGR01', DETAIL = 'RECONCILE_ACCOUNT_NOT_FOUND';
    END IF;
    INSERT INTO reconcile_runs (
        reconcile_account_id, reconciliation_type, as_of, started_at, status,
        algorithm_version, tolerance_units, matching_time_window,
        allow_probable_matches, minimum_probable_score, evidence_received_cutoff, metadata
    ) VALUES (
        account.id, run_type, as_of, started, 'RUNNING', 'pg_reconcile/0.1/reference+amount-time-v1',
        account.tolerance_units, account.matching_time_window,
        account.allow_probable_matches, account.minimum_probable_score, started, metadata
    ) RETURNING id INTO result;
    RETURN result;
END
$body$;

CREATE FUNCTION _reconcile_finish_run(run_id uuid, failed boolean DEFAULT false)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
BEGIN
    PERFORM set_config('pg_reconcile.internal_run_update', 'on', true);
    UPDATE reconcile_runs
    SET status = CASE WHEN failed THEN 'FAILED'::reconcile_run_status ELSE 'COMPLETED'::reconcile_run_status END,
        completed_at = clock_timestamp()
    WHERE id = run_id AND status = 'RUNNING';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'reconciliation run % is not running', run_id
            USING ERRCODE = '55000', DETAIL = 'RECONCILE_IMMUTABLE_RUN';
    END IF;
    PERFORM set_config('pg_reconcile.internal_run_update', 'off', true);
END
$body$;

CREATE FUNCTION _reconcile_balance_into_run(p_run_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    run_row reconcile_runs%ROWTYPE;
    account_row reconcile_accounts%ROWTYPE;
    observation reconcile_balance_observations%ROWTYPE;
    ledger_balance numeric;
    ledger_boundary jsonb;
    difference numeric;
    result_status reconcile_balance_status;
    result_id uuid;
BEGIN
    SELECT * INTO run_row FROM reconcile_runs WHERE id = p_run_id AND status = 'RUNNING';
    IF run_row.id IS NULL OR run_row.reconciliation_type NOT IN ('BALANCE', 'FULL') THEN
        RAISE EXCEPTION 'run % is not a running balance reconciliation', p_run_id
            USING ERRCODE = '22023', DETAIL = 'RECONCILE_INVALID_RUN';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM reconcile_integration_state WHERE extension_name = 'pg_ledger') THEN
        RAISE EXCEPTION 'pg_ledger adapter is not enabled'
            USING ERRCODE = 'PGR09', DETAIL = 'RECONCILE_LEDGER_ADAPTER_MISSING';
    END IF;
    SELECT * INTO account_row FROM reconcile_accounts WHERE id = run_row.reconcile_account_id;

    SELECT * INTO observation
    FROM reconcile_balance_observations o
    WHERE o.reconcile_account_id = run_row.reconcile_account_id
      AND o.observed_at <= run_row.as_of
      AND o.received_at <= run_row.evidence_received_cutoff
    ORDER BY o.observed_at DESC, o.received_at DESC, o.id DESC
    LIMIT 1;
    SELECT b.balance_units, b.boundary INTO ledger_balance, ledger_boundary
    FROM _reconcile_ledger_balance_at(
        account_row.ledger_account_id,
        coalesce(observation.observed_at, run_row.as_of),
        run_row.evidence_received_cutoff
    ) b;
    IF ledger_balance IS NULL THEN
        RAISE EXCEPTION 'mapped ledger account no longer exists'
            USING ERRCODE = 'PGR01', DETAIL = 'RECONCILE_ACCOUNT_NOT_FOUND';
    END IF;
    IF observation.id IS NULL THEN
        INSERT INTO reconcile_balance_results (
            run_id, ledger_balance_units, tolerance_units, status, ledger_boundary
        ) VALUES (
            p_run_id, ledger_balance, run_row.tolerance_units,
            'MISSING_EXTERNAL_OBSERVATION', coalesce(ledger_boundary, '{}'::jsonb)
        ) RETURNING id INTO result_id;
        RETURN result_id;
    END IF;
    difference := observation.balance_units - ledger_balance;
    result_status := CASE
        WHEN difference = 0 THEN 'MATCHED'::reconcile_balance_status
        WHEN abs(difference) <= run_row.tolerance_units THEN 'WITHIN_TOLERANCE'::reconcile_balance_status
        ELSE 'MISMATCH'::reconcile_balance_status
    END;
    INSERT INTO reconcile_balance_results (
        run_id, external_observation_id, ledger_balance_units, external_balance_units,
        difference_units, tolerance_units, status, ledger_boundary
    ) VALUES (
        p_run_id, observation.id, ledger_balance, observation.balance_units,
        difference, run_row.tolerance_units, result_status, coalesce(ledger_boundary, '{}'::jsonb)
    ) RETURNING id INTO result_id;
    RETURN result_id;
END
$body$;

CREATE FUNCTION reconcile_balance(account_id uuid, as_of timestamptz DEFAULT clock_timestamp())
RETURNS reconcile_balance_results
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    new_run uuid;
    result reconcile_balance_results%ROWTYPE;
BEGIN
    new_run := _reconcile_execute_run_rust(account_id, 'BALANCE', as_of);
    SELECT * INTO result FROM reconcile_balance_results WHERE run_id = new_run;
    RETURN result;
END
$body$;

CREATE FUNCTION _reconcile_transactions_into_run(p_run_id uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    run_row reconcile_runs%ROWTYPE;
    account_row reconcile_accounts%ROWTYPE;
    external_row reconcile_external_transactions%ROWTYPE;
    manual_row reconcile_manual_decisions%ROWTYPE;
    candidate record;
    candidate_count bigint;
    compatible_count bigint;
    signed_units numeric;
    reference_keys text[];
    reversed_ledger_transaction uuid;
    inserted_count bigint := 0;
BEGIN
    SELECT * INTO run_row FROM reconcile_runs WHERE id = p_run_id AND status = 'RUNNING';
    IF run_row.id IS NULL OR run_row.reconciliation_type NOT IN ('TRANSACTIONS', 'FULL') THEN
        RAISE EXCEPTION 'run % is not a running transaction reconciliation', p_run_id
            USING ERRCODE = '22023', DETAIL = 'RECONCILE_INVALID_RUN';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM reconcile_integration_state WHERE extension_name = 'pg_ledger') THEN
        RAISE EXCEPTION 'pg_ledger adapter is not enabled'
            USING ERRCODE = 'PGR09', DETAIL = 'RECONCILE_LEDGER_ADAPTER_MISSING';
    END IF;
    SELECT * INTO account_row FROM reconcile_accounts WHERE id = run_row.reconcile_account_id;

    CREATE TEMP TABLE IF NOT EXISTS reconcile_candidate_cache (
        ledger_transaction_id uuid NOT NULL,
        ledger_entry_id uuid NOT NULL,
        amount_units numeric NOT NULL,
        asset_identity text NOT NULL,
        event_at timestamptz NOT NULL,
        reference text,
        metadata jsonb
    ) ON COMMIT DROP;
    TRUNCATE pg_temp.reconcile_candidate_cache;
    INSERT INTO pg_temp.reconcile_candidate_cache
    SELECT * FROM _reconcile_ledger_candidates(
        account_row.ledger_account_id, run_row.as_of, run_row.evidence_received_cutoff
    );
    CREATE INDEX IF NOT EXISTS reconcile_candidate_cache_reference_idx
        ON pg_temp.reconcile_candidate_cache (reference);
    CREATE INDEX IF NOT EXISTS reconcile_candidate_cache_asset_amount_time_idx
        ON pg_temp.reconcile_candidate_cache (asset_identity, amount_units, event_at);
    CREATE INDEX IF NOT EXISTS reconcile_candidate_cache_external_id_idx
        ON pg_temp.reconcile_candidate_cache ((metadata->>'external_transaction_id'));
    CREATE INDEX IF NOT EXISTS reconcile_candidate_cache_external_ref_idx
        ON pg_temp.reconcile_candidate_cache ((metadata->>'external_reference'));
    CREATE INDEX IF NOT EXISTS reconcile_candidate_cache_provider_ref_idx
        ON pg_temp.reconcile_candidate_cache ((metadata->>'provider_reference'));
    CREATE INDEX IF NOT EXISTS reconcile_candidate_cache_txid_idx
        ON pg_temp.reconcile_candidate_cache ((metadata->>'txid'));
    CREATE INDEX IF NOT EXISTS reconcile_candidate_cache_txid_output_idx
        ON pg_temp.reconcile_candidate_cache (
            (((metadata->>'txid') || ':' || (metadata->>'output_index')))
        );
    CREATE INDEX IF NOT EXISTS reconcile_candidate_cache_tx_hash_idx
        ON pg_temp.reconcile_candidate_cache ((metadata->>'tx_hash'));
    CREATE INDEX IF NOT EXISTS reconcile_candidate_cache_tx_hash_log_idx
        ON pg_temp.reconcile_candidate_cache (
            (((metadata->>'tx_hash') || ':' || (metadata->>'log_index')))
        );
    ANALYZE pg_temp.reconcile_candidate_cache;

    CREATE TEMP TABLE IF NOT EXISTS reconcile_manual_cache (
        id uuid PRIMARY KEY,
        external_transaction_id uuid NOT NULL UNIQUE,
        ledger_transaction_id uuid,
        ledger_entry_id uuid,
        decision reconcile_manual_decision NOT NULL,
        actor text NOT NULL
    ) ON COMMIT DROP;
    TRUNCATE pg_temp.reconcile_manual_cache;
    INSERT INTO pg_temp.reconcile_manual_cache (
        id, external_transaction_id, ledger_transaction_id, ledger_entry_id, decision, actor
    )
    SELECT DISTINCT ON (d.external_transaction_id)
           d.id, d.external_transaction_id, d.ledger_transaction_id,
           d.ledger_entry_id, d.decision, d.actor
    FROM reconcile_manual_decisions d
    JOIN reconcile_external_transactions e ON e.id = d.external_transaction_id
    WHERE e.reconcile_account_id = run_row.reconcile_account_id
      AND d.created_at <= run_row.evidence_received_cutoff
    ORDER BY d.external_transaction_id, d.created_at DESC, d.id DESC;
    CREATE UNIQUE INDEX IF NOT EXISTS reconcile_manual_cache_ledger_match_idx
        ON pg_temp.reconcile_manual_cache (ledger_entry_id)
        WHERE decision = 'MATCH';

    FOR external_row IN
        SELECT e.*
        FROM reconcile_external_transactions e
        WHERE e.reconcile_account_id = run_row.reconcile_account_id
          AND e.event_at <= run_row.as_of
          AND e.received_at <= run_row.evidence_received_cutoff
          AND e.status <> 'FAILED'
          AND NOT EXISTS (
              SELECT 1 FROM reconcile_external_transactions successor
              WHERE successor.supersedes_id = e.id
                AND successor.received_at <= run_row.evidence_received_cutoff
                AND successor.event_at <= run_row.as_of
          )
        ORDER BY e.event_at, e.id
    LOOP
        signed_units := CASE external_row.direction
            WHEN 'CREDIT' THEN external_row.amount_units
            ELSE -external_row.amount_units
        END;
        reference_keys := reconcile_external_reference_keys(
            external_row.external_transaction_id,
            external_row.external_reference,
            external_row.metadata
        );

        SELECT d.* INTO manual_row
        FROM pg_temp.reconcile_manual_cache c
        JOIN reconcile_manual_decisions d ON d.id = c.id
        WHERE c.external_transaction_id = external_row.id;
        IF manual_row.id IS NOT NULL THEN
            IF manual_row.decision = 'MATCH' THEN
                IF EXISTS (
                    SELECT 1 FROM reconcile_matches m
                    WHERE m.run_id = p_run_id
                      AND m.ledger_entry_id = manual_row.ledger_entry_id
                      AND m.status IN ('EXACT', 'PROBABLE')
                      AND m.external_transaction_id IS DISTINCT FROM external_row.id
                ) THEN
                    RAISE EXCEPTION 'manual match reuses a ledger entry already matched in this run'
                        USING ERRCODE = 'PGR08', DETAIL = 'RECONCILE_INVALID_MANUAL_MATCH';
                END IF;
                INSERT INTO reconcile_matches (
                    run_id, external_transaction_id, ledger_transaction_id, ledger_entry_id,
                    status, score, reason
                ) VALUES (
                    p_run_id, external_row.id, manual_row.ledger_transaction_id,
                    manual_row.ledger_entry_id, 'EXACT', 1000,
                    jsonb_build_object('strategy', 'manual', 'decision_id', manual_row.id,
                                       'actor', manual_row.actor)
                );
            ELSE
                INSERT INTO reconcile_matches (
                    run_id, external_transaction_id, status, score, reason
                ) VALUES (
                    p_run_id, external_row.id, 'UNMATCHED_EXTERNAL', NULL,
                    jsonb_build_object('strategy', 'manual_unmatched',
                                       'decision_id', manual_row.id, 'actor', manual_row.actor)
                );
            END IF;
            inserted_count := inserted_count + 1;
            manual_row := NULL;
            CONTINUE;
        END IF;

        -- A linked external reversal is first paired with a ledger reversal of
        -- the transaction matched to the original external item. This keeps
        -- reversal semantics stronger than a coincidental amount/time match.
        IF external_row.reverses_external_transaction_id IS NOT NULL THEN
            SELECT m.ledger_transaction_id INTO reversed_ledger_transaction
            FROM reconcile_matches m
            WHERE m.run_id = p_run_id
              AND m.external_transaction_id = external_row.reverses_external_transaction_id
              AND m.status IN ('EXACT', 'PROBABLE')
            ORDER BY m.created_at, m.id
            LIMIT 1;
            IF reversed_ledger_transaction IS NOT NULL THEN
                SELECT count(*), count(*) FILTER (
                    WHERE c.asset_identity = external_row.asset_identity
                      AND c.amount_units = signed_units
                ) INTO candidate_count, compatible_count
                FROM pg_temp.reconcile_candidate_cache c
                WHERE c.metadata->>'reverses_transaction_id' = reversed_ledger_transaction::text;
                IF compatible_count = 1 THEN
                    SELECT c.* INTO candidate
                    FROM pg_temp.reconcile_candidate_cache c
                    WHERE c.metadata->>'reverses_transaction_id' = reversed_ledger_transaction::text
                      AND c.asset_identity = external_row.asset_identity
                      AND c.amount_units = signed_units
                    LIMIT 1;
                    IF EXISTS (
                        SELECT 1 FROM reconcile_matches m
                        WHERE m.run_id = p_run_id
                          AND m.ledger_entry_id = candidate.ledger_entry_id
                          AND m.status IN ('EXACT', 'PROBABLE')
                    ) OR EXISTS (
                        SELECT 1 FROM pg_temp.reconcile_manual_cache reserved
                        WHERE reserved.decision = 'MATCH'
                          AND reserved.ledger_entry_id = candidate.ledger_entry_id
                          AND reserved.external_transaction_id <> external_row.id
                    ) THEN
                        INSERT INTO reconcile_matches (
                            run_id, external_transaction_id, ledger_transaction_id,
                            ledger_entry_id, status, score, reason
                        ) VALUES (
                            p_run_id, external_row.id, candidate.ledger_transaction_id,
                            candidate.ledger_entry_id, 'CONFLICT', 200,
                            jsonb_build_object('strategy', 'linked_reversal',
                                               'conflict', 'candidate_already_matched')
                        );
                        inserted_count := inserted_count + 1;
                        CONTINUE;
                    END IF;
                    INSERT INTO reconcile_matches (
                        run_id, external_transaction_id, ledger_transaction_id,
                        ledger_entry_id, status, score, reason
                    ) VALUES (
                        p_run_id, external_row.id, candidate.ledger_transaction_id,
                        candidate.ledger_entry_id, 'EXACT', 200,
                        jsonb_build_object('strategy', 'linked_reversal',
                            'reverses_external_transaction_id',
                            external_row.reverses_external_transaction_id,
                            'reverses_ledger_transaction_id', reversed_ledger_transaction)
                    );
                    inserted_count := inserted_count + 1;
                    CONTINUE;
                ELSIF compatible_count > 1 THEN
                    FOR candidate IN
                        SELECT c.* FROM pg_temp.reconcile_candidate_cache c
                        WHERE c.metadata->>'reverses_transaction_id' = reversed_ledger_transaction::text
                          AND c.asset_identity = external_row.asset_identity
                          AND c.amount_units = signed_units
                    LOOP
                        INSERT INTO reconcile_matches (
                            run_id, external_transaction_id, ledger_transaction_id,
                            ledger_entry_id, status, score, reason
                        ) VALUES (
                            p_run_id, external_row.id, candidate.ledger_transaction_id,
                            candidate.ledger_entry_id, 'AMBIGUOUS', 200,
                            jsonb_build_object('strategy', 'linked_reversal',
                                               'candidate_count', compatible_count)
                        );
                        inserted_count := inserted_count + 1;
                    END LOOP;
                    CONTINUE;
                ELSIF candidate_count > 0 THEN
                    SELECT c.* INTO candidate
                    FROM pg_temp.reconcile_candidate_cache c
                    WHERE c.metadata->>'reverses_transaction_id' = reversed_ledger_transaction::text
                    LIMIT 1;
                    INSERT INTO reconcile_matches (
                        run_id, external_transaction_id, ledger_transaction_id,
                        ledger_entry_id, status, score, reason
                    ) VALUES (
                        p_run_id, external_row.id, candidate.ledger_transaction_id,
                        candidate.ledger_entry_id, 'CONFLICT', 200,
                        jsonb_build_object('strategy', 'linked_reversal',
                            'external_asset', external_row.asset_identity,
                            'ledger_asset', candidate.asset_identity,
                            'external_units', signed_units::text,
                            'ledger_units', candidate.amount_units::text)
                    );
                    inserted_count := inserted_count + 1;
                    CONTINUE;
                END IF;
            END IF;
        END IF;

        -- Level 1: a strong provider/reference mapping. A reused strong reference
        -- is never silently resolved by a lower-priority heuristic.
        SELECT count(*), count(*) FILTER (
            WHERE c.asset_identity = external_row.asset_identity
              AND c.amount_units = signed_units
        ) INTO candidate_count, compatible_count
        FROM pg_temp.reconcile_candidate_cache c
        WHERE (
            c.reference = ANY(reference_keys)
            OR c.metadata->>'external_transaction_id' = ANY(reference_keys)
            OR c.metadata->>'external_reference' = ANY(reference_keys)
            OR c.metadata->>'provider_reference' = ANY(reference_keys)
            OR c.metadata->>'txid' = ANY(reference_keys)
            OR (c.metadata->>'txid') || ':' || (c.metadata->>'output_index') = ANY(reference_keys)
            OR c.metadata->>'tx_hash' = ANY(reference_keys)
            OR (c.metadata->>'tx_hash') || ':' || (c.metadata->>'log_index') = ANY(reference_keys)
        );

        IF candidate_count > 0 THEN
            IF compatible_count = 1 THEN
                SELECT c.* INTO candidate
                FROM pg_temp.reconcile_candidate_cache c
                WHERE c.asset_identity = external_row.asset_identity
                  AND c.amount_units = signed_units
                  AND (
                    c.reference = ANY(reference_keys)
                    OR c.metadata->>'external_transaction_id' = ANY(reference_keys)
                    OR c.metadata->>'external_reference' = ANY(reference_keys)
                    OR c.metadata->>'provider_reference' = ANY(reference_keys)
                    OR c.metadata->>'txid' = ANY(reference_keys)
                    OR (c.metadata->>'txid') || ':' || (c.metadata->>'output_index') = ANY(reference_keys)
                    OR c.metadata->>'tx_hash' = ANY(reference_keys)
                    OR (c.metadata->>'tx_hash') || ':' || (c.metadata->>'log_index') = ANY(reference_keys)
                  ) LIMIT 1;
                IF EXISTS (
                    SELECT 1 FROM reconcile_matches m
                    WHERE m.run_id = p_run_id
                      AND m.ledger_entry_id = candidate.ledger_entry_id
                      AND m.status IN ('EXACT', 'PROBABLE')
                ) OR EXISTS (
                    SELECT 1 FROM pg_temp.reconcile_manual_cache reserved
                    WHERE reserved.decision = 'MATCH'
                      AND reserved.ledger_entry_id = candidate.ledger_entry_id
                      AND reserved.external_transaction_id <> external_row.id
                ) THEN
                    INSERT INTO reconcile_matches (
                        run_id, external_transaction_id, ledger_transaction_id,
                        ledger_entry_id, status, score, reason
                    ) VALUES (
                        p_run_id, external_row.id, candidate.ledger_transaction_id,
                        candidate.ledger_entry_id, 'CONFLICT', 150,
                        jsonb_build_object('strategy', 'explicit_reference',
                                           'conflict', 'candidate_already_matched')
                    );
                    inserted_count := inserted_count + 1;
                    CONTINUE;
                END IF;
                INSERT INTO reconcile_matches (
                    run_id, external_transaction_id, ledger_transaction_id, ledger_entry_id,
                    status, score, reason
                ) VALUES (
                    p_run_id, external_row.id, candidate.ledger_transaction_id,
                    candidate.ledger_entry_id, 'EXACT', 150,
                    jsonb_build_object('strategy', 'explicit_reference',
                        'reference', coalesce(external_row.external_reference,
                                              external_row.external_transaction_id),
                        'amount', 'exact', 'asset', 'exact')
                );
                inserted_count := inserted_count + 1;
            ELSIF compatible_count > 1 THEN
                FOR candidate IN
                    SELECT c.*
                    FROM pg_temp.reconcile_candidate_cache c
                    WHERE c.asset_identity = external_row.asset_identity
                      AND c.amount_units = signed_units
                      AND (c.reference = ANY(reference_keys)
                        OR c.metadata->>'external_transaction_id' = ANY(reference_keys)
                        OR c.metadata->>'external_reference' = ANY(reference_keys)
                        OR c.metadata->>'provider_reference' = ANY(reference_keys)
                        OR c.metadata->>'txid' = ANY(reference_keys)
                        OR (c.metadata->>'txid') || ':' || (c.metadata->>'output_index') = ANY(reference_keys)
                        OR c.metadata->>'tx_hash' = ANY(reference_keys)
                        OR (c.metadata->>'tx_hash') || ':' || (c.metadata->>'log_index') = ANY(reference_keys))
                LOOP
                    INSERT INTO reconcile_matches (
                        run_id, external_transaction_id, ledger_transaction_id, ledger_entry_id,
                        status, score, reason
                    ) VALUES (
                        p_run_id, external_row.id, candidate.ledger_transaction_id,
                        candidate.ledger_entry_id, 'AMBIGUOUS', 150,
                        jsonb_build_object('strategy', 'explicit_reference',
                                           'candidate_count', compatible_count)
                    );
                    inserted_count := inserted_count + 1;
                END LOOP;
            ELSE
                SELECT c.* INTO candidate
                FROM pg_temp.reconcile_candidate_cache c
                WHERE c.reference = ANY(reference_keys)
                   OR c.metadata->>'external_transaction_id' = ANY(reference_keys)
                   OR c.metadata->>'external_reference' = ANY(reference_keys)
                   OR c.metadata->>'provider_reference' = ANY(reference_keys)
                   OR c.metadata->>'txid' = ANY(reference_keys)
                   OR (c.metadata->>'txid') || ':' || (c.metadata->>'output_index') = ANY(reference_keys)
                   OR c.metadata->>'tx_hash' = ANY(reference_keys)
                   OR (c.metadata->>'tx_hash') || ':' || (c.metadata->>'log_index') = ANY(reference_keys)
                LIMIT 1;
                INSERT INTO reconcile_matches (
                    run_id, external_transaction_id, ledger_transaction_id, ledger_entry_id,
                    status, score, reason
                ) VALUES (
                    p_run_id, external_row.id, candidate.ledger_transaction_id,
                    candidate.ledger_entry_id, 'CONFLICT', 100,
                    jsonb_build_object('strategy', 'explicit_reference',
                        'external_asset', external_row.asset_identity,
                        'ledger_asset', candidate.asset_identity,
                        'external_units', signed_units::text,
                        'ledger_units', candidate.amount_units::text)
                );
                inserted_count := inserted_count + 1;
            END IF;
            CONTINUE;
        END IF;

        -- Level 2: exact asset + signed units within the configured window.
        -- A zero window is the safe default and disables this strategy.
        IF run_row.matching_time_window > interval '0 seconds' THEN
            SELECT count(*) INTO candidate_count
            FROM pg_temp.reconcile_candidate_cache c
            WHERE c.asset_identity = external_row.asset_identity
              AND c.amount_units = signed_units
              AND abs(extract(epoch FROM (c.event_at - external_row.event_at))) * interval '1 second'
                    <= run_row.matching_time_window
              AND NOT EXISTS (
                  SELECT 1 FROM reconcile_matches m
                  WHERE m.run_id = p_run_id AND m.ledger_entry_id = c.ledger_entry_id
                    AND m.status IN ('EXACT', 'PROBABLE')
              )
              AND NOT EXISTS (
                  SELECT 1 FROM pg_temp.reconcile_manual_cache reserved
                  WHERE reserved.decision = 'MATCH'
                    AND reserved.ledger_entry_id = c.ledger_entry_id
                    AND reserved.external_transaction_id <> external_row.id
              );
            IF candidate_count = 1 THEN
                SELECT c.* INTO candidate
                FROM pg_temp.reconcile_candidate_cache c
                WHERE c.asset_identity = external_row.asset_identity
                  AND c.amount_units = signed_units
                  AND abs(extract(epoch FROM (c.event_at - external_row.event_at))) * interval '1 second'
                        <= run_row.matching_time_window
                  AND NOT EXISTS (
                      SELECT 1 FROM reconcile_matches m
                      WHERE m.run_id = p_run_id AND m.ledger_entry_id = c.ledger_entry_id
                        AND m.status IN ('EXACT', 'PROBABLE')
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM pg_temp.reconcile_manual_cache reserved
                      WHERE reserved.decision = 'MATCH'
                        AND reserved.ledger_entry_id = c.ledger_entry_id
                        AND reserved.external_transaction_id <> external_row.id
                  ) LIMIT 1;
                INSERT INTO reconcile_matches (
                    run_id, external_transaction_id, ledger_transaction_id, ledger_entry_id,
                    status, score, reason
                ) VALUES (
                    p_run_id, external_row.id, candidate.ledger_transaction_id,
                    candidate.ledger_entry_id, 'EXACT',
                    50 + reconcile_timestamp_score(
                        (extract(epoch FROM (candidate.event_at - external_row.event_at)) * 1000)::bigint),
                    jsonb_build_object('strategy', 'exact_amount_time', 'asset', 'exact',
                        'amount', 'exact', 'timestamp_delta_ms',
                        (extract(epoch FROM (candidate.event_at - external_row.event_at)) * 1000)::bigint)
                );
                inserted_count := inserted_count + 1;
                CONTINUE;
            ELSIF candidate_count > 1 THEN
                FOR candidate IN
                    SELECT c.*
                    FROM pg_temp.reconcile_candidate_cache c
                    WHERE c.asset_identity = external_row.asset_identity
                      AND c.amount_units = signed_units
                      AND abs(extract(epoch FROM (c.event_at - external_row.event_at))) * interval '1 second'
                            <= run_row.matching_time_window
                      AND NOT EXISTS (
                          SELECT 1 FROM reconcile_matches m
                          WHERE m.run_id = p_run_id
                            AND m.ledger_entry_id = c.ledger_entry_id
                            AND m.status IN ('EXACT', 'PROBABLE')
                      )
                      AND NOT EXISTS (
                          SELECT 1 FROM pg_temp.reconcile_manual_cache reserved
                          WHERE reserved.decision = 'MATCH'
                            AND reserved.ledger_entry_id = c.ledger_entry_id
                            AND reserved.external_transaction_id <> external_row.id
                      )
                LOOP
                    INSERT INTO reconcile_matches (
                        run_id, external_transaction_id, ledger_transaction_id, ledger_entry_id,
                        status, score, reason
                    ) VALUES (
                        p_run_id, external_row.id, candidate.ledger_transaction_id,
                        candidate.ledger_entry_id, 'AMBIGUOUS', 50,
                        jsonb_build_object('strategy', 'exact_amount_time',
                                           'candidate_count', candidate_count)
                    );
                    inserted_count := inserted_count + 1;
                END LOOP;
                CONTINUE;
            END IF;
        END IF;

        INSERT INTO reconcile_matches (run_id, external_transaction_id, status, reason)
        VALUES (p_run_id, external_row.id, 'UNMATCHED_EXTERNAL',
                jsonb_build_object('strategy', 'none', 'reason', 'no deterministic candidate'));
        inserted_count := inserted_count + 1;
    END LOOP;

    -- Preserve all ledger-side absences as explicit results.
    FOR candidate IN
        SELECT c.*
        FROM pg_temp.reconcile_candidate_cache c
        WHERE NOT EXISTS (
            SELECT 1 FROM reconcile_matches m
            WHERE m.run_id = p_run_id AND m.ledger_entry_id = c.ledger_entry_id
              AND m.status IN ('EXACT', 'PROBABLE', 'AMBIGUOUS', 'CONFLICT')
        )
    LOOP
        INSERT INTO reconcile_matches (
            run_id, ledger_transaction_id, ledger_entry_id, status, reason
        ) VALUES (
            p_run_id, candidate.ledger_transaction_id, candidate.ledger_entry_id,
            'UNMATCHED_LEDGER', jsonb_build_object('strategy', 'none',
                'asset', candidate.asset_identity, 'units', candidate.amount_units::text)
        );
        inserted_count := inserted_count + 1;
    END LOOP;
    RETURN inserted_count;
END
$body$;

CREATE FUNCTION reconcile_transactions(account_id uuid, as_of timestamptz DEFAULT clock_timestamp())
RETURNS SETOF reconcile_matches
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    new_run uuid;
BEGIN
    new_run := _reconcile_execute_run_rust(account_id, 'TRANSACTIONS', as_of);
    RETURN QUERY SELECT * FROM reconcile_matches WHERE run_id = new_run ORDER BY created_at, id;
END
$body$;

CREATE FUNCTION reconcile_full(account_id uuid, as_of timestamptz DEFAULT clock_timestamp())
RETURNS TABLE(
    run_id uuid,
    balance_status reconcile_balance_status,
    exact_matches bigint,
    ambiguous_matches bigint,
    unmatched_external bigint,
    unmatched_ledger bigint,
    conflicts bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    new_run uuid;
BEGIN
    new_run := _reconcile_execute_run_rust(account_id, 'FULL', as_of);
    RETURN QUERY
    SELECT new_run, b.status,
           count(*) FILTER (WHERE m.status = 'EXACT'),
           count(*) FILTER (WHERE m.status = 'AMBIGUOUS'),
           count(*) FILTER (WHERE m.status = 'UNMATCHED_EXTERNAL'),
           count(*) FILTER (WHERE m.status = 'UNMATCHED_LEDGER'),
           count(*) FILTER (WHERE m.status = 'CONFLICT')
    FROM reconcile_balance_results b
    LEFT JOIN reconcile_matches m ON m.run_id = b.run_id
    WHERE b.run_id = new_run
    GROUP BY b.status;
END
$body$;

CREATE FUNCTION reconcile_run(run_id uuid)
RETURNS reconcile_runs
LANGUAGE sql STABLE PARALLEL RESTRICTED
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog
AS 'SELECT * FROM reconcile_runs WHERE id = run_id';

CREATE FUNCTION reconcile_results(run_id uuid)
RETURNS TABLE(result_kind text, result jsonb)
LANGUAGE sql STABLE PARALLEL RESTRICTED
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog
AS $body$
    SELECT 'balance', to_jsonb(b) FROM reconcile_balance_results b WHERE b.run_id = $1
    UNION ALL
    SELECT 'match', to_jsonb(m) FROM reconcile_matches m WHERE m.run_id = $1
$body$;

CREATE FUNCTION reconcile_match_manual(
    external_transaction uuid,
    ledger_transaction uuid,
    reason text,
    actor text DEFAULT session_user
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    external_row reconcile_external_transactions%ROWTYPE;
    account_row reconcile_accounts%ROWTYPE;
    candidate record;
    result uuid;
    signed_units numeric;
BEGIN
    SELECT * INTO external_row FROM reconcile_external_transactions
    WHERE id = external_transaction FOR UPDATE;
    IF external_row.id IS NULL THEN
        RAISE EXCEPTION 'external transaction % does not exist', external_transaction
            USING ERRCODE = 'PGR01', DETAIL = 'RECONCILE_ACCOUNT_NOT_FOUND';
    END IF;
    signed_units := CASE external_row.direction WHEN 'CREDIT' THEN external_row.amount_units
                                                ELSE -external_row.amount_units END;
    SELECT * INTO account_row FROM reconcile_accounts WHERE id = external_row.reconcile_account_id;
    SELECT c.* INTO candidate
    FROM _reconcile_ledger_candidates(
        account_row.ledger_account_id, 'infinity'::timestamptz, clock_timestamp()
    ) c
    WHERE c.ledger_transaction_id = ledger_transaction
      AND c.asset_identity = external_row.asset_identity
      AND c.amount_units = signed_units
    ORDER BY c.ledger_entry_id
    LIMIT 1;
    IF candidate.ledger_transaction_id IS NULL THEN
        RAISE EXCEPTION 'manual match ledger transaction is absent or has incompatible asset/amount'
            USING ERRCODE = 'PGR08', DETAIL = 'RECONCILE_INVALID_MANUAL_MATCH';
    END IF;
    IF actor IS DISTINCT FROM session_user::text THEN
        RAISE EXCEPTION 'manual decision actor must be the authenticated database session user'
            USING ERRCODE = 'PGR08', DETAIL = 'RECONCILE_INVALID_MANUAL_MATCH';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'pg_reconcile:manual:ledger-entry:' || candidate.ledger_entry_id::text, 0
    ));
    IF EXISTS (
        SELECT 1
        FROM (
            SELECT DISTINCT ON (d.external_transaction_id)
                   d.external_transaction_id, d.ledger_entry_id, d.decision
            FROM reconcile_manual_decisions d
            ORDER BY d.external_transaction_id, d.created_at DESC, d.id DESC
        ) active
        WHERE active.decision = 'MATCH'
          AND active.ledger_entry_id = candidate.ledger_entry_id
          AND active.external_transaction_id <> external_transaction
    ) THEN
        RAISE EXCEPTION 'ledger entry already has an active manual mapping'
            USING ERRCODE = 'PGR08', DETAIL = 'RECONCILE_INVALID_MANUAL_MATCH';
    END IF;
    INSERT INTO reconcile_manual_decisions (
        external_transaction_id, ledger_transaction_id, ledger_entry_id,
        decision, reason, actor
    ) VALUES (
        external_transaction, ledger_transaction, candidate.ledger_entry_id,
        'MATCH', reason, session_user::text
    ) RETURNING id INTO result;
    RETURN result;
END
$body$;

CREATE FUNCTION reconcile_mark_external_unmatched(
    external_transaction uuid,
    reason text,
    actor text DEFAULT session_user
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    result uuid;
BEGIN
    PERFORM 1 FROM reconcile_external_transactions WHERE id = external_transaction FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'external transaction % does not exist', external_transaction
            USING ERRCODE = 'PGR01', DETAIL = 'RECONCILE_ACCOUNT_NOT_FOUND';
    END IF;
    IF actor IS DISTINCT FROM session_user::text THEN
        RAISE EXCEPTION 'manual decision actor must be the authenticated database session user'
            USING ERRCODE = 'PGR08', DETAIL = 'RECONCILE_INVALID_MANUAL_MATCH';
    END IF;
    INSERT INTO reconcile_manual_decisions (
        external_transaction_id, decision, reason, actor
    ) VALUES (
        external_transaction, 'MARK_UNMATCHED_EXTERNAL', reason, session_user::text
    ) RETURNING id INTO result;
    RETURN result;
END
$body$;

CREATE FUNCTION reconcile_all(
    external_system text,
    as_of timestamptz DEFAULT clock_timestamp()
) RETURNS TABLE(account_id uuid, run_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    account_row record;
    summary record;
BEGIN
    FOR account_row IN
        SELECT id FROM reconcile_accounts a
        WHERE a.enabled AND a.external_system = reconcile_all.external_system
        ORDER BY a.id
    LOOP
        SELECT * INTO summary FROM reconcile_full(account_row.id, as_of);
        account_id := account_row.id;
        run_id := summary.run_id;
        RETURN NEXT;
    END LOOP;
END
$body$;

CREATE FUNCTION reconcile_all_enabled(as_of timestamptz DEFAULT clock_timestamp())
RETURNS TABLE(account_id uuid, run_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog, pg_temp
AS $body$
DECLARE
    account_row record;
    summary record;
BEGIN
    FOR account_row IN SELECT id FROM reconcile_accounts WHERE enabled ORDER BY id LOOP
        SELECT * INTO summary FROM reconcile_full(account_row.id, as_of);
        account_id := account_row.id;
        run_id := summary.run_id;
        RETURN NEXT;
    END LOOP;
END
$body$;

CREATE FUNCTION reconcile_validate()
RETURNS TABLE(check_name text, status text, violations bigint)
LANGUAGE sql STABLE PARALLEL RESTRICTED
SECURITY DEFINER
SET search_path = @extschema@, pg_catalog
AS 'SELECT * FROM _reconcile_validate_rust()';
