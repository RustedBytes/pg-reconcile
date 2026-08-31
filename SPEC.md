# Technical Specification: `pg-reconcile`

## 1. Purpose

`pg_reconcile` is a PostgreSQL extension implemented with Rust and `pgrx` for reconciling internal ledger balances and transaction records against balances and transactions reported by external financial systems.

The extension is intended for:

* bank accounts;
* payment providers;
* cryptocurrency wallets;
* blockchain addresses;
* custodians;
* liquidity providers;
* settlement accounts;
* cash accounts;
* other external systems that represent assets also tracked in `pg_ledger`.

`pg_reconcile` must answer two distinct questions:

1. **Balance reconciliation**

> Does the balance recorded in `pg_ledger` match the balance reported by the external source at a specific time?

2. **Transaction reconciliation**

> Can external transactions be matched to internal ledger transactions, and which items remain unmatched, duplicated, conflicting, or ambiguous?

The extension must not:

* contact banks or blockchains;
* make HTTP/DNS requests;
* fetch blockchain data;
* modify external systems;
* create FX prices;
* perform customer-facing exchange operations;
* alter historical ledger entries.

External data is ingested by the application and passed to `pg_reconcile`.

---

# 2. Compatibility

Initial target:

```text
PostgreSQL: 14–18
Rust:       1.96+
pgrx:       0.19.2
```

Extension name:

```sql
CREATE EXTENSION pg_reconcile;
```

Package:

```toml
[package]
name = "pg_reconcile"
version = "0.1.0"
edition = "2024"
rust-version = "1.96"

[dependencies]
pgrx = "=0.19.2"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
sha2 = "0.11"
uuid = { version = "1", features = ["serde", "v7"] }
num-bigint = { version = "0.4", features = ["serde"] }
num-traits = "0.2"
```

Support the same PostgreSQL feature matrix as the existing RustedBytes extensions:

```text
pg14
pg15
pg16
pg17
pg18
```

The extension should have no hard Rust dependency on `pg_ledger`, `pg_money`, or `pg_cryptocurrency`.

Optional SQL-level interoperability should be enabled dynamically.

---

# 3. Position in the stack

```text
External systems
      │
      ├── banks
      ├── payment processors
      ├── blockchain nodes/indexers
      ├── custodians
      └── liquidity providers
      │
      ▼
Rust collectors / webhooks / importers
      │
      ▼
pg_reconcile
      │
      ├──────── external observations
      ├──────── matching
      ├──────── discrepancies
      └──────── reconciliation runs
      │
      ▼
pg_ledger
```

Responsibilities:

```text
pg_money
    precise fiat amounts

pg_cryptocurrency
    precise blockchain asset identities and amounts

pg_fx
    prices and quotes

pg_ledger
    internal accounting truth

pg_reconcile
    comparison of accounting truth with external reality
```

---

# 4. Design principles

The implementation must follow these principles.

## 4.1 Append-only evidence

External observations must be immutable.

Once an external balance or external transaction is ingested, its original representation must not be edited.

Corrections are represented by:

* another observation;
* supersession;
* explicit invalidation metadata;
* another reconciliation run.

Do not overwrite historical evidence.

## 4.2 Reconciliation is reproducible

Every reconciliation result must record enough information to determine:

* which internal ledger state was examined;
* which external observations were examined;
* which matching algorithm/version was used;
* what tolerance policy was applied;
* when the reconciliation ran.

## 4.3 External systems are not trusted blindly

Imported data should retain:

```text
source
external identifier
observed time
received time
raw metadata
normalization metadata
```

## 4.4 Ledger history is not mutated

`pg_reconcile` must never modify `ledger_entries` or historical ledger transactions.

A discrepancy may result in an application later posting an adjustment transaction, but that is outside the reconciliation engine itself.

## 4.5 Exact arithmetic only

No floating point.

Balances and transaction amounts must use exact smallest-unit integers internally.

---

# 5. Core concepts

The extension should model five main concepts:

```text
reconciliation account
external balance observation
external transaction
reconciliation run
reconciliation result/match
```

---

# 6. Reconciliation accounts

A reconciliation account maps an internal ledger account to an external financial account.

Examples:

```text
ledger:
    treasury:bank:USD

external:
    Monobank business account ****1234
```

or:

```text
ledger:
    hotwallet:BTC

external:
    bc1q...
```

