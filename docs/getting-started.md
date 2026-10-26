# Get started with Stayo

Use a Stayo SDK to connect an application to one Stayo project. The SDK needs
the project's HTTPS URL and **public project key**. It never needs a database
password, JWT signing key, service-role key, or third-party API key.

> **Release status:** SDK `0.1.0` packages are prepared locally and a test build
> is installed on the test VPS. Registry publication and provider/device acceptance
> remain open. See the
> [acceptance report](release-status.md#verification) before using registry install
> commands. The SDK APIs and examples below are the intended `0.1.0` interface.

## 1. Get the project connection details

Open your project in the Stayo cabinet and go to its **Connection** section.
Copy the project URL and public key. Keep the public key in the application's
configuration; it identifies the project but does not grant a user access to
rows or files. RLS policies and the signed-in user's session control access.

Do not put provider credentials in an application bundle. Save those in the
project's **Secrets** section and use a server function to call the provider.
Read [Secrets and server functions](secrets-and-functions.md).

Customer sign-in is at `/login`; `/admin` initializes and manages the server
operator. A project customer does not need a bootstrap token. Use the project's
**Backups** tab for encrypted copies and confirmed restoration. See
[Back up and restore a project](cabinet-backups.md).

## 2. Install the SDK

Use these public coordinates only after the corresponding package is confirmed
published. During local development in this repository, use its source package.

| Platform | Published install | Local source while unpublished |
| --- | --- | --- |
| Browser / Node.js | `npm install @stayo/sdk@0.1.0` | `npm install /path/to/stayo-sdk-0.1.0.tgz` |
| iOS / macOS | [stayo-swift](https://github.com/RomanKarasevDev/stayo-swift), exact version `0.1.0` | Add `sdk/stayo-swift` as a local package |
| Android | `implementation("live.stayo:stayo-android:0.1.0")` | Resolve the local Maven repository as described in the [Android README](reference/android.md) |

SwiftPM requires a tagged package repository; a monorepo subdirectory cannot be
used as a remote SwiftPM dependency. See each package README for its exact
development and build instructions.

## 3. Create a table with row-level access

Run this once in your project's SQL console. It creates a private notes table:
each signed-in user can only read and change rows they own.

```sql
create table public.notes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid()
    references auth.users(id) on delete cascade,
  title text not null,
  created_at timestamptz not null default now()
);

alter table public.notes enable row level security;
grant select, insert, update, delete on public.notes to authenticated;

create policy notes_select_own on public.notes
  for select to authenticated using ((select auth.uid()) = owner_id);
create policy notes_insert_own on public.notes
  for insert to authenticated with check ((select auth.uid()) = owner_id);
create policy notes_update_own on public.notes
  for update to authenticated
  using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);
create policy notes_delete_own on public.notes
  for delete to authenticated using ((select auth.uid()) = owner_id);
```

To receive Realtime events for this table, add it to the project's Realtime
publication if it is not already there:

```sql
alter publication supabase_realtime add table public.notes;
```

Realtime currently delivers `INSERT` and `UPDATE`. After a reconnect, fetch the
current rows again; the event stream is not a history log. See the
[Realtime guide](realtime.md).

## 4. Connect and read your rows

When email confirmation is enabled, collect the code from the project email.
Use the [confirmation and password recovery examples](auth-and-oauth.md#confirm-an-email-or-recover-a-password-with-its-code)
for Web, Swift and Kotlin. A pending signup does not create an authenticated
session; recovery must verify its code before changing the password.

### Web and Node.js

```ts
import { createClient } from '@stayo/sdk'

const stayo = createClient({
  url: import.meta.env.VITE_STAYO_URL,
  publicKey: import.meta.env.VITE_STAYO_PUBLIC_KEY,
})

await stayo.auth.signInWithPassword({ email, password })
const user = await stayo.auth.getUser()
const { data: notes } = await stayo.from('notes')
  .select('id,title,created_at')
  .eq('owner_id', user.id)
  .order('created_at', { ascending: false })
  .range(0, 19)
  .execute()
```

For a Node.js process, read the public URL/key from `process.env` instead of
`import.meta.env`. For SSR, create a new client per request and pass request-scoped session storage.
Never share one user's client with another request. Details are in the
[JavaScript README](reference/javascript.md#ssr).

### iOS and macOS

```swift
import Foundation
import Stayo

struct Note: Codable, Sendable {
    let id: String
    let title: String
    let created_at: String
}

let stayo = try StayoClient(
    url: URL(string: projectURL)!,
    publicKey: publicProjectKey
)
try await stayo.auth.signIn(email: email, password: password)
let result = try await stayo.database.from("notes")
    .select("id,title,created_at")
    .order("created_at")
    .range(0, 19)
    .execute(as: [Note].self)
let notes = result.value
```

The default session store uses Apple Keychain. Pass a namespace when one app
needs separate sessions for different accounts. See the
[Swift README](reference/swift.md).

### Android

```kotlin
import live.stayo.sdk.StayoClient

val stayo = StayoClient(projectURL, publicProjectKey, applicationContext)
stayo.auth.signInWithPassword(email, password)
val result = stayo.from("notes")
    .select("id,title,created_at")
    .order("created_at")
    .range(0, 19)
    .execute()
val notes = result.data
```

Use the `Context` constructor in an Android app; it stores encrypted session
ciphertext in the app's private, non-backed-up storage and keeps its key in
Android Keystore. See the [Android README](reference/android.md).

## 5. Choose the next feature

- [Email and Google/Apple sign-in](auth-and-oauth.md)
- [Upload private files with user-scoped RLS](storage.md)
- [Call a server function with the user's session](secrets-and-functions.md)
- [Subscribe to row changes and recover after disconnects](realtime.md)
- [Understand errors and fix common setup issues](troubleshooting.md)

Table and Storage permissions are enforced by the runtime. Test with two
accounts: verify that each can see its own rows and cannot access another
account's rows or objects.

Functions allow two concurrent calls per project. Handle status `429` and SDK
code `FUNCTION_CONCURRENCY_LIMIT` in the app; do not automatically repeat a call
that may have side effects. The SDK discards upstream provider message text.
