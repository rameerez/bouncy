# Bouncy guides

These guides describe the published **v0.1.0** API. Start with the [README installation steps](../README.md#installation), then connect SES and schedule the jobs.

| Guide | What it covers |
|---|---|
| [Amazon SES setup](amazon-ses.md) | Credentials, IAM, SNS authorization, feedback routing and offline receiver tests |
| [Configuration reference](configuration.md) | Every setting, its default and the supported scope |
| [API reference](api.md) | Individual/batch status, model integration, queries, operations and errors |
| [Operations](operations.md) | Jobs, scheduling, tasks, freshness, hooks and monitoring |
| [Bounce handling](bounce-handling.md) | Hard/soft bounces, complaints and opt-in mailbox-full escalation |
| [Action Mailer delivery](delivery.md) | Modes, SMTP envelopes, bypasses and unsupported send paths |
| [Admin integration](admin.md) | Host-owned badges, recovery actions, Madmin and tenant authorization |
| [Recovery](recovery.md) | SES suppression removal, local holds and partial failures |
| [Troubleshooting](troubleshooting.md) | “The mailer says sent, but the email never arrived” and sync failures |
| [Migrating](migrating.md) | Importing existing evidence, cutover and rollback |
| [Compatibility](compatibility.md) | Ruby/Rails versions, bigint/UUID, JSON/JSONB and database locks |
| [Privacy and retention](privacy.md) | Stored data, pruning and erasure |

See also [release history](../CHANGELOG.md), [contributing](../CONTRIBUTING.md) and [security reporting](../SECURITY.md).
