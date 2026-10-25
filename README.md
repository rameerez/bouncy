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
- Signed SNS webhooks for new bounces and complaints, with exact-topic authorization, per-recipient deduplication, a cached signing certificate and one log line per refused message.
- Address status, model predicates and scopes, and batch lookups for badges on your lists.
- Action Mailer interception that checks To, Cc, Bcc and the SMTP envelope, keeps display names, and stops bang deliveries too.
- `Bouncy.hold` for senders that check an address and send in one step, and a synchronous hook for every SES event.
- Audited support holds and provider-aware recovery that preserves exact address spelling.
- Sync and pruning jobs, hooks, and read-only setup diagnostics. Use your existing scheduler and admin framework.

## Requirements

- Ruby **3.3+** and Rails **7.2.3.2+**, below Rails 9. Tested on Ruby 3.3/3.4/4.0 and Rails 7.2/8.0/8.1.
- **PostgreSQL, MySQL or SQLite**, with bigint or UUID primary keys.
- **Amazon SES**, one account and region. SES SMTP is supported; suppression management needs AWS API credentials.

Start in observation mode and verify your sending setup before enabling dropping. See [compatibility and validation](guides/compatibility.md) for the tested matrix and remaining validation limits.

## Installation

Add these lines to your application's Gemfile:

```ruby
gem "bouncy", "~> 0.2.0"
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

Cut oversized webhook bodies before Rails reads them. Rails reads a whole chunked body, and parses a JSON body for its log, before any route runs. SNS posts 256 KB at most:

```ruby
# config/application.rb
config.middleware.insert_before 0, Bouncy::BodyLimit, path: "/bouncy/webhooks/ses" # limit: 300.kilobytes by default
```

Use the path your app routes to the receiver. The limit covers that path with a trailing slash or a format suffix, and also the full path when the app runs under a prefix; adjacent routes are untouched. The receiver keeps its own 2 MiB limit as well.

The receiver logs one warning for each message it refuses, with the status, the reason and the topic ARN (or the `SubscribeURL` host of a failed confirmation), and never an address or the body. That line is how a dead subscription shows up in production:

```text
[bouncy] refused an SNS message (401): SNS topic is not authorized; topic arn:aws:sns:us-east-1:999999999999:feedback
```

Follow the [SES setup guide](guides/amazon-ses.md) to connect bounce and complaint notifications to **`POST /bouncy/webhooks/ses`**. Deploy the allowlisted receiver before subscribing the SNS topic. Bouncy does not create or change your AWS configuration.

Check the policy and import the suppression list:

```sh
bin/rails bouncy:doctor
bin/rails bouncy:sync
```

Schedule `Bouncy::SyncJob` **hourly** and `Bouncy::PruneJob` **daily** with your existing job system. The [operations guide](guides/operations.md) includes scheduling examples and monitoring checks. After reviewing a complete, verified sync and testing delivery in staging, change `config.interception` to `:drop`.

Until `config.scope` is set, Bouncy is inactive: mail goes out untouched and status reports `:unconfigured`. Explicit sync, block, release and erasure operations raise. `Bouncy::SyncJob` and `Bouncy::PruneJob` skip with one info line instead, so a job you schedule before the feature is on does not fail every run. No database or AWS call runs just from loading the gem.

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

`blocked?` describes known restrictions, not guaranteed deliverability or whether this particular message will be dropped. Provider-derived dropping requires a fresh, complete, policy-verified sync, unless you [run without a sync](#run-without-a-sync). Independent manual and active soft holds apply even when the mirror is stale. Recognized database outages fail open; the status API exposes `:unavailable`.

For a list page, load all addresses in one query:

```ruby
statuses = Bouncy.statuses(users.map(&:email))
statuses["Ada@Example.com"].blocked?
statuses.blocked # Hash of normalized addresses to blocked statuses
```

See the [API reference](guides/api.md) for all status readers, batch semantics and model scopes. Model scopes expect a trimmed lowercase stored column; use `bouncy :email, normalized_attribute: :canonical_email` if you keep a separate normalized value.

### Stop repeated sends

Three modes: `:log` records what would be dropped while allowing delivery, `:drop` removes enforceable blocked recipients, and `:off` disables interception. The other recipients keep their entries as written, display names included. Bouncy decides where Mail hands the message to the transport, after every interceptor and every mailer callback, so it judges the recipients the transport would really get. A message with no recipient left reaches no transport, whether you call `deliver_now`, `deliver_now!`, `deliver_later` or `deliver_later!`.

Direct SDK sends and custom transports have [separate boundaries](guides/delivery.md).

```ruby
# An explicit exception for synchronous mail only:
Bouncy.unblocked { SupportMailer.recovery(address).deliver_now }
```

### Check and send in one step

A sender that records its own outcome checks the address itself, then sends. Hold the address around both, so no new bounce or complaint can land between the check and the send:

```ruby
Bouncy.hold(order.email) do
  next order.receipt_skipped! if Bouncy.blocked?(order.email)

  ReceiptMailer.with(order:).receipt.deliver_now
  order.receipt_sent!
