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

Each configured attribute gets the same methods with its own prefix. There is no `email_complained` class scope in v0.1.0. Blank values are false for the boolean predicates and excluded from the unblocked scope; a direct `email_status` call still follows single-address input validation.

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

Use service methods for changes instead of editing or deleting suppression rows directly. Their independent evidence and release metadata are part of the consistency contract. Relations from `Bouncy.blocked` and `Bouncy.events` are empty when unconfigured, but explicit operations raise. See [recovery](recovery.md) and [operations](operations.md).

## Errors

All gem errors inherit from `Bouncy::Error`:

| Error | Meaning / response |
|---|---|
| `InvalidAddress` | Invalid lookup/mutation input; correct the address. |
| `ConfigurationError` | Missing or invalid setup; fix configuration or dependencies. |
| `ProviderError` | Provider/transport failure, or a sync lock already held. Inspect and retry through your job policy. |
| `UnsafeSnapshot < ProviderError` | Scope mismatch or inability to establish a safe bootstrap/release snapshot. |
| `ReleaseFailed < ProviderError` | Partial/failed provider release; inspect `error.outcomes` before retrying. |
| `ReleaseConflict` | Local evidence changed during release; reload and review the newer state. |
| `AuthenticationError` | SNS authorization/signature failure. |
| `MalformedMessage` | Invalid SNS input. |

Missing support notes and unsupported release destinations raise `ArgumentError`. Rails/database errors not recognized as connection outages are not silently swallowed. A successful local database transaction does not make remote provider operations atomic. Never display a recovery success message from a rescue branch.