Table:

```sql
CREATE TABLE reconcile_accounts (
    id uuid PRIMARY KEY,

    name text NOT NULL,

    ledger_account_id uuid NOT NULL,

    asset_identity text NOT NULL,

    external_system text NOT NULL,
    external_account_id text NOT NULL,

    account_kind reconcile_account_kind NOT NULL,

    balance_mode reconcile_balance_mode NOT NULL,

    tolerance_units numeric NOT NULL DEFAULT 0
        CHECK (tolerance_units >= 0),

    enabled boolean NOT NULL DEFAULT true,

    metadata jsonb,

    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,

    UNIQUE (external_system, external_account_id, asset_identity)
);
```

Suggested account kinds:

```rust
enum ReconcileAccountKind {
    Bank,
    BlockchainWallet,
    Custodian,
    PaymentProvider,
    LiquidityProvider,
    Cash,
    Other,
}
```

Expose as PostgreSQL enum or pgrx base type.

---

# 7. Balance modes

External systems expose different balance concepts.

For example a bank may report:

```text
book balance
available balance
pending balance
```

A crypto custodian may report:

```text
total
available
locked
```

Therefore reconciliation accounts need an explicit mode.

Suggested enum:

```rust
enum ReconcileBalanceMode {
    Book,
    Available,
    Settled,
    Total,
}
```

Initial v1 can support:

```text
BOOK
AVAILABLE
SETTLED
TOTAL
```

The configured mode identifies which external balance field corresponds to the mapped ledger account.

---

# 8. Asset identity

`pg_reconcile` should use a canonical asset representation compatible with `pg_ledger`.

Examples:

```text
USD
EUR
UAH

BTC@bitcoin
ETH@ethereum
USDT@ethereum
USDT@tron
```

Do not identify crypto assets only by ticker.

These must remain distinct:

```text
USDT@ethereum
USDT@tron
```

Unknown assets may support explicit scales:

```text
TOK@private-chain/8
```

The extension may implement:

```text
reconcile_asset
```

or simply use validated canonical text in v1.

Preferred long-term type:

```rust
struct ReconcileAsset {
    identity: String,
    scale: u32,
}
```

Optional adapters:

```sql
reconcile_asset(ledger_asset)
reconcile_asset(money_with_currency)
reconcile_asset(crypto_asset)
```

---

# 9. External balance observations

Table:

```sql
CREATE TABLE reconcile_balance_observations (
    id uuid PRIMARY KEY,

    reconcile_account_id uuid NOT NULL
        REFERENCES reconcile_accounts(id),

    balance_units numeric NOT NULL,

    observed_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL,

    external_reference text,

    source_sequence text,

    payload_hash bytea,

    metadata jsonb,

    created_at timestamptz NOT NULL
);
```

Important timestamps:

```text
observed_at
    when the external system says the balance applied

received_at
    when our system received the observation

created_at
    when PostgreSQL persisted it
```

Example:

```sql
SELECT reconcile_balance_insert(
    account_id      => ...,
    balance         => 'USD 10542.32',
    observed_at     => '2026-08-31T14:00:00Z',
    external_ref    => 'statement:2026-08-31'
);
```

For crypto:

```sql
SELECT reconcile_balance_insert(
    account_id      => ...,
    balance         => '1.42510000 BTC',
    observed_at     => ...,
    external_ref    => 'bitcoin:block:912345'
);
```

Duplicate external observations should be rejected or idempotently returned using:

```text
external_reference
```

and/or a canonical payload hash.

---

# 10. External transactions

Table:

```sql
CREATE TABLE reconcile_external_transactions (
    id uuid PRIMARY KEY,

    reconcile_account_id uuid NOT NULL
        REFERENCES reconcile_accounts(id),

    external_transaction_id text NOT NULL,

    amount_units numeric NOT NULL,

    direction reconcile_direction NOT NULL,

    event_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL,

    status reconcile_external_status NOT NULL,

    counterparty text,
    description text,

    external_reference text,

    payload_hash bytea,

    metadata jsonb,

    created_at timestamptz NOT NULL,

    UNIQUE (
        reconcile_account_id,
        external_transaction_id
    )
);
```

Direction:

```rust
enum ReconcileDirection {
    Credit,
    Debit,
}
```

Status:

