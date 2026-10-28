# HotCodePushCore

`HotCodePushCore` is the HotCodePush update-protocol client for iOS: the wire types, the evaluator, the downloader with its signature check and delta patches, the state machine and the debug screen behind every HotCodePush SDK on Apple platforms.
It is held to the same fixture suite as the [JavaScript](https://github.com/hotcodepush-team/protocol) and [Android](https://github.com/hotcodepush-team/core-android) clients.

## Installation

The package is not tagged yet: pin one commit and bump it deliberately, never a branch.

```swift
// Swift Package Manager
.package(url: "https://github.com/hotcodepush-team/core-ios.git", revision: "<sha>")
```

```ruby
# CocoaPods
pod 'HotCodePushCore', :git => 'https://github.com/hotcodepush-team/core-ios.git', :commit => '<sha>'
```

The package supports iOS 15 and later.

## Usage

```swift
import HotCodePushCore

let index = try Json.decoder.decode(ChannelIndex.self, from: data)
let evaluation = Evaluator.evaluation(of: index, device: deviceInfo)
// evaluation.outcome: the release to take, or the reason not to; evaluation.verdicts: every release explained

DebugScreenViewController.present(core: core, from: viewController)
```

Once the resource file lists `publicKeys`, the downloader refuses a manifest that is unsigned or whose signature does not verify, before it fetches a byte of the bundle.
The package is the foundation of the HotCodePush SDKs, not their supported API: an app uses the SDK for its framework.

## Documentation

See [hotcodepush.com/docs](https://hotcodepush.com/docs).

## Development

```sh
nvm use
npm ci              # the protocol fixtures the tests read
npm test            # swift test
npm run lint        # swiftlint --strict
npm run fmt         # swiftlint --fix, run before every commit
```

CI adds the iOS simulator build and builds the XCFramework with `scripts/build-xcframework.sh`.
`CLAUDE.md` holds the layout and the rules.

## License

See [LICENSE](./LICENSE).
The package includes FreeBSD's bspatch under the BSD 2-clause licence; [THIRD-PARTY-NOTICES](./THIRD-PARTY-NOTICES) carries its notice, which an app's distribution must reproduce.
