# CLAUDE.md

`HotCodePushProtocol`, the HotCodePush update-protocol client for Apple platforms: the wire types, the evaluator, the downloader, the signature check, the patch application, the file store, the state machine and the debug screen every HotCodePush SDK on iOS runs, held to the fixture suite of `@hotcodepush/protocol`.
`@hotcodepush/protocol` (`protocol-js`) and the Android library `com.hotcodepush:protocol-android` (`protocol-android`) implement the same functions and types; a change to one is a change to the other two.
The Capacitor SDK consumes it at a pinned git revision until its publish decision — SPM by `revision`, the pod by `:git` and `:commit` — never a branch; it is not the supported API, apps use the SDK for their framework.
Stack: Swift 5.9, C for FreeBSD's `bspatch.c` over the system's libbz2, iOS 13 and the macOS host for the tests, XCTest, SwiftLint, CocoaPods for the podspec, Node 24 for the fixtures.

The plan is the private `handbook` repo, checked out beside this one: `../handbook/docs/`.
Its `sdk-api.md` (the SDK surface, the state and the functions, statuses and reasons) and `architecture.md` (_The device protocol_, _Signing_, _Packs_, _Debugging_, _Evolving the wire format_, _Testing_) are binding here.
When code and plan disagree, stop and surface it; never improvise.

## Layout

```
Sources/HotCodePushProtocol        the package: no framework import, UIKit in DebugScreen.swift alone and behind canImport; PrivacyInfo.xcprivacy is its resource
Sources/HotCodePushBspatch         the C target linking libbz2: bspatch.c and its header, byte for byte protocol-android's, which a CI step compares
Tests/HotCodePushProtocolTests     XCTest on the host; FixtureTests reads node_modules/@hotcodepush/protocol/fixtures after npm ci
Tests/BspatchFixtures              what BspatchTests reads: the committed inputs old.bin, new.bin and valid.patch, the patch written once by bsdiff 4.3, and the hostile patches make-patches.sh writes with bash, xxd and bzip2
Package.swift                      the manifest; HotCodePushProtocol.podspec mirrors it for CocoaPods, where the pod compiles the C sources into its one module
THIRD-PARTY-NOTICES                bspatch's BSD 2-clause notice
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

`ci.yml` compares the bspatch sources with protocol-android's, then runs the lint, the tests and an iOS simulator build, on every push to `main` and every pull request.
No releases yet: the version stays `0.0.0`, and release-please and the tag arrive with the publish decision.
The fixtures move with `package.json`'s pin: a protocol change is a bump of that sha, and the cases the new build adds fail here until the Swift follows.

## Rules

- The wire format is additive only and parsed strictly: every v1 field is present, a nullable one as `null`, an absent one refuses the document; a field, a condition type or a platform the reader does not know is kept, and an unknown condition fails closed.
- What the device writes follows the same schema: a required key is always written, a nullable one as an explicit `null`, an optional one left out when empty. A synthesized `Encodable` drops a `nil`, so a type that goes on the wire or to the app writes its own `encode(to:)`.
- A value is checked before it names anything: ids are identifiers, hashes lowercase sha256, paths relative with no `.` or `..` segment — split on scalars, never on characters — timestamps UTC with a `Z`, URLs absolute, and the pack's ustar headers carry a checksum that must add up.
- The evaluator is `@hotcodepush/protocol`'s, case for case: the outcome and the verdicts behind it come from the fixtures, never from a reading of the plan.
- A downloaded release that has left the cached index — revoked, or gone from it — is discarded before it would install, never applied.
- A build whose resource file carries `channelId: null` — built without a token or offline — answers `FAILED` with `UNKNOWN_CHANNEL` without a request and sends no report; a channel set at runtime makes it a device like any other, and clearing that choice returns it to the answer.
- Safety is on by default and cannot be switched off: the readiness gate, the local blocklist, the automatic rollback.
- Every key in the store is `hotcodepush.<name>`; three identity keys survive everything, the rest is a cache dropped on an unknown `stateVersion`.
- Statuses and reasons are `SCREAMING_SNAKE_CASE` from the one catalog; a method throws a plain error only for a programming mistake.
- Nothing here writes a cryptographic primitive or parses a standard format by hand beyond ustar and gzip: CryptoKit hashes, Security verifies, FreeBSD's `bspatch.c` applies BSDIFF40 over the system's libbz2, zlib and Foundation do the rest.
- `bspatch.c` is FreeBSD's with the lower bound on the old file's offset that FreeBSD dropped in 2019 restored, every change listed under its licence header, and byte for byte protocol-android's: a change lands in both cores at once, and `ci.yml` fails on a difference.
- The signature allow-list is pinned and has one entry, `rsa-v1_5-sha256`: the manifest string is verified as received with `SecKeyVerifySignature` under the key its `keyId` names; a value under any other prefix, `ed25519` included, is an unknown scheme.
- A public key is the resource file's `{ der, keyId }`: the PKCS #1 DER goes to `SecKeyCreateWithData` as it stands, the key id is taken as given, and no ASN.1 is handled and no key format converted here. A key the system refuses is the app's configuration and the message says so; a key under 2048 bits is refused, its size read from the imported key.
- A download stays on the URL the core pinned and never follows a redirect; a streamed delta the updates host does not serve gives way to the envelope's full pack.
- A pack entry is named by ustar's prefix and name fields, `prefix/name` when the prefix is not empty: a content hash is a file entry, its body the stored gzip object, and `patches/{from}/{to}` a patch entry, its body a BSDIFF40 patch from the content of the file `from` to the content of the file `to`. An entry of any other name is skipped with its body, never an error, so a later entry kind does not break a shipped SDK; a header whose checksum does not add up or a cut archive stays an error.
- A patch applies only to a file of the signed manifest the device lacks, from a base it holds in the file store or the embedded bundle, never past the manifest's size of the target; the store takes the result only when it hashes to the target.
- A patch that does not apply — no base, a malformed patch, another hash, no memory — leaves its file to the single-file fetch after the pack: an update never fails because of a patch.
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
