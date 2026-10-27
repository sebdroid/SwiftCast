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

    /// How the session retries after the connection drops unexpectedly.
    public struct ReconnectPolicy: Equatable, Sendable {
        /// The pause before each attempt, measured from the loss for the
        /// first attempt and from the end of the previous attempt after that.
        public var attemptInterval: Duration
        /// How long after the loss attempts may start. Once no further
        /// attempt fits, the session moves to ``ConnectionState/failed(_:_:)``.
        /// Every loss gets at least one attempt, even when `window` is
        /// shorter than `attemptInterval`.
        public var window: Duration

        var rejoinInterval: Duration = .seconds(1)
        var rejoinWindow: Duration = .seconds(15)

        public init(attemptInterval: Duration = .seconds(3), window: Duration = .seconds(40)) {
            self.attemptInterval = attemptInterval
            self.window = window
        }
    }

    /// Which running instances of ``CastSession/appID`` the session attaches
    /// to on its own, such as after a reconnect or when a receiver status
    /// lists the app. ``CastSession/connect(to:)`` always joins a running
    /// instance and ``CastSession/load(_:autoplay:startTime:activeTrackIDs:customData:)``
    /// always joins or launches one.
    public enum AutoJoinPolicy: Equatable, Sendable {
        /// Only the application session this session last attached to.
        case sameSession
        /// Any instance of the app, including one another sender started.
        case sameApp
        /// None. The caller decides when to join, for example by loading media.
        case never
    }

    /// The receiver application used for media (Default Media Receiver by default).
    public var appID: CastAppID
    /// Whether to reconnect automatically when the connection drops unexpectedly.
    public var reconnectsAutomatically = true
    /// Spacing and time limit of automatic reconnection attempts.
    public var reconnectPolicy = ReconnectPolicy()
    /// Which application sessions are attached to automatically. Defaults to
    /// ``AutoJoinPolicy/sameSession``.
    public var autoJoinPolicy: AutoJoinPolicy = .sameSession

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
    /// The application session last attached to, kept across reconnects so
    /// ``AutoJoinPolicy/sameSession`` can recognise it.
    @ObservationIgnored private var attachedSessionID: String?
    @ObservationIgnored private var rejoinTask: Task<Void, Never>?
    @ObservationIgnored private var rejoinGeneration = 0
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
            try await establish(device, epoch: currentEpoch, rejoining: false)
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

    /// Loads media, launching ``appID`` on the receiver if necessary.
    ///
    /// A launch of the same app already pending on the client is joined
    /// instead of sent again, and it is cancelled only when every caller
    /// waiting on it has been cancelled. Its `LAUNCH_STATUS` updates still
    /// reach the `onStatus` of any ``ReceiverController/launch(_:timeout:onStatus:)``
    /// call waiting on it; this call has none of its own.
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

    /// Loads a queue, launching ``appID`` on the receiver if necessary.
    ///
    /// A launch of the same app already pending on the client is joined
    /// instead of sent again, and it is cancelled only when every caller
    /// waiting on it has been cancelled. Its `LAUNCH_STATUS` updates still
    /// reach the `onStatus` of any ``ReceiverController/launch(_:timeout:onStatus:)``
    /// call waiting on it; this call has none of its own.
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

    private func establish(_ device: CastDevice, epoch currentEpoch: Int, rejoining: Bool) async throws {
        let client = makeClient(device)
        try await client.connect()
        let status: ReceiverStatus
        do {
            guard currentEpoch == epoch else { throw CancellationError() }
            status = try await client.receiver.getStatus()
            guard currentEpoch == epoch else { throw CancellationError() }
        } catch {
            await client.disconnect()
            throw error
        }
        self.client = client
        receiverStatus = status
        connectionState = .connected(device)
        observe(client, device: device, epoch: currentEpoch)
        if !rejoining, let app = status.application(appID) {
            _ = try? await attachMedia(to: app, client: client, epoch: currentEpoch)
        } else if rejoining, attachedSessionID != nil, autoJoinPolicy != .never {
            startRejoin(client: client, epoch: currentEpoch)
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
                if let app = status.application(self.appID) {
                    if self.mediaController == nil, self.allowsAutoAttach(to: app) {
                        _ = try? await self.attachMedia(to: app, client: client, epoch: currentEpoch)
                    }
                } else {
                    // While a rejoin runs, the receiver may not list the app
                    // yet, so only a status seen outside one ends the session.
                    if self.rejoinTask == nil || self.mediaController != nil {
                        self.attachedSessionID = nil
                    }
                    if self.mediaController != nil { self.detachMedia() }
                }
            }
        }
        connectionTasks = [stateTask, receiverTask]
    }

    private func allowsAutoAttach(to app: CastApplication) -> Bool {
        switch autoJoinPolicy {
        case .sameSession: app.sessionId == attachedSessionID
        case .sameApp: true
        case .never: false
        }
    }

    /// After a reconnect the receiver may not list the running application
    /// straight away, so poll for it for a while instead of giving up on the
    /// first status.
    private func startRejoin(client: CastClient, epoch currentEpoch: Int) {
        rejoinTask?.cancel()
        let interval = reconnectPolicy.rejoinInterval
        let deadline = ContinuousClock.now.advanced(by: reconnectPolicy.rejoinWindow)
        rejoinGeneration += 1
        let generation = rejoinGeneration
        rejoinTask = Task { [weak self] in
            defer { if let self, self.rejoinGeneration == generation { self.rejoinTask = nil } }
            while await self?.attemptRejoin(client: client, epoch: currentEpoch) == false {
                let next = ContinuousClock.now.advanced(by: interval)
                guard next <= deadline else { return }
                try? await Task.sleep(until: next, clock: .continuous)
                if Task.isCancelled { return }
            }
        }
    }

    /// Returns `false` while it is worth trying again.
    private func attemptRejoin(client: CastClient, epoch currentEpoch: Int) async -> Bool {
        guard currentEpoch == epoch, mediaController == nil else { return true }
        guard let status = try? await client.receiver.getStatus() else { return false }
        guard currentEpoch == epoch, mediaController == nil else { return true }
        guard let app = status.application(appID) else { return false }
        guard allowsAutoAttach(to: app) else { return true }
        return (try? await attachMedia(to: app, client: client, epoch: currentEpoch)) != nil
    }

    private func connectionLost(device: CastDevice, error: CastError, epoch lostEpoch: Int) async {
        rejoinTask?.cancel()
        detachMedia()
        client = nil
        guard reconnectsAutomatically else {
            connectionState = .failed(device, error)
            return
        }
        let policy = reconnectPolicy
        let clock = ContinuousClock()
        let lost = clock.now
        let deadline = lost.advanced(by: policy.window)
        var nextAttempt = lost.advanced(by: policy.attemptInterval)
        var attempt = 0
        repeat {
            attempt += 1
            connectionState = .reconnecting(device, attempt: attempt)
            try? await clock.sleep(until: nextAttempt)
            guard lostEpoch == epoch else { return }
            do {
                try await establish(device, epoch: lostEpoch, rejoining: true)
                return
            } catch {
                guard lostEpoch == epoch else { return }
            }
            nextAttempt = clock.now.advanced(by: policy.attemptInterval)
        } while nextAttempt <= deadline
        connectionState = .failed(device, error)
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
        attachedSessionID = app.sessionId
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
        rejoinTask?.cancel()
        rejoinTask = nil
        attachedSessionID = nil
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
