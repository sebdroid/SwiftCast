import Foundation

/// Controls media playback in a running receiver application that supports
/// the `urn:x-cast:com.google.cast.media` namespace.
///
/// Obtain one from ``CastClient/mediaController(for:)`` or
/// ``CastClient/launchMediaApp(_:)``.
public actor MediaController {
    public nonisolated let client: CastClient
    public nonisolated let application: CastApplication

    /// The latest media status, or `nil` when no media is loaded.
    public private(set) var status: MediaStatus?
    /// When ``status`` was last updated (for position interpolation).
    public private(set) var statusDate: Date?
    /// `true` once the application session has ended or the connection was lost.
    public private(set) var isClosed = false
    /// `true` while ``status`` describes a media session that accepts
    /// commands. It turns `false` once a ``stop()`` reply arrives or the
    /// receiver rejects the session id, even though ``status`` may still hold
    /// the final `IDLE` status for display. While it is `false`, playback,
    /// volume, track and queue commands throw ``CastError/noMediaSession``
    /// without contacting the receiver. Loading media, or a status for a
    /// different media session, makes it `true` again.
    public var hasActiveSession: Bool { status != nil && !sessionEnded }

    private var sessionEnded = false

    private let statusBroadcaster = Broadcaster<MediaStatus?>()
    private var listenTask: Task<Void, Never>?

    init(client: CastClient, application: CastApplication) {
        self.client = client
        self.application = application
    }

    deinit {
        listenTask?.cancel()
    }

    func start() {
        guard listenTask == nil else { return }
        let messages = client.messages()
        let transportID = application.transportId
        let sessionID = application.sessionId
        listenTask = Task { [weak self] in
            for await message in messages {
                guard let self else { return }
                switch message.namespace {
                case .media where message.sourceID == transportID:
                    await self.handleMedia(message)
                case .connection where message.sourceID == transportID && message.type == "CLOSE":
                    await self.close()
                    return
                case .receiver where message.type == "RECEIVER_STATUS":
                    // Receiver statuses always describe the full set of running apps.
                    let status = try? message.json?["status"]?.decode(ReceiverStatus.self)
                    if let status, !(status.applications ?? []).contains(where: { $0.sessionId == sessionID }) {
                        await self.close()
                        return
                    }
                default:
                    break
                }
            }
            await self?.close()
        }
    }

    /// Streams media status changes, starting with the current status.
    /// `nil` indicates that no media is loaded. The stream finishes when
    /// the session closes.
    public func statusUpdates() -> AsyncStream<MediaStatus?> {
        if isClosed {
            return AsyncStream { $0.yield(nil); $0.finish() }
        }
        return statusBroadcaster.subscribe(initial: .some(status))
    }

    /// The estimated playback position right now.
    public func estimatedTime(at date: Date = Date()) -> Double? {
        guard let status else { return nil }
        let elapsed = statusDate.map { date.timeIntervalSince($0) } ?? 0
        return status.estimatedTime(after: max(0, elapsed))
    }

    // MARK: - Loading

    /// Loads media and returns the resulting status.
    @discardableResult
    public func load(
        _ media: MediaInformation,
        autoplay: Bool = true,
        startTime: Double? = nil,
        activeTrackIDs: [Int]? = nil,
        playbackRate: Double? = nil,
        customData: JSONValue? = nil,
        credentials: String? = nil
    ) async throws -> MediaStatus {
        let request = LoadRequest(
            sessionId: application.sessionId,
            media: media,
            autoplay: autoplay,
            currentTime: startTime,
            activeTrackIds: activeTrackIDs,
            playbackRate: playbackRate,
            customData: customData,
            credentials: credentials
        )
        return try requireStatus(try await send(request, timeout: .seconds(60)))
    }

    /// Loads a queue of items and starts playing at `startIndex`.
    @discardableResult
    public func loadQueue(
        _ items: [QueueItem],
        startIndex: Int = 0,
        repeatMode: RepeatMode = .off,
        customData: JSONValue? = nil
    ) async throws -> MediaStatus {
        precondition(!items.isEmpty, "A queue requires at least one item")
        let request = QueueLoadRequest(
            sessionId: application.sessionId,
            items: items,
            startIndex: startIndex,
            repeatMode: repeatMode,
            customData: customData
        )
        return try requireStatus(try await send(request, timeout: .seconds(60)))
    }

    // MARK: - Transport controls

    @discardableResult
    public func play() async throws -> MediaStatus? {
        try await sessionCommand("PLAY")
    }

    @discardableResult
    public func pause() async throws -> MediaStatus? {
        try await sessionCommand("PAUSE")
    }

    /// Stops playback and unloads the media. The receiver normally answers
    /// with an `IDLE` status for the stopped session, which is kept so a UI
    /// can go on showing what was playing. The stopped session no longer
    /// takes commands, so later session commands throw
    /// ``CastError/noMediaSession`` until new media is loaded; see
    /// ``hasActiveSession``.
    @discardableResult
    public func stop() async throws -> MediaStatus? {
        try await sessionCommand("STOP", endsSession: true)
    }

    /// Seeks to an absolute position in seconds.
    @discardableResult
    public func seek(to time: Double, resumeState: ResumeState? = nil) async throws -> MediaStatus? {
        try await sessionCommand("SEEK", ["currentTime": .number(max(0, time)), "resumeState": resumeState.map { .string($0.rawValue) }])
    }

    /// Seeks relative to the estimated current position.
    @discardableResult
    public func skip(by seconds: Double) async throws -> MediaStatus? {
        guard let current = estimatedTime() else { throw CastError.noMediaSession }
        return try await seek(to: current + seconds)
    }

    @discardableResult
    public func setPlaybackRate(_ rate: Double) async throws -> MediaStatus? {
        try await sessionCommand("SET_PLAYBACK_RATE", ["playbackRate": .number(rate)])
    }

    /// Sets the stream (not device) volume.
    @discardableResult
    public func setStreamVolume(_ level: Double) async throws -> MediaStatus? {
        try await sessionCommand("SET_VOLUME", ["volume": ["level": .number(min(max(level, 0), 1))]])
    }

    /// Mutes or unmutes the stream.
    @discardableResult
    public func setStreamMuted(_ muted: Bool) async throws -> MediaStatus? {
        try await sessionCommand("SET_VOLUME", ["volume": ["muted": .bool(muted)]])
    }

    /// Selects the active tracks (e.g. subtitles) and optionally their style.
    /// Pass an empty array to disable all text tracks.
    @discardableResult
    public func setActiveTracks(_ trackIDs: [Int], textTrackStyle: TextTrackStyle? = nil) async throws -> MediaStatus? {
        var fields: [String: JSONValue?] = ["activeTrackIds": .array(trackIDs.map { .number(Double($0)) })]
        if let textTrackStyle { fields["textTrackStyle"] = try JSONValue(encoding: textTrackStyle) }
        return try await sessionCommand("EDIT_TRACKS_INFO", fields)
    }

    // MARK: - Queue controls

    @discardableResult
    public func next() async throws -> MediaStatus? {
        try await sessionCommand("QUEUE_UPDATE", ["jump": 1])
    }

    @discardableResult
    public func previous() async throws -> MediaStatus? {
        try await sessionCommand("QUEUE_UPDATE", ["jump": -1])
    }

    /// Jumps to the queue item with the given receiver-assigned ID.
    @discardableResult
    public func jump(toItemID itemID: Int) async throws -> MediaStatus? {
        try await sessionCommand("QUEUE_UPDATE", ["currentItemId": .number(Double(itemID))])
    }

    @discardableResult
    public func setRepeatMode(_ mode: RepeatMode) async throws -> MediaStatus? {
        try await sessionCommand("QUEUE_UPDATE", ["repeatMode": .string(mode.rawValue)])
    }

    /// Inserts items before the item with `beforeItemID`, or at the end.
    @discardableResult
    public func insert(_ items: [QueueItem], beforeItemID: Int? = nil) async throws -> MediaStatus? {
        try await sessionCommand("QUEUE_INSERT", [
            "items": try JSONValue(encoding: items),
            "insertBefore": beforeItemID.map { .number(Double($0)) },
        ])
    }

    @discardableResult
    public func remove(itemIDs: [Int]) async throws -> MediaStatus? {
        try await sessionCommand("QUEUE_REMOVE", ["itemIds": .array(itemIDs.map { .number(Double($0)) })])
    }

    // MARK: - Status

    /// Requests the current media status from the receiver.
    @discardableResult
    public func refreshStatus() async throws -> MediaStatus? {
        let response = try await send(["type": "GET_STATUS"] as JSONValue, timeout: nil)
        return commit(try parseStatus(response))
    }

    /// Stops listening and closes the virtual connection to the application.
    ///
    /// Web receivers may shut down when their last connected sender closes
    /// its connection explicitly. To leave playback running, disconnect the
    /// client instead. To end playback deliberately, use ``ReceiverController/stop(_:)``.
    public func detach() async {
        await client.closeVirtualConnection(to: application.transportId)
        close()
    }

    // MARK: - Private

    private func sessionCommand(_ type: String, _ fields: [String: JSONValue?] = [:], endsSession: Bool = false) async throws -> MediaStatus? {
        guard !sessionEnded, let sessionID = status?.mediaSessionId else { throw CastError.noMediaSession }
        var object: [String: JSONValue] = ["type": .string(type), "mediaSessionId": .number(Double(sessionID))]
        for (key, value) in fields {
            if let value { object[key] = value }
        }
        let response: InboundMessage
        do {
            response = try await send(JSONValue.object(object), timeout: nil)
        } catch let error as CastError where error.mediaErrorInfo?.reason == .invalidMediaSessionId {
            if status?.mediaSessionId == sessionID {
                update(nil)
                sessionEnded = true
            }
            throw error
        }
        let committed = commit(try parseStatus(response))
        // The media messages spec invalidates the mediaSessionId on STOP, so
        // commands sent with it afterwards could only fail on the receiver.
        // A reply for another session describes one that is still live.
        if endsSession, committed?.mediaSessionId == sessionID { sessionEnded = true }
        return committed
    }

    private func send(_ payload: some Encodable & Sendable, timeout: Duration?) async throws -> InboundMessage {
        guard !isClosed else { throw CastError.sessionClosed }
        return try await client.request(payload, namespace: .media, to: application.transportId, timeout: timeout)
    }

    /// Loads start a new media session, so their status replaces the cache
    /// even when the receiver reuses the session id.
    private func requireStatus(_ response: InboundMessage) throws -> MediaStatus {
        guard let status = commit(try parseStatus(response), replacing: true) else {
            throw CastError.unexpectedResponse("Media status missing from response")
        }
        return status
    }

    private func handleMedia(_ message: InboundMessage) {
        // Responses to our own requests are applied by the requester, in
        // request order. Applying them here as well would race with that: a
        // late-delivered reply (such as the empty GET_STATUS sent on attach)
        // could overwrite the newer status from a LOAD.
        guard message.type == "MEDIA_STATUS", (message.requestID ?? 0) == 0 else { return }
        // As in Chrome, a broadcast that cannot be parsed leaves the current
        // state alone. An empty status list does clear it: that is how a
        // receiver reports that no media session is left.
        let parsed: MediaStatusEntry?
        do { parsed = try parseStatus(message) } catch { return }
        commit(parsed)
    }

    /// `nil` means the receiver has no media session. Throws, without
    /// touching state, when the message is not a usable `MEDIA_STATUS`.
    /// Only the first entry is read: a status message carries just the
    /// sessions that changed or were asked about.
    private func parseStatus(_ message: InboundMessage) throws -> MediaStatusEntry? {
        guard message.type == "MEDIA_STATUS" else {
            throw CastError.unexpectedResponse("Expected MEDIA_STATUS, got \(message.type ?? "untyped message")")
        }
        guard let entries = message.json?["status"]?.arrayValue else {
            throw CastError.malformedMessage("MEDIA_STATUS has no status list")
        }
        guard let first = entries.first else { return nil }
        guard let decoded = try? first.decode(MediaStatusEntry.self) else {
            throw CastError.malformedMessage("Media status entry could not be decoded")
        }
        return decoded
    }

    /// Applies an entry onto the cached status of the same media session.
    /// A different session, or `replacing`, starts from the entry alone so
    /// nothing of the previous session's media or queue survives, and is
    /// treated as a live session again.
    @discardableResult
    private func commit(_ entry: MediaStatusEntry?, replacing: Bool = false) -> MediaStatus? {
        guard let entry else {
            update(nil)
            return nil
        }
        let newStatus: MediaStatus
        if !replacing, let cached = status, cached.mediaSessionId == entry.status.mediaSessionId {
            let elapsed = statusDate.map { max(0, Date().timeIntervalSince($0)) } ?? 0
            newStatus = entry.applied(to: cached, elapsed: elapsed)
        } else {
            newStatus = entry.status
            sessionEnded = false
        }
        update(newStatus)
        return newStatus
    }

    private func update(_ newStatus: MediaStatus?) {
        statusDate = Date()
        guard newStatus != status else { return }
        status = newStatus
        statusBroadcaster.yield(newStatus)
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        listenTask?.cancel()
        listenTask = nil
        if status != nil {
            status = nil
            statusBroadcaster.yield(nil)
        }
        statusBroadcaster.finishAll()
    }

    private struct LoadRequest: Encodable, Sendable {
        let type = "LOAD"
        let sessionId: String
        let media: MediaInformation
        let autoplay: Bool
        let currentTime: Double?
        let activeTrackIds: [Int]?
        let playbackRate: Double?
        let customData: JSONValue?
        let credentials: String?
    }

    private struct QueueLoadRequest: Encodable, Sendable {
        let type = "QUEUE_LOAD"
        let sessionId: String
        let items: [QueueItem]
        let startIndex: Int
        let repeatMode: RepeatMode
        let customData: JSONValue?
    }
}