```rust
enum ReconcileExternalStatus {
    Pending,
    Settled,
    Reversed,
    Failed,
}
```

Store the amount internally as signed or unsigned smallest units.

Recommended API convention:

```text
direction + positive units
```

rather than allowing users to provide inconsistent signs.

---

# 11. Blockchain-specific transaction metadata

The generic table must support blockchain-specific evidence through metadata.

Example:

```json
{
  "network": "bitcoin",
  "txid": "...",
  "block_height": 912345,
  "block_hash": "...",
  "confirmations": 8,
  "address": "bc1q...",
  "output_index": 1
}
```

For Ethereum/token networks:

```json
{
  "network": "ethereum",
  "tx_hash": "...",
  "block_number": 24123456,
  "log_index": 17,
  "contract": "0x...",
  "from": "0x...",
  "to": "0x..."
}
```

No blockchain-specific schema is required in v1 unless query performance justifies dedicated columns later.

---

# 12. Reconciliation runs

Each reconciliation must create an immutable run record.

```sql
CREATE TABLE reconcile_runs (
    id uuid PRIMARY KEY,

    reconcile_account_id uuid NOT NULL
        REFERENCES reconcile_accounts(id),

    reconciliation_type reconcile_run_type NOT NULL,

    as_of timestamptz NOT NULL,

    started_at timestamptz NOT NULL,
    completed_at timestamptz,

    status reconcile_run_status NOT NULL,

    algorithm_version text NOT NULL,

    tolerance_units numeric NOT NULL,

    metadata jsonb
);
```

Types:

```rust
enum ReconcileRunType {
    Balance,
    Transactions,
    Full,
}
```

Statuses:

```rust
enum ReconcileRunStatus {
    Running,
    Completed,
    Failed,
}
```

---

# 13. Balance reconciliation

The balance reconciliation algorithm compares:

```text
internal ledger balance at as_of

vs.

latest qualifying external balance observation
at or before as_of
```

The result is:

```text
difference =
    external_balance - ledger_balance
```

Example:

```text
Ledger:
    1,004,200.00 USD

External:
    1,004,199.83 USD

Difference:
    -0.17 USD
```

The result table:

```sql
CREATE TABLE reconcile_balance_results (
    id uuid PRIMARY KEY,

    run_id uuid NOT NULL
        REFERENCES reconcile_runs(id),

    external_observation_id uuid NOT NULL,

    ledger_balance_units numeric NOT NULL,
    external_balance_units numeric NOT NULL,

    difference_units numeric NOT NULL,

    tolerance_units numeric NOT NULL,

    status reconcile_balance_status NOT NULL,

    created_at timestamptz NOT NULL
);
```

Statuses:

```rust
enum ReconcileBalanceStatus {
    Matched,
    WithinTolerance,
    Mismatch,
    MissingExternalObservation,
}
```

Rules:

```text
difference == 0
    MATCHED

abs(difference) <= tolerance
    WITHIN_TOLERANCE

otherwise
    MISMATCH
```

---

# 14. Historical ledger balance

`pg_reconcile` must not compare a historical external balance against the current cached ledger balance.

It must retrieve:

```text
ledger balance as of observation time
```

Possible integration path with `pg_ledger`:

```sql
ledger_balance_at(account_id, timestamptz)
```

If that function does not exist, add an optional adapter to reconstruct it from ledger entries.

Recommended addition to `pg_ledger` if absent:

```sql
ledger_balance_at(
    account_id uuid,
    at timestamptz
) RETURNS ledger_amount
```

The reconciliation result should record the exact ledger transaction/entry boundary used where possible.

---

# 15. Transaction matching

The extension must support matching external transactions to internal ledger entries or ledger transactions.

Possible match criteria:

```text
external reference
amount
asset
timestamp
direction
counterparty
provider reference
blockchain txid
metadata
```

Matching should be deterministic and scored.

Suggested scoring model:

```text
exact external_reference       +100
exact transaction reference    +100
exact amount                    +50
exact asset                     mandatory
timestamp <= 2 sec             +30
timestamp <= 30 sec            +20
timestamp <= 5 min             +10
counterparty match              +20
metadata reference match        +50
```

Do not use fuzzy matching silently.

---

# 16. Match statuses

```rust
enum ReconcileMatchStatus {
    Exact,
    Probable,
    Ambiguous,
    UnmatchedExternal,
    UnmatchedLedger,
    Conflict,
}
```

