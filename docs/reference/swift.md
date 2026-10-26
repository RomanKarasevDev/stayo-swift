# Stayo Swift 0.1.0

Start with the [Stayo quickstart](../getting-started.md) and read
[auth/OAuth](../auth-and-oauth.md),
[secrets/functions](../secrets-and-functions.md), and
[Realtime recovery](../realtime.md) before integrating those flows.

Native iOS 16+/macOS 13+ client for the Stayo compatible runtime. Foundation
URLSession/WebSocket, CryptoKit, Security/Keychain and AuthenticationServices;
no external or Supabase libraries. Swift tools 5.9+.

## Install

The SwiftPM product is `Stayo`. The standalone source repository is
[stayo-swift](https://github.com/RomanKarasevDev/stayo-swift). Version `0.1.0`
remains a candidate until the [release status](../release-status.md#verification)
confirms its public tag and acceptance. For local development, choose **Add
Local…** in Xcode and select the checkout containing `Package.swift`, or use:

```swift
.package(path: "../stayo-swift")
// target dependencies: [.product(name: "Stayo", package: "stayo-swift")]
```

After the verified public release, use the exact tagged dependency:

```swift
.package(url: "https://github.com/RomanKarasevDev/stayo-swift.git", exact: "0.1.0")
```

## Connect and authenticate

```swift
import Foundation
import Stayo

let client = try StayoClient(
    url: URL(string: "https://YOUR_PROJECT_DOMAIN")!,
    publicKey: "YOUR_PUBLIC_APPLICATION_KEY"
)
let session = try await client.auth.signIn(email: email, password: password)
let user = try await client.auth.user()
try await client.auth.signOut()
```

Find the URL and public key in the project cabinet. Privileged service-role and
secret keys are rejected. External API keys go into project **Secrets**, then
server functions read them. Never embed an external API key in the app.

`signUp(email:password:metadata:)` returns a user; when confirmation is enabled,
there is no session until `verify(email:token:type:)`. Standard Stayo email codes
use `verify(email: email, token: code, type: "email")`; see the
[complete email flow](../auth-and-oauth.md#confirm-an-email-or-recover-a-password-with-its-code).
Use `recoverPassword` then
`verify(..., type: "recovery")` and `updatePassword`. Session tokens persist in a
Keychain generic-password item scoped by normalized project origin + namespace,
with `AfterFirstUnlockThisDeviceOnly`. Use `namespace:` to separate app accounts
and `MemorySessionStore()` for ephemeral tests. Recreate a client to reopen the
stored session; `session()` refreshes near-expiry credentials. Concurrent refresh
requests share one exchange. Starting a sign-in, signup, verification or OAuth
flow clears the previous local session and closes its subscriptions; failed
sign-in leaves the app signed out. Each auth result is bound to that transition,
and refresh is additionally bound to its original session revision. Logout invalidates in-flight refresh and closes
subscriptions before contacting the server with `scope=local` (only that session). Network errors during logout do not
restore local credentials. Do not log session objects.

### Google / Apple system browser

Configure providers and **exact redirect URL** in the project's Auth settings.
Register the custom URL scheme in Xcode URL Types. Keep `OAuthBrowser` alive for
the login flow and pass the current presentation window:

```swift
let browser = await OAuthBrowser(anchor: window)
let session = try await browser.signIn(
    auth: client.auth, provider: .google,
    redirectURL: URL(string: "myapp://login/callback")!,
    allowedRedirectURLs: [URL(string: "myapp://login/callback")!]
)
```

`beginOAuth`/`completeOAuth` also support an app-owned system browser coordinator.
A fresh S256 verifier is held in memory for 10 minutes, bound to the redirect,
and consumed once on callback or cancellation. GoTrue validates provider state;
the PKCE exchange validates this client's code/verifier. The SDK preserves the
allowlisted redirect URL unchanged. Restarted or canceled flows must start again.

## Database, Storage and Functions

```swift
struct Note: Codable, Sendable { let id: String; let title: String }
let notes = try await client.database.from("notes")
    .select("id,title").filter("title", .ilike, "%hello%")
    .order("title").range(0, 19).execute(as: [Note].self, exactCount: true)
let created = try await client.database.from("notes")
    .insert(["title": "Hello"], as: [Note].self)
let changed = try await client.database.from("notes").filter("id", .eq, noteID)
    .update(["title": "Changed"], as: [Note].self)
let deleted = try await client.database.from("notes").filter("id", .eq, noteID)
    .delete(as: [Note].self)
let result = try await client.database.rpc("my_function", parameters: ["input": "value"], as: JSONValue.self)

let photos = client.storage.bucket("photos")
let upload = try await photos.upload("images/photo.png", data: pngData, contentType: "image/png")
let data = try await photos.download("images/photo.png")
let link = try await photos.signedURL("images/photo.png", expiresIn: 60)
let removed = try await photos.remove(["images/photo.png"])

let answer = try await client.functions.invoke("ask-ai", body: ["prompt": "Hello"], as: JSONValue.self)
```

Tables/buckets require server RLS policies. A public key identifies the app;
the current bearer session authorizes the user. Use filters on update/delete:
unfiltered operations affect every row permitted by RLS. `schema:` selects a
PostgREST schema and `QueryResult.contentRange` exposes pagination metadata.
Paths encode individual segments and reject traversal/empty/backslash segments.
Signed URLs must use the project origin and Storage signing path. The SDK rejects
all HTTP redirects; credentials are never forwarded to redirect targets.

Functions require an authenticated session and discovery marker
`/.well-known/stayo.json`: protocol `1`, runtime `1.3.0-compatible`,
`capabilities.functions: true`. Missing/old/health-only runtimes fail closed.
Invocations remain bound to the initiating login, including during discovery
and body encoding. Account transitions reject stale invocations rather than
submitting their body as the new user; same-account token refresh remains valid.
Sign-out and other auth transitions cancel active function requests. A request
already dispatched can have server effects; cancellation does not undo them.
No database mutation, RPC or function invocation is retried automatically.
Cancel the calling Task to abort URLSession. Server errors expose HTTP status and
bounded machine code, never server message text/request data. There are no SDK logs.
Top-level service codes and Functions' nested `error.code` are supported; overload
is `.http(status: 429, code: "FUNCTION_CONCURRENCY_LIMIT")`.
Cancelling a Task stops the client request. Before response headers, the handler
can retain its project slot until completion or the 60-second worker deadline;
cancelling both calls can leave new calls receiving that overload error.

## Realtime

```swift
let subscription = try await client.realtime.subscribe(table: "notes")
for await event in subscription.events {
    switch event {
    case .change(let row): print(row.event) // INSERT / UPDATE only
    case .status(.resyncRequired): /* refetch your database snapshot */ break
    case .status: break
    }
}
await subscription.unsubscribe()
// Or await client.realtime.close()
```

Realtime emits `subscribed` only after both the Phoenix join acknowledgment and
the `postgres_changes` system readiness message, in either order. A missing
readiness response triggers a bounded reconnect. Realtime uses Phoenix JSON
protocol 1.0.0, heartbeats, bounded
1–30 second reconnect delay, bearer updates and explicit cancellation. Only
INSERT/UPDATE subscriptions are requested; DELETE deliveries are ignored.
Reconnect or a dropped event emits `resyncRequired`. Delivery is not historical;
refetch on that event. Each subscription owns a socket; keep subscriptions scoped
to your feature and unsubscribe when it closes. Logout closes all sockets.

## Examples and verification

```sh
swift test
swift run stayo-example
# Configure STAYO_URL / STAYO_PUBLIC_KEY and optionally STAYO_EMAIL /
# STAYO_PASSWORD through your local run environment to use your server.
# STAYO_QUERY_NOTES=1 queries an RLS-protected notes table.
./scripts/package.sh
```

The executable prints capability versions and counts, never tokens/credentials.
`Examples/SwiftUI/StayoNotesApp.swift` is an iOS/macOS app template: add Stayo,
copy it into a new SwiftUI project, set Info.plist `STAYO_URL` and
`STAYO_PUBLIC_KEY`, and configure your notes table. See `RELEASE.md` for acceptance.
Tests exercise URLProtocol HTTP fixtures and a real loopback WebSocket fixture
(Python 3 standard library). These do not prove hosted RLS, OAuth provider/device,
Keychain entitlements, VPS isolation or production readiness.
