# Changelog

## [Unreleased]

## [0.2.0] - 2026-10-25

Eight features that apps need to replace a hand-rolled SES integration with Bouncy. There is no new migration: the address lock uses database locks, not a column.

### Added

- `config.ses.configuration_set` stamps `X-SES-CONFIGURATION-SET` on every message that names no set of its own, whatever the interception mode, and adds the set to the sending-policy check, so SES publishes each mail's events to the app's topic without a header in every mailer.
- `Bouncy.hold(email) { ... }` takes a shared lock per address around an app's own check and send, and every Bouncy write takes it exclusively until its transaction ends, so a new bounce or complaint cannot land between the check and the send; inside a PostgreSQL REPEATABLE READ or SERIALIZABLE transaction it raises, because that snapshot cannot see a block committed during the wait.
- `config.on_notification` receives every SES notification synchronously (`type`, `recipients`, `message_id`, `occurred_at`, `tags`, `raw`) after its state commits and before the receiver answers, so an app can track its own Send and Delivery events, and a raise answers 503 so that SNS delivers again; the `after_*` hooks are unchanged.
- `config.ses.subscription_confirmation = :subscribe_url` confirms an SNS subscription by visiting the signed `SubscribeURL` on the topic's own SNS host and answers 503 unless that visit gets a 2xx, so credentials without `sns:ConfirmSubscription` can confirm; the default `:api` is unchanged.
- `config.require_fresh_sync = false` lets a webhook block drop mail with no sync at all, so an app on an SES account that other apps share need not mirror their suppression lists; the default `true` keeps the 0.1 rule.
- `config.webhook_blocking = :strict` blocks every Permanent bounce, whatever its subtype, and every recipient a complaint names, because without a sync nothing else reads the account list and a complaint does not say who complained; it is the default when `require_fresh_sync` is `false`, and `:cautious`, the 0.1 rule, stays the default while a sync runs.
- The SNS signing certificate is cached for the process (at most 16 URLs, one hour each, fetched again once when a signature fails on a certificate older than a minute), because each request builds a new verifier and an app that subscribes to Send and Delivery events got one HTTPS download per mail.
- The receiver logs one warning per refused message or failed confirmation, with the status, the reason and the topic ARN or `SubscribeURL` host and never an address or the body, because a silent 4xx or 503 left a dead subscription undiagnosable.
- `Bouncy::SyncJob` and `Bouncy::PruneJob` return early with one info line while `config.scope` is unset, because a scheduled job in an app with the feature off failed every run and filled the failed-jobs list; `Bouncy.sync!` still raises.
- `Bouncy::BodyLimit` is Rack middleware (300 KB by default, configurable) that cuts the receiver's body before Rails reads a whole chunked body or parses it for its log; the receiver's own 2 MiB limit stays.

### Changed

- The recipient check moved to the delivery method that Mail calls after every interceptor and mailer callback, so a message that `:drop` left with no recipient reaches no transport, `deliver_now!` and `deliver_later!` included, and a recipient that a later callback or interceptor adds is checked too.
- The interceptor keeps each remaining To, Cc, Bcc and SMTP envelope entry as written, display name included, because it looks up only the entry's bare address.
- The `after_*` hooks run after the commit of the outermost transaction and after the enclosing `Bouncy.hold`, so a hook never runs while Bouncy holds an address; a rollback drops them, and Rails transactional tests keep 0.1's timing.
- The sync's scope lock reads its answer without the query cache, so a second sync in one cached request cannot take the lock without locking.

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
