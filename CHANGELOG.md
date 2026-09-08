# Changelog

## Unreleased

- Initial Rails integration for SES suppression import, local status, manual holds and provider-aware recovery.
- Authenticated, topic-authorized SNS bounce ingestion with per-recipient deduplication.
- Action Mailer interception, optional model macro, install generator and background jobs.
- Minitest, SimpleCov and Ruby/Rails/database compatibility suites.
- Review fixes (2026-09-08): idempotent reconciliation (no events, hooks or version bumps when nothing changed; no provider lookups for rows without provider evidence); an unconfigured scope leaves mail untouched and reports `:unconfigured` instead of raising; `all_sending_paths_listed` replaces `account_policy_only` and observation mode reports a `policy_reason`; single-recipient complaints block locally; scope locks fail fast on every database; log mode previews drop mode faithfully; the unused `payload` column is gone; the SNS verifier refuses SDK versions without the hooks it bounds.

- Suppression complaint subtypes remain provider hints or diagnostics instead of creating new complaint blocks.
- Sync persists changed provider timestamps without restriction event churn and fences concurrent recovery against newer evidence.
- Address policy diagnostics follow the latest scoped sync through verification loss, failed checks and recovery; `policy_reason` explains unverified state.

- Optional soft-bounce escalation: `config.soft_bounce_threshold`, `config.soft_bounce_window` and `config.soft_bounce_block_for` turn repeated soft bounces into a local hold. Default stays record-only. Occurrence times are retained and bounded so the window rolls, and recovery clears them. Found while migrating a host application that had its own threshold; the schema anticipated this but nothing wrote the columns.

- `config.ses.sns_message_verifier` injects the SNS certificate verifier so a host can test its mounted receiver offline. Topic authorization, certificate-URL checks and the real signature check still run, so the seam cannot hide a receiver that would accept a foreign topic.

This is an unpublished development release. See the README for supported boundaries and remaining release validation.

- Dogfooding review: mailbox-only soft escalation, bounded configuration, out-of-order counting and release fences; shared AWS credentials; reusable sync freshness and fail-closed bootstrap APIs.
