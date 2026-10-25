# Action Mailer delivery boundaries

Supported paths are `deliver_now`, `deliver_now!`, `deliver_later` and `deliver_later!`, with queued jobs executing in a configured worker, and messages delivered with Mail directly. Bouncy registers a Mail interceptor through the Rails engine.

The interceptor wraps the message's delivery method in `Bouncy::Interceptor::Gate`, through Mail's own `Message#delivery_method(klass, settings)`. Mail's `deliver` and `deliver!` both end by calling that delivery method, after every interceptor and every Action Mailer callback, so the gate is the one point that sees the recipients the transport would get. A `before_deliver` callback or an interceptor runs before some of them; the gate runs after all of them.

The gate checks To/Cc/Bcc and the actual SMTP envelope, persists skip evidence, then removes blocked recipients in `:drop` mode. Each remaining entry keeps its text, display name included; only its bare address is looked up, so `"Ada <ADA@example.com>"` in an explicit envelope matches `ada@example.com`. When no recipient is left, the gate does not call the transport, so the bang methods, which ignore `perform_deliveries`, send nothing either. A host callback that replaces a blocked recipient with an allowed one sends to the allowed one: the decision follows what the transport gets. Recognized database outages preserve original headers, envelope and delivery flag.

`:log` observes while allowing delivery. `:off` disables interception. Manual holds apply independently; provider-derived dropping requires a recent complete sync, unless `require_fresh_sync` is `false`. An interrupted worker or unsupported policy must not enforce an old mirror forever. Log mode applies the same freshness rule, so each `skipped` event's `would_drop` and `stale_provider_evidence` flags show exactly what drop mode would have done. An unconfigured scope disables interception entirely and logs one warning.

`Bouncy.unblocked { ... }` is an execution-context exception with nested/exception-safe cleanup. It only wraps synchronous delivery; it does not serialize into jobs or apply to another process.

## The configuration set

With `config.ses.configuration_set`, the interceptor stamps `X-SES-CONFIGURATION-SET` on every message that does not name its own set. SES reads the header and removes it before delivery. The stamp does not depend on the interception mode, `Bouncy.unblocked` or the scope: turning interception off never stops the events that SES publishes for the set. The set joins the sending-policy check.

## A sender that checks and sends in one step

The interceptor decides about each message, but an app that records its own outcome ("sent", "skipped") checks the address itself first. Without a lock, a bounce can commit between that check and the send; the interceptor then drops a message the app records as sent. Hold the address around both:

```ruby
Order.transaction do
  order.lock!
  Bouncy.hold(order.email) do
    if Bouncy.blocked?(order.email)
      order.update!(receipt: "skipped")
    else
      ReceiptMailer.with(order:).receipt.deliver_now
      order.update!(receipt: "sent")
    end
  end
end
```

`Bouncy.hold` takes a shared lock for the address. Every Bouncy write to that address (webhook, sync, `block!`, `release!`) takes it exclusively first, before any row lock, until its own transaction ends. A new block therefore commits before the check or after the send. Inside a transaction the hold lasts until that transaction ends, so the outcome commits before the block. Take your own row locks before the hold, as above.

| Database | Lock | Two senders to one address |
|---|---|---|
| PostgreSQL | Advisory lock on a 64-bit key of the scope and address; transaction-level inside a transaction | Both proceed |
| MySQL | Named lock (`GET_LOCK`), waiting up to `innodb_lock_wait_timeout` | They take turns |
| SQLite | `flock` on one file beside the database, shared or exclusive, per connection | Both proceed |

A wait that times out raises `ActiveRecord::LockWaitTimeout`; the receiver answers 503 and SNS retries. A write inside the same connection's own hold does not wait for itself. The hold needs no migration. Unconfigured, `Bouncy.hold` only runs the block.

The check must see the latest committed state, not an older snapshot. Inside a hold, `Bouncy.status`, `Bouncy.blocked?`, `Bouncy.statuses` and the gate read with `LOCK IN SHARE MODE` on MySQL, which reads the latest committed row at any isolation level. PostgreSQL reads the latest state with every statement at READ COMMITTED, its default.

At PostgreSQL REPEATABLE READ or SERIALIZABLE, the statement that takes the lock fixes the transaction's snapshot before it waits, so a block committed during the wait stays invisible. `Bouncy.hold` inside such a transaction therefore raises `Bouncy::ConfigurationError` at once. Hold the address outside the transaction instead, around it: the session-level lock lasts until the block ends, and the snapshot starts after the lock. On SQLite, whose snapshot starts at a transaction's first read, use the same pattern, or take the hold before the transaction reads anything.

Hooks never run inside a lock. A write releases its address when the outermost transaction ends, and the hooks wait for that transaction's commit: after a commit callback of a `transaction(joinable: false)` savepoint they still wait for the outer transaction, and a rollback drops them. Transactional tests run inside such a transaction, which rolls back, so Bouncy's hooks do not run there; test them with `self.use_transactional_tests = false`. The hooks of a write made inside a hold run when the hold ends.

## Direct sends and other senders

Direct SDK sends, custom network clients and sister apps do not run the callback or the interceptor. Their account restrictions can still appear in a later sync. Custom transports must honor `smtp_envelope_to`; reconstructing recipients needs host integration and tests.

An interceptor that replaces the message's delivery method after Bouncy's interceptor ran removes the gate. Register such interceptors before Bouncy loads, or test the transport path.

## Host tests

Use synthetic blocked and allowed recipients in one message. Capture the actual transport envelope, not just rendered headers. Exercise Bcc, display names, an explicit envelope different from headers, an all-blocked message with each of the four delivery methods and queued delivery. Simulate a database outage after lookup to prove no partial mutation occurs.
