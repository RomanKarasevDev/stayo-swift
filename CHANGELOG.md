# Changelog

## 0.1.0 (unpublished)

- Native Auth/PKCE browser, namespaced Keychain sessions and refresh/logout barriers.
- Typed database/RPC, object storage and runtime-gated server functions.
- Database, RPC and Storage calls, like Functions, are bound to the session they
  started with: transitions cancel them and late responses fail with
  `staleSession`; no request is retried.
- INSERT/UPDATE websocket streams with token refresh, reconnect and resync events.
- SwiftPM source package, Apple example and local protocol fixtures.
- Email/code confirmation and recovery; bounded nested Functions error codes.
- Portable guides and shared UUID notes schema across the three SDK examples.

Public SwiftPM repository/tag, real OAuth and device/Keychain acceptance remain
open. Client cancellation does not guarantee immediate server slot release.
