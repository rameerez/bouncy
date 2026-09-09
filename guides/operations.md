# Scheduling, monitoring and operations

Bouncy supplies Active Job classes and Rails tasks. It does not install a scheduler, edit recurring-job files or start workers. Configure the same scope, credentials and dependencies in web and job processes.

## Schedule the jobs

Run `Bouncy::SyncJob` hourly and `Bouncy::PruneJob` daily. Both use the `default` queue. Ensure a worker consumes it; enqueuing a job is not evidence that it ran.

For an app already using [Solid Queue recurring tasks](https://github.com/rails/solid_queue#recurring-tasks):

```yaml
# config/recurring.yml
production:
  bouncy_sync:
    class: Bouncy::SyncJob
    schedule: every hour
  bouncy_prune:
    class: Bouncy::PruneJob
    schedule: every day at 3am
```

Merge these entries into your existing production section. Start the scheduler and workers using your app's normal deployment process. Solid Queue is optional. Other schedulers can enqueue the same classes:

```ruby
Bouncy::SyncJob.perform_later
Bouncy::PruneJob.perform_later
```

If you use cron instead, run the work synchronously in the app's configured environment:

```cron
0 * * * * cd /srv/myapp && RAILS_ENV=production bin/rails bouncy:sync
0 3 * * * cd /srv/myapp && RAILS_ENV=production bin/rails runner 'Bouncy::PruneJob.perform_now'
```

Adapt the path and Ruby/environment setup to your deployment. Choose one recurring mechanism. Configure failure alerts and retries through your existing job system; these jobs do not declare a custom retry policy.

A second sync in the same scope fails immediately with `Bouncy::ProviderError` if another owns the lock. Do not overlap scheduled runs unnecessarily. See [database lock requirements](compatibility.md#synchronization).

## Available tasks

Run with `RAILS_ENV=production` in production:

| Command | Effect |
|---|---|
| `bin/rails bouncy:doctor` | Read AWS identity/policy/topic attributes and local sync times; print JSON. Does not mutate AWS or test write permission. |
| `bin/rails bouncy:ses:setup` | Run provider diagnostics and print a setup plan. Never provisions AWS. Any `APPLY` environment variable is rejected, including `APPLY=0`. |
| `bin/rails bouncy:sync` | Read the full provider list, reconcile local rows and print the sync event details. |
| `bin/rails bouncy:bootstrap` | Require a fresh, complete, policy-verified mirror, running a sync if necessary; raise on failure. |

Doctor reports `policy_verified`, `policy_reason`, `topic_allowlist`, per-topic readability and publisher-policy review requirements, plus `last_attempt` and `last_success`. Write permission remains unknown until an explicitly authorized operation is exercised. It does not verify public endpoint reachability, subscription activation, notification delivery or job scheduling.

A normal exit from doctor or sync can still describe an unverified policy. Inspect the JSON, not just the exit status. AWS read failures may raise before doctor/setup can print a result. Bootstrap is the strict freshness check for a planned cutover; do not put it on every container restart and make unrelated deployments depend on live AWS availability.

## Monitor the mirror

```ruby
Bouncy.sync_fresh?
Bouncy.last_sync&.details
Bouncy.last_successful_sync&.created_at
```

A successful authoritative summary has `complete: true`, `enumerated: true`, `policy_verified: true`, and entry/change counts. An enumerated list with unsupported policy has `complete: false` and an explanation in `policy_reason`. A recorded provider error has `complete: false` and `error_class`.

`entries` counts exact provider entries; address counts are normalized. Metadata-only refreshes and unchanged restrictions do not emit per-address change events. Each completed reconciliation still emits a summary. A lock acquisition failure or some configuration/database failures can occur before a summary is recorded; monitor job failures as well as freshness.

Keep the sync interval shorter than `stale_after` (default two hours). If the mirror is stale or a newer sync reports unverified policy, the interceptor stops dropping based on provider/webhook evidence. Independent manual and active soft holds remain effective. The status API can still show historical restrictions; it describes evidence, not the current transport decision.

A host health check can use `Bouncy.sync_fresh?` and rescue recognized database outages to report an unhealthy dependency. Decide in the host whether to expose this as a separate email-health indicator or affect overall readiness. Do not expose address history or provider diagnostics in an unauthenticated health response.

## Hooks and instrumentation

```ruby
Bouncy.configure do |config|
  config.after_event = ->(event) { Rails.logger.info("Bouncy event #{event.id}: #{event.kind}") }
  config.after_block = ->(event) { SupportNotificationJob.perform_later(event.id) }
  config.after_release = ->(event) { RecoveryNotificationJob.perform_later(event.id) }
end
```

Implement the example jobs in the host. Callbacks receive a committed `Bouncy::Event`. `after_event` runs for every newly created event, including sync summaries and interception observations. `after_block` runs when `details["became_blocked"]` is true, not for every repeated bounce. `after_release` runs for explicit `release` events, including local-only releases; it does not run for `sync_released`. Use `after_event` with a kind check if you need to observe reconciliation releases.

Hooks are best effort. Exceptions emit `hook_error.bouncy` with `hook` and `error_class`, and do not undo the event. A process can stop after commit before notification completes. Use idempotent consumers and a host outbox/reconciliation mechanism for guaranteed external work. Jobs should tolerate an event being pruned before execution.

Other Active Support notifications are `unconfigured.bouncy` (operation attempted while inactive) and `unavailable.bouncy` (interception encounters a recognized database outage). Subscribe using your existing instrumentation:

```ruby
ActiveSupport::Notifications.subscribe("hook_error.bouncy") do |*args|
  notification = ActiveSupport::Notifications::Event.new(*args)
  Rails.logger.error("Bouncy hook failed: #{notification.payload[:hook]} (#{notification.payload[:error_class]})")
end
```

These are not delivery receipts. Avoid logging addresses, raw payloads or arbitrary exception messages.

## Retention and operational history

Schedule pruning; setting retention alone deletes nothing. `PruneJob` deletes events whose local `created_at` is older than the configured duration. Current state, exact provider evidence and inactive release fences remain. See [privacy and erasure](privacy.md).

Use `Bouncy.events.for(address).recent` for occurrence-ordered address history. Operational events such as sync summaries may have no address. `skipped` events include `mode`, `would_drop`, `dropped` and `stale_provider_evidence`: in log mode, they preview the enforcement decision while delivery continues.

The gem does not send test messages or automatically resend after recovery. Exercise the real SES feedback and authorized recovery lifecycle in your own staging setup before relying on dropping in production. Automated SDK/signature tests are not a substitute for validating your credentials, topic and delivery path.
