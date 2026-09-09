# 📨 `bouncy`: know when your app's emails bounce

[![Tests](https://github.com/rameerez/bouncy/actions/workflows/test.yml/badge.svg)](https://github.com/rameerez/bouncy/actions/workflows/test.yml)

**Email bounce handling and suppression management for Rails.** Your email provider knows which addresses it has blocked. Now your app can know too.

“I never got the email.” The job succeeded, your mailer ran, and SES refused an address on its suppression list. `bouncy` brings that information into your app so you can see the restriction, stop repeated attempts and help the person recover.

```ruby
Bouncy.blocked?("ada@example.com")
# => true

Bouncy.status("ada@example.com").reason
# => :hard_bounce

Bouncy.release!("ada@example.com", note: "Corrected and verified with the customer")
```

Works for every address your app sends to: customers, invitees, buyers and contacts. No `User` record required. Use the optional model macro when you have one:

```ruby
class User < ApplicationRecord
  bouncy :email
end

user.email_blocked?
User.email_blocked
```

> [!TIP]
> **🚀 Ship your next Rails app 10x faster!** I've built **[RailsFast](https://railsfast.com/?ref=bouncy)**, a production-ready Rails boilerplate with authentication, payments, admin and the boring parts already wired up. It's the home of the gem ecosystem that Bouncy belongs to.

## Status

**Unpublished development version: `0.1.0.alpha1`.** The core implementation and automated tests are in place. Live SES installation and host application migration/rollback remain release gates. Do not treat this checkout as a published production release.

Initial support: **Amazon SES, including SES SMTP**, one account and region, PostgreSQL/MySQL/SQLite, Rails 7.2–8.1 and Ruby 3.3/3.4/4.0. Other providers and a hosted dashboard are outside this release.

## What it does

- Mirrors the complete SES account suppression list into two local tables.
- Receives signed SNS feedback, authorizes the exact topic, and records each recipient independently.
- Exposes local address status, model scopes and a compact event history.
- Observes or drops blocked recipients through Action Mailer's normal delivery path, including Bcc and explicit SMTP envelopes.
- Releases exact provider address variants before clearing local evidence. Manual holds remain independent.
- Reconciles provider changes, retains release ordering information and reports incomplete or stale observations.

Soft bounces are recorded without blocking an address, unless you opt into a threshold (`config.soft_bounce_threshold`). An ordinary complaint blocks locally only when SES names exactly one recipient; a complaint that lists several possible recipients is recorded as candidates and enforced once the provider lists the address at the next sync. Suppression-list refusal notices are recorded separately and never become new complaint blocks. Delivery means the receiving server accepted a message; it does not prove inbox placement or reading.

## Installation

While developing locally:

```ruby
# Gemfile
gem "bouncy", path: "../bouncy"
gem "aws-sdk-sesv2"
gem "aws-sdk-sns"
gem "aws-sdk-sts"
```

```sh
bundle install
bin/rails generate bouncy:install
bin/rails db:migrate
```

The generator writes a migration and initializer. It prints the model line and scheduling instructions; your application owns its models, routes, scheduler and admin UI.

Migrations follow the same conventions as `usage_credits`, `api_keys` and `nondisposable`: resolve the host's primary-key setting at migration time, use PostgreSQL JSONB or MySQL/SQLite JSON, and supply model defaults where MySQL requires them. UUID apps use native PostgreSQL UUIDs or application-generated UUID strings on MySQL/SQLite. See [database compatibility](guides/compatibility.md).

```ruby
# config/initializers/bouncy.rb
Bouncy.configure do |config|
  config.scope = "ses:123456789012:us-east-1:account"
  config.ses.region = "us-east-1"
  config.ses.topic_arns = ["arn:aws:sns:us-east-1:123456789012:feedback"]
  config.ses.identities = ["example.com"]
  config.ses.configuration_sets = ["transactional"]
  config.ses.all_sending_paths_listed = true # The two lists above are complete.
  config.interception = :log
end

# config/routes.rb
mount Bouncy::Engine => "/bouncy"
```

Deploy the receiver with its allowlist before subscribing the topic. Follow the [Amazon SES setup guide](guides/amazon-ses.md), bootstrap with `bin/rails bouncy:sync`, and schedule `Bouncy::SyncJob` hourly and `Bouncy::PruneJob` daily using your existing job system.

Until `config.scope` is set, Bouncy is inactive: mail is delivered untouched, every address reads as unrestricted, relations are empty, and one warning is logged. Sync, block and release raise `Bouncy::ConfigurationError`. That lets you add the gem before its environment variables exist without breaking mailer tests.

Run `bin/rails bouncy:doctor` to check the sending policy, then sync to import restrictions. An unverified policy leaves new imports in observation mode; `policy_reason` explains why. If verification later fails, historical restrictions remain queryable, but the interceptor stops dropping recipients based on provider or webhook evidence until a fresh, complete, verified sync succeeds. Independent manual holds still apply. Every sync records a summary; unchanged addresses create no additional events or hooks.

SMTP credentials are not AWS API credentials. The optional SDKs use the usual AWS credential chain, `config.ses.credentials`, or injected clients. Rails encrypted credentials must be passed explicitly. Requiring the gem does not query your database or call AWS.


For a host migrating an existing suppression system, run `bin/rails bouncy:bootstrap` after importing legacy state and before starting mail workers. It requires a fresh complete sync with verified policy, performs one if needed, and raises on failure. `Bouncy.sync_fresh?` exposes the same health predicate the interceptor uses, so host health checks need no duplicated freshness logic. This startup gate does not change runtime fail-open behavior during later outages.

## Email status

```ruby
status = Bouncy.status("ada@example.com")
status.blocked?
status.reasons       # All effective reasons, including an independent manual hold
status.knowledge     # :observed, :no_known_block, :unavailable, :unconfigured
status.provider_listed?   # the provider lists this address in the configured scope
status.policy_unverified? # listed, but the latest sync did not verify the sending policy
status.policy_reason      # why verification failed or is unknown; nil when verified or unlisted
status.stale?
status.observed_at
status.last_event

Bouncy.blocked
Bouncy.events.for("ada@example.com").recent
```

`blocked?` asks about known local restrictions. An unknown address is not certified deliverable. Recognized database outages return `false` from the boolean API and `:unavailable` from the richer status API. Programming errors still raise.

Policy diagnostics use the latest sync in the address's scope, including failed checks. They do not erase historical evidence or replace the freshness check: `blocked?` can remain true while the interceptor lets mail through because verification failed or the sync is stale. Obtain a new status object after a sync to refresh its observations.

Model scopes expect the stored column to use Bouncy's trimmed lowercase comparison. For mixed-case display values, supply a persisted normalized column:

```ruby
bouncy :email, normalized_attribute: :canonical_email
bouncy :billing_email
```

The macro adds `email_blocked?`, `email_bounced?`, `email_complained?`, `email_status`, and class scopes `email_blocked`, `email_bounced`, `email_unblocked`. The last excludes blank values and makes no deliverability claim.

## Sending mail

Start in `:log`. After reviewing a complete import and testing delivery in staging, set `config.interception = :drop`. `:off` disables interception.

In drop mode, Bouncy checks both headers and the SMTP envelope, removes only blocked recipients, and prevents normal delivery if no recipients remain. Provider-derived dropping needs a fresh, complete sync; local administrative holds remain effective independently. Log mode applies the same rule, so its `skipped` events (`would_drop`, `stale_provider_evidence`) preview exactly what drop mode would do. A recognized database outage leaves the original message intact.

```ruby
# A deliberate exception for synchronous mail in this execution context:
Bouncy.unblocked { SupportMailer.recovery(address).deliver_now }
```

This bypass does not travel with an enqueued job. Bang delivery methods bypass Mail's `perform_deliveries` check and may attempt transport with an empty envelope, causing an error. Direct SDK sends and custom senders need their own integration. See [delivery boundaries](guides/delivery.md).

## Support and recovery

```ruby
Bouncy.block!("ada@example.com", note: "Hold while support investigates", actor: "support:42")
Bouncy.release!("ada@example.com", at: :local) # Remove local policy; retain provider evidence
Bouncy.release!("ada@example.com", note: "Verified recovery", actor: "support:42")
```

Default recovery enumerates exact provider variants and confirms removal before clearing local state. Failures raise and leave local evidence available for review. A concurrent newer change can raise `Bouncy::ReleaseConflict`; review the latest state before retrying. Remote calls and your database cannot be one atomic transaction.

`Bouncy::ReleaseFailed#outcomes` identifies removed, already absent, failed and unattempted exact variants. The recovery audit records these outcomes too; a partial remote success never becomes a local success notice.

Releasing an SES account restriction can affect sister apps in that account and region. Your host application must authorize the action and confirm appropriate permission before resuming contact after a complaint. Release does not resend a message or repair a mailbox.

Use any admin UI. Bouncy has **no Madmin dependency, generator or adapter**. An [optional admin recipe](guides/admin.md) shows how host-owned glue uses these APIs.

## Repeated soft bounces

Soft bounces are recorded by default. Opt in to a temporary local hold for repeated SES `MailboxFull` events. Content, size, attachment, general and unknown failures stay record-only because they do not establish a mailbox problem:

```ruby
Bouncy.configure do |config|
  config.soft_bounce_threshold = 3       # nil (the default) keeps soft bounces record-only
  config.soft_bounce_window = 30.days    # occurrences older than this stop counting
  config.soft_bounce_block_for = 30.days # how long the resulting hold lasts
end
```

Thresholds must be between 1 and 50. The window really rolls: each occurrence time is retained, and one that ages out stops counting rather than accumulating forever. Redelivered notifications count once. The resulting hold reads as `:soft_bounces`, is local policy like a manual hold, and so applies even while a provider sync is stale — the provider never listed this address, your application did. `Bouncy.release!` clears the history and fences delayed pre-release soft feedback. Out-of-order events inside the current window still count; expired events cannot start a new hold.

Hard bounces and complaints keep their own reason when soft evidence accumulates underneath them.

## Hooks and retention

```ruby
Bouncy.configure do |config|
  config.after_block = ->(event) { SupportNotificationJob.perform_later(event.id) }
  config.after_release = ->(event) { Rails.logger.info("Email recovery recorded: #{event.id}") }
  config.record_deliveries = true # Optional normalized server-acceptance events
end
```

Hooks run after commit. A hook failure emits `hook_error.bouncy`; it does not undo ingestion. Hooks are best effort: use a host outbox for guaranteed external work.

Events default to 90-day retention. Raw payloads, subjects and message bodies are not stored. Inactive state rows retain release ordering metadata. `Bouncy.forget!(email)` erases local state and history only; it does not release SES, and a later sync may import the restriction again.

## Development

```sh
bin/setup
bundle exec rake test
bundle exec appraisal install
bundle exec appraisal rake test
DATABASE_URL=postgresql:///bouncy_test bundle exec rake test
```

Tests use Minitest, SimpleCov (90% line and branch minimum), actual generated migrations, SDK stubs and real RSA-signed SNS messages. See [contributing](CONTRIBUTING.md) for the compatibility matrix and isolated database setup.

## More Rails gems

Pair Bouncy with [`nondisposable`](https://github.com/rameerez/nondisposable) for disposable-address validation, [`api_keys`](https://github.com/rameerez/api_keys) for API authentication, [`usage_credits`](https://github.com/rameerez/usage_credits) for usage billing, and [`pricing_plans`](https://github.com/rameerez/pricing_plans) for subscription plans.

## License

Available as open source under the [MIT License](LICENSE.txt).
