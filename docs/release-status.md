# Stayo SDK 0.1.0 — release status

The JavaScript/TypeScript, Swift and Kotlin SDKs are release candidates. Public
npm, SwiftPM and Maven Central availability has **not** been confirmed. Registry
installation commands in these guides apply after an approved public release.

## Packages

| Platform | Prepared coordinate | Minimum platform |
| --- | --- | --- |
| Web / Node.js | `@stayo/sdk@0.1.0` | Modern browsers; Node.js 22 |
| Apple | SwiftPM product `Stayo`, tag `0.1.0` | iOS 16; macOS 13; Swift tools 5.9 |
| Android | `live.stayo:stayo-android:0.1.0` | Android API 26; JDK 17 for building |

The source repositories are [stayo-js](https://github.com/RomanKarasevDev/stayo-js),
[stayo-swift](https://github.com/RomanKarasevDev/stayo-swift) and
[stayo-android](https://github.com/RomanKarasevDev/stayo-android). Source availability
does not establish a public package release. Registry namespace ownership,
publisher signatures and installation from the actual registries remain unverified.
The SDK source exports contain SDK code, examples, licenses and
portable guides. The enclosing OwnBase control plane is a separate project.

## Verification

Local release preparation builds and installs the actual package archives in
fresh consumers. Its manifest identifies the source revision, artifacts and
checksums. These checks are separate from real provider and device acceptance.

The compatible test runtime has separate recorded checks for authentication,
CRUD/RLS, files, functions, Realtime, email codes, encrypted backup/restore,
load limits and reboot. Evidence retains the exact runtime and SDK revision used
for each scenario. A newer package archive does not silently inherit every live
check performed with an earlier archive.

Real Google/Apple OAuth and physical-device Keychain/Keystore acceptance remain
open. The OpenAI example/provider check is deferred. Do not use these guides as
evidence that those checks have passed.

## Release decision

Public publication, documentation hosting and production deployment require a
separate owner decision. Maven artifacts must receive the approved publisher's
signatures; an unsigned local ZIP is a preparation artifact. Public SwiftPM
installation requires a repository with `Package.swift` at its root and an
approved version tag. No account passwords, signing keys or provider credentials
belong in an SDK archive or in this handbook.
