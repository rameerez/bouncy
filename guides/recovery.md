# Remove an email from the SES suppression list from Rails

Support recovery is a deliberate action on a shared provider restriction. The host app must authorize the operator, identify the intended address/account and verify that further contact is appropriate, especially after a complaint.

```ruby
Bouncy.release!(address, note: "Address corrected and verified", actor: "support:42")
```

Bouncy obtains a complete supported-scope snapshot, finds the exact provider variants corresponding to the normalized local address, deletes those exact identifiers and checks absence. Only then does it conditionally clear local state. A newer local change causes `Bouncy::ReleaseConflict`, preserving the latest evidence.

A partial provider operation raises `Bouncy::ReleaseFailed`. Inspect `error.outcomes` or the `release_failed` event: some variants may have been removed while another failed. Local provider evidence remains blocked until a successful recovery/reconciliation. Remote calls cannot be rolled back with your database transaction.

Inactive rows retain a release-time fence. Older feedback and stale snapshots cannot simply reapply the released evidence. A genuinely newer failure can block the address again. Provider changes after a completed observation remain possible; this is not a permanent deliverability guarantee.

## Local holds

```ruby
Bouncy.block!(address, note: "Support hold")
Bouncy.release!(address, at: :local)
```

A manual hold is application-local. Sync never deletes it because SES does not list the address. Local-only release clears that local policy while preserving provider/event evidence. Default provider-aware recovery is broader and requires a note.

## What recovery does not do

It does not repair a mailbox, reverse list consent, restore permission after a complaint, guarantee inbox arrival or resend anything. A host resend action must authorize the request, regenerate expiring content and prevent duplicate business effects.

`Bouncy.forget!(address)` is local erasure, not recovery. It removes history and ordering metadata without changing SES; a future sync may import the provider restriction again.
