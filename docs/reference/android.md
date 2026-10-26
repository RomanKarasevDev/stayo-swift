# Stayo Android 0.1.0

Start with the [Stayo quickstart](../getting-started.md) and read
[auth/OAuth](../auth-and-oauth.md),
[secrets/functions](../secrets-and-functions.md), and
[Realtime recovery](../realtime.md) before integrating those flows.

Independent Kotlin SDK for Android 8 / API 26 and later. No Supabase SDK dependency.
The package is prepared locally; it has **not been published to Maven Central**.
Source: [stayo-android](https://github.com/RomanKarasevDev/stayo-android).

Once published, add `mavenCentral()` and:

```kotlin
implementation("live.stayo:stayo-android:0.1.0")
```

```kotlin
import live.stayo.sdk.*
import kotlinx.serialization.json.*

val stayo = StayoClient("https://project.example.com", "PUBLIC_KEY", applicationContext)
stayo.auth.signInWithPassword("user@example.com", password)
val notes = stayo.from("notes").select().eq("owner_id", userId).order("created_at").range(0, 19).execute()
stayo.from("notes").insert(buildJsonObject { put("title", "Hello") }).execute()
stayo.from("notes").update(buildJsonObject { put("title", "Updated") }).eq("id", noteId).execute()
stayo.from("notes").delete().eq("id", noteId).execute()
val result = stayo.rpc("my_function", buildJsonObject { put("argument", 42) })
val bucket = stayo.storage.from("photos")
bucket.upload("user/avatar.jpg", bytes, "image/jpeg")
val signedUrl = bucket.createSignedUrl("user/avatar.jpg", expiresSeconds = 60)
val downloaded = bucket.download("user/avatar.jpg")
bucket.remove(listOf("user/avatar.jpg"))
val response = stayo.functions.invoke("hello", buildJsonObject { put("message", "Android") })
```

Methods suspend; cancel the caller's coroutine to abort HTTP. Each mutation/function
call dispatches once and redirects are disabled. Authenticated HTTP refreshes an
expiring session first. `StayoException` exposes status and bounded service code,
without response bodies/request headers. Never put service-role or provider secrets
in an Android app. Store provider secrets in the project's customer cabinet.
Functions require the server's `1.3.0-compatible` discovery capability and a user session.
Nested Functions `error.code` is preserved: overload has status `429` and code
`FUNCTION_CONCURRENCY_LIMIT`. Provider messages are discarded; calls are not retried.
Cancelling a coroutine stops the client request. Before response headers, the
handler can retain its project slot until completion or the 60-second worker
deadline; cancelling both calls can leave new calls receiving that overload error.

## Auth and system browser

`auth.signUp`, `verifyOtp`/`verifyTokenHash`, `resetPasswordForEmail`, `getUser`,
`updateUser`, `refreshSession`, `signOut` cover account flows. Observe `auth.session`
as a StateFlow. Standard Stayo emails contain a code: pass it with the email to
`verifyOtp(email, code, "email")`; use type `"recovery"` before changing a forgotten
password. See the [complete email flow](../auth-and-oauth.md#confirm-an-email-or-recover-a-password-with-its-code).
Starting signup, sign-in, confirmation or a new OAuth flow clears
the previous local identity before exchanging credentials. A pending transition
cannot refresh the previous user's session. Signup can return a user without
creating a session when email confirmation is enabled. Logout clears local sessions and subscriptions before
requesting server logout. It invalidates pending refresh and code exchange results.

Allowlist the exact callback in the project's Google/Apple Auth settings and
register the same Android intent filter (see sample). Prefer a verified HTTPS App
Link for production; custom schemes require a unique app-owned scheme.

```kotlin
stayo.auth.launchOAuth(activity, OAuthProvider.GOOGLE, "my-app://auth/callback")
// From your callback Activity/onNewIntent:
stayo.auth.handleOAuthCallback(intent.dataString!!)
// If the user cancels the browser flow:
stayo.auth.cancelOAuth()
```

PKCE S256 verifier is encrypted, scoped to the project, expires after ten minutes
and is consumed once, including rejected callbacks. GoTrue manages provider state.
An exact scheme/authority/path and all fixed callback query parameters are checked.
No callback token fragment is accepted. A pending flow survives app process death
when the client is recreated with the same project and namespace. A new login,
logout or cancellation invalidates it. OAuth/provider configuration must be
completed on a real test project; local fixtures don't prove provider login.

The Context constructor uses AES-256-GCM with a non-exportable Android Keystore
key and authenticated project/name binding. Only ciphertext is stored under
`noBackupFilesDir` (excluded from Auto Backup and device transfer). Keys and
ciphertexts are independent per normalized project origin and caller namespace.
Storage errors fail closed. `StayoOptions` defaults to per-instance memory storage
for JVM testing; use the Context constructor in a real app. Do not share storage
instances between users in server environments.

## Realtime

```kotlin
val subscription = stayo.realtime.subscribe("notes")
scope.launch { subscription.changes.collect { change -> render(change.record) } }
scope.launch {
    subscription.resyncVersion.collect { revision ->
        if (revision > 0) reloadSnapshot() // Any gap/reconnect or buffer overflow.
    }
}
subscription.close()
```

Only INSERT and UPDATE are exposed. SUBSCRIBED waits for both the Phoenix join
acknowledgement and postgres_changes system readiness. Either message order is
accepted; error or missing readiness triggers reconnect within the15-second join
deadline. Phoenix 1.0.0 join/reply, heartbeat, bounded
reconnect, token updates and explicit leave are handled by the SDK. Status is a
StateFlow; `resyncVersion` is durable within the subscription, so a fast transition
to SUBSCRIBED cannot hide a gap. Delivery is not historical; initially fetch a
snapshot, then refetch when resync is required. RLS remains authoritative.

## Build, tests and local package smoke

Use JDK 17 and Android SDK platform 35. Set `ANDROID_HOME` or untracked
`local.properties`; the Gradle 8.13 wrapper is included.

```sh
./gradlew :library:testDebugUnitTest :library:assembleRelease :sample:assembleDebug
./gradlew :library:publishReleasePublicationToLocalBuildRepository
./gradlew :sample:assembleDebug -PstayoPackaged
```

The second sample build resolves the AAR/POM from `build/maven` as an external
Maven dependency. It detects missing transitives and consumer issues. The local
publication includes AAR, POM, Gradle metadata, source jar and Javadoc jar. Remote
Maven publication/signing/namespace verification require separate owner approval
and credentials. No external repository or publishing credentials are configured.

The sample provides project connection, email/password signup/login, Google/Apple
browser initiation, CRUD, function invocation and realtime notes. Its public
configuration is entered locally. Add an RLS-protected `public.notes` table with
`id`, `owner_id`, `body`, `created_at` for a real project (set owner defaults in SQL).
It contains no sample privileged token and never logs passwords or sessions.

JVM MockWebServer fixtures prove SDK wire behavior, cancellation and auth races.
They don't prove actual Android Keystore/device behavior, pinned runtime RLS,
Google/Apple OAuth, DNS/TLS, worker isolation, provider calls or VPS recovery.
Those remain release gates with ROM-104's shared real-runtime acceptance.
