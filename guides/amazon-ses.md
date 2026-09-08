# Amazon SES bounce handling in Rails

Use this when a Rails mailer succeeds but SES refuses delivery because an address is on its suppression list. Bouncy works with SES SMTP and SDK-based Action Mailer delivery; management calls use separate AWS API credentials.

## Supported sending policy

The first release supports one AWS account, one region and account-level suppression of both bounces and complaints. Configure `ses:<account>:<region>:account`. The adapter verifies the AWS caller account and SES client region, reads the enabled account reasons, and checks suppression overrides on supplied configuration sets, including defaults found on configured identities.

List all sending identities and configuration sets, then set `all_sending_paths_listed = true` to confirm the lists are complete. Dynamic per-message overrides, SES tenants and other accounts are not inferred from a default mailer. Unknown or conflicting policy leaves sync in observation mode: the list is mirrored, nothing is enforced, and `bouncy:doctor` and each `sync` event carry a `policy_reason` in plain words. Bouncy cannot discover every future sending decision.

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

Inject SDK clients through `config.ses.client`, `sns_client`, and `sts_client` if needed. Keep account and region consistent. Default clients use bounded connection/read timeouts and retries. Never print credentials in setup output.

## Failure and ordering

The webhook commits each recipient's event and address transition before acknowledging. Retries deduplicate independently. Authentication failure returns 401, malformed input 400, oversized bodies 413 and recognized transient provider/database failures 503.

Bodies are bounded to 2 MiB before parsing. Set a corresponding proxy limit. Certificate retrieval permits strict regional SNS HTTPS URLs, verifies TLS, rejects redirects and caps responses. Transport outages remain retryable.

Sync enumerates all pages without a time filter. Failure or unsupported policy is not a successful empty list. Clearing missing restrictions requires complete enumeration, exact identifier checks and unchanged local state. Provider pagination is not an atomic snapshot; remote writers can change state after any observation. Inspect freshness and failures.

SES management addresses are case-sensitive. Bouncy retains exact spelling independently of lowercase local lookup keys and releases all observed variants. A lowercase NotFound does not establish that another case variant is absent.

Complaint notifications name every recipient of the message when the mailbox provider redacts the complainer. Bouncy blocks locally only when exactly one recipient is named; otherwise it records candidates and lets the next complete sync establish the restriction from the provider's own list. Account-list refusal events are hints rather than new mailbox failures. Allow up to the next scheduled sync for these hints in the initial implementation.

Reconciliation is idempotent: a snapshot that changes nothing about an address refreshes its observation time only, without events, hooks or version bumps. Rows with neither provider evidence nor a webhook-derived block are never looked up at the provider. Only one sync runs per scope at a time; a second one fails immediately with `Bouncy::ProviderError` instead of queueing behind a run that may be waiting on AWS.
