# SwiftCast

[![CI](https://github.com/CreatureSurvive/SwiftCast/actions/workflows/ci.yml/badge.svg)](https://github.com/CreatureSurvive/SwiftCast/actions/workflows/ci.yml)
[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0+-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20visionOS-blue)](#requirements)
[![Swift Package Manager](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)](#installation)
[![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

A pure-Swift Google Cast (Chromecast) **sender** for iOS, iPadOS, macOS, tvOS and visionOS.

Google's official Cast SDK is closed source, iOS-only, heavy, and still built around Objective-C
delegates. SwiftCast implements the Cast V2 protocol directly on `Network.framework` and gives you
a small, modern API built on Swift concurrency. It has no dependencies and runs everywhere Apple's
networking stack does, including **tvOS and macOS**, which the official SDK doesn't support.

```swift
import SwiftCast

let device = await CastDiscovery.scan().first!
let client = CastClient(device: device)
try await client.connect()

let media = try await client.launchMediaReceiver()
try await media.load(MediaInformation(
    url: URL(string: "https://example.com/movie.m3u8")!,
    contentType: "application/x-mpegurl",
    metadata: .movie(title: "Big Buck Bunny")
))
try await media.pause()
```

## Features

- **Discovery** of devices and speaker groups over Bonjour (`CastDiscovery`, observable `CastDeviceBrowser`).
- **Connection management**: TLS, framing, virtual connections, heartbeat with dead-peer detection,
  request/response correlation with timeouts and cancellation.
- **Receiver control**: launch, join and stop apps, device volume and mute, app availability.
- **Media control**: load, queue, play/pause/stop/seek, playback rate, stream volume, text/audio
  track selection with caption styling, queue navigation and editing, HLS segment formats,
  live streams, `customData`, and status streaming with position interpolation.
- **Custom receivers**: send and receive messages on any namespace. This covers Jellyfin, your own
  receiver apps, and anything else.
- **`CastSession`**: an `@Observable` layer for SwiftUI that joins running sessions and reconnects
  automatically with backoff.
- **SwiftUI views**: `CastButton` and `CastDevicePicker`.
- **`castctl`**: a command-line controller for scripting and debugging.
- Swift 6 language mode with strict concurrency throughout. Unknown protocol values decode as
  `.unknown(_)` instead of failing.

## Installation

Add SwiftCast to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/CreatureSurvive/SwiftCast.git", from: "1.0.1"),
],
targets: [
    .target(name: "MyApp", dependencies: ["SwiftCast"]),
]
```

Or in Xcode, choose **File › Add Package Dependencies…** and enter
`https://github.com/CreatureSurvive/SwiftCast`.

### Requirements

| Platform | Minimum |
| --- | --- |
| iOS | 17.0 |
| macOS | 14.0 |
| tvOS | 17.0 |
| visionOS | 1.0 |

The package manifest requires Swift 6.0 or later and builds in Swift 6 language mode. CI tests
Swift 6.1 (Xcode 16.4) and Xcode 26. No third-party dependencies.

### Local network privacy (iOS, iPadOS, macOS, visionOS)

[Local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
applies on iOS and iPadOS 14, macOS 15 and visionOS 1 or later. Both Bonjour discovery and the
outgoing TCP connection to a device count as local network operations, so the system asks the user
for access the first time either happens. Add a
[`NSLocalNetworkUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription)
to explain why, and list the Cast service type in
[`NSBonjourServices`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbonjourservices):

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Find and control Cast devices on your network.</string>
<key>NSBonjourServices</key>
<array>
    <string>_googlecast._tcp</string>
</array>
```

tvOS doesn't have local network privacy, so the keys aren't required there. On macOS,
command-line tools run from Terminal, such as `castctl`, are allowed local network access
automatically.

### Entitlements (macOS)

Sandboxed macOS apps need the
[`com.apple.security.network.client`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client)
entitlement, which allows outgoing network connections such as the one to port 8009.

## Usage

### Discovery

```swift
// One-shot scan
let devices = await CastDiscovery.scan(for: .seconds(3))

// Continuous
for await devices in CastDiscovery.devices() {
    print(devices.map(\.name))
}

// SwiftUI
@State private var browser = CastDeviceBrowser()
List(browser.devices) { Text($0.name) }
    .task { await browser.run() }
```

`CastDevice(host:port:)` connects to a known address without discovery.

### SwiftUI with `CastSession`

```swift
struct PlayerView: View {
    @State private var cast = CastSession()   // Default Media Receiver

    var body: some View {
        VStack {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                ProgressView(value: cast.estimatedTime(at: context.date) ?? 0,
                             total: cast.duration ?? 1)
            }
            Button(cast.isPlaying ? "Pause" : "Play") {
                Task { try await cast.togglePlayPause() }
            }
        }
        .toolbar { CastButton(session: cast) }
    }

    func castMovie() async throws {
        try await cast.load(MediaInformation(
            url: movieURL,
            contentType: "video/mp4",
            metadata: .movie(title: "Movie", images: [CastImage(url: posterURL)]),
            tracks: [.webVTTSubtitles(id: 1, url: subtitlesURL, name: "English", language: "en")]
        ), activeTrackIDs: [1])
    }
}
```

`CastSession` publishes `connectionState`, `receiverStatus`, `mediaStatus`, `volume`, `isPlaying`
and `duration`. It reconnects after network blips and re-attaches to the running app. Which app
sessions it re-attaches to is set by `autoJoinPolicy`: `.sameSession` (the default) only rejoins the
session it was attached to, `.sameApp` joins any running instance of `appID`, and `.never` leaves
joining to you.

### Media

```swift
let media = try await client.launchMediaReceiver()   // joins if already running

try await media.load(info, startTime: 120)
try await media.seek(to: 300, resumeState: .playbackStart)
try await media.setPlaybackRate(1.5)
try await media.setActiveTracks([2], textTrackStyle: TextTrackStyle(edgeType: .dropShadow, fontScale: 1.3))

for await status in await media.statusUpdates() {
    print(status?.playerState, status?.currentTime)
}
```

Queues:

```swift
try await media.loadQueue(tracks.map { QueueItem(media: $0) }, startIndex: 0, repeatMode: .all)
try await media.next()
```

HLS from a media server such as Jellyfin or Plex:

```swift
var info = MediaInformation(url: hlsURL, contentType: "application/x-mpegurl")
info.hlsSegmentFormat = .fmp4
info.hlsVideoSegmentFormat = .fmp4
```

### Custom receiver apps and namespaces

```swift
let app = try await client.receiver.launch(CastAppID("ABCD1234"))
try await client.openVirtualConnection(to: app.transportId)

let namespace = CastNamespace("urn:x-cast:com.example.player")
let messages = client.messages(in: namespace)
let reply = try await client.request(["type": "HELLO"] as JSONValue, namespace: namespace, to: app.transportId)
```

`request` correlates replies by `requestId`. Use `send` for fire-and-forget messages.

### Errors

Every failure surfaces as a `CastError`. Standard Cast error replies (`LAUNCH_ERROR`,
`LOAD_FAILED`, `INVALID_REQUEST`, `INVALID_PLAYER_STATE`, …) are mapped to typed cases.

## `castctl`

```
swift run castctl scan
swift run castctl status 192.168.1.20
swift run castctl watch 192.168.1.20 30
swift run castctl play 192.168.1.20 https://example.com/video.mp4 video/mp4
swift run castctl pause|resume|stop 192.168.1.20
swift run castctl volume 192.168.1.20 0.3
```

## Architecture

| Layer | Type | Responsibility |
| --- | --- | --- |
| Wire | `CastMessage`, `FrameDecoder` | Dependency-free protobuf codec and length-prefixed framing |
| Transport | `CastTransport`, `NetworkTransport` | TLS byte stream (injectable for tests) |
| Protocol | `CastClient` (actor) | Virtual connections, heartbeat, routing, request correlation |
| Controllers | `ReceiverController`, `MediaController` (actor) | Typed receiver and media APIs |
| UI | `CastSession`, `CastButton`, `CastDevicePicker` | Observable state, reconnection, SwiftUI |

## Testing

`swift test` runs the suite against an in-memory mock receiver. It covers wire-format conformance
(verified against reference protobuf bytes), framing under arbitrary chunking, request
correlation, timeouts, cancellation, heartbeat failure detection, reconnection, and session
lifecycle. The suite is clean under Thread Sanitizer.

`castctl` was verified against an onn. 4K Streaming Box (Google TV): discovery, launch,
HLS load, seek, pause, resume, volume, and control from separate connections while playback
continues.

## Limitations

- SwiftCast is a sender, not a receiver.
- It doesn't do screen mirroring or Cast Connect (Android TV receiver handoff credentials beyond
  `credentials` in `LOAD`).
- It doesn't perform device authentication yet, so peers are unauthenticated. Certificates are not
  validated because Cast devices present self-signed certificates.

## Changelog

See [CHANGELOG.md](CHANGELOG.md). Releases follow [Semantic Versioning](https://semver.org).

## Contributing

Issues and pull requests are welcome. Please run `swift test` before opening a pull request, and
add tests for new behavior.

## License

Available under the MIT license. See [LICENSE](LICENSE) for details.

Google Cast and Chromecast are trademarks of Google LLC. This project is not affiliated with
Google.
