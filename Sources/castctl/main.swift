import Foundation
import SwiftCast

// castctl — a small command-line Cast controller built on SwiftCast.
//
//   castctl scan
//   castctl status <host>
//   castctl play <host> <url> [content-type]
//   castctl pause|resume|stop <host>
//   castctl volume <host> <0.0-1.0>
//   castctl quit <host>            (stops the running app)

func usage() -> Never {
    print("""
    usage:
      castctl scan
      castctl status <host>
      castctl watch <host> [seconds]
      castctl play <host> <url> [content-type]
      castctl pause|resume|stop <host>
      castctl seek <host> <seconds>
      castctl volume <host> <level>
      castctl quit <host>
    """)
    exit(64)
}

func sanitized(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 == " " || !CharacterSet.controlCharacters.contains($0) }))
}

func describe(_ status: ReceiverStatus) {
    if let volume = status.volume {
        print("volume: \(volume.level.map { String(format: "%.2f", $0) } ?? "?") muted: \(volume.muted ?? false)")
    }
    if status.isStandBy == true { print("standby: true") }
    for app in status.applications ?? [] {
        print("app: \(sanitized(app.displayName ?? app.appId.rawValue)) [\(sanitized(app.appId.rawValue))] session=\(sanitized(app.sessionId))\(app.isIdleScreen == true ? " (idle screen)" : "")")
        if let text = app.statusText, !text.isEmpty { print("  status: \(sanitized(text))") }
    }
}

func describe(_ status: MediaStatus?) {
    guard let status else { print("media: none"); return }
    let time = status.currentTime.map { String(format: "%.1fs", $0) } ?? "?"
    let duration = status.media?.duration.map { String(format: "%.1fs", $0) } ?? "?"
    let reason = status.idleReason.map { " (\(sanitized($0.rawValue)))" } ?? ""
    print("media: \(sanitized(status.media?.metadata?.title ?? status.media?.contentId ?? "unknown")) \(sanitized(status.playerState.rawValue))\(reason) \(time)/\(duration)")
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

if command == "scan" {
    let devices = await CastDiscovery.scan(for: .seconds(3))
    if devices.isEmpty { print("No Cast devices found.") }
    for device in devices {
        print("\(sanitized(device.name))\t\(sanitized(device.modelName ?? "-"))\tid=\(sanitized(device.id))\tcaps=\(device.capabilities.rawValue)")
    }
    exit(0)
}

guard arguments.count >= 2 else { usage() }
let client = CastClient(host: arguments[1])

do {
    try await client.connect()
    switch command {
    case "status":
        let status = try await client.receiver.getStatus()
        describe(status)
        if let app = status.foregroundApplication, app.supports(.media) {
            let media = try await client.mediaController(for: app)
            describe(await media.status)
        }
    case "play":
        guard arguments.count >= 3, let url = URL(string: arguments[2]) else { usage() }
        let contentType = arguments.count >= 4 ? arguments[3] : "video/mp4"
        let media = try await client.launchMediaReceiver()
        let status = try await media.load(MediaInformation(
            url: url,
            contentType: contentType,
            metadata: .generic(title: url.lastPathComponent)
        ))
        describe(status)
        // Follow the first few seconds so buffering failures are visible.
        let updates = await media.statusUpdates()
        let follower = Task { for await update in updates { describe(update) } }
        try await Task.sleep(for: .seconds(8))
        follower.cancel()
    case "pause", "resume", "stop", "seek":
        let status = try await client.receiver.getStatus()
        guard let app = status.foregroundApplication else { print("Nothing is playing."); break }
        let media = try await client.mediaController(for: app)
        switch command {
        case "pause": describe(try await media.pause())
        case "resume": describe(try await media.play())
        case "stop": describe(try await media.stop())
        default:
            guard arguments.count >= 3, let seconds = Double(arguments[2]) else { usage() }
            describe(try await media.seek(to: seconds))
        }
    case "watch":
        let seconds = arguments.count >= 3 ? Double(arguments[2]) ?? 30 : 30
        describe(try await client.receiver.getStatus())
        let availability = try await client.receiver.availability(of: [.defaultMediaReceiver, .youTube, .jellyfin])
        for (app, state) in availability.sorted(by: { $0.key.rawValue < $1.key.rawValue }) { print("availability \(sanitized(app.rawValue)): \(state.rawValue)") }
        let states = await client.stateUpdates()
        let watcher = Task {
            for await status in await client.receiverStatusUpdates() { describe(status) }
        }
        let stateWatcher = Task {
            for await state in states { print("state: \(sanitized("\(state)"))") }
        }
        try await Task.sleep(for: .seconds(seconds))
        watcher.cancel()
        stateWatcher.cancel()
        print("final state: \(sanitized("\(await client.state)"))")
    case "volume":
        guard arguments.count >= 3, let level = Double(arguments[2]) else { usage() }
        describe(try await client.receiver.setVolume(level))
    case "quit":
        let status = try await client.receiver.getStatus()
        if let app = status.foregroundApplication {
            try await client.receiver.stop(app)
            print("Stopped \(sanitized(app.displayName ?? app.appId.rawValue)).")
        }
    default:
        usage()
    }
    await client.disconnect()
} catch {
    print("error: \(sanitized(error.localizedDescription))")
    exit(1)
}
