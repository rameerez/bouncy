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

## Repeated soft bounces

`config.soft_bounce_threshold` (default `nil`) turns repeated SES `MailboxFull` bounces into a local hold once that many fall inside `config.soft_bounce_window`, lasting `config.soft_bounce_block_for`. Occurrence times are retained per address and bounded, so the window rolls instead of accumulating a total that only grows, and redelivered notifications count once because event deduplication runs first.

This is your policy, not the provider's: the address is not on the provider's suppression list, so the hold applies regardless of sync freshness, exactly like a manual hold, and `Bouncy.release!` clears the counters along with the hold. Choose an integer threshold from 1 to 50. Content, size, attachment and unknown failures never count toward it. The adapter marks eligible observations explicitly; the core does not infer eligibility from an arbitrary negative event.

Migrating from an existing threshold of your own? Preserve timed holds with their original expiry; preserve indefinite holds as explicit manual holds with a migration note. Review differences between the old rule and mailbox-only escalation instead of inventing an expiry at cutover. See [migrating](migrating.md).

For the support workflow, see [admin integration](admin.md) and [recovery](recovery.md). For someone who says the email never arrived, follow [troubleshooting](troubleshooting.md) rather than assuming suppression is always the cause.

Bouncy does not manage marketing subscriptions, transport retries, open/click tracking or a complete outbound-message archive. Keep the tools you use for those jobs. A provider console may be enough when you do not need app-visible state or embedded recovery. There is no requirement to adopt another dependency merely to receive a bounce notification.
