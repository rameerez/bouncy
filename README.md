# 📨 `bouncy` - Know when your app's emails bounce

[![Gem Version](https://badge.fury.io/rb/bouncy.svg)](https://badge.fury.io/rb/bouncy) [![Build Status](https://github.com/rameerez/bouncy/actions/workflows/test.yml/badge.svg)](https://github.com/rameerez/bouncy/actions/workflows/test.yml)

> [!TIP]
> **🚀 Ship your next Rails app 10x faster!** I've built **[RailsFast](https://railsfast.com/?ref=bouncy)**, a production-ready Rails boilerplate template that comes with everything you need to launch a software business in days, not weeks. Go [check it out](https://railsfast.com/?ref=bouncy)!

`bouncy` brings **email bounce handling and suppression management** into your Rails app.

“I never got the email.” Your mailer ran, the job succeeded, but Amazon SES refused an address on its suppression list. Bouncy keeps a local mirror so you can see what happened, avoid repeated attempts, and release the address from your own admin.

```ruby
Bouncy.blocked?("ada@example.com")             # => true
Bouncy.status("ada@example.com").reason       # => :hard_bounce
Bouncy.release!("ada@example.com", note: "Verified recovery with the customer")
```

Works for every address your app sends to: customers, invitees, buyers and contacts. No `User` record required. If you have one, add a single line:

```ruby
class User < ApplicationRecord
  bouncy :email
end

user.email_blocked?
User.email_blocked
```

Check out my other 💎 Ruby gems: [`nondisposable`](https://github.com/rameerez/nondisposable) · [`api_keys`](https://github.com/rameerez/api_keys) · [`usage_credits`](https://github.com/rameerez/usage_credits) · [`pricing_plans`](https://github.com/rameerez/pricing_plans)

## What you get

- A local mirror of the SES account suppression list, including restrictions from before installation and other apps on the same account.
- Signed SNS webhooks for new bounces and complaints, with exact-topic authorization and per-recipient deduplication.
- Address status, model predicates and scopes, and batch lookups for badges on your lists.
- Action Mailer interception that checks To, Cc, Bcc and the SMTP envelope.
- Audited support holds and provider-aware recovery that preserves exact address spelling.
- Sync and pruning jobs, hooks, and read-only setup diagnostics. Use your existing scheduler and admin framework.

## Requirements

- Ruby **3.3+** and Rails **7.2.3.2+**, below Rails 9. Tested on Ruby 3.3/3.4/4.0 and Rails 7.2/8.0/8.1.
- **PostgreSQL, MySQL or SQLite**, with bigint or UUID primary keys.
- **Amazon SES**, one account and region. SES SMTP is supported; suppression management needs AWS API credentials.

This is the first release. Start in observation mode and verify your sending setup before enabling dropping. See [compatibility and validation](guides/compatibility.md) for the tested matrix and remaining validation limits.

## Installation

Add these lines to your application's Gemfile:

```ruby
gem "bouncy", "~> 0.1.0"
gem "aws-sdk-sesv2"
gem "aws-sdk-sns"
gem "aws-sdk-sts"
```

Then install the gem and generate its tables and initializer:

```sh
bundle install
bin/rails generate bouncy:install
bin/rails db:migrate
```

The migration follows your app's primary-key setting and uses PostgreSQL JSONB or MySQL/SQLite JSON. See [database compatibility](guides/compatibility.md#migrations) for UUID configuration.

Configure your actual account, region and sending paths:

```ruby
# config/initializers/bouncy.rb
Bouncy.configure do |config|
  config.scope = "ses:123456789012:us-east-1:account"
  config.ses.region = "us-east-1"
  config.ses.topic_arns = ["arn:aws:sns:us-east-1:123456789012:feedback"]
  config.ses.identities = ["example.com"]
  config.ses.configuration_sets = [] # List every set you use, if any.
  config.ses.all_sending_paths_listed = true # Confirm both lists are complete.
  config.interception = :log
end
```

The SDKs use the AWS credential chain. If your mailer uses Rails encrypted credentials, pass its AWS credential provider explicitly through `config.ses.credentials`. SMTP credentials cannot authenticate management calls. See [credentials and IAM](guides/amazon-ses.md#iam-and-sdk-dependencies).

Mount the receiver in your routes:

```ruby
# config/routes.rb
mount Bouncy::Engine => "/bouncy"
```

Follow the [SES setup guide](guides/amazon-ses.md) to connect bounce and complaint notifications to **`POST /bouncy/webhooks/ses`**. Deploy the allowlisted receiver before subscribing the SNS topic. Bouncy does not create or change your AWS configuration.

Check the policy and import the suppression list:

```sh
bin/rails bouncy:doctor
bin/rails bouncy:sync
```

Schedule `Bouncy::SyncJob` **hourly** and `Bouncy::PruneJob` **daily** with your existing job system. The [operations guide](guides/operations.md) includes scheduling examples and monitoring checks. After reviewing a complete, verified sync and testing delivery in staging, change `config.interception` to `:drop`.

Until `config.scope` is set, Bouncy is inactive: mail goes out untouched and status reports `:unconfigured`. Explicit sync, block, release and erasure operations raise. No database or AWS call runs just from loading the gem.

## Usage

### Check an address

```ruby
status = Bouncy.status("ada@example.com")
status.blocked?          # Any effective local restriction?
status.reasons          # All reasons, including independent local holds
status.knowledge        # :observed, :no_known_block, :unavailable, :unconfigured
status.provider_listed?  # Exact provider identifiers are present locally
status.policy_reason    # Why a listed address's sending policy is unverified
status.stale?           # Address observation is missing or older than stale_after

Bouncy.blocked
Bouncy.events.for("ada@example.com").recent.limit(20)
```

`blocked?` describes known restrictions, not guaranteed deliverability or whether this particular message will be dropped. Provider-derived dropping requires a fresh, complete, policy-verified sync. Independent manual and active soft holds apply even when the mirror is stale. Recognized database outages fail open; the status API exposes `:unavailable`.

For a list page, load all addresses in one query:

```ruby
statuses = Bouncy.statuses(users.map(&:email))
statuses["Ada@Example.com"].blocked?
statuses.blocked # Hash of normalized addresses to blocked statuses
```

See the [API reference](guides/api.md) for all status readers, batch semantics and model scopes. Model scopes expect a trimmed lowercase stored column; use `bouncy :email, normalized_attribute: :canonical_email` if you keep a separate normalized value.

### Stop repeated sends

Three modes: `:log` records what would be dropped while allowing delivery, `:drop` removes enforceable blocked recipients, and `:off` disables interception. An all-blocked message is prevented from normal delivery.

Normal `deliver_now` and `deliver_later` are supported. Bang delivery methods, direct SDK sends and custom transports have [separate boundaries](guides/delivery.md).

```ruby
# An explicit exception for synchronous mail only:
Bouncy.unblocked { SupportMailer.recovery(address).deliver_now }
```

### Help someone recover

```ruby
Bouncy.block!(address, note: "Support is investigating", actor: "support:42")
Bouncy.release!(address, at: :local) # Clear manual/soft holds; retain provider/webhook evidence
Bouncy.release!(address, note: "Verified recovery", actor: "support:42")
```

Default release removes exact provider variants and verifies absence before clearing local state. Errors leave evidence available for review. Releasing an SES restriction can affect sister apps in that account and region; authorize the action in your app. Release does not resend mail or restore consent after a complaint. See [recovery and partial failures](guides/recovery.md).

Use any admin UI. Bouncy has **no Madmin dependency, generator or adapter**. The [admin recipe](guides/admin.md) covers host-owned recovery actions, badges and notifications.

### Handle repeated mailbox-full bounces

Soft bounces are record-only by default. To add a temporary local hold after repeated SES `MailboxFull` bounces:

```ruby
Bouncy.configure do |config|
  config.soft_bounce_threshold = 3
  config.soft_bounce_window = 30.days
  config.soft_bounce_block_for = 30.days
end
```

Only mailbox-full events count. Content, attachment-size and unknown failures never trigger this hold. See [bounce classification](guides/bounce-handling.md) and [configuration defaults](guides/configuration.md).

### React to changes

```ruby
Bouncy.configure do |config|
  config.after_block = ->(event) { SupportNotificationJob.perform_later(event.id) }
  config.after_release = ->(event) { Rails.logger.info("Email recovery: #{event.id}") }
end
```

Your app defines the notification job. Hooks run after commit and are best effort. Events default to 90-day retention; no raw message bodies or payloads are stored. See [hooks and monitoring](guides/operations.md#hooks-and-instrumentation) and [privacy](guides/privacy.md).

## Documentation

The [guide index](guides/README.md) covers setup, every configuration option and public API, scheduling, admin integration, recovery, migration and troubleshooting.

## Development

```sh
bin/setup
bundle exec rake test
bundle exec rubocop
bundle exec appraisal install
bundle exec appraisal rake test
```

Tests use Minitest, SimpleCov with 90% line and branch minimums, generated migrations, SDK stubs and real RSA-signed SNS messages. See [contributing](CONTRIBUTING.md) for PostgreSQL/MySQL and UUID test runs. Report vulnerabilities through [private security reporting](SECURITY.md).

## License

Available as open source under the [MIT License](LICENSE.txt).
