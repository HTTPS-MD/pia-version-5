# supabase/

| Item | What it is |
|---|---|
| `database-history.sql` | Every database change made so far, in the order it was applied, in one readable file (read-only reference, not a build script). |
| `functions/` | Edge Functions (join with student number, learning profile). |

`database-history.sql` extends a base schema that was created before migrations were used, so
it cannot rebuild the database from nothing. Take `pg_dump --schema-only` of the live project
for that. The 64 original migration files are still on the `dev` branch.
