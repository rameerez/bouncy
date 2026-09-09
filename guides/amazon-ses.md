# Amazon SES bounce handling in Rails

Use this when a Rails mailer succeeds but SES refuses delivery because an address is on its suppression list. Bouncy works with SES SMTP and SDK-based Action Mailer delivery; management calls use separate AWS API credentials.

## Supported sending policy

The first release supports one AWS account, one region and account-level suppression of both bounces and complaints. Configure `ses:<account>:<region>:account`. The adapter verifies the AWS caller account and SES client region, reads the enabled account reasons, and checks suppression overrides on supplied configuration sets, including defaults found on configured identities.

List all sending identities and configuration sets, then set `all_sending_paths_listed = true` to confirm the lists are complete. Dynamic per-message overrides, SES tenants and other accounts are not inferred from a default mailer. Unknown or conflicting policy leaves sync in observation mode: the list is mirrored and provider-derived interception is suspended. Historical restrictions and independent manual holds remain. Read `policy_reason` in doctor, the sync summary or `Bouncy.status(address)` for the explanation. Bouncy cannot discover every future sending decision.

## Connect an existing SNS topic

1. Configure the exact topic allowlist and mount `/bouncy`. Deploy `POST /bouncy/webhooks/ses` before subscribing.
2. Review the topic's publisher policy. Allow the SES service principal only with the intended `AWS:SourceAccount` and `AWS:SourceArn` conditions. Preserve existing statements and destinations. A signature alone is insufficient if unrelated publishers can write to the authorized topic.
3. Subscribe the public HTTPS URL. Use normal SNS envelopes, not raw message delivery. Bouncy verifies the signature and confirms with the authenticated topic and token.
4. Connect bounce and complaint feedback through existing identity notification settings or configuration-set destinations. Inspect existing forwarding/defaults before changing them. Delivery events are optional.
5. Confirm the subscription is active and test feedback. Configure suitable SNS retries and optionally a dead-letter queue. Sync cannot reconstruct lost delivery or soft-bounce history.
6. Run `bouncy:doctor` and `bouncy:sync`. Schedule `Bouncy::SyncJob` hourly and `Bouncy::PruneJob` daily. Check that workers actually execute them.
7. Test a mixed-recipient message in staging. Enable `:drop` after reviewing scope and imported restrictions.

`bouncy:ses:setup` prints a read-only plan and diagnostic reads. It never creates topics, alters policies, overwrites settings, sends test mail or edits schedules. `APPLY` is rejected. Doctor reports publisher-policy review and write authorization as manual/unknown checks, rather than trying a mutation.

## IAM and SDK dependencies

Add `aws-sdk-sesv2`, `aws-sdk-sns`, and `aws-sdk-sts` to the host bundle. These load lazily.

Runtime reads use `ses:ListSuppressedDestinations`, `ses:GetSuppressedDestination`, `ses:GetAccount`, `sts:GetCallerIdentity`, plus `ses:GetEmailIdentity` and `ses:GetConfigurationSet` for configured policies. Recovery adds `ses:DeleteSuppressedDestination`. Confirmation uses `sns:ConfirmSubscription`; doctor uses `sns:GetTopicAttributes`. Restrict resource-scoped actions to intended resources where AWS supports it. This release never calls `PutSuppressedDestination` or provisioning APIs.

Set `config.ses.credentials` to an AWS credential provider to share the same credentials across SES, SNS and STS. For `aws-actionmailer-ses`, pass the credential object and region from the mailer's `ses_settings`; the AWS default chain does not read Rails encrypted credentials. [AWS credential-provider documentation](https://docs.aws.amazon.com/sdk-for-ruby/v3/developer-guide/credential-providers.html).

Inject SDK clients through `config.ses.client`, `sns_client`, and `sts_client` if needed. Keep account and region consistent. Default clients use bounded connection/read timeouts and retries. Never print credentials in setup output.

### Rails encrypted credentials

When the mailer already builds an AWS credential provider, share that object with Bouncy. Otherwise, for a host storing an `aws` section in encrypted credentials:

```ruby
# config/initializers/bouncy.rb, alongside the scope/topic configuration
require "aws-sdk-sesv2"

settings = Rails.application.credentials.fetch(:aws)
Bouncy.configure do |config|
  config.ses.region = settings.fetch(:region)
  config.ses.credentials = Aws::Credentials.new(
    settings.fetch(:access_key_id),
    settings.fetch(:secret_access_key),
    settings[:session_token]
  )
end
```

These are example credential key names; use your app's existing schema. Prefer the SDK credential chain when your deployment supplies role credentials that refresh automatically. A static `Aws::Credentials` object will not refresh expiring session credentials. Never copy SMTP passwords into these settings.

### Permission checklist

The following are the API actions the shipped adapter calls. Grant them to the app's API identity, independently of the identity used to send through SMTP:

| Action | Used for |
|---|---|
| `ses:ListSuppressedDestinations` | Full provider enumeration for sync and release |
| `ses:GetSuppressedDestination` | Exact-identifier absence checks |
| `ses:GetAccount` | Account suppression reasons |
| `ses:GetEmailIdentity` | Default configuration sets on each configured identity |
| `ses:GetConfigurationSet` | Suppression overrides on explicit and discovered default sets |
| `ses:DeleteSuppressedDestination` | Explicit provider recovery only |
| `sns:ConfirmSubscription` | Confirm the authorized receiver subscription |
| `sns:GetTopicAttributes` | Doctor's topic readability/publisher-policy review information |
| `sts:GetCallerIdentity` | Verify the credentials' account |

