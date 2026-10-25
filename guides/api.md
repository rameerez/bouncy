# API reference

All operations use the configured sending scope. Addresses are compared after trimming whitespace and lowercasing; exact provider identifiers are retained separately for SES management calls. This is a lookup policy, not mailbox verification. Invalid input to a single-address lookup raises `Bouncy::InvalidAddress` when configured.

## Address status

```ruby
status = Bouncy.status(" Ada@Example.com ")
Bouncy.blocked?("ada@example.com") # Same as status.blocked?
```

| Reader | Meaning |
|---|---|
| `blocked?` | Any effective local restriction exists. Does not incorporate the interceptor's mode or global sync freshness. |
| `reasons` | Array containing any of `:complaint`, `:hard_bounce`, `:provider_list`, `:manual`, `:soft_bounces`. |
| `reason` | First reason in the priority order above, or `nil`. |
| `knowledge` | `:observed` when a row exists; `:no_known_block` when none exists; `:unavailable` on recognized database outages; `:unconfigured` when no scope is set. An observed row can be inactive after release. |
| `email` | Normalized address from the row, or `nil` if there is no row. |
| `scope`, `provider` | Configuration captured when the status was constructed. |
| `record` | Underlying `Bouncy::Suppression`, or `nil`, for host-owned admin links. |
| `provider_listed?` | Exact provider entries exist in the local mirror, even if policy verification has not made them enforceable. |
| `provider_updated_at` | Latest update time among those provider entries, or `nil`. |
| `blocked_at` | Time the block in force began: when the address became blocked locally, or the `at:` time of the `Bouncy.import!` that blocked it. Stays while further evidence arrives; a block after an expired soft hold starts anew. `nil` when not blocked. |
| `observed_at` | Provider check time if present, otherwise the last address event time, or `nil`. |
| `stale?` | True for unavailable/unconfigured knowledge, missing observation time or an observation older than `stale_after`. This is address freshness; use `Bouncy.sync_fresh?` for mirror health. |
| `policy_unverified?` | A locally listed address whose latest scoped sync did not report verified sending policy. |
| `policy_reason` | Explanation for that unverified policy; `nil` when verified or not listed locally. |
| `last_event` | Latest address event by occurrence time and ID, or `nil`; fetched lazily. |
| `release_supported?` | Whether the available status uses the supported SES provider. Does not test IAM rights or authorize an operator. |

A false boolean is not a deliverability guarantee. Recognized database connection outages return unavailable status; missing tables, invalid SQL and programming errors still raise. Obtain a new status after a state change or sync; existing objects are not live subscriptions.

## Batch lookup

```ruby
statuses = Bouncy.statuses(users.map(&:email))
statuses["ADA@example.com"].reasons
statuses.each { |email, status| puts [email, status.knowledge].join(": ") }
statuses.size
statuses.to_h
statuses.blocked # Hash containing only blocked entries
```

`Bouncy::StatusSet` includes `Enumerable`. Inputs are normalized and deduplicated; invalid entries are skipped. One query loads restriction rows. Accessing `last_event` or policy diagnostics can issue additional queries.

A lookup for an address not included in the batch does not query the database and returns no-known-block status. Include every address you need to inspect. When unconfigured or unavailable, each requested valid address remains in the enumeration with that knowledge, and lookups return it too.

## Model integration

```ruby
class User < ApplicationRecord
  normalizes :email, with: ->(value) { value.strip.downcase }
  bouncy :email
  normalizes :billing_email, with: ->(value) { value.strip.downcase }
  bouncy :billing_email
end

user.email_status
user.email_blocked?
user.email_bounced?     # Hard bounce or active soft-bounce hold
user.email_complained?

User.email_blocked
User.email_bounced
User.email_unblocked
```

Each configured attribute gets the same methods with its own prefix. There is no `email_complained` class scope. Blank values are false for the boolean predicates and excluded from the unblocked scope; a direct `email_status` call still follows single-address input validation.

SQL scopes expect stored values to use the same trimmed lowercase comparison. Normalize every configured attribute and backfill existing data in the host. If you preserve mixed-case display values, use a persisted comparison column:

```ruby
bouncy :email, normalized_attribute: :canonical_email
```

The override applies to status and predicates as well as scopes. Your app must populate that column correctly. A normalized override accepts one attribute per macro call. No model integration is required for recipients without a host record.

## Queries and mutations

