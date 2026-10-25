# Configuration reference

Configure Bouncy once in `config/initializers/bouncy.rb`, using the same settings in web and job processes. Configuration is process-wide; do not switch the sending scope per request or tenant. One installed instance supports one SES account and region. Host authorization remains separate.

```ruby
Bouncy.configure do |config|
  config.scope = "ses:123456789012:us-east-1:account"
  config.ses.region = "us-east-1"
  config.ses.topic_arns = ["arn:aws:sns:us-east-1:123456789012:feedback"]
  config.ses.identities = ["example.com"]
  config.ses.configuration_sets = []
  config.ses.all_sending_paths_listed = true
  config.interception = :log
end
```

Replace the examples with your actual deployment. Set `all_sending_paths_listed` only after inventorying every sending identity and configuration set, including per-message selections. See [SES policy verification](amazon-ses.md#supported-sending-policy).

## Core settings

| Setting | Default | Meaning |
|---|---|---|
| `provider` | `:ses` | SES is the only built-in provider. |
| `scope` | `nil` | `ses:<account-id>:<region>:account`; at most 191 characters. Must match the AWS caller and SES client region. |
| `interception` | `:log` | `:log` previews dropping, `:drop` removes enforceable recipients, `:off` disables the interceptor. |
| `stale_after` | `2.hours` | Freshness window for complete syncs and address observations. Keep it positive and longer than your sync interval. |
| `require_fresh_sync` | `true` | `true` enforces provider and webhook evidence only while a complete sync is fresh. `false` enforces every recorded block with no sync, for an app that runs no `SyncJob`. |
| `webhook_blocking` | `:cautious` with `require_fresh_sync`, `:strict` without | Which notifications block. `:cautious` blocks General/NoEmail bounces and complaints naming one recipient; the sync covers the rest. `:strict` blocks every Permanent bounce and every recipient a complaint names. See [bounce handling](bounce-handling.md#ses-event-classification). |
| `record_deliveries` | `false` | Record normalized per-recipient SES Delivery events when enabled and routed to the topic. Server acceptance is not inbox placement. |
| `retention` | `90.days` | Delete events older than this by local creation time when the prune job runs. Does not delete state rows. |
| `maximum_event_age` | `90.days` | Feedback older than this cannot apply a new restriction. Retention must be at least this long; both must be positive. |
| `soft_bounce_threshold` | `nil` | Record-only by default. An integer from 1 to 50 enables escalation for repeated `MailboxFull` bounces. |
| `soft_bounce_window` | `30.days` | Positive rolling window of eligible occurrence times. |
| `soft_bounce_block_for` | `30.days` | Positive duration of the temporary local hold triggered by escalation. |
| `after_event` | No-op lambda | Called with every newly committed event. |
| `after_block` | No-op lambda | Called when an event records a transition to blocked. |
| `after_release` | No-op lambda | Called for explicit `release` events, including local-only releases. |
| `on_notification` | No-op lambda | Called with a `Bouncy::Notification` for every SES notification, after its state commits and before the receiver answers. A raise answers 503 so SNS retries. |
| `adapter` | `nil` | Advanced injection point, primarily for tests. The internal adapter contract is not a promise of support for other providers. |

The `after_*` callbacks take one `Bouncy::Event`. They are best effort; see [hook semantics](operations.md#hooks-and-instrumentation). Read current settings through `Bouncy.configuration`. `Bouncy.configure` assigns settings; `Bouncy.configuration.validate!` explicitly checks the local configuration without calling AWS. It raises on an unset scope or invalid supported options; it does not verify credentials or sending policy.

## SES settings

All are under `config.ses`:

| Setting | Default | Meaning |
|---|---|---|
| `region` | `nil` | AWS region matching the scope, SDK clients and SNS topics. |
| `credentials` | `nil` | AWS SDK credential provider shared by default SES, SNS and STS clients. `nil` uses the normal SDK chain. |
| `topic_arns` | `[]` | Exact allowed SNS topic ARNs. No wildcard or automatically trusted topic. |
| `identities` | `[]` | Every sending domain/address identity; default configuration sets are also checked. |
| `configuration_sets` | `[]` | Every explicitly selected configuration set. Empty is valid if none are used. |
| `all_sending_paths_listed` | `false` | Your assertion that the two lists are complete. Until true, policy verification cannot pass. |
| `configuration_set` | `nil` | Configuration set that the interceptor stamps as `X-SES-CONFIGURATION-SET` on every message without one, in every interception mode. It joins the policy check; you need not repeat it in `configuration_sets`. Blank stamps nothing. |
| `subscription_confirmation` | `:api` | `:api` confirms SNS subscriptions with `sns:ConfirmSubscription`. `:subscribe_url` visits the signed `SubscribeURL` instead and requires a 2xx answer. |
| `client` | `nil` | Optional injected `Aws::SESV2::Client`. |
| `sns_client` | `nil` | Optional injected `Aws::SNS::Client`. |
| `sts_client` | `nil` | Optional injected `Aws::STS::Client`. |
| `sns_message_verifier` | `nil` | Trusted signature-verifier replacement for offline tests. Keep the default in production. |

Default clients use a 3-second open timeout, 10-second read timeout and SDK retry limit of 2. These are per-request settings, not an overall sync deadline. Injected clients own their credentials/timeouts; `ses.credentials` does not override them. The bounded SNS certificate downloader and the `SubscribeURL` visit separately use a 3-second open timeout, 5-second read timeout, no redirects and no transport retries.

## Receiver body limit

`Bouncy::BodyLimit` is Rack middleware, not a setting. Insert it first, with the path your app routes to the receiver:

```ruby
# config/application.rb
config.middleware.insert_before 0, Bouncy::BodyLimit, path: "/bouncy/webhooks/ses", limit: 300.kilobytes
```

`path` defaults to `/bouncy/webhooks/ses` and `limit` to 300 KB. A request to that path reads at most `limit + 1` bytes, and a longer body answers 413. The path matches after repeated slashes are squeezed, with an optional trailing slash or format suffix (`.json`), the forms a Rails route accepts. It is compared with `PATH_INFO` and with `SCRIPT_NAME + PATH_INFO`, so it holds when the app is mounted under a prefix. Other paths, adjacent routes such as `/bouncy/webhooks/ses-admin` included, pass untouched. The receiver keeps its own 2 MiB limit.

SDK gems remain host dependencies even when injecting clients. See [SES setup](amazon-ses.md) for credentials and the signature-verifier test example.

## Development and test environments

Leave `scope` unset in environments that should not use Bouncy. Status reports `:unconfigured`, relations are empty, the interceptor leaves mail untouched and one warning is logged per process. Explicit mutations and sync raise `Bouncy::ConfigurationError`; the receiver returns 503 and logs the refusal. `Bouncy::SyncJob` and `Bouncy::PruneJob` skip with one info line.

`:off` only disables interception. It does not disable configured webhooks, synchronization or explicit mutations. A test that exercises those paths needs an isolated database and stubbed provider clients. Never use production credentials for an offline test.

There is no built-in admin framework, scheduler, AWS provisioning mode, remote manual block, marketing unsubscribe manager or resend setting. The host supplies those separate workflows where needed.
