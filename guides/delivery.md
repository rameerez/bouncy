# Action Mailer delivery boundaries

Supported paths are normal `deliver_now` and `deliver_later` when the queued job executes in a configured worker. Bouncy registers its interceptor through the Rails engine.

The interceptor calculates the recipient decision before changing the message. It checks To/Cc/Bcc and the actual SMTP envelope, preserves explicit subsets, persists skip evidence, then removes blocked recipients in `:drop` mode. Recognized database outages preserve original headers, envelope and delivery flag.

`:log` observes while allowing delivery. `:off` disables interception. Manual holds apply independently; provider-derived dropping requires a recent complete sync. An interrupted worker or unsupported policy must not enforce an old mirror forever. Log mode applies the same freshness rule, so each `skipped` event's `would_drop` and `stale_provider_evidence` flags show exactly what drop mode would have done. An unconfigured scope disables interception entirely and logs one warning.

`Bouncy.unblocked { ... }` is an execution-context exception with nested/exception-safe cleanup. It only wraps synchronous delivery; it does not serialize into jobs or apply to another process.

## Bang methods and other senders

Mail's `deliver!` invokes interceptors but bypasses `perform_deliveries`. Therefore `deliver_now!` and `deliver_later!` can attempt transport after all recipients have been removed. Built-in Mail transports reject the empty envelope. These methods are outside the supported guarantee.

Direct SDK sends, custom network clients and sister apps do not run this interceptor. Their account restrictions can still appear in a later sync. Custom transports must honor `smtp_envelope_to`; reconstructing recipients needs host integration and tests.

Review ordering if another host interceptor rewrites or adds recipients after Bouncy. An app that changes recipients later must apply the check at its final recipient decision and test the transport path.

## Host tests

Use synthetic blocked and allowed recipients in one message. Capture the actual transport envelope, not just rendered headers. Exercise Bcc, an explicit envelope different from headers, an all-blocked message and queued delivery. Simulate a database outage after lookup to prove no partial mutation occurs.
