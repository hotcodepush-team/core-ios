# HotCodePushProtocol

`HotCodePushProtocol` is the HotCodePush update-protocol client for iOS: the wire types, the evaluator, the downloader with its signature check, the state machine and the debug screen behind every HotCodePush SDK on Apple platforms, held to the same fixture suite as the JavaScript and Android clients. Learn more at [hotcodepush.com](https://hotcodepush.com).

## Installation

The package is not tagged yet; a consumer pins one commit and bumps it deliberately, never a branch.

Swift Package Manager:

```swift
.package(url: "https://github.com/hotcodepush-team/protocol-ios.git", revision: "<sha>")
```

CocoaPods:

```ruby
pod 'HotCodePushProtocol', :git => 'https://github.com/hotcodepush-team/protocol-ios.git', :commit => '<sha>'
```

The package supports iOS 13 and later.

## Usage

```swift
import HotCodePushProtocol

let index = try Json.decoder.decode(ChannelIndex.self, from: data)
let evaluation = Evaluator.evaluation(of: index, device: deviceInfo)
// evaluation.outcome: the release to take, or the reason not to; evaluation.verdicts: every release explained
```

An SDK opens the debug screen over its own view controller. The screen shows the device, the channel, the releases, the last check with its code, the index and this session's log, and its share button hands the same content to the share sheet as text:

```swift
DebugScreenViewController.present(core: core, from: viewController)
```

Once the resource file lists `publicKeys`, the downloader refuses a manifest that is unsigned or whose Ed25519 signature does not verify against them, before it fetches a byte of the bundle.

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

`npm run verify` runs the lint and the tests; `xcodebuild -scheme HotCodePushProtocol -destination 'generic/platform=iOS Simulator' build` is the iOS build CI adds.

## License

See [LICENSE](./LICENSE).
