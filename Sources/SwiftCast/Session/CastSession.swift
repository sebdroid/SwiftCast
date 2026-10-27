import Foundation
import Observation

/// A high-level, observable Cast session for SwiftUI apps.
///
/// `CastSession` connects to a device, launches or joins a receiver app,
/// mirrors receiver and media status as observable properties and
/// transparently reconnects after transient network failures.
///
/// ```swift
/// @State private var cast = CastSession()
///
/// Button("Cast") {
///     Task {
///         try await cast.connect(to: device)
///         try await cast.load(MediaInformation(url: url, contentType: "video/mp4"))
///     }
/// }
/// Text(cast.mediaStatus?.playerState.rawValue ?? "Idle")
/// ```
@MainActor
@Observable
public final class CastSession {
    /// The session's connection lifecycle.
    public enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting(CastDevice)
        case connected(CastDevice)
        case reconnecting(CastDevice, attempt: Int)
        case failed(CastDevice, CastError)

        public var device: CastDevice? {
            switch self {
            case .disconnected: nil
            case .connecting(let device), .connected(let device), .reconnecting(let device, _), .failed(let device, _): device
            }
        }
    }

    /// The receiver application used for media (Default Media Receiver by default).
    public var appID: CastAppID
    /// Whether to reconnect automatically when the connection drops unexpectedly.
    public var reconnectsAutomatically = true
    /// Maximum automatic reconnection attempts before giving up.
    public var maximumReconnectAttempts = 5

    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var receiverStatus: ReceiverStatus?
    /// The current media status of ``appID``, if it is running and has media.
    public private(set) var mediaStatus: MediaStatus?
    /// When ``mediaStatus`` was last received.
    public private(set) var mediaStatusDate: Date?
    /// The underlying client, for advanced use (custom namespaces, etc.).
    public private(set) var client: CastClient?
    /// The media controller for ``appID`` once it is running.
    public private(set) var mediaController: MediaController?

    @ObservationIgnored private var connectionTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var mediaTask: Task<Void, Never>?
    /// In-flight attach, shared so concurrent callers (a load and a receiver
    /// status update) don't create competing controllers for one application.
    @ObservationIgnored private var pendingAttach: (sessionID: String, task: Task<MediaController, any Error>)?
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private let makeClient: @Sendable (CastDevice) -> CastClient

    public init(appID: CastAppID = .defaultMediaReceiver) {
        self.appID = appID
        self.makeClient = { CastClient(device: $0) }
    }

    /// Creates a session with a custom client factory (useful for testing).
    public init(appID: CastAppID = .defaultMediaReceiver, makeClient: @escaping @Sendable (CastDevice) -> CastClient) {
        self.appID = appID
        self.makeClient = makeClient
    }

    // MARK: - Derived state

    public var device: CastDevice? { connectionState.device }

    public var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    /// The device volume (0–1), if known.
    public var volume: Double? { receiverStatus?.volume?.level }
    public var isMuted: Bool { receiverStatus?.volume?.muted ?? false }

    public var isPlaying: Bool { mediaStatus?.playerState == .playing }

    /// Duration of the current media in seconds, if known.
    public var duration: Double? { mediaStatus?.media?.duration }

    /// Estimated playback position at `date`, interpolated from the last
    /// status. Drive a `TimelineView` with this for a smooth progress bar.
    public func estimatedTime(at date: Date = Date()) -> Double? {
        guard let mediaStatus else { return nil }
        let elapsed = mediaStatusDate.map { max(0, date.timeIntervalSince($0)) } ?? 0
        return mediaStatus.estimatedTime(after: elapsed)
    }

    // MARK: - Connection

    /// Connects to `device`, joining ``appID`` if it is already running.
    /// Any existing connection is closed first.
    public func connect(to device: CastDevice) async throws {
        await teardown(stopApplication: false)
        epoch += 1
        let currentEpoch = epoch
        connectionState = .connecting(device)
        do {
            try await establish(device, epoch: currentEpoch)
        } catch {
            guard currentEpoch == epoch else { throw error }
            let castError = (error as? CastError) ?? .connectionFailed(error.localizedDescription)
            connectionState = .failed(device, castError)
            throw castError
        }
    }

    /// Disconnects from the device, optionally stopping the receiver app.
    public func disconnect(stopApplication: Bool = false) async {
        epoch += 1
        await teardown(stopApplication: stopApplication)
        connectionState = .disconnected
    }

    // MARK: - Playback

    /// Loads media, launching ``appID`` on the receiver if necessary. A launch
    /// shared with other callers is cancelled only when every caller waiting
    /// on it has been cancelled.
    @discardableResult
    public func load(
        _ media: MediaInformation,
        autoplay: Bool = true,
        startTime: Double? = nil,
        activeTrackIDs: [Int]? = nil,
        customData: JSONValue? = nil
    ) async throws -> MediaStatus {
        let controller = try await ensureMediaController()
        let status = try await controller.load(media, autoplay: autoplay, startTime: startTime, activeTrackIDs: activeTrackIDs, customData: customData)
        apply(status)
        return status
    }

    /// Loads a queue, launching ``appID`` on the receiver if necessary. A launch
    /// shared with other callers is cancelled only when every caller waiting
    /// on it has been cancelled.
    @discardableResult
    public func loadQueue(_ items: [QueueItem], startIndex: Int = 0, repeatMode: RepeatMode = .off) async throws -> MediaStatus {
        let controller = try await ensureMediaController()
        let status = try await controller.loadQueue(items, startIndex: startIndex, repeatMode: repeatMode)
        apply(status)
        return status
    }

    public func play() async throws { try await command { try await $0.play() } }
    public func pause() async throws { try await command { try await $0.pause() } }
    public func stop() async throws { try await command { try await $0.stop() } }

    public func togglePlayPause() async throws {
        if isPlaying { try await pause() } else { try await play() }
    }

    public func seek(to time: Double) async throws {
        try await command { try await $0.seek(to: time) }
    }

    public func skip(by seconds: Double) async throws {
        guard let now = estimatedTime() else { throw CastError.noMediaSession }
        try await seek(to: now + seconds)
    }

    public func setActiveTracks(_ trackIDs: [Int], textTrackStyle: TextTrackStyle? = nil) async throws {
        try await command { try await $0.setActiveTracks(trackIDs, textTrackStyle: textTrackStyle) }
    }

    public func next() async throws { try await command { try await $0.next() } }
    public func previous() async throws { try await command { try await $0.previous() } }

    /// Sets the device volume (0–1).
    public func setVolume(_ level: Double) async throws {
        guard let client else { throw CastError.notConnected }
        receiverStatus = try await client.receiver.setVolume(level)
    }

    public func setMuted(_ muted: Bool) async throws {
        guard let client else { throw CastError.notConnected }
        receiverStatus = try await client.receiver.setMuted(muted)
    }

    // MARK: - Private

    private func establish(_ device: CastDevice, epoch currentEpoch: Int) async throws {
        let client = makeClient(device)
        try await client.connect()
        guard currentEpoch == epoch else {
            await client.disconnect()
            throw CancellationError()
        }
        self.client = client
        let status = try await client.receiver.getStatus()
        guard currentEpoch == epoch else { throw CancellationError() }
        receiverStatus = status
        connectionState = .connected(device)
        observe(client, device: device, epoch: currentEpoch)
        if let app = status.application(appID) {
            _ = try? await attachMedia(to: app, client: client, epoch: currentEpoch)
        }
    }

    private func observe(_ client: CastClient, device: CastDevice, epoch currentEpoch: Int) {
        let stateTask = Task { [weak self] in
            for await state in await client.stateUpdates() {
                guard let self, currentEpoch == self.epoch else { return }
                if case .closed(let error?) = state {
                    await self.connectionLost(device: device, error: error, epoch: currentEpoch)
                    return
                }
            }
        }
        let receiverTask = Task { [weak self] in
            for await update in await client.receiverStatusUpdates() {
                guard let self, currentEpoch == self.epoch else { return }
                // Stream elements can be delivered after newer statuses have
                // arrived (for example the pre-launch status after a LAUNCH
                // reply), so act on the client's latest status instead.
                let status = await client.receiverStatus ?? update
                guard currentEpoch == self.epoch else { return }
                self.receiverStatus = status
                if status.application(self.appID) == nil, self.mediaController != nil {
                    self.detachMedia()
                } else if let app = status.application(self.appID), self.mediaController == nil {
                    _ = try? await self.attachMedia(to: app, client: client, epoch: currentEpoch)
                }
            }
        }
        connectionTasks = [stateTask, receiverTask]
    }

    private func connectionLost(device: CastDevice, error: CastError, epoch lostEpoch: Int) async {
        detachMedia()
        client = nil
        guard reconnectsAutomatically else {
            connectionState = .failed(device, error)
            return
        }
        var delay: Duration = .milliseconds(500)
        for attempt in 1...max(1, maximumReconnectAttempts) {
            guard lostEpoch == epoch else { return }
            connectionState = .reconnecting(device, attempt: attempt)
            try? await Task.sleep(for: delay)
            guard lostEpoch == epoch else { return }
            do {
                try await establish(device, epoch: lostEpoch)
                return
            } catch {
                delay = min(delay * 2, .seconds(8))
            }
        }
        if lostEpoch == epoch { connectionState = .failed(device, error) }
    }

    private func ensureMediaController() async throws -> MediaController {
        if let mediaController, await !mediaController.isClosed { return mediaController }
        guard let client, isConnected else { throw CastError.notConnected }
        let currentEpoch = epoch
        let status = try await client.receiver.getStatus()
        let app: CastApplication
        if let running = status.application(appID) {
            app = running
        } else {
            app = try await client.receiver.launch(appID)
        }
        guard currentEpoch == epoch else { throw CastError.notConnected }
        return try await attachMedia(to: app, client: client, epoch: currentEpoch)
    }

    @discardableResult
    private func attachMedia(to app: CastApplication, client: CastClient, epoch currentEpoch: Int) async throws -> MediaController {
        if let mediaController, mediaController.application.sessionId == app.sessionId, await !mediaController.isClosed {
            return mediaController
        }
        if let pendingAttach, pendingAttach.sessionID == app.sessionId {
            return try await pendingAttach.task.value
        }
        let task = Task { try await client.mediaController(for: app) }
        pendingAttach = (app.sessionId, task)
        defer { if pendingAttach?.sessionID == app.sessionId { pendingAttach = nil } }
        let controller = try await task.value
        guard currentEpoch == epoch else { throw CastError.notConnected }
        mediaTask?.cancel()
        mediaController = controller
        let updates = await controller.statusUpdates()
        mediaTask = Task { [weak self] in
            for await status in updates {
                guard let self, currentEpoch == self.epoch else { return }
                self.mediaStatus = status
                self.mediaStatusDate = Date()
            }
            guard let self, currentEpoch == self.epoch, self.mediaController === controller else { return }
            self.detachMedia()
        }
        return controller
    }

    private func detachMedia() {
        pendingAttach = nil
        mediaTask?.cancel()
        mediaTask = nil
        mediaController = nil
        mediaStatus = nil
        mediaStatusDate = nil
    }

    private func command(_ body: (MediaController) async throws -> MediaStatus?) async throws {
        guard let mediaController else { throw CastError.noMediaSession }
        if let status = try await body(mediaController) { apply(status) }
    }

    private func apply(_ status: MediaStatus) {
        mediaStatus = status
        mediaStatusDate = Date()
    }

    private func teardown(stopApplication: Bool) async {
        connectionTasks.forEach { $0.cancel() }
        connectionTasks = []
        let controller = mediaController
        detachMedia()
        if let client {
            if stopApplication, let app = controller?.application {
                try? await client.receiver.stop(app)
            }
            await client.disconnect()
        }
        client = nil
        receiverStatus = nil
    }
}