Semantics:

```text
EXACT
    uniquely identified using strong deterministic evidence

PROBABLE
    uniquely best candidate above configured confidence threshold

AMBIGUOUS
    multiple candidates satisfy the rule

UNMATCHED_EXTERNAL
    external transaction with no matching ledger item

UNMATCHED_LEDGER
    ledger item with no matching external transaction

CONFLICT
    same reference but incompatible asset/amount/state
```

---

# 17. Matches table

```sql
CREATE TABLE reconcile_matches (
    id uuid PRIMARY KEY,

    run_id uuid NOT NULL
        REFERENCES reconcile_runs(id),

    external_transaction_id uuid,

    ledger_transaction_id uuid,
    ledger_entry_id uuid,

    status reconcile_match_status NOT NULL,

    score integer,

    reason jsonb NOT NULL,

    created_at timestamptz NOT NULL
);
```

Example `reason`:

```json
{
  "external_reference": "exact",
  "amount": "exact",
  "timestamp_delta_ms": 823,
  "counterparty": "not_checked"
}
```

---

# 18. Matching hierarchy

Preferred matching order:

### Level 1: explicit mapping

```text
external transaction ID
    ↔
ledger metadata external reference
```

Examples:

```text
bank_transaction_id
payment_provider_transaction_id
blockchain txid + output/log index
```

If an explicit unique mapping exists, no heuristic search is required.

### Level 2: deterministic composite match

Example:

```text
same asset
same signed amount
event_at within configured window
same account
```

### Level 3: scored candidate matching

Only used if deterministic matching fails.

### Level 4: unmatched

Do not invent a match below threshold.

---

# 19. Manual reconciliation

Operators need to resolve ambiguous cases.

Expose:

```sql
reconcile_match_manual(
    external_transaction,
    ledger_transaction,
    reason
)
```

and:

```sql
reconcile_mark_external_unmatched(...)
```

Manual decisions must themselves be immutable audit records.

Do not overwrite automatic results.

Create:

```sql
CREATE TABLE reconcile_manual_decisions (
    id uuid PRIMARY KEY,

    external_transaction_id uuid,
    ledger_transaction_id uuid,

    decision reconcile_manual_decision NOT NULL,

    reason text NOT NULL,

    actor text NOT NULL,

    created_at timestamptz NOT NULL
);
```

---

# 20. Reversals

External systems frequently reverse transactions.

Example:

```text
T1 +100 USD
T2 -100 USD reversal
```

The reconciliation engine should preserve both records.

An external transaction may contain:

```text
reverses_external_transaction_id
```

or this may be inferred from provider metadata.

The engine should match a reversal to a `pg_ledger` reversal transaction where possible.

Never delete the original transaction.

---

# 21. Pending vs settled transactions

A bank/card/blockchain transaction may appear first as pending and later become settled.

Do not mutate the original external observation.

Recommended model:

```text
external logical transaction
    ├── observation 1: PENDING
    └── observation 2: SETTLED
```

For v1 this can be represented by multiple immutable external rows connected through:

```text
external_reference
supersedes_id
```

Recommended field:

```sql
supersedes_id uuid
    REFERENCES reconcile_external_transactions(id)
```

---

# 22. Reconciliation API

Minimum public API:

```text
reconcile_create_account()
reconcile_account()

reconcile_balance_insert()
reconcile_external_transaction_insert()

reconcile_balance()
reconcile_transactions()
reconcile_full()

reconcile_run()
reconcile_results()

reconcile_match_manual()

reconcile_validate()
```

---

# 23. Example: create bank reconciliation account

```sql
SELECT reconcile_create_account(
    name                => 'treasury-monobank-usd',
    ledger_account_id   => :ledger_account,
    asset               => 'USD',
    external_system     => 'monobank',
    external_account_id => 'account-123',
    account_kind        => 'BANK',
    balance_mode        => 'BOOK',
    tolerance           => 'USD 0.01'
);
```

---

# 24. Example: ingest bank balance

```sql
SELECT reconcile_balance_insert(
    reconcile_account_id => :account_id,
    balance              => 'USD 1004199.83',
    observed_at          => '2026-08-31T12:00:00Z',
    external_reference   => 'statement:2026-08-31:12:00'
);
```

