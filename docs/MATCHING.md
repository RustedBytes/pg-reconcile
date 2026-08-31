# Matching

The v0.1 engine is deliberately conservative and deterministic.

1. A linked external reversal is paired with the ledger reversal of the
   transaction matched to its predecessor, when present.
2. A ledger reference or metadata reference equal to the provider transaction
   ID, external reference, provider reference, blockchain txid/transaction
   hash, or txid/output and hash/log key is examined. One asset-and-amount-compatible
   candidate is `EXACT`; several are `AMBIGUOUS`; a strong reference with no
   compatible candidate, or whose sole candidate is already matched, is
   `CONFLICT`. A strong reference never falls through to a weaker heuristic.
3. If no strong reference exists and `matching_time_window` is greater than
   zero, exact asset plus exact signed smallest units within that window is
   examined. One candidate is `EXACT`; several are `AMBIGUOUS`.
4. Anything else is stored as `UNMATCHED_EXTERNAL`; unused ledger entries are
   stored as `UNMATCHED_LEDGER`.

Asset equality is mandatory. No ticker-only comparison, floating point,
unannounced fuzzy matching, or match below a threshold occurs. `PROBABLE` and
general scored matching are reserved for a later version; the account fields
are present so future algorithms can freeze their policy in each run.

Scores and structured JSON reasons are evidence, not hidden decision inputs.
Reference matches use score 150; amount/time matches use amount score 50 plus
the documented timestamp score. Manual decisions use score 1000 and reference
their immutable decision UUID.

An exact/probable match is one-to-one within a run: neither an external item nor
a ledger entry can be reused. Manual mappings reserve their ledger entry before
automatic matching and are serialized by an advisory lock. The authenticated
database `session_user` is the audit actor; callers cannot supply another name.
