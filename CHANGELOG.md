# Changelog

## Unreleased

- Initial Rails integration for SES suppression import, local status, manual holds and provider-aware recovery.
- Authenticated, topic-authorized SNS bounce ingestion with per-recipient deduplication.
- Action Mailer interception, optional model macro, install generator and background jobs.
- Minitest, SimpleCov and Ruby/Rails/database compatibility suites.
- Review fixes (2026-09-08): idempotent reconciliation (no events, hooks or version bumps when nothing changed; no provider lookups for rows without provider evidence); an unconfigured scope leaves mail untouched and reports `:unconfigured` instead of raising; `all_sending_paths_listed` replaces `account_policy_only` and observation mode reports a `policy_reason`; single-recipient complaints block locally; scope locks fail fast on every database; log mode previews drop mode faithfully; the unused `payload` column is gone; the SNS verifier refuses SDK versions without the hooks it bounds.

This is an unpublished development release. See the README for supported boundaries and remaining release validation.
