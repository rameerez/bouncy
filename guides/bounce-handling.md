# Handling bounced emails in Rails

Your sending provider can refuse a known restricted address while your application keeps treating it as a normal contact. Bouncy embeds that provider state in Rails so a support person can inspect the reason, the app can avoid repeated attempts, and authorized recovery can reach the provider before clearing local evidence.

```ruby
Bouncy.blocked?("invitee@example.com")
Bouncy.status("invitee@example.com").reasons
Bouncy.events.for("invitee@example.com").recent
```

No User record is needed. Optional `bouncy :email` model integration adds predicates and scopes when you do have a customer/contact model. Keep its stored comparison column normalized consistently with the API.

Start with [SES setup](amazon-ses.md). Both SES SMTP and Action Mailer SDK delivery can use the same management API mirror. API credentials are separate from SMTP credentials. Import historical restrictions before enabling delivery interception.

Webhooks handle new events promptly; recurring full sync covers prior history, shared-account changes, missed notifications and console releases. Neither mechanism proves every mailbox is reachable. Soft bounces are record-only unless you configure a threshold, an ordinary complaint blocks locally only when it names a single recipient, and message-size failures never globally invalidate an address. Suppression-list refusal notices are recorded separately from new complaints.

## SES event classification in v0.1.0

The adapter supports identity `notificationType` and configuration-set `eventType` envelopes. It records the normalized kind separately from the provider subtype:

| SES feedback | Local kind / effect |
|---|---|
| Permanent bounce, `General` or `NoEmail` | `hard_bounce`; records a webhook-derived block. |
| Transient or Undetermined bounce | `soft_bounce`; record-only unless eligible mailbox-full escalation is enabled. |
| `OnAccountSuppressionList` bounce or complaint | `provider_suppressed`; evidence of a prior refusal, not a new hard bounce/complaint block. Sync imports the list's reason. |
| `Suppressed`, `OnTenantSuppressionList`, `EmailValidationSuppressed` bounce | `unknown`; no inferred account-level block. |
| `UnsubscribedRecipient` bounce | `unsubscribe`; no global block or subscription management. |
| Ordinary complaint with exactly one named recipient | `complaint` with confirmed certainty; records a local block. |
| Ordinary complaint naming several recipients | `complaint` candidates; no block until the provider list confirms the address. |
| Complaint marked `not-spam` | `ignored`; does not automatically release existing evidence. |
| Other/unrecognized bounce or complaint subtype | `unknown`; retained for investigation. |
| Delivery | `delivery` per recipient only when `record_deliveries` is enabled; otherwise an addressless `ignored` observation. Does not release a block. |
| DeliveryDelay | `delay`; no mailbox-full escalation or global block. |
| Reject / Rendering Failure | Addressless `reject` / `rendering_failure` event; no global address restriction. |
| Other event types | `ignored`; no open/click tracking or subscription handling. |

The receiving server's acceptance is not evidence of inbox placement. See [AWS's notification fields](https://docs.aws.amazon.com/ses/latest/dg/notification-contents.html) for provider payload definitions.

Invalid recipients cannot acquire a hold. Old, future-dated (more than five minutes ahead), out-of-order blocking feedback and feedback fenced by a release are retained with `details["ignored_for_policy"]` rather than applying a new restriction. Soft events can arrive out of order within their active window. Retries use a dedupe identity that includes scope, provider, feedback ID, kind and recipient.

Blocking evidence is separate from enforcement: even a confirmed hard bounce requires a fresh authoritative sync for provider-derived interception. Manual and active soft holds are independent local policy. See [delivery](delivery.md).

## Repeated soft bounces

`config.soft_bounce_threshold` (default `nil`) turns repeated SES `MailboxFull` bounces into a local hold once that many fall inside `config.soft_bounce_window`, lasting `config.soft_bounce_block_for`. Occurrence times are retained per address and bounded, so the window rolls instead of accumulating a total that only grows, and redelivered notifications count once because event deduplication runs first.

This is your policy, not the provider's: the address is not on the provider's suppression list, so the hold applies regardless of sync freshness, exactly like a manual hold, and `Bouncy.release!` clears the counters along with the hold. Choose an integer threshold from 1 to 50. Content, size, attachment and unknown failures never count toward it. The adapter marks eligible observations explicitly; the core does not infer eligibility from an arbitrary negative event.

Migrating from an existing threshold of your own? Preserve timed holds with their original expiry; preserve indefinite holds as explicit manual holds with a migration note. Review differences between the old rule and mailbox-only escalation instead of inventing an expiry at cutover. See [migrating](migrating.md).

For the support workflow, see [admin integration](admin.md) and [recovery](recovery.md). For someone who says the email never arrived, follow [troubleshooting](troubleshooting.md) rather than assuming suppression is always the cause.

Bouncy does not manage marketing subscriptions, transport retries, open/click tracking or a complete outbound-message archive. Keep the tools you use for those jobs. A provider console may be enough when you do not need app-visible state or embedded recovery. There is no requirement to adopt another dependency merely to receive a bounce notification.