---

# 25. Example: execute balance reconciliation

```sql
SELECT *
FROM reconcile_balance(
    account_id => :account_id,
    as_of      => '2026-08-31T12:00:00Z'
);
```

Possible result:

```text
ledger_balance      USD 1004200.00
external_balance    USD 1004199.83
difference          USD -0.17
tolerance           USD 0.01
status              MISMATCH
```

---

# 26. Example: blockchain reconciliation

Mapped internal account:

```text
hotwallet:USDT:tron
```

External account:

```text
TRON address
```

Observation:

```sql
SELECT reconcile_balance_insert(
    account_id         => :tron_wallet,
    balance            => '250000.123456 USDT@tron',
    observed_at        => clock_timestamp(),
    external_reference => 'tron:block:76452211'
);
```

Result:

```text
ledger:
    250000.123456 USDT@tron

external:
    250000.123456 USDT@tron

difference:
    0

status:
    MATCHED
```

---

# 27. Reconciliation batches

Support multiple accounts:

```sql
SELECT *
FROM reconcile_all(
    external_system => 'monobank',
    as_of            => clock_timestamp()
);
```

And:

```sql
SELECT *
FROM reconcile_all_enabled();
```

Large runs should execute account-by-account instead of holding locks across the entire provider.

---

# 28. Concurrency

Reconciliation should generally be read-heavy and should avoid locking ledger accounts.

External ingestion must be idempotent.

Use unique keys such as:

```text
provider + external account + external transaction ID
```

Concurrent duplicate imports must produce only one canonical record.

Manual resolutions require row-level locking on the unresolved case.

---

# 29. Isolation

Balance reconciliation should use one consistent database snapshot.

For a single reconciliation run:

```text
read ledger state
read external observation
calculate comparison
persist result
```

must occur transactionally.

If strong historical consistency is required, callers may execute under:

```sql
REPEATABLE READ
```

The extension should document this.

---

# 30. Tolerance policies

Tolerance is asset-specific.

Examples:

```text
USD:
    $0.01

BTC:
    1 satoshi

USDT:
    1 micro-unit

some banks:
    $0.00
```

Never define reconciliation tolerance as floating percentage by default.

Primary representation:

```text
absolute smallest units
```

Optional future support:

```text
absolute tolerance
relative tolerance
both
```

---

# 31. Reconciliation issues

Provide a unified operational view:

```sql
reconcile_issues
```

Example output:

```text
account
issue_type
asset
amount
external_reference
age
severity
run_id
```

Issue types:

```text
BALANCE_MISMATCH
EXTERNAL_UNMATCHED
LEDGER_UNMATCHED
AMBIGUOUS_MATCH
DUPLICATE_EXTERNAL
CONFLICTING_REFERENCE
STALE_EXTERNAL_BALANCE
```

---

# 32. Severity

Suggested severity enum:

```text
INFO
WARNING
ERROR
CRITICAL
```

Examples:

```text
within tolerance
    INFO

one unmatched recent payment
    WARNING

balance mismatch
    ERROR

large unexplained treasury deficit
    CRITICAL
```

The extension should not decide business-specific monetary severity thresholds in v1.

Applications may configure that later.

---

# 33. Validation API

Provide:

```sql
SELECT * FROM reconcile_validate();
```

Checks should include:

```text
all reconcile accounts reference valid ledger accounts

asset identities match mapped ledger account assets

no malformed external transactions

no conflicting duplicate external references

all completed runs have results

all manual matches reference valid entities

no match points to incompatible assets

no duplicate active exact mappings

reconciliation result arithmetic is internally consistent
```

Example:

```text
check                         status   violations
--------------------------------------------------
account_mapping               OK       0
asset_consistency             OK       0
external_identity_uniqueness  OK       0
match_consistency             OK       0
run_completeness              OK       0
balance_math                  OK       0
```

---

# 34. Security model

The extension should be secure-by-default.

Unlike earlier extension defaults, do not grant table reads to `PUBLIC`.

Recommended:

```text
PUBLIC:
    no table access
    no mutation functions
```

Suggested roles:

```text
reconcile_reader
reconcile_ingestor
reconcile_operator
reconcile_admin
```

Permissions:

```text
reconcile_reader
    read runs/results/issues

reconcile_ingestor
    insert external observations

reconcile_operator
    execute reconciliation
    add manual resolution decisions

reconcile_admin
    configure mappings and policies
```

