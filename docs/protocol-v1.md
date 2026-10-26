# Stayo SDK protocol v1

Status: implementation contract for ROM-98. SDK artifacts are not yet published.

## Clients and trust

The JavaScript, Swift and Kotlin clients take the HTTPS origin of a project and
its public key. They use the project's API, never the customer or operator
session. There are no Supabase library dependencies. The server remains the
versioned compatible runtime. HTTP is permitted only for loopback development.

Public clients reject known service-role/secret keys. Public keys identify an
application; user access tokens and database/storage RLS authorize its actions.
Third-party API secrets are configured in the customer cabinet and are never
downloaded by the application SDK.

## Wire contract

| Capability | Route | Authorization |
| --- | --- | --- |
| Signup | POST /auth/v1/signup | public apikey |
| Password/refresh/code exchange | POST /auth/v1/token?grant_type=password, refresh_token, pkce | public apikey |
| Current user / update password | GET/PUT /auth/v1/user | user bearer + apikey |
| Logout | POST /auth/v1/logout | user bearer + apikey |
| Recovery | POST /auth/v1/recover | public apikey |
| Confirmation | POST /auth/v1/verify | public apikey |
| Google/Apple OAuth | GET /auth/v1/authorize | PKCE S256 + redirect_to |
| Tables / RPC | /rest/v1/{table}, /rest/v1/rpc/{name} | user bearer + apikey; anonymous reads use public key |
| Objects | /storage/v1/object/{bucket}/{path} | user bearer + apikey |
| Signed download | POST /storage/v1/object/sign/{bucket}/{path} | user bearer + apikey |
| Functions | POST /functions/v1/{name} | authenticated user bearer + apikey |
| Realtime | /realtime/v1/websocket?apikey=...&vsn=1.0.0 | user token in join/auth messages |

CRUD uses PostgREST filters, Prefer: return=representation, schema profile
headers, Range/Content-Range and JSON bodies. Mutations and function invocations
are never retried automatically. Errors retain HTTP status and service code but
never attach request headers, tokens or bodies. Cancellation aborts the request.
Service codes may use top-level `code`/`error_code` or the Functions envelope
`{"error":{"code":"FUNCTION_CONCURRENCY_LIMIT"}}`. SDKs extract bounded machine
codes only; nested provider messages are discarded. HTTP 429 does not trigger
an automatic invocation retry.
Storage object segments are percent-encoded individually; traversal, empty
segments and backslashes are rejected. Signed URLs stay bound to the project
origin. No third-party redirects receive credentials.

Email verification uses `POST /auth/v1/verify` with `{email, token, type}`;
`type` is `email` for the standard signup code or `recovery` for password recovery.
A token-hash integration instead sends `{token_hash, type}`. Never combine these
forms. A successful verification returns the user session; a recovery session
authorizes the subsequent authenticated password update. See the
[email flow examples](auth-and-oauth.md#confirm-an-email-or-recover-a-password-with-its-code).

## Sessions and OAuth

Session persistence is namespaced by normalized project origin and caller
namespace. Refresh is single-flight; logout invalidates pending refresh work,
clears persisted state and closes subscriptions. Node clients have per-instance
memory storage; SSR accepts a per-request storage adapter, never a global user
session. Apple uses Keychain. Android encrypts stored tokens with an AES-GCM key
in Android Keystore and excludes the ciphertext from device backup.

OAuth uses a fresh verifier, S256 challenge and exact redirect allowlist. The
Auth service owns provider state validation; clients do not require an
undocumented extra callback query parameter.
The pending verifier is consumed once. Canceled, mismatched or repeated callbacks
cannot replace the session. Native login uses the system browser. Google/Apple
client secrets remain in the project's Auth service.

## Realtime

Implement Phoenix JSON protocol 1.0.0 with join refs, heartbeat, bounded reconnect
backoff, access_token updates and explicit unsubscribe. Only INSERT and UPDATE
are published by the new runtime. DELETE is excluded on the server because
deleted-row RLS cannot be assumed. Reconnect emits a resync-required status:
clients must refetch a snapshot; historical delivery is not guaranteed.

## Functions and compatibility

Functions require a live user session and the capability marker discovered at
`GET /.well-known/stayo.json`: `protocol_version=1`,
`runtime_version=1.3.0-compatible`, `capabilities.functions=true`.
Workers have a 60-second deadline, 150 MB memory and two concurrent calls per
project. Unknown names return 404, unavailable runtime 503 and overload 429.
Before headers arrive, a cancelled client request can leave its worker slot
occupied until the handler completes or reaches its deadline. Cancellation does
not guarantee immediate slot release or undo external side effects.
The former health-only dispatcher must not be accepted as a function result.
Deployments and secret revisions expose their saved and application states;
an unapplied revision cannot silently execute with stale configuration.

## Release acceptance

The same fixture server and real pinned runtime scenarios must exercise all
three packaged clients: Auth, refresh races/logout, callback replay, CRUD/RLS,
Storage paths/signing, function single-dispatch/cancellation, websocket refresh
and reconnect. Two users and two projects prove the access boundaries. Local
fixtures, Docker, device tests and VPS/provider evidence are reported separately.
