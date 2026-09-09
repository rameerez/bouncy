# Ruby, Rails and database compatibility

Bouncy's compatibility suite covers Ruby 3.3, 3.4 and 4.0 with Rails 7.2, 8.0 and 8.1. Each combination runs on SQLite, PostgreSQL and MySQL with bigint and UUID keys. Rails 7.2 uses Minitest 5 because Active Support constrains that dependency; Rails 8 uses Minitest 6.

The v0.1.0 release run on September 9, 2026 passed all 54 combinations using Ruby 3.3.5/3.4.7/4.0.5, Rails 7.2.3.2/8.0.5.1/8.1.3.1, PostgreSQL 18.3 and MySQL 8.4.11. Every combination passed the 90% line and branch coverage gates (131 tests on SQLite, 135 on PostgreSQL/MySQL). A fresh Rails app installed from the release archive also passed generator/migration, model/batch APIs, normal mail interception, local recovery and mounted receiver checks. The [first public GitHub Actions run](https://github.com/rameerez/bouncy/actions/runs/34306365294) also passed all 54 matrix jobs plus lint/package build. These automated checks do not establish a live SES lifecycle. Live SES lifecycle and independent installation validation remain outstanding for this first release.

The runtime JSON gem is constrained below version 3 because the supported Rails releases still pass a positional options hash to `JSON.parse`. Optional AWS SDKs load lazily and are host dependencies. There is no database or AWS lookup during boot.

## Migrations

The install generator uses `templates/create_bouncy_tables.rb.erb`, the house `primary_and_foreign_key_types` helper and adapter-specific JSON helpers. The generated migration is self-contained; it calls no Bouncy model or provider API.

The host setting is resolved when the migration runs:

```ruby
# config/application.rb
config.generators do |generator|
  generator.orm :active_record, primary_key_type: :uuid
end
```

Without a setting, Rails chooses its standard primary key. Explicit bigint/integer settings remain intact. With UUIDs, PostgreSQL uses native UUID columns and its standard generated default. SQLite and MySQL use 36-character strings; the gem supplies UUIDs at record creation. Provided IDs are preserved. There are no User foreign keys.

| Database | JSON storage | JSON defaults | UUID storage |
|---|---|---|---|
| PostgreSQL | JSONB | Database and model defaults | Native UUID |
| MySQL 8.4 | JSON | Model defaults; no literal SQL JSON default | 36-character string |
| SQLite | JSON | Database and model defaults | 36-character string |

The gem's JSON attributes inherit the database's native type. Every new record gets an independent hash/array default. No adapter probe or attribute-schema query is performed at boot. Unsupported database adapters raise before reconciliation.

MySQL identity columns explicitly use `utf8mb4_bin`. Case/accent-insensitive equality must not collapse addresses beyond Bouncy's trimmed lowercase policy. Scope and address limits keep compound indexes within supported database key limits. Use an application-normalized host column for model scopes.

The tests execute the generated migration, persist JSON and UUID records, and reverse it. Tests also run the full lifecycle using UUID primary keys, including event ordering, recovery and concurrency. Existing released migrations must remain immutable; later schema changes require additive migrations.

## Synchronization

PostgreSQL uses a session advisory lock; MySQL uses a named connection lock. Both are held on a checked-out connection across the provider scan and local reconciliation, with cleanup on failure. Every adapter tries the lock without waiting: a second sync for the same scope raises `Bouncy::ProviderError` immediately rather than queueing behind a run that may be waiting on the provider. Tests verify exclusion from an independent process as well as separate connections.

SQLite uses an OS file lock alongside the database file. All workers must access the same database file and lock path on a filesystem that supports `flock`. In-memory SQLite only exists inside its process and uses a process-specific lock file. Network filesystems and replicated SQLite arrangements need separate validation.

Background scheduling remains host-owned. Normal Action Mailer delivery and a correctly configured job worker are tested; custom senders and bang delivery methods have [explicit boundaries](delivery.md).
