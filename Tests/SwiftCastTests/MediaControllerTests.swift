import Foundation
import Testing
@testable import SwiftCast

@Suite("MediaController", .timeLimit(.minutes(1)))
struct MediaControllerTests {
    func connectedClient(appRunning: Bool = false) async throws -> (CastClient, MockReceiver) {
        let mock = MockReceiver()
        Fixtures.installDefaultReceiver(on: mock, appRunning: appRunning)
        let client = CastClient { mock }
        try await client.connect()
        return (client, mock)
    }

    @Test func launchesAndLoadsMedia() async throws {
        let (client, mock) = try await connectedClient()
        let media = try await client.launchMediaReceiver()
        #expect(mock.sentMessages(ofType: "LAUNCH").count == 1)
        #expect(mock.sentMessages(ofType: "CONNECT").contains { $0.destinationID == Fixtures.transportID })

        let status = try await media.load(
            MediaInformation(url: URL(string: "https://example.com/video.mp4")!, contentType: "video/mp4", metadata: .movie(title: "Big Buck Bunny")),
            startTime: 30
        )
        #expect(status.mediaSessionId == 1)
        #expect(status.currentTime == 30)
        let load = try #require(mock.sentMessages(ofType: "LOAD").first)
        #expect(load.destinationID == Fixtures.transportID)
        #expect(load.json?["sessionId"]?.stringValue == Fixtures.sessionID)
        #expect(load.json?["media"]?["metadata"]?["title"]?.stringValue == "Big Buck Bunny")
        #expect(load.json?["autoplay"]?.boolValue == true)
    }

    @Test func joinsRunningAppInsteadOfRelaunching() async throws {
        let (client, mock) = try await connectedClient(appRunning: true)
        _ = try await client.launchMediaReceiver()
        #expect(mock.sentMessages(ofType: "LAUNCH").isEmpty)
    }

    /// Web receivers shut down when their last sender sends an explicit
    /// CLOSE, so disconnecting must leave application connections alone.
    @Test func disconnectLeavesApplicationRunning() async throws {
        let (client, mock) = try await connectedClient(appRunning: true)
        _ = try await client.launchMediaReceiver()
        await client.disconnect()
        let closes = mock.sentMessages(ofType: "CLOSE").map(\.destinationID)
        #expect(closes == [CastEndpoint.platformReceiver])
    }

    /// Replies to the controller's own requests must not be re-applied by
    /// its listener, where a late GET_STATUS reply could erase a newer LOAD.
    @Test func mediaSessionSurvivesAttachFollowedByLoad() async throws {
        for _ in 0..<50 {
            let (client, _) = try await connectedClient()
            let media = try await client.launchMediaReceiver()
            try await media.load(MediaInformation(url: URL(string: "https://example.com/v.mp4")!, contentType: "video/mp4"))
            await Task.yield()
            #expect(await media.status?.mediaSessionId == 1)
            await client.disconnect()
        }
    }

    @Test func commandsRequireAMediaSession() async throws {
        let (client, _) = try await connectedClient()
        let media = try await client.launchMediaReceiver()
        await #expect(throws: CastError.noMediaSession) { try await media.pause() }
    }

    @Test func transportCommandsUseSessionAndPreserveMediaInfo() async throws {
        let (client, mock) = try await connectedClient()
        let media = try await client.launchMediaReceiver()
        try await media.load(MediaInformation(url: URL(string: "https://example.com/video.mp4")!, contentType: "video/mp4"))

        let paused = try #require(try await media.pause())
        #expect(paused.playerState == .paused)
        // PAUSE response omitted `media`; it is carried over from LOAD.
        #expect(paused.media?.duration == 596.5)
        #expect(mock.sentMessages(ofType: "PAUSE").first?.json?["mediaSessionId"]?.intValue == 1)

        let sought = try #require(try await media.seek(to: 100, resumeState: .playbackStart))
        #expect(sought.currentTime == 100)
        let seek = try #require(mock.sentMessages(ofType: "SEEK").first)
        #expect(seek.json?["resumeState"]?.stringValue == "PLAYBACK_START")

        _ = try await media.play()
        #expect(await media.status?.playerState == .playing)
    }

    @Test func statusUpdatesStreamUnsolicitedChanges() async throws {
        let (client, mock) = try await connectedClient()
        let media = try await client.launchMediaReceiver()
        try await media.load(MediaInformation(url: URL(string: "https://example.com/video.mp4")!, contentType: "video/mp4"))
        let updates = await media.statusUpdates()

        mock.push(Fixtures.mediaStatus(sessionID: 1, state: "PLAYING", time: 5, includeMedia: false), namespace: .media, from: Fixtures.transportID, to: "*")
        var states: [PlayerState?] = []
        for await status in updates {
            states.append(status?.playerState)
            if status?.playerState == .playing { break }
        }
        #expect(states.first == .buffering) // initial value
        #expect(states.last == .playing)
        #expect(await media.status?.media?.metadata?.title == "Big Buck Bunny")
    }

