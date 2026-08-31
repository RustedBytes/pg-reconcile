# SQL fragments

These files are embedded into the generated extension script by pgrx in this
order: schema, indexes, views, optional adapters, permissions. They are not
intended to be executed independently.

`@extschema@` is substituted by PostgreSQL because `pg_reconcile` is
non-relocatable after installation. This pins `SECURITY DEFINER` search paths
while still allowing `CREATE EXTENSION pg_reconcile SCHEMA chosen_schema`.