Scope grants to the intended region and resources where supported. Account-level SES actions need account-level access; a send-only grant on a domain identity is insufficient. STS caller identity is an identity lookup, not proof of any SES/SNS grant. A read-only role can run observation/sync with the required reads, but cannot perform provider recovery. Doctor does not prove deletion permission.

### Topic publisher policy

The runtime IAM identity and the SNS topic publisher policy are separate. For identity-level SES feedback, review a statement like this on your intended topic, replacing every example value:

```json
{
  "Sid": "AllowIntendedSesIdentity",
  "Effect": "Allow",
  "Principal": { "Service": "ses.amazonaws.com" },
  "Action": "sns:Publish",
  "Resource": "arn:aws:sns:us-east-1:123456789012:feedback",
  "Condition": {
    "StringEquals": { "AWS:SourceAccount": "123456789012" },
    "ArnEquals": { "AWS:SourceArn": "arn:aws:ses:us-east-1:123456789012:identity/example.com" }
  }
}
```

This is one statement to merge into a reviewed policy, not a replacement for the whole policy. Check other statements for unrelated publisher access. Configuration-set event destinations need the source conditions appropriate to that destination. Follow [AWS's SNS notification setup](https://docs.aws.amazon.com/ses/latest/dg/configure-sns-notifications.html) for identity notifications and preserve existing destinations. Review the [account suppression settings](https://docs.aws.amazon.com/ses/latest/dg/sending-email-suppression-list.html) before asserting that both bounce and complaint suppression apply to every sending path.

## Testing your mounted receiver

A host test that posts to the mounted route would otherwise download Amazon's signing certificate over the network. `config.ses.sns_message_verifier` injects the signature verifier. The following test subclass changes only certificate retrieval while retaining RSA verification:

```ruby
class LocalCertificate < Aws::SNS::MessageVerifier
  private

  def https_get(*) = OpenSSL::X509::Certificate.new(File.read("test/fixtures/sns.pem")).to_pem
end

Bouncy.configuration.ses.sns_message_verifier = LocalCertificate.new
```

Topic authorization and certificate-URL checks run outside the injected verifier. This example also retains the SDK's RSA signature check. The injected object itself is trusted: replacing it with a verifier that always succeeds would skip cryptographic authentication, so keep the default in production. Sign fixtures with a locally generated key and assert that a valid signature on an unlisted `TopicArn` is rejected.

## Failure and ordering

The webhook commits each recipient's event and address transition before acknowledging. Retries deduplicate independently. Authentication failure returns 401, malformed input 400, oversized bodies 413 and recognized transient provider/database failures 503.

Bodies are bounded to 2 MiB before parsing. Set a corresponding proxy limit. Certificate retrieval permits strict regional SNS HTTPS URLs, verifies TLS, rejects redirects and caps responses. Transport outages remain retryable.

Sync enumerates all pages without a time filter. Failure or unsupported policy is not a successful empty list. Clearing missing restrictions requires complete enumeration, exact identifier checks and unchanged local state. Webhook-only blocking evidence is not cleared on a single absent list entry: it must be over an hour old and absent across two qualifying checks. Independent manual and soft holds are preserved. Provider pagination is not an atomic snapshot; remote writers can change state after any observation. Inspect freshness and failures.

SES management addresses are case-sensitive. Bouncy retains exact spelling independently of lowercase local lookup keys and releases all observed variants. A lowercase NotFound does not establish that another case variant is absent.

Ordinary complaint notifications can name candidate recipients when the mailbox provider redacts the complainer. Bouncy blocks locally only when exactly one recipient is named; otherwise it records candidates and lets the next complete sync establish the restriction from the provider's own list. Account-list refusal events are hints rather than new mailbox failures. Complaint subtypes `OnAccountSuppressionList` and `OnTenantSuppressionList` describe existing suppression, not a new complaint: the former is a provider-list hint, the latter an unsupported-scope diagnostic. Unknown complaint subtypes remain diagnostics. These distinctions follow the [SES notification contract](https://docs.aws.amazon.com/ses/latest/dg/notification-contents.html). Allow up to the next scheduled sync for account-list hints in the initial implementation.

Reconciliation is idempotent: an identical address observation refreshes its check time without address events, hooks or version bumps. Changed provider timestamps are saved and advance the row version so concurrent recovery cannot clear newer evidence; they create no restriction event when the address and reason are unchanged. Every run still records a sync summary. Partial lists can refresh listed variants but cannot erase missing ones. Rows with neither provider evidence nor a webhook-derived block are never looked up at the provider. Only one sync runs per scope at a time; a second one fails immediately with `Bouncy::ProviderError` instead of queueing behind a run that may be waiting on AWS.

Only inject a trusted verifier that performs signature verification. Bouncy still checks topic authorization and the certificate URL, but a custom verifier controls signature checking; keep offline substitutes in tests.