Internal functions must not be executable by `PUBLIC`.

Mutation entry points requiring elevated internal table access should use:

```text
SECURITY DEFINER
```

with a pinned extension schema and `pg_catalog` search path.

---

# 35. Sensitive metadata

External metadata may contain:

```text
bank account identifiers
counterparty names
wallet addresses
payment provider references
customer references
```

Therefore:

```text
metadata must not be exposed publicly
```

Provide optional sanitized views if useful.

---

# 36. Idempotency

All ingestion functions must support idempotency.

Example:

```sql
SELECT reconcile_external_transaction_insert(
    ...,
    idempotency_key => 'monobank:tx:123456'
);
```

Behavior:

```text
same key + same canonical payload
    return existing record

same key + different canonical payload
    raise IDEMPOTENCY_CONFLICT
```

Use SHA-256 fingerprinting similar to `pg_ledger`.

---

# 37. Stable error classes

Define stable machine-readable error conditions.

Examples:

```text
RECONCILE_ACCOUNT_NOT_FOUND
RECONCILE_ASSET_MISMATCH
RECONCILE_EXTERNAL_DUPLICATE
RECONCILE_IDEMPOTENCY_CONFLICT
RECONCILE_NO_EXTERNAL_BALANCE
RECONCILE_STALE_EXTERNAL_BALANCE
RECONCILE_AMBIGUOUS_MATCH
RECONCILE_INVALID_MANUAL_MATCH
RECONCILE_LEDGER_ADAPTER_MISSING
```

Application code must not need to parse error strings.

---

# 38. Optional `pg_ledger` interoperability

If `pg_ledger` exists when `pg_reconcile` is installed:

```text
enable ledger adapters automatically
```

If installed later:

```sql
SELECT reconcile_enable_pg_ledger();
```

Adapters should provide internal helpers to:

```text
get ledger account asset

get current ledger balance

get historical ledger balance

query candidate transactions

query candidate entries

detect ledger reversals
```

Do not directly alter ledger data.

---

# 39. Optional `pg_money` interoperability

If available:

```sql
SELECT reconcile_balance_insert(
    account,
    'USD 100.00'::money_with_currency,
    ...
);
```

Adapters:

```text
money_with_currency → reconcile amount
money_minor → reconcile amount
```

If installed later:

```sql
SELECT reconcile_enable_pg_money();
```

---

# 40. Optional `pg_cryptocurrency` interoperability

Adapters:

```text
crypto_amount → reconcile amount
crypto_asset → reconcile asset
```

Example:

```sql
SELECT reconcile_balance_insert(
    account,
    '1.20000000 BTC'::crypto_amount,
    ...
);
```

Enable later:

```sql
SELECT reconcile_enable_pg_cryptocurrency();
```

---

# 41. No dependency on `pg_fx`

`pg_reconcile` does not require pricing to determine whether an account balances.

Reconciliation is per asset.

Do not convert:

```text
BTC discrepancy → USD
```

inside the core engine.

Applications may use `pg_fx` separately to calculate economic exposure.

---

# 42. Indexes

Minimum indexes:

```sql
reconcile_balance_observations (
    reconcile_account_id,
    observed_at DESC
)

reconcile_external_transactions (
    reconcile_account_id,
    event_at
)

reconcile_external_transactions (
    external_transaction_id
)

reconcile_runs (
    reconcile_account_id,
    started_at DESC
)

reconcile_matches (
    external_transaction_id
)

reconcile_matches (
    ledger_transaction_id
)

reconcile_matches (
    status
)
```

Consider partial indexes for unresolved items:

```sql
WHERE status IN ('AMBIGUOUS', 'UNMATCHED_EXTERNAL', 'CONFLICT')
```

---

# 43. Partitioning

Do not require partitioning in v1.

Design high-volume tables to permit future native PostgreSQL partitioning:

```text
reconcile_external_transactions
reconcile_balance_observations
reconcile_matches
reconcile_runs
```

Likely partition key:

```text
event_at
```

or:

```text
created_at
```

---

# 44. Retention

Raw reconciliation evidence may have long regulatory retention requirements.

Therefore the core extension must not automatically delete observations.

Future purge functions must be opt-in.

Examples:

