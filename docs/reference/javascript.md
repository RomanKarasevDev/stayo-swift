# @stayo/sdk 0.1.0

Start with the [Stayo quickstart](../getting-started.md) and read
[auth/OAuth](../auth-and-oauth.md),
[secrets/functions](../secrets-and-functions.md), and
[Realtime recovery](../realtime.md) before integrating those flows.

Standalone TypeScript/JavaScript client for Stayo project APIs. No runtime dependencies
and no Supabase client libraries. Uses native Fetch, Web Crypto and WebSocket.
Source: [stayo-js](https://github.com/RomanKarasevDev/stayo-js).
Supports Node.js 22+ and modern browsers with these APIs. This package is prepared
for publication; npm availability, a real runtime and provider/device acceptance
are separate release gates.

```sh
npm install @stayo/sdk@0.1.0
```

```ts
import { createClient } from '@stayo/sdk'

const stayo = createClient({
  url: 'https://project.example.com',
  publicKey: 'PUBLIC_PROJECT_KEY',
  oauthRedirectUrls: ['https://app.example.com/callback'],
})
await stayo.auth.signInWithPassword({ email, password })
const { data: notes, count } = await stayo.from<Note>('notes')
  .select('id,title', { count: 'exact' })
  .eq('owner_id', (await stayo.auth.getUser()).id)
  .order('id', { ascending: false }).range(0, 19).execute()
```

Use the project origin and public application key from the customer cabinet.
HTTPS is required except for `localhost`, `127.0.0.1` and `::1` development.
A URL must be an origin, without a path, query, fragment or embedded credentials.
Known secret/service-role keys are rejected. Database and Storage RLS enforce user
access: a public key identifies the app and grants no ownership by itself.
Third-party provider keys belong in the cabinet's Secrets section and server
functions. They must never be embedded in a web or mobile application.

## Auth and sessions

```ts
const signup = await stayo.auth.signUp({ email, password, data: { name: 'Ada' } })
// signup.session can be null while email confirmation is pending.
await stayo.auth.verifyOtp({ email, token: confirmationCode, type: 'email' })
await stayo.auth.recoverPassword(email) // configure mail delivery on the runtime
await stayo.auth.verifyOtp({ email, token: recoveryCode, type: 'recovery' })
await stayo.auth.updatePassword(newPassword)
const user = await stayo.auth.getUser() // server-validated user, not cached claims
const session = await stayo.auth.getSession() // cached session, not authorization proof
const off = stayo.auth.onAuthStateChange((event, session) => { /* update your UI */ })
await stayo.auth.signOut() // clears local state; revokes this server session (scope=local)
// Always update UI from SIGNED_OUT even if server revocation throws.
off()
stayo.dispose() // close subscriptions/timers; keep persisted login for next launch
```

All network failures throw `StayoError` with `code` and HTTP `status` (`0` for
client/transport errors). Messages are deliberately generic; headers, token/body
values and provider error text are not attached. Cancellation/deadline is `aborted`.
Functions' nested `error.code` is preserved, including `FUNCTION_CONCURRENCY_LIMIT`
with HTTP 429; nested provider messages are discarded.
No HTTP operation is automatically retried, including Functions and mutations.
Requests use `redirect: 'error'`, omit cookies and remain bound to the project origin.

Browser sessions use localStorage unless you provide `storage` or set
`persistSession: false`. localStorage requires normal XSS defenses in your app.
Node defaults to per-client memory. Persistence is namespaced by normalized project
origin and `storageNamespace`. Use one client for each signed-in browser context.
Refresh is single-flight within that client, checks expiry before requests and
runs automatically in browsers. `autoRefresh: false` disables the browser timer.
Cross-tab coordination is not provided: avoid multiple tabs rotating the same
persisted refresh token concurrently. Separate accounts need separate namespaces.
A storage read/write failure surfaces as `storage_error`; it is not silently ignored.

### Google and Apple PKCE

```ts
const { url } = await stayo.auth.beginOAuth({
  provider: 'google', // or 'apple'
  redirectTo: 'https://app.example.com/callback',
})
window.location.assign(url)
// On the exact allowlisted callback, using the same storage/namespace:
await stayo.auth.completeOAuth(window.location.href)
history.replaceState(null, '', '/callback') // remove code from browser history
// If your app cancels before returning:
await stayo.auth.cancelOAuth()
```

Configure the same exact redirect in the runtime and `oauthRedirectUrls`. The SDK
preserves `redirect_to` unchanged so an exact server allowlist works. GoTrue owns
and validates the OAuth provider state. The SDK creates a 32-byte random verifier,
sends S256, validates the exact callback origin/path/query and consumes pending
PKCE once before exchange. Cancel/mismatch/duplicate callback code/replay cannot
replace a session. Pending attempts expire after ten minutes. No implicit-token
callbacks are accepted. Use the system browser in native wrappers. Email/code and token-hash confirmation and recovery use `verifyOtp`; provider login uses PKCE.

### SSR

Create a fresh client for each request. Never share a signed-in client across users.
Provide a per-request `StorageAdapter` with `getItem`, `setItem`, `removeItem`
(sync or async); protect its session data in a server-side session store or secure
cookies. Example in `examples/ssr.mjs` uses a request-scoped adapter. Account cookies
must be `HttpOnly`, `Secure` and `SameSite`, with CSRF protections for writes; pass
only verified user data to HTML. Never expose access/refresh tokens in rendered HTML.

## Database, Storage and Functions

```ts
await stayo.from('notes').insert({ title: 'Hello' }).execute()
await stayo.from('notes').update({ title: 'Updated' }).eq('id', noteId).execute()
await stayo.from('notes').delete().eq('id', noteId).execute()
await stayo.from('notes').upsert({ id: noteId, title: 'Hello' }, { onConflict: 'id' }).execute()
const rows = await stayo.schema('app').rpc('search_notes', { term: 'hello' })

const files = stayo.storage.from('photos')
await files.upload('album/photo.png', file, { contentType: 'image/png', upsert: false })
const blob = await files.download('album/photo.png')
const url = await files.createSignedUrl('album/photo.png', 60)
await files.remove(['album/photo.png'])

const abort = new AbortController()
const result = await stayo.functions.invoke('ask-ai', {
  body: { prompt: 'Summarize this note' }, signal: abort.signal,
})
```

Queries offer `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `like`, `ilike`, `is`, `in`,
`filter`, `order`, `limit`, `range`, `select`, CRUD/upsert and schema profiles.
Call `execute()` explicitly: reusing/executing a mutation again sends it again.
The response is `{ data, count, status }`; the generic type is compile-time only.
RLS must permit both the row selection and mutation. RPC uses POST and no retries.
Uploads/downloads buffer the object in memory; streaming large objects is outside
0.1.0. Object segments are encoded separately and traversal/backslashes rejected.
Signed download URLs stay on the project origin under the signing endpoint.

Functions require a signed-in user and `GET /.well-known/stayo.json` returning
`protocol_version: 1`, `runtime_version: '1.3.0-compatible'` and
`capabilities.functions: true`. The legacy health dispatcher is not accepted as a
function runtime. Each invocation checks the marker; no successful-call cache can
mask a runtime downgrade. The worker enforces 60 seconds, 150 MB and two concurrent
calls per project. SDK timeout defaults to 65 seconds for invocation, 30 seconds
otherwise. 404/429/503 propagate as errors and are not retried. Aborting the client
stops waiting; an already dispatched external provider operation may still finish.
Before response headers, the handler can retain a project slot until completion
or the 60-second worker deadline. Cancelling both calls can leave new calls
receiving `429 FUNCTION_CONCURRENCY_LIMIT`; the SDK does not retry them.

## Realtime

```ts
const subscription = stayo.realtime.subscribe({
  schema: 'public', table: 'notes', event: '*',
  onChange(change) { /* INSERT/UPDATE; update your local view */ },
  onStatus(status) {
    if (status === 'resync-required') void reloadNotes()
  },
})
subscription.unsubscribe()
```

Uses Phoenix JSON protocol 1.0.0, join references, heartbeat acknowledgments, token
updates and bounded reconnect delays (1, 2, 5, 10, then 30 seconds). A subscription becomes `subscribed` only after both Phoenix join acknowledgment
and PostgreSQL readiness (`system` status `ok`), in either order. A missed
heartbeat/readiness timeout reconnects. On successful rejoin the status is
`resync-required`: refetch a snapshot because history is not guaranteed. Only
INSERT and UPDATE are subscribed/delivered; server-side DELETE publication must
also be disabled because removed-row RLS cannot be assumed. Logout closes all
subscriptions. `dispose()` closes them and all timers without erasing persistence.

## Local development and evidence

```sh
npm ci
npm test
npm run pack:smoke
```

`npm test` performs a strict TypeScript build and focused Node protocol/concurrency
fixtures. `pack:smoke` creates a tarball, installs it into an empty temporary
consumer without registry dependencies, checks public declarations and executes
Auth/CRUD/Storage/Functions against a local HTTP fixture. Neither test proves
runtime RLS, real Google/Apple authentication, browser behavior, TLS, provider calls
or VPS acceptance. Run the packaged client against the same pinned 1.3.0 runtime
fixture used by Swift/Kotlin, with two users and two independent projects, before
public release. The examples assume an RLS-protected `notes(id,title,owner_id)` table.

Protocol sources checked during implementation: [Auth PKCE](https://supabase.com/docs/guides/auth/sessions/pkce-flow),
[Realtime protocol](https://supabase.com/docs/guides/realtime/protocol).
