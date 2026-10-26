# Back up and restore a Stayo project

Sign in to the customer cabinet at `/login`, then open your project. `/admin`
is the separate operator panel: its bootstrap-token screen initializes a server
owner and is not the customer sign-in flow.

## Create a backup

1. Open **Backups** and enter your current cabinet password.
2. Select **Create backup** and wait for the operation to complete.
3. Confirm that the new copy is verified and available to restore.

The service uses the configured encrypted backup destination. The cabinet shows
metadata for the latest 100 copies; it does not expose storage credentials,
object paths, recovery keys, archive contents, or secret values. Creation requires
a provisioned, running compatible runtime. Another project operation blocks it.

## Restore a selected copy

1. Choose a verified backup belonging to this project.
2. Read its date and the replacement warning. Copy any changes that must survive
   before proceeding: restoration replaces the project's current state.
3. Type the project's slug exactly and enter your current cabinet password.
4. Select **Restore selected backup** and wait for completion. Public project
   traffic is unavailable while the restore executor holds maintenance mode.
5. Reopen **Secrets** and **Functions**, then invoke a published function.

Restoration includes named secrets, function drafts and the separately approved
function sources. A draft saved after the last publication remains a draft after
recovery; restoring a backup does not authorize publishing it. Secret values
remain hidden in management responses. Restored values are encrypted for their
project and name again and are rematerialized for function execution in private
host memory.

The browser never retries a mutating request automatically. If the response was
lost, first check the operation status. Retrying the same intent in the still-open
form with the same idempotency key returns the original job. Reloading the page
may create a new intent, so check the previous job before submitting again.
On a failed restore, contact the operator before trying again; public traffic may
remain in maintenance until the cause is resolved. New backups are blocked until
a subsequent restore completes successfully. A healthy container or an unrelated
configuration update does not clear that gate. Recovery restore remains available. A queued request is not
successful recovery. A same-server restore is separate from recovery after
losing the host and master key, which requires the operator recovery procedure.

## Customer API

| Method | Path under `/api/v1/customer/projects/{id}` | Request |
| --- | --- | --- |
| GET | `/backups` | Metadata, latest backup/restore job, availability and busy state |
| POST | `/backups` | `current_password` |
| POST | `/restore` | `backup_id`, `confirmation_slug`, `current_password` |

Both mutations require the customer session, same-origin CSRF protection and an
`Idempotency-Key`. Ownership, password confirmation, a durable job, its replay
receipt and a value-free audit record are checked/committed together. A restore
accepts only a completed, verified real-runtime backup for the same project.
The returned `job_id` means admission; poll GET until the operation completes.

After recovery, reconnect Realtime subscriptions and fetch current application
data. Realtime resumes its normal expiry of old service messages; saved events
do not guarantee replay to subscribers.

See the [repeat on `2ae0d7e`](release-status.md#verification)
for the current test candidate's cabinet backup/restore, real reboot and exact
preservation classification. Native Safari performed backup and mutations;
background Chromium performed restore and the final checks.
See the [native Safari/Firefox acceptance on `0903969`](release-status.md#verification)
for full cabinet cycles, encrypted backup/restore and the detailed reboot
follow-up. The [historical `e1d8474` full-flow report](release-status.md#verification)
records its recovery and interruption checks. The [historical `1365e19` report](release-status.md#verification)
records dated Realtime partitions and its native Safari cycle. The
[host executor fixture](release-status.md#verification) adds corruption
and retention checks. See the [restore interruption report](release-status.md#verification)
for the subsequent fix and its exact acceptance boundaries.

The restore executor now commits its finalization cursor before opening traffic.
After that point, restart replays only proxy finalization, preserving newer writes;
it does not download the archive or repeat SQL, files, secrets or function imports.
Cancellation after successful verification still allows mandatory finalization.
A legacy interrupted job with an unknown cursor stops for operator recovery.
Preserve current data before authorizing a replacement restore.

Operators must not downgrade to an older executor while a restore is queued or
running. Earlier binaries do not understand the new cursors and can replay the
old destructive step. Finish/recover active jobs and preserve current project
state before considering an operator-controlled downgrade.