```sql
reconcile_archive_before(...)
reconcile_delete_runs_before(...)
```

should not be part of initial v1.

---

# 45. Views

Provide:

```text
reconcile_accounts_view
reconcile_latest_balances
reconcile_latest_results
reconcile_unmatched_external
reconcile_unmatched_ledger
reconcile_ambiguous
reconcile_issues
reconcile_run_summary
```

Example summary:

```text
run_id
account
balance_status

external_transactions
matched_exact
matched_probable
ambiguous
unmatched_external
unmatched_ledger

started_at
completed_at
```

---

# 46. `reconcile_full()`

High-level API:

```sql
SELECT *
FROM reconcile_full(
    account_id => ...,
    as_of      => clock_timestamp()
);
```

Workflow:

```text
1. create reconciliation run

2. locate latest valid external balance

3. calculate historical ledger balance

4. store balance result

5. load relevant external transactions

6. load relevant ledger transactions

7. perform deterministic matching

8. perform scored matching where enabled

9. store unresolved items

10. mark run completed

11. return summary
```

If any internal failure occurs:

```text
whole run creation/result persistence rolls back
```

---

# 47. Matching configuration

Each account should optionally define:

```text
matching_time_window

allow_probable_matches

minimum_probable_score
```

Example:

```text
bank:
    ±5 minutes

blockchain:
    exact tx reference preferred
    no heuristic if txid exists

payment processor:
    ±30 seconds
```

Default:

```text
heuristics disabled unless explicitly configured
```

This is safer for financial records.

---

# 48. Matching plugin model

Design the internal Rust architecture so match strategies can be extended.

Suggested trait:

```rust
trait MatchStrategy {
    fn find_candidates(
        external: &ExternalTransaction,
        ledger: &[LedgerCandidate],
    ) -> Vec<MatchCandidate>;
}
```

Initial strategies:

```text
ReferenceMatch
ExactAmountTimeMatch
ScoredMatch
```

Future:

```text
BlockchainMatch
BankStatementMatch
CardSettlementMatch
ProviderSpecificMatch
```

Do not make provider-specific code part of v1.

---

# 49. Rust module structure

Recommended layout:

```text
pg-reconcile/
├── Cargo.toml
├── pg_reconcile.control
├── src/
│   ├── lib.rs
│   ├── account.rs
│   ├── asset.rs
│   ├── amount.rs
│   ├── balance.rs
│   ├── external_transaction.rs
│   ├── reconciliation.rs
│   ├── matching.rs
│   ├── scoring.rs
│   ├── manual.rs
│   ├── validation.rs
│   ├── idempotency.rs
│   ├── errors.rs
│   └── spi.rs
│
├── sql/
│   ├── schema.sql
│   ├── indexes.sql
│   ├── permissions.sql
│   ├── views.sql
│   └── adapters.sql
│
├── docs/
│   ├── ARCHITECTURE.md
│   ├── API.md
│   ├── SECURITY.md
│   ├── MATCHING.md
│   ├── RECONCILIATION.md
│   └── UPGRADING.md
│
└── tests/
    ├── balances.rs
    ├── transactions.rs
    ├── matching.rs
    ├── ambiguity.rs
    ├── idempotency.rs
    ├── manual.rs
    ├── concurrency.rs
    ├── security.rs
    └── interoperability.rs
```

---

# 50. pgrx responsibilities

Use Rust/pgrx for:

```text
asset validation
exact amount conversion
canonical hashing
matching/scoring engine
idempotency fingerprints
state validation
reconciliation orchestration
machine-readable errors
cross-extension adapters
```

Use PostgreSQL for:

```text
tables
indexes
foreign keys
uniqueness
transactions
MVCC
privileges
views
historical storage
row-level locks where necessary
```

Avoid implementing PostgreSQL's transactional machinery manually in Rust.

---

# 51. Test requirements

The extension must not be considered production-ready without tests for the following cases.

## Balance tests

```text
exact balance match

difference inside tolerance

difference outside tolerance

external observation missing

external observation after as_of

historical ledger balance different from current balance

asset mismatch
```

## Transaction tests

```text
exact external reference

amount + time match

ambiguous candidates

wrong asset

wrong amount

duplicate provider transaction

external reversal

ledger reversal

pending → settled progression
```

## Idempotency tests

