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
| `provider` | `:ses` | SES is the only built-in provider in v0.1.0. |
| `scope` | `nil` | `ses:<account-id>:<region>:account`; at most 191 characters. Must match the AWS caller and SES client region. |
| `interception` | `:log` | `:log` previews dropping, `:drop` removes enforceable recipients, `:off` disables the interceptor. |
| `stale_after` | `2.hours` | Freshness window for complete syncs and address observations. Keep it positive and longer than your sync interval. |
| `record_deliveries` | `false` | Record normalized per-recipient SES Delivery events when enabled and routed to the topic. Server acceptance is not inbox placement. |
| `retention` | `90.days` | Delete events older than this by local creation time when the prune job runs. Does not delete state rows. |
| `maximum_event_age` | `90.days` | Feedback older than this cannot apply a new restriction. Retention must be at least this long; both must be positive. |
| `soft_bounce_threshold` | `nil` | Record-only by default. An integer from 1 to 50 enables escalation for repeated `MailboxFull` bounces. |
| `soft_bounce_window` | `30.days` | Positive rolling window of eligible occurrence times. |
| `soft_bounce_block_for` | `30.days` | Positive duration of the temporary local hold triggered by escalation. |
| `after_event` | No-op lambda | Called with every newly committed event. |
| `after_block` | No-op lambda | Called when an event records a transition to blocked. |
| `after_release` | No-op lambda | Called for explicit `release` events, including local-only releases. |
| `adapter` | `nil` | Advanced injection point, primarily for tests. The internal adapter contract is not a promise of support for other providers. |

Callbacks take one `Bouncy::Event`. They are best effort; see [hook semantics](operations.md#hooks-and-instrumentation). Read current settings through `Bouncy.configuration`. `Bouncy.configure` assigns settings; `Bouncy.configuration.validate!` explicitly checks the local configuration without calling AWS. It raises on an unset scope or invalid supported options; it does not verify credentials or sending policy.

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
| `client` | `nil` | Optional injected `Aws::SESV2::Client`. |
| `sns_client` | `nil` | Optional injected `Aws::SNS::Client`. |
| `sts_client` | `nil` | Optional injected `Aws::STS::Client`. |
| `sns_message_verifier` | `nil` | Trusted signature-verifier replacement for offline tests. Keep the default in production. |

Default clients use a 3-second open timeout, 10-second read timeout and SDK retry limit of 2. These are per-request settings, not an overall sync deadline. Injected clients own their credentials/timeouts; `ses.credentials` does not override them. The bounded SNS certificate downloader separately uses a 3-second open timeout, 5-second read timeout and no transport retries.

SDK gems remain host dependencies even when injecting clients. See [SES setup](amazon-ses.md) for credentials and the signature-verifier test example.

## Development and test environments

Leave `scope` unset in environments that should not use Bouncy. Status reports `:unconfigured`, relations are empty, the interceptor leaves mail untouched and one warning is logged per process. Explicit mutations and sync raise `Bouncy::ConfigurationError`; the receiver returns 503.

`:off` only disables interception. It does not disable configured webhooks, synchronization or explicit mutations. A test that exercises those paths needs an isolated database and stubbed provider clients. Never use production credentials for an offline test.

There is no built-in admin framework, scheduler, AWS provisioning mode, remote manual block, marketing unsubscribe manager or resend setting. The host supplies those separate workflows where needed.
