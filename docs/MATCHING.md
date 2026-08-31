# Matching

The v0.1 engine is deliberately conservative and deterministic.

1. A ledger reference or metadata reference equal to the provider transaction
   ID/external reference is examined first. One asset-and-amount-compatible
   candidate is `EXACT`; several are `AMBIGUOUS`; a strong reference with no
   compatible candidate is `CONFLICT`.
2. If no strong reference exists and `matching_time_window` is greater than
   zero, exact asset plus exact signed smallest units within that window is
   examined. One candidate is `EXACT`; several are `AMBIGUOUS`.
3. Anything else is stored as `UNMATCHED_EXTERNAL`; unused ledger entries are
   stored as `UNMATCHED_LEDGER`.

Asset equality is mandatory. No ticker-only comparison, floating point,
unannounced fuzzy matching, or match below a threshold occurs. `PROBABLE` and
general scored matching are reserved for a later version; the account fields
are present so future algorithms can freeze their policy in each run.

Scores and structured JSON reasons are evidence, not hidden decision inputs.
Reference matches use score 150; amount/time matches use amount score 50 plus
the documented timestamp score. Manual decisions use score 1000 and reference
their immutable decision UUID.