```text
same key + same payload

same key + different payload

100 concurrent duplicate imports
```

## Concurrency tests

```text
multiple reconciliation workers

manual match racing automatic reconciliation

same external feed imported concurrently
```

## Security tests

Verify that ordinary application roles cannot:

```text
modify external observations

modify reconciliation results

modify historical matches

call internal mutation functions

change ledger data through pg_reconcile
```

---

# 52. Full-stack integration tests

Test with:

```text
pg_money
pg_cryptocurrency
pg_fx
pg_ledger
pg_reconcile
```

Required scenarios:

### Bank deposit

```text
external bank deposit
→ ledger deposit
→ exact match
```

### Missing ledger posting

```text
external bank transaction exists
ledger transaction missing
→ UNMATCHED_EXTERNAL
```

### Missing external transaction

```text
ledger withdrawal exists
provider statement missing
→ UNMATCHED_LEDGER
```

### Crypto deposit

```text
BTC transaction
→ ledger credit
→ match using txid
```

### USDT network isolation

```text
USDT@ethereum
must never match
USDT@tron
```

### Balance mismatch

```text
ledger USDT:
1000.000000

on-chain:
999.999999

tolerance:
0

→ MISMATCH
```

### Historical correction

```text
external item arrives late
event_at belongs to yesterday
received_at today
historical reconciliation reflects yesterday correctly
```

---

# 53. Benchmark requirements

Create:

```text
ci/test-highload.sh
bench/run.sh
```

Benchmark:

```text
1M external transactions
10M external transactions

matching against:
    1M ledger entries

workers:
    1
    4
    16
    64
```

Measure:

```text
ingestion throughput
exact-reference matching throughput
amount/time matching throughput
balance reconciliation latency
run completion latency
database growth per external transaction
database growth per match
```

The benchmark must verify invariants after execution.

---

# 54. Production invariants

The following must always hold:

```text
external evidence is immutable

reconciliation results are immutable

manual decisions are append-only

asset identities never silently change

crypto assets on different networks never match

matching never changes ledger history

a completed reconciliation run references a reproducible data set

idempotent ingestion never produces duplicate canonical external transactions

balance difference arithmetic is exact

all historical comparisons use historical ledger state
```

---

# 55. Initial v0.1 scope

Implement only:

```text
reconciliation accounts

external balance observations

external transaction ingestion

balance reconciliation

explicit-reference transaction matching

exact amount + timestamp matching

reconciliation runs

match/result storage

manual matching

reconcile_validate()

pg_ledger interoperability

pg_money interoperability

pg_cryptocurrency interoperability
```

Do not implement yet:

```text
provider APIs

HTTP

bank-specific parsers

blockchain RPC

machine learning matching

automatic accounting adjustments

FX exposure

regulatory reporting

automatic deletion/retention

distributed reconciliation
```

---

# 56. v0.2 candidates

Possible next features:

```text
scored matching
pending → settled lifecycle helpers
statement/import batches
provider adapters
reconciliation checkpoints
reconciliation alerts
partition maintenance
large batch/COPY ingestion
```

---

# 57. v1.0 criteria

Before declaring `pg_reconcile` 1.0:

```text
binary formats frozen

upgrade tests exist

PostgreSQL 14–18 matrix passes

cross-extension installation-order matrix passes

security review completed

100+ concurrent-worker stress test passes

duplicate ingestion race tests pass

large historical dataset benchmark passes

reconciliation invariants verified after fault injection

stable SQL error identifiers documented

all public API documented
```

---

# 58. Expected final architecture

```text
                     External systems
            ┌─────────────┼──────────────┐
            │             │              │
           Banks       Blockchains    Providers
            │             │              │
            └─────────────┼──────────────┘
                          │
                    Rust collectors
                          │
                          ▼
                    pg_reconcile
                     │         │
             observations     matching
                     │         │
                     └────┬────┘
                          │
                          ▼
                      pg_ledger
                          │
                ┌─────────┴──────────┐
                ▼                    ▼
            pg_money         pg_cryptocurrency
```

The architectural rule for the full RustedBytes financial stack is:

```text
pg_money
    defines fiat amounts

pg_cryptocurrency
    defines blockchain assets

pg_fx
    explains how one asset was priced against another

pg_ledger
    records where assets moved

pg_reconcile
    proves whether the ledger agrees with external reality
```

