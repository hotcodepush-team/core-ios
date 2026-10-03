# CLAUDE.md

`HotCodePushProtocol`, the HotCodePush update-protocol client for Apple platforms: the wire types, the evaluator, the downloader, the signature check, the file store, the state machine and the debug screen every HotCodePush SDK on iOS runs, held to the fixture suite of `@hotcodepush/protocol`.
`@hotcodepush/protocol` (`protocol-js`) and the Android library `com.hotcodepush:protocol-android` (`protocol-android`) implement the same functions and types; a change to one is a change to the other two.
The Capacitor SDK consumes it at a pinned git revision until its publish decision — SPM by `revision`, the pod by `:git` and `:commit` — never a branch; it is not the supported API, apps use the SDK for their framework.
Stack: Swift 5.9, iOS 13 and the macOS host for the tests, XCTest, SwiftLint, CocoaPods for the podspec, Node 24 for the fixtures.

The plan is the private `handbook` repo, checked out beside this one: `../handbook/docs/`.
Its `sdk-api.md` (the SDK surface, the state and the functions, statuses and reasons) and `architecture.md` (_The device protocol_, _Signing_, _Packs_, _Debugging_, _Evolving the wire format_, _Testing_) are binding here.
When code and plan disagree, stop and surface it; never improvise.

## Layout

```
Sources/HotCodePushProtocol        the package: no framework import, UIKit in DebugScreen.swift alone and behind canImport; PrivacyInfo.xcprivacy is its resource
Tests/HotCodePushProtocolTests     XCTest on the host; FixtureTests reads node_modules/@hotcodepush/protocol/fixtures after npm ci
Package.swift                      the manifest; HotCodePushProtocol.podspec mirrors it for CocoaPods
package.json                       private, only the pinned @hotcodepush/protocol the fixtures come from
```

## Commands

| Command          | Does                                                                            |
| ---------------- | ------------------------------------------------------------------------------- |
| `npm ci`         | installs the protocol package the fixtures are read from                        |
| `npm run lint`   | `swiftlint lint --strict`                                                       |
| `npm run fmt`    | `swiftlint --fix`                                                               |
| `npm test`       | `swift test`                                                                    |
| `npm run verify` | the lint and the tests                                                          |

`ci.yml` runs the lint, the tests and an iOS simulator build on every push and pull request.
No releases yet: the version stays `0.0.0`, and release-please and the tag arrive with the publish decision.
The fixtures move with `package.json`'s pin: a protocol change is a bump of that sha, and the cases the new build adds fail here until the Swift follows.

## Rules

- The wire format is additive only and parsed strictly: every v1 field is present, a nullable one as `null`, an absent one refuses the document; a field, a condition type or a platform the reader does not know is kept, and an unknown condition fails closed.
- What the device writes follows the same schema: a required key is always written, a nullable one as an explicit `null`, an optional one left out when empty. A synthesized `Encodable` drops a `nil`, so a type that goes on the wire or to the app writes its own `encode(to:)`.
- A value is checked before it names anything: ids are identifiers, hashes lowercase sha256, paths relative with no `.` or `..` segment — split on scalars, never on characters — timestamps UTC with a `Z`, URLs absolute, and the pack's ustar headers carry a checksum that must add up.
- The evaluator is `@hotcodepush/protocol`'s, case for case: the outcome and the verdicts behind it come from the fixtures, never from a reading of the plan.
- A downloaded release that has left the cached index — revoked, or gone from it — is discarded before it would install, never applied.
- Safety is on by default and cannot be switched off: the readiness gate, the local blocklist, the automatic rollback.
- Every key in the store is `hotcodepush.<name>`; three identity keys survive everything, the rest is a cache dropped on an unknown `stateVersion`.
- Statuses and reasons are `SCREAMING_SNAKE_CASE` from the one catalog; a method throws a plain error only for a programming mistake.
- Nothing here writes a cryptographic primitive or parses a standard format by hand beyond ustar and gzip: the platform's CryptoKit, zlib and Foundation do that.
- The signature allow-list is pinned and has one entry, `ed25519`: the manifest string is verified as received under the key its `keyId` names, and a key or signature of the Expo bridge's `rsa-v1_5-sha256` verifies nothing here, so the suite's RSA cases are asserted as refused.
- A download stays on the URL the core pinned and never follows a redirect; a streamed delta the updates host does not serve gives way to the envelope's full pack.
- The debug screen shows what `DebugReport` renders, and the share text is the same sections: a fact joins both through `DebugReport`, never the screen alone. The session log lives in memory, the newest two hundred lines, never on disk and never on the wire.

## Naming

- A name says what the function does on first read: the verb, the object and, where it matters, the qualifier.
- Prefixes: `fetch` HTTP, `resolve` derivations without I/O, `build` functions that assemble a document without sending it, `handle` the lifecycle entry points.
- Alphabetical ordering within a scope.
- One thing per function, its name saying which; never a function that both decides something and phrases the message about it.
- Booleans carry `is` or `has`; a state with a moment is a timestamp such as `pausedAt`, never a boolean.
- Test titles read `should <verb> …`, lowercase, conditions starting with `when`.
- Fixtures and examples carry invented data only.

## Agent workspace

- `.claude/skills/` holds the developer skills copied from `hotcodepush-team/.github`, pinned in `skills-lock.json`.
- Commits are conventional commits; `main` is trunk, CI is the gate, and a commit that lands an issue says `Closes #<n>`.
