# Authentication and OAuth

## Email and password

The SDKs support sign-up, email verification, password sign-in, password
recovery, password update, refresh, and sign-out. Signup may return a user
without a session while confirmation is pending. Email confirmation and recovery
require working outbound mail delivery on the project runtime; a successful SDK
request does not prove that a message reached an inbox.

Use the server-validated `getUser()` / `user()` API when authorization decisions
depend on the current user. A cached session is useful for restoring UI state,
but its local claims are not an authorization check. Database and Storage RLS
remain authoritative.

## Confirm an email or recover a password with its code

Stayo's standard project emails contain a one-time code. Collect that code in
application UI and submit it with the same email address. Do not put codes,
passwords or session tokens in logs, analytics or URLs.

### JavaScript / TypeScript

```ts
await stayo.auth.signUp({email, password})
// After the confirmation email arrives:
await stayo.auth.verifyOtp({email, token: confirmationCode, type: 'email'})
await stayo.auth.getUser()

await stayo.auth.recoverPassword(email)
// After the recovery email arrives, from a signed-out client:
await stayo.auth.verifyOtp({email, token: recoveryCode, type: 'recovery'})
await stayo.auth.updatePassword(newPassword)
await stayo.auth.signOut()
await stayo.auth.signInWithPassword({email, password: newPassword})
```

### Swift

```swift
_ = try await client.auth.signUp(email: email, password: password)
_ = try await client.auth.verify(email: email, token: confirmationCode, type: "email")
_ = try await client.auth.user()
try await client.auth.recoverPassword(email: email)
_ = try await client.auth.verify(email: email, token: recoveryCode, type: "recovery")
_ = try await client.auth.updatePassword(newPassword)
```

### Kotlin

```kotlin
stayo.auth.signUp(email, password)
stayo.auth.verifyOtp(email, confirmationCode, "email")
stayo.auth.getUser()
stayo.auth.resetPasswordForEmail(email)
stayo.auth.verifyOtp(email, recoveryCode, "recovery")
stayo.auth.updateUser(password = newPassword)
```

Codes expire and are consumed by the server. An invalid, expired or replayed code
must not create a session. Request a new email explicitly when needed; observe
the project's configured expiry, resend interval and delivery limits. The SDKs
do not automatically retry verification or password updates.

A custom integration that supplies a token hash can use JavaScript
`verifyOtp({token_hash, type: 'email'})` or Android `verifyTokenHash`. A verification
request uses either email/code or a token hash. The TypeScript input rejects
combining those forms.

## Configure Google or Apple

1. In project settings, open **Sign-in providers and redirects**.
2. Copy the displayed **Provider callback URL** into the provider console. This
   URL belongs to Stayo Auth, not to your application's callback.
3. Create the provider's web client credentials. For native clients, add the
   platform client IDs as documented in the cabinet; the web client ID must be
   first in the comma-separated list.
4. Save the client secret in the cabinet's protected field, then enable the
   provider with the matching client ID.
5. Add every exact application callback URL to **Additional post-login redirect
   URLs**. Wildcards, query strings, and fragments are not accepted. Public web
   callbacks require HTTPS; loopback HTTP is for local development. Native
   schemes must be unique reverse-domain identifiers.
6. Wait for the Auth apply job to finish, then complete a real sign-in and return
   to the correct application before accepting the setup.

Google requires the provider callback URL to exactly match an authorized
redirect URI. Apple web sign-in uses a Services ID, associated domains and return
URLs, and a signed client-secret JWT. Apple limits that JWT lifetime to six
months; rotate it before expiry. See the official [Google web server OAuth
guide](https://developers.google.com/identity/protocols/oauth2/web-server),
[Apple Sign in with Apple configuration](https://developer.apple.com/documentation/signinwithapple/configuring-your-environment-for-sign-in-with-apple),
and [Apple client-secret guide](https://developer.apple.com/documentation/accountorganizationaldatasharing/creating-a-client-secret).

Provider credentials stay server-side and are encrypted in project storage. The
SDK must never receive the provider client secret. A saved setting means it was
stored; only a real browser/device login proves the complete provider setup.

## Browser PKCE

```ts
const stayo = createClient({
  url: projectURL,
  publicKey: publicProjectKey,
  oauthRedirectUrls: ['https://app.example.com/auth/callback'],
})

const { url } = await stayo.auth.beginOAuth({
  provider: 'google', // or 'apple'
  redirectTo: 'https://app.example.com/auth/callback',
})
window.location.assign(url)
// On the exact callback page, with the same storage namespace:
await stayo.auth.completeOAuth(window.location.href)
history.replaceState(null, '', '/auth/callback')
```

Use the system browser from native apps. Do not put an OAuth callback code in
analytics, application logs, or a shared URL. The SDK validates and consumes the
pending PKCE verifier once. Cancelled, expired, mismatched, or repeated callbacks
must start a new login.

## Native callback handling

### Apple platforms

Use `OAuthBrowser` with the current presentation anchor. Register the exact
reverse-domain callback scheme in the app and in the project's redirect list.
Keep the browser coordinator alive until success or cancellation. The default
Apple Keychain store persists session tokens, scoped to project and namespace.
Pending PKCE state stays in the running client; after the app terminates, start
a new OAuth attempt instead of trying to reuse its callback.

See [Swift SDK OAuth examples](reference/swift.md#google--apple-system-browser).

### Android

Register an exact Android callback intent filter, preferably a verified HTTPS
App Link for production. Start `launchOAuth(...)`; complete the callback in both
`onCreate` and `onNewIntent`, since Android may reuse the Activity. Call
`cancelOAuth()` when the user cancels. The pending PKCE state is encrypted and
can survive process death when the client is recreated with the same namespace.

See [Android SDK callback example](reference/android.md#auth-and-system-browser).

## Current acceptance boundary

SDK protocol fixtures and local runtime tests do not prove Google/Apple provider
approval, native browser handoff, Universal/App Links, or physical-device secure
storage. A packaged Swift client has passed save/relaunch/replace/delete and
project isolation against the native Mac Keychain. The packaged JavaScript SDK
completed real signup confirmation and password recovery on the test VPS,
including code replay denial and old/new password checks. See the
[dated mail receipt and exact runtime/package identities](release-status.md#verification).
Provider accounts and physical devices are still needed for the remaining checks.
