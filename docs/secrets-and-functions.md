# Project secrets and server functions

Use project secrets when a server-side function must call a third-party API.
The mobile app or browser calls Stayo with its public key and the signed-in
user's session. The function reads the secret for its own project and performs
the provider request.

```text
Application → Stayo SDK → Authenticated project function → External API
                                  ↑
                         Project secret storage
```

## Add or rotate a secret

1. In the project cabinet, open **Secrets**.
2. Enter a name such as `PAYMENTS_API_KEY` and paste the value into the protected
   field. Confirm your cabinet password when prompted.
3. Save the change and wait for the Functions status to become available.
4. The value is never returned by the management API or shown again. “Saved”
   confirms encrypted storage; it does not verify that the provider accepts it.
5. To rotate a key, save its replacement and then verify the external function
   with a safe provider operation. Deleting a key removes access from running
   functions and can make them unavailable.

If the cabinet cannot confirm a write result, refresh the section before
submitting anything again. A request can commit even when its response is lost.
Check the updated metadata and the applied function version, then use a safe
function call to verify the intended behavior without returning or logging the
secret. A timestamp does not verify the provider key. If the runtime cannot
accept a change while another operation is applying, wait for that operation to
finish and refresh before entering the value and password again. The SDK and
cabinet do not automatically repeat these writes.

Names use uppercase letters, numbers, and underscores, start with a letter, and
are limited to 64 characters. A project can store up to 64 secrets; each UTF-8
value can be up to 16 KiB and can contain newlines. Platform and runtime
variable names are reserved. Never put values in function source, commit them,
or paste them into logs/issues.

Secrets are encrypted with project/name-bound XChaCha20-Poly1305. Backup archives
include encrypted secret and function state, with an independent recovery
recipient. Restore re-encrypts secrets for the target project's identity. The
[customer cabinet acceptance](release-status.md#verification) records a live
same-host restore of named secrets, file bytes, published functions and separate
drafts on the exact installed candidate. Power-loss and replacement-host recovery
remain separate acceptance checks.

## Create and publish a function

The function editor stores a draft separately from the last approved version.
Review the source, save the draft, and explicitly publish its version. A newer
edit in another tab cannot silently replace the selected version. Wait for the
deployment state to report that the approved version is applied before invoking
it from an SDK.

Example `hello` function:

```ts
Deno.serve(async (request) => {
  const input = await request.json()
  return Response.json({ message: `Hello, ${String(input.name ?? 'there')}` })
})
```

Example of reading a project secret and making a generic HTTPS request:

```ts
Deno.serve(async () => {
  const token = Deno.env.get('PARTNER_API_TOKEN')
  if (!token) return Response.json({ error: 'not_configured' }, { status: 503 })

  const response = await fetch('https://api.example.com/v1/status', {
    headers: { authorization: `Bearer ${token}` },
    redirect: 'error',
  })
  return new Response(response.body, {
    status: response.status,
    headers: { 'content-type': response.headers.get('content-type') ?? 'application/json' },
  })
})
```

Replace the example hostname and response contract with your provider's
documented API. Never return the token, include it in error text, or log request
headers. Function code can use and disclose its own project's secrets, so review
source changes before publishing.

## Invoke a function

All SDKs send the current user's bearer token and make one request. They do not
retry function calls automatically because an external side effect may already
have happened. A user must be signed in. Unknown functions return `404`, project
overload returns `429`, and unavailable isolation/runtime returns `503`.

```ts
const result = await stayo.functions.invoke('hello', {
  body: { name: 'Ada' },
  signal: abortController.signal,
})
```

The worker limit is 60 seconds and 150 MB, with two concurrent invocations per
project. Cancellation stops the client from waiting and signals the server; an
external provider may still have completed work after dispatch. Make provider
operations idempotent when the provider supports it.

Before response headers arrive, an already running handler can retain its slot
after the client cancels, until the handler finishes or reaches the 60-second
worker deadline. Cancelling both clients can therefore leave new calls receiving
`429 FUNCTION_CONCURRENCY_LIMIT` during that interval. Cancellation does not
reserve a replacement slot and does not make an automatic retry safe.

## Isolation and availability

Functions run in a project-scoped network with access to the public HTTPS egress
adapter and their own project API gateway. Private, loopback, host, metadata, and
other-project destinations are blocked. Runtime credentials such as database
passwords, JWT signing secrets and service-role keys are not passed to user code.
The function gets only public project configuration and named secrets for its
own project.

The function API is available only when discovery at
`/.well-known/stayo.json` reports protocol `1`, runtime
`1.3.0-compatible`, and `capabilities.functions: true`. The new template is
experimental and customer projects currently default to `1.2.0-compatible`.
Existing projects do not upgrade automatically. Enablement requires an operator
to explicitly select and accept the new runtime.

## Provider examples

The first provider-specific example and live OpenAI check are intentionally
deferred by the owner. This guide therefore uses a generic HTTPS request and
does not claim that any provider key has been validated.
