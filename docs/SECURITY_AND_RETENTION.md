# NestTrack security, payment review, and retention

## Payment evidence and review

NestTrack does not process, hold, or settle payments. For rent, the tenant selects one or more unpaid months, makes the bank transfer outside NestTrack, and uploads an image of the receipt. The grouped submission is recorded as **Pending** until the landlord confirms or rejects it. Confirmation marks its selected rent rows paid. Rejection requires a reason, preserves the submitted proof/history, reopens the unpaid rent rows, and shows the tenant why they should correct and resubmit. These decisions are administrative records, not proof of bank settlement.

Rent proof images live in the private `rent-payment-proofs` storage bucket. Authenticated tenants can upload only into their own folder; the submitting tenant and active organization landlords/managers can view a signed image link. The submission RPC verifies the tenant owns every selected rent row, rejects duplicate pending submissions, and derives the total and months from the database rows. Use the existing bank records to reconcile transfers independently.

For a maintenance ticket, the tenant submits a non-empty bank reference or receipt number rather than an uploaded file. That evidence is recorded with the submitting user and timestamp before the assigned technician can confirm receipt.

The organization’s landlord can set the high-value review threshold in Payments. The default is ₦100,000. When the technician confirms a payment at or above the threshold, the ticket moves to **Pending landlord review** rather than a final paid state. A tenant can dispute submitted or confirmed evidence; disputes are also routed for landlord/manager review. Only an authorized landlord/manager can approve or keep a payment disputed. If a dispute is resolved before any technician confirmation, it returns to **Evidence submitted**—manager approval alone does not mark it paid, and the assigned technician must still verify receipt. If the technician has already confirmed, landlord/manager approval can finalize a payment that was disputed or met the high-value threshold.

Every evidence submission, resubmission, technician confirmation, dispute, and manager review creates a row in `public.ticket_payment_events`. The app displays recent events on the ticket. These rows are append-only to normal authenticated users; authorization to read is limited to the ticket tenant, assigned technician, organization landlord/manager, and platform administrator.

Maintenance-ticket evidence currently means a **text reference/receipt number**, not an uploaded image or PDF. Do not put full bank-account numbers, card data, passwords, or unnecessary personal data in references or notes. Rent receipt images should show only the information needed to reconcile the transfer; avoid uploading unrelated personal or account data.

## Message history and deletion

Message mutation is performed through `edit_message` and `soft_delete_message` RPCs. The database blocks direct authenticated updates/deletes to message rows. An edit stores the previous body and actor/time in `public.message_history`; soft deletion stores the prior body and leaves a visible deletion marker in the conversation. Participants can view versions through the participant-checked `get_message_history` RPC.

Retention behavior:

- Message versions and soft-deleted message bodies are retained for at least **365 days**.
- A soft-deleted message remains visible as a marker during retention; an edit history is available to conversation participants.
- Only a platform administrator can call `purge_retained_message_history(p_before)`.
- The database rejects a cutoff less than 365 days in the past. The function permanently removes eligible soft-deleted messages and corresponding old history rows.
- The purge is manual in this release. Establish a reviewed operational cadence and verify backup/legal-hold requirements before running it. Do not automate it until data-retention obligations are defined.

Editing history includes previous message text and may contain personal information. Restrict administrator access and document any applicable tenant privacy, retention, or legal-hold policy before launch.

## Local accounts and production

There are no seeded demo users or demo passwords in the application. Local development without Supabase requires a freshly created local account and is not a multi-user persistence service. A production build without Supabase configuration presents a blocking configuration screen instead of enabling local account mode.

Production safeguards:

- Set Supabase URL and anon/publishable key at build time; never expose a service-role key to the browser.
- Apply RLS policies and RPC authorization from the forward migrations.
- Test with role-separated accounts and a staging project before production.
- Keep backups, restore procedures, logs, access reviews, and an incident-response contact current.
- Avoid storing bank details in message bodies or logs; verify who can view landlord payment instructions for the deployed version.
