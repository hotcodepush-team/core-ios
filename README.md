# HotCodePushCore

`HotCodePushCore` is the HotCodePush update-protocol client for iOS: the wire types, the evaluator, the downloader with its signature check and the byte-level patches it applies from delta packs, the state machine and the debug screen behind every HotCodePush SDK on Apple platforms, held to the same fixture suite as the JavaScript and Android clients. Learn more at [hotcodepush.com](https://hotcodepush.com).

## Installation

The package is not tagged yet; a consumer pins one commit and bumps it deliberately, never a branch.

Swift Package Manager:

```swift
.package(url: "https://github.com/hotcodepush-team/core-ios.git", revision: "<sha>")
```

CocoaPods:

```ruby
pod 'HotCodePushCore', :git => 'https://github.com/hotcodepush-team/core-ios.git', :commit => '<sha>'
```

The package supports iOS 13 and later.

## Usage

```swift
import HotCodePushCore

let index = try Json.decoder.decode(ChannelIndex.self, from: data)
let evaluation = Evaluator.evaluation(of: index, device: deviceInfo)
// evaluation.outcome: the release to take, or the reason not to; evaluation.verdicts: every release explained
```

An SDK opens the debug screen over its own view controller. The screen shows the device, the channel, the releases, the last check with its code, the index and this session's log, and its share button hands the same content to the share sheet as text:

```swift
DebugScreenViewController.present(core: core, from: viewController)
```

Once the resource file lists `publicKeys`, the downloader refuses a manifest that is unsigned or whose signature does not verify against them, before it fetches a byte of the bundle. The scheme is `rsa-v1_5-sha256`, verified by the system's Security framework with the keys as the resource file carries them for iOS, PKCS #1 DER beside their key ids.

The package is the foundation of the HotCodePush SDKs, not their supported API: an app uses the SDK for its framework.

## Documentation

See [hotcodepush.com/docs](https://hotcodepush.com/docs).

## Development

```sh
nvm use
npm ci                       # the protocol fixtures the tests read
swiftlint lint --strict
swift test
```

`npm run verify` runs the lint and the tests; `xcodebuild -scheme HotCodePushCore -destination 'generic/platform=iOS Simulator' build` is the iOS build CI adds.

`Tests/BspatchFixtures/make-patches.sh` rewrites the hostile patches `BspatchTests` reads; `valid.patch` beside them is a committed input, written once by bsdiff 4.3, and the script never regenerates it.

## License

See [LICENSE](./LICENSE). The package includes FreeBSD's bspatch under the BSD 2-clause licence; [THIRD-PARTY-NOTICES](./THIRD-PARTY-NOTICES) carries its notice, which an app's distribution must reproduce.
