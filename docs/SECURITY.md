# Security

The extension grants nothing to `PUBLIC`: no table/view reads and no function
execution. It also revokes direct access to internal helper functions. Mutation
entry points are `SECURITY DEFINER` functions with a pinned extension schema,
`pg_catalog`, and `pg_temp` search path.

Create the roles you need before installing the extension to receive the
recommended grants automatically:

- `reconcile_reader`: sanitized operational views and stored results;
- `reconcile_ingestor`: external balance and transaction ingestion;
- `reconcile_operator`: execute runs and append manual decisions;
- `reconcile_admin`: configure accounts and enable adapters.

If roles are created later, grant the same functions explicitly or reinstall
the privilege policy during your deployment. Membership in these roles is an
application security decision and is never created automatically.

Raw table metadata can contain account identifiers, counterparties, wallet
addresses, and customer references. Reader grants target views that omit raw
metadata. Direct table access should be reserved for tightly controlled audit
and administration roles.

Append-only triggers are defense in depth and apply even to a role with table
write privileges. The extension never exposes a path that changes
`ledger_accounts`, `ledger_entries`, or `ledger_transactions`.
