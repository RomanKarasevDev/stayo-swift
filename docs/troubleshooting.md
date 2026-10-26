# Errors and troubleshooting

The SDKs expose a bounded service error code and HTTP status. They do not attach
authorization headers, session tokens, request bodies, provider error text, or
secret values to error messages. Avoid adding those values to application logs.

| Status / code | Meaning | What to check |
| --- | --- | --- |
| `0` / `network_error` | Request could not complete, was canceled, or the response could not be trusted | Connectivity, TLS, exact project origin, client cancellation, and server reachability |
| `400` | Request shape, filter, path, or callback is invalid | Match the SDK method signature and remove invalid path segments/query/fragment from OAuth redirects |
| `401` / `not_authenticated` | No valid user session | Sign in again, check email confirmation, or inspect refresh-token expiry |
| `403` | Server policy denied the operation | Check RLS, Storage policies, table grants, and ownership filters using a second test account |
| `404` / `FUNCTION_NOT_FOUND` | The function name is not deployed | Check spelling and the function's approved version and apply status |
| `409` | The saved function version changed or a project operation is in progress | Refresh the cabinet, select the current draft version, and retry the management action after the job finishes |
| `429` / `FUNCTION_CONCURRENCY_LIMIT` | Two function calls are already running for the project | Wait for a response and avoid automatically retrying side-effecting work |
| `503` / `unavailable_capability` | The runtime does not advertise the required feature or isolation is unavailable | Confirm the project uses `1.3.0-compatible`, wait for apply, and check discovery plus Functions status |
| `502` / `FUNCTION_EXECUTION_FAILED` | The function failed before producing a safe response | Inspect the function source and runtime status; do not put the secret in the returned error |
| `storage_error` | The configured client storage could not be read or written | Verify browser privacy settings or platform storage availability; the SDK fails closed |

## OAuth redirect errors

The application redirect must appear exactly in both the SDK configuration and
the project's allowed redirect list. Public web URLs require HTTPS. Do not add a
query, fragment, wildcard, username, or password. For Google and Apple, the
provider's callback URL is a different URL: copy it from project settings into
the provider console.

## Realtime appears connected but no events arrive

Verify the table is in the Realtime publication, RLS permits the signed-in user
to see the row, and the event is `INSERT` or `UPDATE`. On a reconnect, fetch a new
snapshot when resync is signaled. An event delivered while a new subscription is
still connecting is not part of an established subscription.

## Function says unavailable

Check that the project is actually running the experimental `1.3.0-compatible`
template, not only that it was selected in metadata. Discovery must report
`capabilities.functions: true`; the private secret mount and enforcing egress
adapter must be healthy. Never paste private mount contents or secret values
into an issue report.

## Report a reproducible issue safely

Include the SDK name/version, operating system, runtime discovery response,
operation name, HTTP status and bounded error code. Replace domains, user IDs,
object names and request values with synthetic examples. Remove tokens, cookies,
provider credentials, secret values and authorization headers before sharing
logs.
