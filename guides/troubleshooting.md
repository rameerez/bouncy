# Action Mailer says sent, but the email was not received

Start by separating what you know:

1. A mailer job completed: your app ran the send path.
2. SES accepted a send request: the provider accepted responsibility for processing it.
3. A delivery event arrived: the receiving server accepted the message.
4. The person saw the message: only the person or another appropriate signal can establish that.

Bouncy records known restrictions and selected provider events. Missing evidence does not mean successful delivery. Spam placement, recipient filters, content problems and incorrect recipient selection may require investigation elsewhere.

```ruby
status = Bouncy.status(address)
[status.knowledge, status.reasons, status.stale?, status.observed_at]
Bouncy.events.for(address).recent.limit(20)
```

## An address is on the SES suppression list

`OnAccountSuppressionList` means SES refused a send because a restriction already existed. It is not a new hard bounce. A complete `Bouncy.sync!` imports restrictions from before installation, sister apps on the same account, missed notifications and console changes.

Inspect the underlying reason and the account/region. After verifying that recovery is appropriate, an authorized support action can call `Bouncy.release!(address, note: ...)`. This operates on exact-case provider identifiers and confirms removal. A lowercase console/API lookup alone may miss another case variant.

Release never resends the original email. Regenerate time-sensitive links in an explicitly authorized host action if a resend is needed. See [recovery](recovery.md).

## Nothing is appearing locally

- Check the configured account, region, credentials and exact SNS topic allowlist.
- Run `bouncy:doctor`. An unknown/manual publisher-policy check is not a pass. If `policy_verified` is false, read `policy_reason`: until it passes, sync mirrors the provider list without enforcing it, and `Bouncy.status(address).policy_unverified?` is true for listed addresses.
- If `Bouncy.status(address).knowledge` is `:unconfigured`, `config.scope` is blank and Bouncy is inactive in that environment.
- Confirm the SNS HTTPS subscription is active and points at the actual mounted route.
- Confirm SES routes the needed event types to that topic, and raw SNS message delivery is disabled.
- Inspect bounded receiver status codes: 401 authorization/signature, 400 malformed input, 413 body limit, 503 retryable infrastructure failure.
- Run a complete sync and verify the scheduled job actually runs in production.

An hourly sync cannot reconstruct every lost delivery or soft-bounce event. SNS retries and operational monitoring still matter.

## The mirror is stale or unavailable

Compare `Bouncy.last_sync` and `Bouncy.last_successful_sync`. A failed/partial run cannot prove absence. A provider scope mismatch blocks authoritative reconciliation. Check credentials, API permissions, configuration-set overrides and worker execution.

Recognized database read outages produce an unavailable status and fail open for interception. Ordinary SQL/programming errors raise. In drop mode, provider-derived enforcement needs a recent complete sync; independent manual holds do not depend on provider freshness.

## A message was locally skipped

Inspect its recipient's `skipped` event and mode. `:log` observes the decision while delivering. `:drop` removes restricted recipients from both headers and envelope. Custom transports or later interceptors that rewrite recipients require host tests. Never infer a send from the absence of a skip record.
