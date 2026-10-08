# CLAUDE.md

`HotCodePushCore`, the HotCodePush update-protocol client for Apple platforms: the wire types, the evaluator, the downloader, the signature check, the patch application, the file store, the state machine and the debug screen every HotCodePush SDK on iOS runs, held to the fixture suite of `@hotcodepush/protocol`.
`@hotcodepush/protocol` (`protocol`) and the Android library `com.hotcodepush:core-android` (`core-android`) implement the same functions and types; a change to one is a change to the other two.
The Capacitor SDK consumes it at a pinned git revision until its publish decision — SPM by `revision`, the pod by `:git` and `:commit` — never a branch; it is not the supported API, apps use the SDK for their framework.
Stack: Swift 5.9, C for FreeBSD's `bspatch.c` over the system's libbz2, iOS 13 and the macOS host for the tests, XCTest, SwiftLint, CocoaPods for the podspec, Node 24 for the fixtures.

The plan is the private `handbook` repo, checked out beside this one: `../handbook/docs/`.
Its `sdk-api.md` (the SDK surface, the state and the functions, statuses and reasons) and `architecture.md` (_The device protocol_, _Signing_, _Packs_, _Debugging_, _Evolving the wire format_, _Testing_) are binding here.
When code and plan disagree, stop and surface it; never improvise.

## Layout

