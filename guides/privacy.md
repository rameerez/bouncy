# Stored data and retention

Bouncy stores the normalized address, exact provider identifiers, reasons, event IDs/times, bounded provider diagnostics, support notes and actor references. Those fields can contain personal information. Raw payloads, subjects, bodies and attachments are not stored by this release.

Default event retention is 90 days, measured from local event creation (`created_at`), not provider occurrence time. Schedule `Bouncy::PruneJob` daily; no pruning happens merely by configuring retention. Retention must cover `maximum_event_age`. Feedback older than that acceptance window can be recorded for diagnostics without applying a new restriction, then ages out under normal pruning. Current state and release ordering metadata survive event pruning.

`Bouncy.forget!(address)` erases local state and events in the configured scope. It does not change the provider list. A subsequent sync or eligible notification can create state again, and erasure also removes local release fences. It is not a complete legal/compliance workflow or a provider recovery action.

Restrict global mirror access to authorized support operators. An address can appear in several tenants or sister apps; a matching address does not authorize disclosure of all associated history. Tenant-facing views must join through host-authorized records and expose only the necessary status.

Treat diagnostics and notes as untrusted text when rendering. Do not log raw notifications, tokens, certificate response bodies or customer email contents. Hook error instrumentation records the hook and exception class, not arbitrary exception messages.

Bouncy sends no telemetry. The optional SDKs contact the configured provider for verification, synchronization, diagnostics and explicitly requested recovery.
