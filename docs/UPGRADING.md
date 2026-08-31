# Upgrading

Version 0.1.0 is the initial SQL and binary format. Before upgrading a future
release, back up the database and read its release notes and migration script.

```sql
ALTER EXTENSION pg_reconcile UPDATE;
SELECT * FROM reconcile_validate();
```

Upgrade scripts must preserve append-only evidence and stable error details.
The CI metadata check requires an explicit migration after 0.1.0.