```
Sources/HotCodePushCore            the package: no framework import, UIKit in DebugScreen.swift and Platform.swift alone and behind canImport; HotCodePushCorePrivacy.bundle holds the privacy manifest, which SPM copies as a resource and the pod ships whole through `s.resources`, no generated target
Sources/HotCodePushBspatch         the C target linking libbz2: bspatch.c and its header, byte for byte core-android's, which a CI step compares
Tests/HotCodePushCoreTests         XCTest on the host; FixtureTests reads node_modules/@hotcodepush/protocol/fixtures after npm ci
Tests/BspatchFixtures              what BspatchTests reads: the committed inputs old.bin, new.bin and valid.patch, the patch written once by bsdiff 4.3, and the hostile patches make-patches.sh writes with bash, xxd and bzip2
Package.swift                      the manifest; HotCodePushCore.podspec mirrors it for CocoaPods, where the pod compiles the C sources into its one module
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

`ci.yml` compares the bspatch sources with core-android's, then runs the lint, the tests and an iOS simulator build, on every push to `main` and every pull request.
No releases yet: the version stays `0.0.0`, and release-please and the tag arrive with the publish decision.
The fixtures move with `package.json`'s pin: a protocol change is a bump of that sha, and the cases the new build adds fail here until the Swift follows.

## Rules

- The wire format is additive only and parsed strictly: every v1 field is present, a nullable one as `null`, an absent one refuses the document; a field, a condition type or a platform the reader does not know is kept, and an unknown condition fails closed.
- What the device writes follows the same schema: a required key is always written, a nullable one as an explicit `null`, an optional one left out when empty. A synthesized `Encodable` drops a `nil`, so a type that goes on the wire or to the app writes its own `encode(to:)`.
- A value is checked before it names anything: ids are identifiers, hashes lowercase sha256, paths relative with no `.` or `..` segment — split on scalars, never on characters — timestamps UTC with a `Z`, URLs absolute, and the pack's ustar headers carry a checksum that must add up.
- The evaluator is `@hotcodepush/protocol`'s, case for case: the outcome and the verdicts behind it come from the fixtures, never from a reading of the plan.
- A downloaded release that has left the cached index — revoked, or gone from it — is discarded before it would install, never applied.
- A build whose resource file carries `channelId: null` — built without a token or offline — answers an explicit call `FAILED` with `CHANNEL_UNKNOWN` without a request, starts no automatic cycle and sends no report; a channel set at runtime makes it a device like any other, and clearing that choice returns it to the answer.
- A build whose resource file carries `embeddedBundleManifest: null` — a React Native or Expo debug build, whose build step bundled no JavaScript — and a debug build with `enabledInDebugBuilds` off answer every cycle `SKIPPED` with `BUILD_DEBUG` and send nothing.
- A rollback's `rolledBack` event is stored and announced at every start until the app is up in a run that received it, so the JavaScript that listens only after its start never misses it; `clearUpdates()` and a new binary drop the stored notice with the rest.
- A batch the events endpoint refuses with a 4xx other than 408 and 429 is dropped, its events gone and the report left unacknowledged for the next one; a 202 takes both, and anything else keeps both for the next sync.
- Safety is on by default and cannot be switched off: the readiness gate, the local blocklist, the automatic rollback.
- A readiness signal reported before the core's latest load of a bundle, the start's own load after its timeout included, belongs to the replaced bundle and counts for nothing.
- The start answers the bundle to serve without awaiting the network, `handleAppStart`; a host in synchronous code asks `handleAppStartBlocking` and waits at most two seconds, then serves the embedded bundle and is reloaded into the right one once the start runs; the cleanup runs after the start, never on its path, and anything the start cannot read answers the embedded bundle.
- A headless start, `isHeadless: true` from a host that will render no screen, still drops a stale store, rolls back a crash and checks, but applies no waiting release, arms no gate and loads nothing: the host serves the start's answer and every persisted marker stays as it was.
- The readiness timer runs in the foreground alone: the background stops it, the resume starts its full window again, and a launch into the background starts it paused.
- A reload the SDK did not perform is reported with `handleAppReload()`: it applies a held or next-start install, gates an unconfirmed release and makes restarts wait for the app again, and is never a crash.
- A channel id is a UUID: `setChannel`, `sync`, `checkForUpdate()` and `downloadUpdate()` refuse any other with the plain error before fetching; the index's app, channel and platform and the manifest's app and platforms must be the device's, else `INDEX_INVALID` or `MANIFEST_INVALID`.
- A fetched index with a lower sequence than the kept one is ignored only while the kept index is younger than `cachedIndexMaxAge`, one day by its `fetchedAt`; an older kept index is replaced whatever the sequence, so a forged far-future sequence freezes a device for a day at most. The sequence is a millisecond time, held in `Int`, 64 bits on every target.
- A new binary, a changed `builtAt`, and a restored phone drop the kept index and its ETag with the stored releases, so the first check fetches unconditionally.
- A resource file with a `checkInterval` below 60 seconds is refused like any other schema violation: no `Core` is created and the app runs its embedded bundle.
- A call joins a running cycle of its own stage and waits for one of another; a download that adopts the running bundle answers `UP_TO_DATE`; a held restart re-checks the cached index before applying.
- A report the endpoint would refuse is left out of the batch and logged `REPORT_UNREADABLE`; a value `setAttributes` would send is at most 256 code points with no control character.
- Tests wait on `waitForBackgroundWork()`, never on a sleep.
- Before the app is up in this run the only reload is a rollback, and checking and downloading never wait. The first render, whatever `readySignal` is, `notifyReady()` or the readiness timeout settles the start, `hasStartSettled`, and every reload the core performs unsettles it until the reloaded app reaches one of the three. The automatic check at start runs at once for a confirmed release and at its confirmation for a new one: a release that was confirmed and later dies before it renders must still receive a fix or a revocation. A reload waits for the settled start whoever asks for it: a restart the core performs on its own, which also waits while the app holds restarts, and the app's `applyUpdate()` and `clearUpdates()`, which `setRestartAllowed(false)` never holds. One restart is held at most: the app's replaces a held one, the core's yields to a held one, and a reload the core performs clears it. A rollback never waits for the start: the one at start after a crash in the previous run and the app's `rollbackUpdate()` reload at once, and the readiness timeout settles the start before it rolls back, so only `setRestartAllowed(false)` can still hold that reload. An install the core holds is persisted as the bundle to serve before it waits, a `next-resume` install included, so the next start runs it when this run never does; a held `applyUpdate()` or `clearUpdates()` persists nothing and stays the app's business.
- Every key in the store is `hotcodepush.<name>`; three identity keys survive everything, the rest is a cache dropped on an unknown `stateVersion`.
- Statuses and reasons are `SCREAMING_SNAKE_CASE` from the one catalog; a method throws a plain error only for a programming mistake.
- Nothing here writes a cryptographic primitive or parses a standard format by hand beyond ustar and gzip: CryptoKit hashes, Security verifies, FreeBSD's `bspatch.c` applies BSDIFF40 over the system's libbz2, zlib and Foundation do the rest.
- `bspatch.c` is FreeBSD's with the lower bound on the old file's offset that FreeBSD dropped in 2019 restored, every change listed under its licence header, and byte for byte core-android's: a change lands in both cores at once, and `ci.yml` fails on a difference.
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
