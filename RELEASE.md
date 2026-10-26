# 0.1.0 release preparation

The release unit is the contents of this directory, extracted as a standalone
SwiftPM repository root. `scripts/package.sh` generates an allowlisted source
archive and SHA-256 in `.build/artifacts`; it excludes build caches, project
configuration and credentials. Check `Package.swift`, `StayoClient.version` and
changelog before approved tagging. Do not publish the enclosing monorepo as the
SwiftPM dependency; its package lives in a subdirectory.

The archive normalizes timestamps/ownership, includes only supported source and
guide files, and refuses symbolic links. Its checksum uses a portable basename.
The integration release-kit workflow additionally includes portable guides and
tests an extracted archive through a local Git version tag and separate consumer.
It does not create a public repository or tag.

Local required checks:

- `swift test` including the real loopback websocket fixture.
- `swift build`; `swift run stayo-example` with no credentials prints setup usage.
- Compile the library and SwiftUI example for iOS Simulator at iOS 16 deployment.
- Extract source archive into a clean temporary directory, build and test it.
- Independent source review and matching runtime fixture scenarios across SDKs.

External acceptance remains explicit: pinned 1.3.0-compatible runtime, two users
and two projects with real CRUD/RLS and Storage, provider email/Google/Apple login,
iPhone and Mac app execution and Keychain persistence, websocket network loss,
real function execution/cancellation/limits, and isolated VPS restore/reboot.
Local fixtures/compilation do not establish these facts. Publication and production
deployment require separate user authorization.