    @Test func ignoresMediaStatusFromOtherApps() async throws {
        let (client, mock) = try await connectedClient()
        let media = try await client.launchMediaReceiver()
        mock.push(Fixtures.mediaStatus(sessionID: 9), namespace: .media, from: "some-other-app", to: "*")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await media.status == nil)
    }

    @Test func sessionClosesWhenAppStops() async throws {
        let (client, mock) = try await connectedClient()
        let media = try await client.launchMediaReceiver()
        try await media.load(MediaInformation(url: URL(string: "https://example.com/video.mp4")!, contentType: "video/mp4"))

        mock.push(Fixtures.receiverStatus(apps: []), namespace: .receiver, to: "*")
        try await eventually { await media.isClosed }
        #expect(await media.status == nil)
        await #expect(throws: CastError.self) { try await media.pause() }
    }

    @Test func sessionClosesOnVirtualConnectionClose() async throws {
        let (client, mock) = try await connectedClient()
        let media = try await client.launchMediaReceiver()
        mock.push(["type": "CLOSE"], namespace: .connection, from: Fixtures.transportID)
        try await eventually { await media.isClosed }
        #expect(await client.state == .connected)
        #expect(await client.isConnected(to: Fixtures.transportID) == false)
    }

    func loadedMedia() async throws -> (MediaController, MockReceiver) {
        let (client, mock) = try await connectedClient()
        let media = try await client.launchMediaReceiver()
        try await media.load(MediaInformation(url: URL(string: "https://example.com/video.mp4")!, contentType: "video/mp4"))
        return (media, mock)
    }

    @Test func loadFailureIsThrown() async throws {
        let (client, mock) = try await connectedClient()
        mock.on("LOAD") { request, mock in
            mock.reply(to: request, ["type": "LOAD_FAILED", "detailedErrorCode": 104, "reason": "GENERIC_LOAD_ERROR", "itemId": 3])
        }
        let media = try await client.launchMediaReceiver()
        let expected = MediaErrorInfo(type: "LOAD_FAILED", reason: .genericLoadError, detailedErrorCode: 104, itemId: 3)
        await #expect(throws: CastError.loadFailed(expected)) {
            try await media.load(MediaInformation(url: URL(string: "https://example.com/missing.mp4")!, contentType: "video/mp4"))
        }
    }

    @Test func genericErrorReplyIsThrown() async throws {
        let (media, mock) = try await loadedMedia()
        mock.on("PLAY") { request, mock in
            mock.reply(to: request, ["type": "ERROR", "reason": "APP_ERROR", "detailedErrorCode": 905, "customData": ["code": "busy"]])
        }
        let before = await media.status
        let expected = MediaErrorInfo(type: "ERROR", reason: .appError, detailedErrorCode: 905, customData: ["code": "busy"])
        await #expect(throws: CastError.mediaError(expected)) { try await media.play() }
        #expect(await media.status == before)
    }

    @Test func invalidPlayerStateCarriesDetails() async throws {
        let (media, mock) = try await loadedMedia()
        mock.on("PAUSE") { request, mock in
            mock.reply(to: request, ["type": "INVALID_PLAYER_STATE", "reason": "INVALID_COMMAND", "customData": ["state": "idle"]])
        }
        let error = await #expect(throws: CastError.self) { try await media.pause() }
        guard case .invalidPlayerState(let info) = error else {
            Issue.record("Expected invalidPlayerState, got \(String(describing: error))")
            return
        }
        #expect(info.reason == .invalidCommand)
        #expect(info.customData == ["state": "idle"])
        #expect(await media.status?.mediaSessionId == 1)
    }

    @Test func invalidMediaSessionClearsCachedSession() async throws {
        let (media, mock) = try await loadedMedia()
        mock.on("PAUSE") { request, mock in
            mock.reply(to: request, ["type": "INVALID_REQUEST", "reason": "INVALID_MEDIA_SESSION_ID"])
        }
        await #expect(throws: CastError.invalidRequest(MediaErrorInfo(type: "INVALID_REQUEST", reason: .invalidMediaSessionId))) {
            try await media.pause()
        }
        #expect(await media.status == nil)
    }

    @Test func nonStatusReplyIsNotSuccess() async throws {
        let (media, mock) = try await loadedMedia()
        mock.on("PLAY") { request, mock in mock.reply(to: request, ["type": "SOMETHING_ELSE"]) }
        let error = await #expect(throws: CastError.self) { try await media.play() }
        guard case .unexpectedResponse = error else {
            Issue.record("Expected unexpectedResponse, got \(String(describing: error))")
            return
        }
        #expect(await media.status?.playerState == .buffering)
    }

    @Test func stopAppliesIdleStatus() async throws {
        let (media, mock) = try await loadedMedia()
        mock.on("STOP") { request, mock in
            mock.reply(to: request, Fixtures.mediaStatus(sessionID: 1, state: "IDLE", includeMedia: false))
        }
        let stopped = try #require(try await media.stop())
        #expect(stopped.playerState == .idle)
        #expect(stopped.media?.duration == 596.5)
        #expect(await media.status == stopped)
    }

    @Test func stopWithEmptyStatusYieldsNil() async throws {
        let (media, mock) = try await loadedMedia()
        mock.on("STOP") { request, mock in mock.reply(to: request, ["type": "MEDIA_STATUS", "status": []]) }
        let stopped = try await media.stop()
        #expect(stopped == nil)
        #expect(await media.status == nil)
    }

    @Test func emptyStatusListMeansNoSession() async throws {
        let (media, mock) = try await loadedMedia()
        mock.on("GET_STATUS") { request, mock in mock.reply(to: request, ["type": "MEDIA_STATUS", "status": []]) }
        #expect(try await media.refreshStatus() == nil)
        #expect(await media.status == nil)
    }

    @Test func malformedStatusInReplyThrowsAndKeepsSession() async throws {
        let (media, mock) = try await loadedMedia()
        mock.on("PLAY") { request, mock in mock.reply(to: request, ["type": "MEDIA_STATUS", "status": [["bogus": 1]]]) }
        let error = await #expect(throws: CastError.self) { try await media.play() }
        guard case .malformedMessage = error else {
            Issue.record("Expected malformedMessage, got \(String(describing: error))")
            return
        }
        #expect(await media.status?.mediaSessionId == 1)
    }

    @Test func malformedStatusBroadcastKeepsSession() async throws {
        let (media, mock) = try await loadedMedia()
        let updates = await media.statusUpdates()
        mock.push(["type": "MEDIA_STATUS", "status": [["bogus": 1]]], namespace: .media, from: Fixtures.transportID, to: "*")
        mock.push(Fixtures.mediaStatus(sessionID: 1, state: "PAUSED", includeMedia: false), namespace: .media, from: Fixtures.transportID, to: "*")
        var seen: [MediaStatus?] = []
        for await status in updates {
            seen.append(status)
            if status?.playerState == .paused { break }
        }
        #expect(!seen.contains(nil))
        #expect(await media.status?.media?.duration == 596.5)
    }

    @Test func usesFirstStatusEntry() async throws {
        let (media, mock) = try await loadedMedia()
        mock.on("PLAY") { request, mock in
            let first = Fixtures.mediaStatus(sessionID: 2, state: "PLAYING")["status"]?.arrayValue ?? []
            let second = Fixtures.mediaStatus(sessionID: 1, state: "PAUSED", includeMedia: false)["status"]?.arrayValue ?? []
            mock.reply(to: request, ["type": "MEDIA_STATUS", "status": .array(first + second)])
        }
        let status = try #require(try await media.play())
        #expect(status.mediaSessionId == 2)
        #expect(status.playerState == .playing)
        #expect(await media.status?.mediaSessionId == 2)
    }

    // MARK: - Status merging

    static let queueItemsJSON: JSONValue = [
        ["itemId": 1, "media": ["contentId": "https://example.com/1.mp3", "contentType": "audio/mpeg"]],
        ["itemId": 2, "media": ["contentId": "https://example.com/2.mp3", "contentType": "audio/mpeg"]],
    ]

    static func statusEntry(_ fields: [String: JSONValue]) -> JSONValue {
        ["type": "MEDIA_STATUS", "status": [.object(fields)]]
    }

    static func fullQueueEntry(sessionID: Int = 1, state: String = "PLAYING") -> [String: JSONValue] {
        var fields = Fixtures.mediaStatus(sessionID: sessionID, state: state, time: 10)["status"]?.arrayValue?.first?.objectValue ?? [:]
        fields["items"] = queueItemsJSON
        fields["currentItemId"] = 1
        fields["repeatMode"] = "REPEAT_ALL"
        fields["activeTrackIds"] = [1]
        return fields
    }

    /// A controller holding a queue session 1 whose status carries media and items.
    func queuedMedia() async throws -> (MediaController, MockReceiver) {
        let (client, mock) = try await connectedClient()
        mock.on("QUEUE_LOAD") { request, mock in mock.reply(to: request, Self.statusEntry(Self.fullQueueEntry())) }
        let media = try await client.launchMediaReceiver()
        let item = QueueItem(media: MediaInformation(url: URL(string: "https://example.com/1.mp3")!, contentType: "audio/mpeg"))
        let loaded = try await media.loadQueue([item, item])
        #expect(loaded.items?.count == 2)
        return (media, mock)
    }

    func broadcast(_ fields: [String: JSONValue], on mock: MockReceiver) {
        mock.push(Self.statusEntry(fields), namespace: .media, from: Fixtures.transportID, to: "*")
    }

    @Test func broadcastWithoutItemsKeepsQueue() async throws {
        let (media, mock) = try await queuedMedia()
        broadcast(["mediaSessionId": 1, "playerState": "PLAYING", "currentTime": 20, "currentItemId": 2], on: mock)
        try await eventually { await media.status?.currentItemId == 2 }
        let status = try #require(await media.status)
        #expect(status.items?.map(\.itemId) == [1, 2])
        #expect(status.repeatMode == .all)
    }

    @Test func broadcastWithoutMediaKeepsMedia() async throws {
        let (media, mock) = try await loadedMedia()
        broadcast(["mediaSessionId": 1, "playerState": "PAUSED", "currentTime": 3], on: mock)
        try await eventually { await media.status?.playerState == .paused }
        #expect(await media.status?.media?.metadata?.title == "Big Buck Bunny")
        #expect(await media.status?.media?.duration == 596.5)
    }

    @Test func partialBroadcastChangesOnlyItsFields() async throws {
        let (media, mock) = try await queuedMedia()
        let before = try #require(await media.status)
        broadcast(["mediaSessionId": 1, "playerState": "PAUSED", "currentTime": 99], on: mock)
        try await eventually { await media.status?.playerState == .paused }
        var expected = before
        expected.playerState = .paused
        expected.currentTime = 99
        #expect(await media.status == expected)
    }

    @Test func broadcastForAnotherSessionReplacesStatus() async throws {
        let (media, mock) = try await queuedMedia()
        broadcast(["mediaSessionId": 2, "playerState": "BUFFERING"], on: mock)
        try await eventually { await media.status?.mediaSessionId == 2 }
        let status = try #require(await media.status)
        #expect(status.media == nil)
        #expect(status.items == nil)
        #expect(status.currentItemId == nil)
        #expect(status.volume == nil)
        #expect(status.playerState == .buffering)
    }

    @Test func loadReplyReplacesStatusEvenForTheSameSession() async throws {
        let (media, mock) = try await queuedMedia()
        mock.on("LOAD") { request, mock in
            mock.reply(to: request, Fixtures.mediaStatus(sessionID: 1, state: "BUFFERING"))
        }
        let loaded = try await media.load(MediaInformation(url: URL(string: "https://example.com/video.mp4")!, contentType: "video/mp4"))
        #expect(loaded.mediaSessionId == 1)
        #expect(loaded.items == nil)
        #expect(loaded.currentItemId == nil)
        #expect(loaded.repeatMode == nil)
        #expect(loaded.activeTrackIds == nil)
        #expect(await media.status == loaded)
    }

    @Test func commandReplyMergesIntoStatus() async throws {
        let (media, mock) = try await queuedMedia()
        mock.on("PLAY") { request, mock in
            mock.reply(to: request, Self.statusEntry(["mediaSessionId": 1, "playerState": "PLAYING", "currentTime": 42]))
        }
        let played = try #require(try await media.play())
        #expect(played.currentTime == 42)
        #expect(played.items?.count == 2)
        #expect(played.media?.duration == 596.5)
        #expect(played.supportedMediaCommands?.rawValue == 12303)
        #expect(await media.status == played)
    }

    @Test func volumeAndPlaybackRateMerge() async throws {
        let (media, mock) = try await queuedMedia()
        broadcast(["mediaSessionId": 1, "volume": ["level": 0.25, "muted": true], "playbackRate": 1.5], on: mock)
        try await eventually { await media.status?.playbackRate == 1.5 }
        let changed = try #require(await media.status)
        #expect(changed.volume?.level == 0.25)
        #expect(changed.volume?.muted == true)
        #expect(changed.playerState == .playing)
        #expect(changed.supportedMediaCommands?.rawValue == 12303)

        broadcast(["mediaSessionId": 1, "playerState": "PAUSED"], on: mock)
        try await eventually { await media.status?.playerState == .paused }
        let kept = try #require(await media.status)
        #expect(kept.volume?.level == 0.25)
        #expect(kept.playbackRate == 1.5)
    }

    @Test func nullAndInvalidFieldsKeepCachedValues() async throws {
        let (media, mock) = try await queuedMedia()
        broadcast(["mediaSessionId": 1, "playerState": "PAUSED", "items": nil, "currentTime": "soon", "media": nil], on: mock)
        try await eventually { await media.status?.playerState == .paused }
        let status = try #require(await media.status)
        #expect(status.items?.count == 2)
        let position = try #require(status.currentTime)
        #expect(position >= 10 && position < 11)
        #expect(status.media?.duration == 596.5)
    }

    @Test func stateScopedFieldsFollowTheLatestPlayerState() async throws {
        let (media, mock) = try await queuedMedia()
        broadcast(["mediaSessionId": 1, "playerState": "IDLE", "idleReason": "INTERRUPTED", "loadingItemId": 2, "preloadedItemId": 2], on: mock)
        try await eventually { await media.status?.idleReason == .interrupted }
        #expect(await media.status?.loadingItemId == 2)

        broadcast(["mediaSessionId": 1, "volume": ["level": 0.5, "muted": false]], on: mock)
        try await eventually { await media.status?.volume?.level == 0.5 }
        #expect(await media.status?.playerState == .idle)
        #expect(await media.status?.idleReason == .interrupted)

        broadcast(["mediaSessionId": 1, "playerState": "PLAYING", "currentItemId": 2], on: mock)
        try await eventually { await media.status?.playerState == .playing }
        let status = try #require(await media.status)
        #expect(status.idleReason == nil)
        #expect(status.loadingItemId == nil)
        #expect(status.preloadedItemId == nil)
        #expect(status.items?.count == 2)
    }

    @Test func errorReasonsDecodeOpenly() throws {
        #expect(MediaErrorReason(rawValue: "DUPLICATE_REQUESTID") == .duplicateRequestId)
        #expect(MediaErrorReason(rawValue: "DUPLICATE_REQUEST_ID") == .duplicateRequestId)
        #expect(MediaErrorReason(rawValue: "SOMETHING_NEW") == .unknown("SOMETHING_NEW"))
        let decoded = try JSONDecoder().decode([MediaErrorReason].self, from: Data(#"["DUPLICATE_REQUESTID","END_OF_QUEUE"]"#.utf8))
        #expect(decoded == [.duplicateRequestId, .endOfQueue])
    }

    @Test func queueAndTrackCommandsEncodeCorrectly() async throws {
        let (client, mock) = try await connectedClient()
        mock.on("QUEUE_LOAD") { request, mock in mock.reply(to: request, Fixtures.mediaStatus(sessionID: 7)) }
        for type in ["QUEUE_UPDATE", "EDIT_TRACKS_INFO", "QUEUE_REMOVE"] {
            mock.on(type) { request, mock in mock.reply(to: request, Fixtures.mediaStatus(sessionID: 7, includeMedia: false)) }
        }
        let media = try await client.launchMediaReceiver()
        let item = QueueItem(media: MediaInformation(url: URL(string: "https://example.com/1.mp3")!, contentType: "audio/mpeg", metadata: .musicTrack(title: "One")))
        let status = try await media.loadQueue([item, item], startIndex: 1, repeatMode: .all)
        #expect(status.mediaSessionId == 7)
        let load = try #require(mock.sentMessages(ofType: "QUEUE_LOAD").first)
        #expect(load.json?["items"]?.arrayValue?.count == 2)
        #expect(load.json?["repeatMode"]?.stringValue == "REPEAT_ALL")
        #expect(load.json?["startIndex"]?.intValue == 1)

        try await media.next()
        try await media.previous()
        try await media.setActiveTracks([2], textTrackStyle: TextTrackStyle(foregroundColor: "#FFFFFFFF", fontScale: 1.2))
        try await media.remove(itemIDs: [3])
        let updates = mock.sentMessages(ofType: "QUEUE_UPDATE")
        #expect(updates.map { $0.json?["jump"]?.intValue } == [1, -1])
        let edit = try #require(mock.sentMessages(ofType: "EDIT_TRACKS_INFO").first)
        #expect(edit.json?["activeTrackIds"] == [2])
        #expect(edit.json?["textTrackStyle"]?["fontScale"]?.doubleValue == 1.2)
        #expect(mock.sentMessages(ofType: "QUEUE_REMOVE").first?.json?["itemIds"] == [3])
    }
}