end
```

Every Bouncy write to that address waits for the block. Inside a transaction, the hold lasts until the transaction commits, so the record of the send commits first. Senders to one address do not wait for each other on PostgreSQL and SQLite; on MySQL they take turns. The lock needs no migration.

The check inside the hold must read the latest committed state. On MySQL, Bouncy's reads inside a hold are locking reads, which do that at any isolation level. PostgreSQL does it at READ COMMITTED, its default; inside a REPEATABLE READ or SERIALIZABLE transaction, `Bouncy.hold` raises `Bouncy::ConfigurationError`, because the transaction's snapshot is fixed before the lock is granted. For those, and on SQLite, hold the address outside the transaction, around it:

```ruby
Bouncy.hold(order.email) do
  Order.transaction(isolation: :repeatable_read) do
    # check, send and record here
  end
end
```

The hold then lasts for the whole block, and the transaction's snapshot starts after it. Hooks of a write made inside a hold run when the hold ends.

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

Your app defines the notification job. Hooks are best effort and run after the commit of the outermost transaction, once the connection holds no Bouncy lock: a rollback drops them, and inside `Bouncy.hold` they wait until the hold ends. One exception: in Rails transactional tests, whose fixture transaction only rolls back, hooks run when your app's own transaction commits, as in 0.1. Events default to 90-day retention; no raw message bodies or payloads are stored. See [hooks and monitoring](guides/operations.md#hooks-and-instrumentation) and [privacy](guides/privacy.md).

To follow your own mail (sent, delivered, bounced), take every SES notification synchronously:

```ruby
Bouncy.configure do |config|
  config.on_notification = lambda do |notification|
    notification.type        # => "Delivery"
    notification.message_id  # => SES message id
    notification.recipients  # => ["ada@example.com"]
    notification.occurred_at # => Time of this event
    notification.tags        # => { "receipt" => ["42"] }
    notification.raw         # => the SES event as a Hash
  end
end
```

It runs for every event type, after Bouncy committed what it records, and before the receiver answers SNS. If it raises, the receiver answers 503 and SNS delivers the notification again, so make it safe to repeat.

### Name the configuration set

To publish SES events (Send, Delivery and the rest) through a configuration set, name it once:

```ruby
config.ses.configuration_set = "transactional"
```

Bouncy stamps `X-SES-CONFIGURATION-SET` on every message that does not name its own set, whatever the interception mode, and checks the set's suppression options with the rest of your [sending policy](guides/amazon-ses.md#supported-sending-policy).

### Confirm the subscription without the SNS API

By default the receiver confirms an SNS subscription with `sns:ConfirmSubscription`. If the app's credentials lack that grant, visit the signed `SubscribeURL` instead:

```ruby
config.ses.subscription_confirmation = :subscribe_url
```

Only an HTTPS URL on the topic's own SNS host is visited. Anything but a 2xx answer makes the receiver answer 503, so SNS sends the confirmation again.

### Run without a sync

By default a webhook block drops mail only while a recent sync verified the provider list. An app that never mirrors the account list, for example on an SES account that other apps share, can enforce what its own webhook records:

```ruby
config.require_fresh_sync = false
```

Every recorded block then drops mail with no `Bouncy::SyncJob` at all. Nothing clears a webhook block on its own. `Bouncy.forget!` removes the local record; `Bouncy.release!` also reads and changes the account's suppression list, which other apps on a shared account rely on.

Without a sync, the webhook must also decide alone which notifications block, so `config.webhook_blocking` defaults to `:strict`:

| Notification | `:strict` (default without a sync) | `:cautious` (default with a sync) |
|---|---|---|
| Permanent bounce, `General` or `NoEmail` | Blocks | Blocks |
| Permanent bounce, any other subtype (`OnAccountSuppressionList`, `Suppressed`, `UnsubscribedRecipient`, ... and future ones) | Blocks | Recorded; the sync reads the account list |
| Transient or Undetermined bounce | Recorded only | Recorded only |
| Complaint naming one recipient | Blocks | Blocks |
| Complaint naming several recipients | Blocks every one | Recorded as candidates; the sync confirms |
| Complaint with a subtype such as `OnAccountSuppressionList` | Blocks | Recorded; the sync reads the account list |
| Complaint marked `not-spam` | Recorded only | Recorded only |

A complaint cannot tell you who complained. In [Amazon's words](https://docs.aws.amazon.com/ses/latest/dg/notification-contents.html#complained-recipients): "Most ISPs remove the email address of the recipient who submitted the complaint from their complaint notification. For this reason, this list contains information about recipients who might have sent the complaint, based on the recipients of the original message and the ISP from which we received the complaint." No field says which case a notification is, so `:strict` blocks every recipient it names: mailing someone who reported you costs more than missing one. Send one message per recipient, as Amazon advises, and a complaint names only that recipient. Set `config.webhook_blocking` yourself to choose either rule with any sync setting.

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
