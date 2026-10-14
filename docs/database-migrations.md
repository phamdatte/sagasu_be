# Database migrations and workflow rules

## Initial setup

Run the Spring Boot application to apply migrations. Do not select and execute
V1 manually in IntelliJ's SQL console: Flyway creates the schema and opens the
transaction that `SET LOCAL` requires. IntelliJ's `postgres.public` console is
connected to database `postgres`, not the application's `sagasu_db` database.
For inspecting application tables, connect to `sagasu_db` and select schema
`sagasu`, then refresh the database tree after the application starts.

Docker Compose initializes database `sagasu_db`. On application startup, Flyway
creates schema `sagasu`, keeps its `flyway_schema_history` there, and applies
`src/main/resources/db/migration/V1__initial_sagasu_schema.sql` once.

V1 includes the complete supplied SQL design: 17 tables, indexes, views,
functions, triggers, and the later additions bundled in the original file.
The original `01_schema`, `02_logic`, and `03_upgrade_v2` comments describe
sections of this single baseline; they are not separate Flyway versions.

Flyway manages the transaction and schema creation. JDBC connections set their
search path to `sagasu, public`; Hibernate also uses `sagasu` as its default
schema and validates entity mappings instead of creating/updating tables.

`SagasuApplication.main` sets the default JVM timezone to UTC before Spring Boot
starts, so JDBC does not inherit unsupported timezone aliases from a developer's
operating system. This covers generated IntelliJ run configurations as well as
Maven and packaged JAR launches. Shared launch settings also specify UTC.

Check applied migrations:

```sh
docker compose exec postgres psql -U postgres -d sagasu_db -c "SELECT version, description, success FROM sagasu.flyway_schema_history ORDER BY installed_rank"
```

## Expanding the schema

1. Leave V1 unchanged after it has been applied or shared with the team.
2. Add the next unused version, for example `V2__add_post_tags.sql`, under
   `src/main/resources/db/migration`. Use two underscores after the version.
3. Qualify objects with `sagasu.` or use `SET LOCAL search_path = sagasu, public;`
   within the migration. Do not add `BEGIN`, `COMMIT`, or `ROLLBACK`; Flyway owns
   the migration transaction.
4. Add matching entity/service changes and test both a fresh database and an
   upgrade from the previous migration version.
5. Restart the application. Flyway validates migration checksums and applies
   pending versions before JPA initializes.

To replace a function later, put its `CREATE OR REPLACE FUNCTION` statement in
a new versioned migration. Keep changes to dependent triggers/views in that
same migration. Coordinate version numbers across branches before merging.

Do not enable Hibernate `ddl-auto: update`, automatic Flyway baselining, or edit
Flyway's history table to bypass migration errors. For a manually initialized
nonempty `sagasu` schema, verify its complete structure against V1 and arrange a
deliberate baseline before enabling automatic migrations. V1 is a fresh-install
baseline, not an upgrade for a partially installed schema.

## Claim workflow contract for backend services

The script's claim functions enforce permissions, lock ordering, post status
changes, handover confirmation, and associated history/notifications. A direct
claim status update does not perform that complete workflow.

Future services must call these functions in a Spring `@Transactional` service:

```sql
SELECT sagasu.change_claim(:claimId, :actorId, :action, :note);
SELECT sagasu.confirm_handover(:claimId, :actorId);
```

Supported actions: `APPROVE`, `REQUEST_INFO`, `RESUBMIT`, `REJECT`, `CANCEL`.
Use parameterized JDBC/native queries. Derive `actorId` from the authenticated
server-side principal, never from an unchecked request field. Do not use a JPA
entity setter or bulk update to change claim status or confirmation timestamps.
After calling a function, refresh/reload any affected managed claim/post entity;
database functions and triggers can change state outside JPA's persistence
context. For other audited writes, set `app.actor_id` transaction-locally using
`set_config('app.actor_id', ..., true)` so connection-pool reuse cannot leak it.

The database is intended for a trusted backend. Routine execution is revoked
from `PUBLIC`; a future dedicated application role needs explicit schema, table,
sequence, and routine privileges. Local development currently uses `postgres`.

The table named `"user"` must be quoted in native SQL and explicitly quoted in
its future JPA mapping (for example `@Table(name = "\"user\"", schema = "sagasu")`).
