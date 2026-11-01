# Changelog

## [0.3.0](https://github.com/hotcodepush-team/core-ios/compare/0.2.0...0.3.0) (2026-11-01)


### ⚠ BREAKING CHANGES

* Signatures is SignatureVerifier, Configuration.isOnConfiguredHost is isUrlOnConfiguredHost, and FileStore.writeFile(_:sha256:) and PackReader.entries(in:) are gone.
* a channel whose index is gone fails the check and is never changed by the SDK ([#33](https://github.com/hotcodepush-team/core-ios/issues/33))

### Features

* a channel whose index is gone fails the check and is never changed by the SDK ([#33](https://github.com/hotcodepush-team/core-ios/issues/33)) ([712de75](https://github.com/hotcodepush-team/core-ios/commit/712de7506d82d21f77d57d905b8c993404b89749))
* one signature verifier, refusals and host check named as in core-android and the protocol ([#37](https://github.com/hotcodepush-team/core-ios/issues/37)) ([eb33ea9](https://github.com/hotcodepush-team/core-ios/commit/eb33ea9811f2e4c65c64ee6d703944cc1636eed1))

## [0.2.0](https://github.com/hotcodepush-team/core-ios/compare/0.1.0...0.2.0) (2026-10-31)


### ⚠ BREAKING CHANGES

* protocol b485e58, the readers refuse what the protocol refuses, the core owns the metered check, and the names follow the protocol ([#29](https://github.com/hotcodepush-team/core-ios/issues/29))
* the wire after the contract audit: no rolled_back event, conditionType, pausedAt, rolloutPercent, stateVersion 6 ([#27](https://github.com/hotcodepush-team/core-ios/issues/27))

### Features

* protocol b485e58, the readers refuse what the protocol refuses, the core owns the metered check, and the names follow the protocol ([#29](https://github.com/hotcodepush-team/core-ios/issues/29)) ([b4d3e8e](https://github.com/hotcodepush-team/core-ios/commit/b4d3e8ec54df807e395c8203b4fe84cb361465b9))
* the wire after the contract audit: no rolled_back event, conditionType, pausedAt, rolloutPercent, stateVersion 6 ([#27](https://github.com/hotcodepush-team/core-ios/issues/27)) ([4bc9d41](https://github.com/hotcodepush-team/core-ios/commit/4bc9d4121749a264f6c563b634e9b0d9dd0646b7))

## 0.1.0 (2026-10-28)


### ⚠ BREAKING CHANGES

* HotCodePushCore requires iOS 15.0.
* every catalog value is lowercase snake_case, held to catalog.json
* a device with a base takes the delta route for any missing file, its static URL first
* reportedAt keeps the month's first acknowledged device report
* handleAppReload() is gone. A host that reloads on its own answers the running bundle itself without calling the core, as the React Native SDK does when React Native asks for a bundle after the start.
* ApplyUpdateResult replaces ApplyResult
* downloadUpdate() is sync() with the download gate open
* the apply moment is stored with the downloaded release
* downloadSizeBytes, and the rollback announced as updateRolledBack
* APPLIED replaces UPDATED, and DOWNLOADED carries applyAt
* the resource file names its strategies and its durations in seconds
* each stage checks the channel id in effect, as core-android does, and stored ids are identifiers
* a channel id is a UUID, and the index and the manifest name the device's app
* tests wait on the core's background work, never on a sleep, over fakes that hold a lock
* the protocol at daa03b8, a binary version padded to three components, http and https URLs only
* every reason names the thing at fault first, SUBJECT_STATE
* the runtime condition and the runtime version leave the core
* the channel's id is null while no id is known
* a build without an embedded bundle skips every cycle with DEBUG_BUILD
* the package is HotCodePushCore in core-ios
* rollback() is rollbackUpdate(), a verb and its object like every other method
* the pack's patch entries applied from the delta, and patches leave the manifest and the envelope
* signatures are RSA alone, verified by Security.framework with the resource file's keys

### Features

* a batch refused with a 4xx drops its events and keeps the report unacknowledged ([65be7ab](https://github.com/hotcodepush-team/core-ios/commit/65be7ab0f89175880e07f445c89ec52d707a9f3c))
* a build without a channel answers UNKNOWN_CHANNEL without a request and reports nothing ([457635b](https://github.com/hotcodepush-team/core-ios/commit/457635bfb1d248af8a87df374a4694f43e8253f9))
* a build without an embedded bundle skips every cycle with DEBUG_BUILD ([3f79d7d](https://github.com/hotcodepush-team/core-ios/commit/3f79d7dcfd4ce19ec986c3eb5677b48c5575d943))
* a channel id is a UUID, and the index and the manifest name the device's app ([10f3e85](https://github.com/hotcodepush-team/core-ios/commit/10f3e85586ab9392c8c05b40bb7f521a6b4fbecf))
* a device without a channel starts no automatic cycle ([b9159cb](https://github.com/hotcodepush-team/core-ios/commit/b9159cbf2d1a043caaa8c1e790c36767068340b0))
* a headless start neither applies a waiting release nor arms the gate ([09aa386](https://github.com/hotcodepush-team/core-ios/commit/09aa386c73cc0242afe5696b83b731e9678e4bd5))
* a reload the core did not perform is never interpreted ([55c52d2](https://github.com/hotcodepush-team/core-ios/commit/55c52d20b1a8ba79dd207042221bf68b0b54a8eb))
* a reload the core did not perform runs through the gate like any start ([e690777](https://github.com/hotcodepush-team/core-ios/commit/e690777a0930676a317c36450ab8a7c878693196))
* APPLIED replaces UPDATED, and DOWNLOADED carries applyAt ([bd36659](https://github.com/hotcodepush-team/core-ios/commit/bd36659ce5eec617f76d5af9d890edd4acb1411a))
* ApplyUpdateResult replaces ApplyResult ([0e330b9](https://github.com/hotcodepush-team/core-ios/commit/0e330b9de997b881dee35b0683464dbdaf875cac))
* build the XCFramework and attach it to release-please's releases ([#23](https://github.com/hotcodepush-team/core-ios/issues/23)) ([75d51f9](https://github.com/hotcodepush-team/core-ios/commit/75d51f93fc7890a929fba30c362b36f065c135e4))
* device-events.json runs against the encoder, and the device never builds a batch the endpoint refuses ([43c9a6a](https://github.com/hotcodepush-team/core-ios/commit/43c9a6a08daa3e7dd808081df4413b6dc51450ff))
* downloadSizeBytes, and the rollback announced as updateRolledBack ([99ebf89](https://github.com/hotcodepush-team/core-ios/commit/99ebf892a371d442a2fde462c5fbfeae53bcbe88))
* downloadUpdate() is sync() with the download gate open ([96c8d4d](https://github.com/hotcodepush-team/core-ios/commit/96c8d4d32282f59cb6898ffc6f8ea3c5b4b531fc))
* each stage checks the channel id in effect, as core-android does, and stored ids are identifiers ([531ab6e](https://github.com/hotcodepush-team/core-ios/commit/531ab6ed0c3d8be228435b5594b390f10c28b6b1))
* every catalog value is lowercase snake_case, held to catalog.json ([17a2cc9](https://github.com/hotcodepush-team/core-ios/commit/17a2cc92ac21c870cec9a5cfe32d427433bdfb70))
* every reason names the thing at fault first, SUBJECT_STATE ([b87894b](https://github.com/hotcodepush-team/core-ios/commit/b87894b3e7bbea73067fa944c6dc5a61f3bab7c0))
* FreeBSD's bspatch as the C target HotCodePushBspatch, over the system's libbz2 ([485d35d](https://github.com/hotcodepush-team/core-ios/commit/485d35d116f3235c7fbce2bc59d6c60c7fefba59))
* raise the iOS floor to 15 and ship the privacy manifest as a resource bundle ([#22](https://github.com/hotcodepush-team/core-ios/issues/22)) ([906073c](https://github.com/hotcodepush-team/core-ios/commit/906073c537d9651a91ef644d4ca694e1642dc69f))
* rollback() is rollbackUpdate(), a verb and its object like every other method ([d2d70f1](https://github.com/hotcodepush-team/core-ios/commit/d2d70f1fc4ecade23506af946caa514f2f287a72))
* signature verification over the manifest bytes against the app's public keys ([6353b16](https://github.com/hotcodepush-team/core-ios/commit/6353b16ff983b10f5e2a4d8ef006bf9df8bc4e24)), closes [#2](https://github.com/hotcodepush-team/core-ios/issues/2)
* signatures are RSA alone, verified by Security.framework with the resource file's keys ([f16d46b](https://github.com/hotcodepush-team/core-ios/commit/f16d46b73be943bba63bfcc659670f34665f89fc))
* the apply moment is stored with the downloaded release ([5562cc2](https://github.com/hotcodepush-team/core-ios/commit/5562cc295a7efd9915b04f20b60c544b19f12a4d))
* the channel's id is null while no id is known ([4d53567](https://github.com/hotcodepush-team/core-ios/commit/4d53567c2378c9f9bdfee8f28732d03741c9a618))
* the core emits the download progress event ([a1f2cc3](https://github.com/hotcodepush-team/core-ios/commit/a1f2cc371dbfdc4c983979ab1585f2069bd547a6))
* the core owns what every bridge repeated ([95fc505](https://github.com/hotcodepush-team/core-ios/commit/95fc50509a4a5a7e14a7148a98820cf0454dae99))
* the debug screen, the session log behind it and the report the share sheet carries ([0a23070](https://github.com/hotcodepush-team/core-ios/commit/0a2307088865ea2d2897e053ec0cf4d52dbf0190)), closes [#3](https://github.com/hotcodepush-team/core-ios/issues/3)
* the index decides the pack; an unlisted base takes the streamed pack directly ([b2f5fad](https://github.com/hotcodepush-team/core-ios/commit/b2f5fadf8bf7c8c0089564dbbc8f02b6385f2fdc))
* the index says when it was published, the host rows go ([bba0cf9](https://github.com/hotcodepush-team/core-ios/commit/bba0cf94109e0fe0dd2b5abe6d085a3c5b5f3d95))
* the pack's patch entries applied from the delta, and patches leave the manifest and the envelope ([06d3d8c](https://github.com/hotcodepush-team/core-ios/commit/06d3d8c86c9bd191cec1ae3f116d44f5ea12692c)), closes [#4](https://github.com/hotcodepush-team/core-ios/issues/4)
* the package converges on the protocol fixtures and reads the wire strictly ([434efe1](https://github.com/hotcodepush-team/core-ios/commit/434efe103f7a56005f6a1d9ed43ac9a816dbf0f0)), closes [#1](https://github.com/hotcodepush-team/core-ios/issues/1)
* the protocol at daa03b8, a binary version padded to three components, http and https URLs only ([ba1c3e6](https://github.com/hotcodepush-team/core-ios/commit/ba1c3e604d3040108f6d4c65d5eff65cf7c6fcd3))
* the resource file names its strategies and its durations in seconds ([fb08ccb](https://github.com/hotcodepush-team/core-ios/commit/fb08ccb145d217fed30ffcf9e8cdf06fb999cccc))
* the rollback notice is stored and announced at every start until the app is up after it ([98f0d57](https://github.com/hotcodepush-team/core-ios/commit/98f0d575285b7e4ea6f8cac0c6e98fa1e0f8f506))
* the runtime condition and the runtime version leave the core ([c9b5266](https://github.com/hotcodepush-team/core-ios/commit/c9b5266d0780d5e56e4b86c847bc6d5ea5184536))
* the start answers the bundle the host serves, and a host in synchronous code waits for it with a bound ([e4eb8af](https://github.com/hotcodepush-team/core-ios/commit/e4eb8af48578053c872ce24b8db89258620df6be))
* the streamed delta from the updates host for a base the bucket holds no delta for ([d872142](https://github.com/hotcodepush-team/core-ios/commit/d87214202dcd7f742a8831cc33201f0f3afbffda)), closes [#5](https://github.com/hotcodepush-team/core-ios/issues/5)
* the Swift package HotCodePushProtocol — the core moved from capacitor-live-updates, renamed, iOS 13 ([efd3f31](https://github.com/hotcodepush-team/core-ios/commit/efd3f3102aa9a2544bed42edd29a54e7cd811d57))


### Bug Fixes

* a crash rollback at start leaves the load to loadBundle() ([2d50639](https://github.com/hotcodepush-team/core-ios/commit/2d5063953f650bb0f46c5ddca7c97e37fc4d11b4))
* a device with a base takes the delta route for any missing file, its static URL first ([3f65e44](https://github.com/hotcodepush-team/core-ios/commit/3f65e44915b8d5e1b405a29434446450ee646e51)), closes [#20](https://github.com/hotcodepush-team/core-ios/issues/20)
* a download is tried three times inside the check before it fails ([45ed3a2](https://github.com/hotcodepush-team/core-ios/commit/45ed3a23b135daa10665b4aeb1dc05de7a09e71d))
* a FAILED or BUILD_DEBUG result carries no release when none was evaluated ([31a7c5b](https://github.com/hotcodepush-team/core-ios/commit/31a7c5bae7a68f3df9ba241eea34f33b449d9438)), closes [#17](https://github.com/hotcodepush-team/core-ios/issues/17)
* a headless start keeps the bundle persisted for the next start ([3707f3a](https://github.com/hotcodepush-team/core-ios/commit/3707f3aa062f7cef568b451fac43c1f0ab870547))
* a new binary drops the kept index and its ETag ([33a2137](https://github.com/hotcodepush-team/core-ios/commit/33a21370b843dea8b0388a26289933a55ac7906b))
* a readiness signal reported before the core's latest load confirms and settles nothing ([c55b8c0](https://github.com/hotcodepush-team/core-ios/commit/c55b8c057bbfc006c67cc0c28a8aaa2f5eafe920))
* a readiness-timeout rollback reloads while an apply is held ([c15ef23](https://github.com/hotcodepush-team/core-ios/commit/c15ef239f4413030e58b6386ff89ceb7350571e8))
* a release of the embedded bundle is adopted in place, not installed ([829f917](https://github.com/hotcodepush-team/core-ios/commit/829f917dd3f13a8055c2c4eb1eb3694e9452e693)), closes [#15](https://github.com/hotcodepush-team/core-ios/issues/15)
* a release of the embedded bundle reports no bytes to download ([2c62c63](https://github.com/hotcodepush-team/core-ios/commit/2c62c63a8cec7f022b93f1fdef0c7728c74c4077))
* a release of the embedded bundle skips the download gate ([7674ff3](https://github.com/hotcodepush-team/core-ios/commit/7674ff381699cde6a1db7167e31e8d49a62e8e48))
* a release of the embedded bundle switches without the gate and is never blocklisted ([b7f120a](https://github.com/hotcodepush-team/core-ios/commit/b7f120aed2544d66eabffccfc810d671bd49b57e))
* a reload the core performs drops the held restart, so it never runs as a second reload ([42ceec4](https://github.com/hotcodepush-team/core-ios/commit/42ceec4cd4bd1613128d0305995657c88d4d4432))
* a resource file with a check interval below 60 seconds is refused ([2e5ec6c](https://github.com/hotcodepush-team/core-ios/commit/2e5ec6ccdd1f8d694bdfcd643bcd2e79b95cf750))
* a restart held at the gate re-checks the index before it applies ([6e70662](https://github.com/hotcodepush-team/core-ios/commit/6e706622554e7484b64d50dfceb5302bd7a6a911))
* a rollback to the embedded bundle reports toReleaseId as null, and every event writes exactly its schema's keys ([3e247f4](https://github.com/hotcodepush-team/core-ios/commit/3e247f448233af77fad9606fdacf1d2c00165770))
* an app the system launched into the background starts with the readiness timer paused ([86dd536](https://github.com/hotcodepush-team/core-ios/commit/86dd5369d0cfc1b81d6793879fb16d9711ad08e3))
* an attribute value is at most 256 code points without a C0 or C1 control ([3bfd17c](https://github.com/hotcodepush-team/core-ios/commit/3bfd17c6dd992b979d838a7aed2877cffce3fe59))
* bspatch.c is protocol-android's byte for byte, with a length past 32 bits a corrupt patch ([dd6236e](https://github.com/hotcodepush-team/core-ios/commit/dd6236e8bd4b3ada72cec9858489e889c2f981f7))
* checkForUpdate() and downloadUpdate() join a running cycle instead of running beside it ([d67a256](https://github.com/hotcodepush-team/core-ios/commit/d67a2564d401d8def763554879f1213f54fe0b10))
* downloadUpdate() never answers UPDATED ([6c4a35b](https://github.com/hotcodepush-team/core-ios/commit/6c4a35b44f04270db9eb0d145f097e0522675838))
* **evaluation:** mandatory counts only the skipped releases the device could take ([de91012](https://github.com/hotcodepush-team/core-ios/commit/de910123c923c531d15b7800c572c3eea49f683a))
* large files inflate streaming to disk, never whole in memory ([a9a36ea](https://github.com/hotcodepush-team/core-ios/commit/a9a36eac37b40e10f7424f22b50f1815063532e4))
* next-resume never installs a mandatory release the app took over ([6c83c34](https://github.com/hotcodepush-team/core-ios/commit/6c83c34154730adda805b115049e4a5de4aa57e0))
* notifyReady()'s previousRelease names the release a switch replaced ([bcaa732](https://github.com/hotcodepush-team/core-ios/commit/bcaa7321538b54acb96993f03b37296ab0223f2a))
* only reloads wait for the app being up; the start check runs at once again, and a held install takes effect at the next start ([34d9c64](https://github.com/hotcodepush-team/core-ios/commit/34d9c641fe51f712720ab8488189235d29e141b4))
* reportedAt keeps the month's first acknowledged device report ([62b5a28](https://github.com/hotcodepush-team/core-ios/commit/62b5a28bcc745a3c16e8d00812ec07240ee7d619)), closes [#19](https://github.com/hotcodepush-team/core-ios/issues/19)
* the check adopts the revoke target that carries the running bundle ([0a31efc](https://github.com/hotcodepush-team/core-ios/commit/0a31efc8f1cc6dc66dc636addd881e46371da02d))
* the file cleanup runs off the start path ([b9a4b73](https://github.com/hotcodepush-team/core-ios/commit/b9a4b7329bc04f4a13c5c5b6f0980e8a2a93ddab))
* the HTTP client runs on iOS 13 — completion handlers and the session's delegate instead of the iOS 15 streams ([b491734](https://github.com/hotcodepush-team/core-ios/commit/b4917341a05db9f145a766591c1ecef73d439ca5))
* the never-backwards rule holds for one day ([3ff9e5b](https://github.com/hotcodepush-team/core-ios/commit/3ff9e5b6750d1a82fba18b0727a533721aa21c53))
* the pod ships its privacy manifest in a bundle directory, with no generated target ([2af6c68](https://github.com/hotcodepush-team/core-ios/commit/2af6c68415fd98abf0aca5513ab2aeb7c0db68ff)), closes [#6](https://github.com/hotcodepush-team/core-ios/issues/6)
* the readiness timer pauses in the background and starts its full window again at the resume ([558c6f0](https://github.com/hotcodepush-team/core-ios/commit/558c6f0caf8843c8a4c4570cffc62a9fa94ef89e))
* the revoke path adopts the running bundle instead of reloading it ([a138f74](https://github.com/hotcodepush-team/core-ios/commit/a138f74c71347a56934351ca6cde60a7325ca299))
* the start sync and the SDK's own restarts wait until the app is up in this run ([b1e9522](https://github.com/hotcodepush-team/core-ios/commit/b1e95223e388c5cb46de949551d852e37c21ae19))
* the start's own reload unsettles the start like every reload the core performs ([442564a](https://github.com/hotcodepush-team/core-ios/commit/442564ad99552cc3bb859cfcf1bf0472d121a4b3))


### Code Refactoring

* tests wait on the core's background work, never on a sleep, over fakes that hold a lock ([68fcc10](https://github.com/hotcodepush-team/core-ios/commit/68fcc1094b595b54b09265f193bef4882a7ce57b))
* the package is HotCodePushCore in core-ios ([ae8ba20](https://github.com/hotcodepush-team/core-ios/commit/ae8ba2010aae6d508253d2896a6a0792bc4e9f70))