| Method | Behavior |
|---|---|
| `Bouncy.blocked` | Scoped ActiveRecord relation of currently restricted suppression rows. |
| `Bouncy.events` | Scoped event relation; chain `.for(address).recent.limit(50)`. |
| `Bouncy.block!(address, note:, actor: nil)` | Add a local manual hold; a nonblank note is required. Returns the suppression row. Does not call SES. |
| `Bouncy.import!(address, reason:, at:, note: nil, actor: nil)` | Record a block that another system recorded at `at`, with `reason` `:hard_bounce`, `:complaint` or `:manual`. Returns the suppression row. Does not call SES. See [imports](#imports). |
| `Bouncy.release!(address, note: nil, actor: nil, at: :provider)` | Provider-aware release by default, requiring a note and verified provider snapshot. Returns the row; may raise on partial remote success. |
| `Bouncy.release!(address, at: :local)` | Clear manual and soft holds and their soft-bounce history; fence delayed pre-release soft feedback and preserve provider/webhook blocks. No provider request. A note is optional. |
| `Bouncy.forget!(address)` | Delete local state and events, including release metadata; no provider mutation. A later sync can reimport the address. |
| `Bouncy.sync!` | Run reconciliation now and return its summary event. Writes local state and reads AWS. |
| `Bouncy.bootstrap!` | Return a fresh complete sync, running one if needed; raise if freshness and policy cannot be established. Explicit cutover check. |
| `Bouncy.last_sync` | Latest sync summary, including recorded failures, or `nil`. |
| `Bouncy.last_successful_sync` | Latest summary marked complete, possibly old, or `nil`. |
| `Bouncy.sync_fresh?` | True only when the latest summary is complete and within `stale_after`. A later recorded failure makes it false. |
| `Bouncy.configured?` | Whether a nonblank scope is assigned; no AWS verification. |
| `Bouncy.scope` | Configured scope after local configuration validation. |
| `Bouncy.unblocked { ... }` | Temporarily bypass interception for synchronous delivery in this execution context. Does not travel with queued jobs. |
| `Bouncy.hold(address) { ... }` | Hold the address while the block runs, and inside a transaction until it ends, so no Bouncy write to it commits between the app's own check and its send. Returns the block's value. See [a sender that checks and sends](delivery.md#a-sender-that-checks-and-sends-in-one-step). |

## Imports

`Bouncy.import!` carries a block from another system, such as the suppression table an app kept before Bouncy. `Bouncy.block!` stays a support action: it holds the address now, needs a note and calls `after_block`. An import records what another system already knew:

```ruby
Bouncy.import!("ada@example.com", reason: :complaint, at: Time.utc(2025, 3, 1), note: "Carried from the old table", actor: "carry-task")
```

- A `:hard_bounce` or `:complaint` becomes the same evidence as a webhook block. It drops mail under the same rule (a fresh sync, or `require_fresh_sync = false`), and a sync clears it under the same [absence rule](amazon-ses.md#failure-and-ordering) as webhook evidence. A `:manual` block becomes a manual hold, which applies whatever the sync state and only a release clears.
- `at` is the time the other system recorded the block, a `Time` or `DateTime` of any age: `maximum_event_age` applies to webhook feedback only. A time more than five minutes ahead raises `ArgumentError`. It becomes `Status#blocked_at` unless the address was blocked earlier.
- It writes one `imported` event (source `import`, occurred at `at`) and calls no hook: not `after_event`, `after_block` or `on_notification`. It is not new evidence.
- The same address, reason and time again writes nothing. So does an import that the address already holds.
- It never weakens a block in force. A complaint outranks a hard bounce, an earlier hold keeps its time and note, and provider evidence and soft holds stay as they are.
- A release at or after `at` fences it: the import records an `imported` event with `ignored_for_policy` and changes nothing. A newer block applies.

`Bouncy::Ingestor` and `Bouncy::Observation` are internal: they record webhook feedback. Their 0.2.0 call shape still works in 0.2.x, but carry blocks with `Bouncy.import!`.

## SES notifications

`config.on_notification` receives a `Bouncy::Notification` for every SES notification on an authorized topic, Send and Delivery included:

| Reader | Meaning |
|---|---|
| `type` | The SES event type as SES names it: `"Send"`, `"Delivery"`, `"Bounce"`, `"Complaint"`, `"DeliveryDelay"`, ... |
| `message_id` | The SES message id of the mail, or `nil`. |
| `recipients` | The addresses the event is about, exactly as SES spells them: bounced, complained, delivered or delayed recipients; the mail's destination for other types. |
| `occurred_at` | The event's own timestamp, else the mail's, else the time SNS published it. |
| `tags` | The mail's SES message tags: each name maps to an array of values. `{}` when there are none. |
| `raw` | The SES event as a Hash, for any other field. |

The hook runs after Bouncy committed what it records from the notification, outside any transaction or Bouncy lock, and before the receiver answers. A raise answers 503 and SNS delivers the notification again: Bouncy's own records deduplicate, so make the hook safe to repeat. Subscription confirmations and refused messages never reach it.

Use service methods for changes instead of editing or deleting suppression rows directly. Their independent evidence and release metadata are part of the consistency contract. Relations from `Bouncy.blocked` and `Bouncy.events` are empty when unconfigured, but explicit operations raise. See [recovery](recovery.md) and [operations](operations.md).

## Errors

All gem errors inherit from `Bouncy::Error`:

| Error | Meaning / response |
|---|---|
| `InvalidAddress` | Invalid lookup/mutation/hold input; correct the address. |
| `ConfigurationError` | Missing or invalid setup; fix configuration or dependencies. Also `Bouncy.hold` inside a PostgreSQL REPEATABLE READ or SERIALIZABLE transaction; hold around the transaction instead. |
| `ProviderError` | Provider/transport failure, or a sync lock already held. Inspect and retry through your job policy. |
| `UnsafeSnapshot < ProviderError` | Scope mismatch or inability to establish a safe bootstrap/release snapshot. |
| `ReleaseFailed < ProviderError` | Partial/failed provider release; inspect `error.outcomes` before retrying. |
| `ReleaseConflict` | Local evidence changed during release; reload and review the newer state. |
| `AuthenticationError` | SNS authorization/signature failure. |
| `MalformedMessage` | Invalid SNS input. |

Missing support notes, unsupported release destinations, an import reason or time that is not supported, and `Bouncy.hold` without a block raise `ArgumentError`. An address lock that waits too long raises `ActiveRecord::LockWaitTimeout`. Rails/database errors not recognized as connection outages are not silently swallowed. A successful local database transaction does not make remote provider operations atomic. Never display a recovery success message from a rescue branch.
