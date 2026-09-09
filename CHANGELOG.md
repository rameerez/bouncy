# Changelog

## [Unreleased]

## [0.1.0] - 2026-09-09

Initial release of email bounce handling and suppression management for Rails, with Amazon SES support.

### Added

- Address-keyed local restrictions and event history, including recipients without a User record.
- Complete SES suppression-list reconciliation with account/region policy checks, exact-case provider identifiers and stale-mirror diagnostics.
- Signed SNS feedback ingestion with exact-topic authorization, bounded certificate fetching, per-recipient deduplication and replay protection.
- Audited local manual holds and provider-aware recovery. Provider release checks exact address variants before clearing local evidence; local holds remain independent of provider policy.
- Normal Action Mailer interception, including Bcc and explicit SMTP envelopes. New installs default to observation mode; provider-derived dropping requires a fresh verified mirror.
- Optional `bouncy :email` model predicates/scopes, individual status, and batch status lookup for lists. Unavailable batches retain requested addresses with explicit knowledge.
- Opt-in repeated MailboxFull escalation with a bounded rolling window and temporary hold. Other soft failures remain record-only.
- Shared AWS credential configuration, explicit bootstrap, read-only setup/doctor tasks, synchronization and retention jobs, and after-commit hooks.
- Adaptive install migrations for bigint/UUID and PostgreSQL JSONB or MySQL/SQLite JSON. Madmin and other admin presentation remain host-owned.

### Compatibility and boundaries

- Ruby 3.3, 3.4 and 4.0; Rails 7.2–8.1; PostgreSQL, MySQL and SQLite.
- Core requires Rails. The SES adapter uses optional AWS SDK gems installed by the host.
- A known restriction is not a deliverability verdict. Provider outages and stale mirrors can suspend interception; direct SDK sends and bang delivery methods have separate boundaries documented in the guides.
- No raw message payload storage, automatic AWS provisioning or built-in admin UI.

### Fixed during release preparation

- Empty or already consumed webhook streams return 400 instead of raising a server error.

Validation: the automated compatibility matrix and packaged installation smoke pass. Live provider acceptance and independent installation validation remain outstanding.
