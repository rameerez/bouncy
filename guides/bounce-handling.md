# Handling bounced emails in Rails

Your sending provider can refuse a known restricted address while your application keeps treating it as a normal contact. Bouncy embeds that provider state in Rails so a support person can inspect the reason, the app can avoid repeated attempts, and authorized recovery can reach the provider before clearing local evidence.

```ruby
Bouncy.blocked?("invitee@example.com")
Bouncy.status("invitee@example.com").reasons
Bouncy.events.for("invitee@example.com").recent
```

No User record is needed. Optional `bouncy :email` model integration adds predicates and scopes when you do have a customer/contact model. Keep its stored comparison column normalized consistently with the API.

Start with [SES setup](amazon-ses.md). Both SES SMTP and Action Mailer SDK delivery can use the same management API mirror. API credentials are separate from SMTP credentials. Import historical restrictions before enabling delivery interception.

Webhooks handle new events promptly; recurring full sync covers prior history, shared-account changes, missed notifications and console releases. Neither mechanism proves every mailbox is reachable. Soft bounces are record-only, an ordinary complaint blocks locally only when it names a single recipient, and message-size failures never globally invalidate an address. Suppression-list refusal notices are recorded separately from new complaints.

For the support workflow, see [admin integration](admin.md) and [recovery](recovery.md). For someone who says the email never arrived, follow [troubleshooting](troubleshooting.md) rather than assuming suppression is always the cause.

Bouncy does not manage marketing subscriptions, transport retries, open/click tracking or a complete outbound-message archive. Keep the tools you use for those jobs. A provider console may be enough when you do not need app-visible state or embedded recovery. There is no requirement to adopt another dependency merely to receive a bounce notification.
