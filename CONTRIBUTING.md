# Contributing to Bouncy

Run `bin/setup`, then `bundle exec rake test`. Tests use Minitest and a minimal Rails app with SQLite. No AWS account or credentials are needed; provider tests use SDK stubs, synthetic messages and real RSA signatures. WebMock rejects outgoing HTTP.

```sh
bundle exec appraisal install
bundle exec appraisal rake test
createdb bouncy_test
DATABASE_URL=postgresql:///bouncy_test bundle exec rake test
bundle exec rubocop
```

The suite recreates its tables and only accepts database names beginning with `bouncy_test` (or in-memory SQLite). Never point it at an application database. PostgreSQL and MySQL tests exercise separate connections/processes, locking and concurrent webhook retries. CI covers Ruby 3.3/3.4/4.0, Rails 7.2/8.0/8.1, PostgreSQL/MySQL/SQLite and bigint/UUID keys: 54 combinations.

Use `DATABASE_URL=mysql2://root@localhost/bouncy_test` for a dedicated local MySQL database. Set `BOUNCY_TEST_PRIMARY_KEY=uuid` to run the entire suite using UUID keys. The migration tests also create, persist to and roll back temporary UUID tables in every normal suite run. PostgreSQL uses JSONB; MySQL and SQLite use JSON. MySQL identity columns use binary collation to preserve the same address comparison contract.

SimpleCov requires 90% line and branch coverage. Add a behavior test for a bug fix, particularly any change to address identity, webhook authorization, recipient handling, release or reconciliation. Coverage is a regression check; it does not establish race safety by itself.

Use double-quoted strings, small Ruby classes and the existing Minitest style. Provider SDKs are optional host dependencies and load lazily. Keep host admin classes, routing authorization and presentation in the implementing application.

`guides/` contains public documentation. Local research, editor settings and customer data must never enter source, fixtures, logs or a release package. The gemspec uses an explicit package allowlist.
