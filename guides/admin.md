# Host-owned admin integration

Bouncy exposes ordinary ActiveRecord models and service methods. Your application owns the admin framework, authentication, tenant filtering, routes, presentation and tests. There is no Madmin code in the gem.

```ruby
@restrictions = Bouncy.blocked.order(blocked_at: :desc)
@events = Bouncy.events.for(authorized_address).recent.limit(50)
```

This is an account scope, not tenant authorization. Resolve and authorize the address in your app before displaying history. An email match alone does not authorize disclosure of unrelated messages. Escape provider diagnostics as untrusted text.

```ruby
# Inside an authorized host recovery action:
Bouncy.release!(authorized_address, note: params.require(:note), actor: "support:#{current_support_user.id}")
```

Show the provider account/region and reason before submission. Require explicit confirmation before complaint recovery. Display typed failures; do not report success after a refused or conflicting release. Recovery changes a shared restriction and does not resend mail.

## Madmin recipe

Write or generate the resource **in the host app**, using its installed Madmin version. Point it at `Bouncy::Suppression`, apply the proper scope, and show email, effective reasons, observation age and recent event. A host controller action calls the recovery API after authorization.

Disable the stock destructive action: deleting a row loses release metadata and does not release SES. Keep local erasure (`Bouncy.forget!`) and recovery separate, with distinct explanations. Test unauthorized access, shared-account effects and provider failures in the host.

The same approach works with ActiveAdmin, RailsAdmin or a custom Rails controller. No gem framework detection or admin generator is needed.

## A badge on your own lists

A user or customer list should show at a glance which addresses cannot be reached. Load the statuses for the page in one query and read each row's status by its address, in any spelling:

```ruby
# controller
@statuses = Bouncy.statuses(@users.map(&:email))
```

```erb
<%# view %>
<% status = @statuses[user.email] %>
<% if status.blocked? %>
  <span class="badge" title="<%= status.reasons.join(", ") %>"><%= status.reason.to_s.humanize %></span>
<% end %>
```

On a detail page, `Bouncy.status(email).record` is the `Bouncy::Suppression` row, which is what your admin's release page is keyed by.

## Address correction in the application

Show a short status notice only after the host has authenticated and authorized the contact. For example: “We couldn't deliver email to this address. Check it in your contact settings.” Link to the host's existing verified address-change flow. Do not expose suppression lookup on a public password-reset form or reveal whether an unrelated address exists.

Changing a contact's email is separate from releasing the old address's shared provider restriction. Update the authorized host record and use its usual verification policy; do not automatically release a complaint or another tenant's address.

## Notify the responsible operator

```ruby
Bouncy.configure do |config|
  config.after_block = ->(event) { EmailRestrictionNoticeJob.perform_later(event.id) }
end
```

Implement that job in the host. Load the event, resolve the responsible seller/operator through authorized host records, and use an idempotency key based on the event ID. Pick an in-app/admin notification or another suitable channel. Do not send an alert to the same blocked recipient, include another tenant's history, or create an alert-mail bounce loop. Handle a pruned/missing event gracefully.

Hooks run after commit but are best effort. For guaranteed notifications, reconcile pending work in a host outbox; an enqueue exception cannot roll back an acknowledged bounce. Test the job and authorization policy with the app's actual customer/seller models before enabling it.
