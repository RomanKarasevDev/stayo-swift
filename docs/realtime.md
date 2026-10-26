# Realtime

Realtime subscriptions report `INSERT` and `UPDATE` events for a project's
database tables. Row-level security still decides which changes a signed-in user
may receive. Physical `DELETE` events are not part of the current contract.

## Subscribe and unsubscribe

```ts
const subscription = stayo.realtime.subscribe({
  schema: 'public',
  table: 'notes',
  event: '*',
  onChange(change) {
    // Apply an INSERT or UPDATE to the screen's current data.
  },
  onStatus(status) {
    if (status === 'resync-required') void reloadNotes()
  },
})

// When the feature closes:
subscription.unsubscribe()
```

Swift provides an `AsyncStream`; Kotlin exposes a change `Flow` and a durable
resync version. Each library's README has the language-specific example.

## Readiness, gaps, and recovery

The SDK does not report `subscribed` until it receives both the Phoenix join
acknowledgment and PostgreSQL change-feed readiness. The messages may arrive in
either order. A missing readiness message or heartbeat triggers bounded
reconnection.

After a network interruption, buffer overflow, or rejoin, the SDK signals
`resync-required` / `resyncRequired`. Fetch a fresh table snapshot before
considering the local view current. Realtime is not a durable event log and
cannot replay events missed while disconnected.

## Permissions and setup

- Enable RLS on the table and create policies for each operation the app needs.
- The user's access token is refreshed and propagated to active subscriptions.
- Sign-out closes project subscriptions. Dispose/close the client when its owner
  leaves the application context.
- The table must be part of the runtime's Realtime publication. The quickstart
  shows the SQL to add it if needed.
- DELETE events stay disabled because a removed row cannot be checked by the same
  row-level policy after deletion.

See [protocol v1](protocol-v1.md) and
[runtime conformance](release-status.md#verification) for the wire and verification
details.
