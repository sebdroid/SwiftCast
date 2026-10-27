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

    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var receiverStatusTask: Task<Void, Never>?
    @ObservationIgnored private var mediaTask: Task<Void, Never>?
    /// In-flight attach, shared so concurrent callers (a load and a receiver
    /// status update) don't create competing controllers for one application.
    @ObservationIgnored private var pendingAttach: (sessionID: String, task: Task<MediaController, any Error>)?
    /// The application session last attached to, kept across reconnects so
    /// ``AutoJoinPolicy/sameSession`` can recognise it.
    @ObservationIgnored private(set) var attachedSessionID: String?
    @ObservationIgnored private var rejoinTask: Task<Void, Never>?
    @ObservationIgnored private var rejoinGeneration = 0
    /// Kept until the loop itself ends, so a cancelled loop that has not
    /// unwound yet still shows up in ``hasReconnectLoop``.
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectGeneration = 0
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private let makeClient: @Sendable (CastDevice) -> CastClient

    /// Whether a rejoin is polling for the remembered application, for tests.
    var isRejoining: Bool { rejoinTask != nil }

    /// Whether a reconnect loop is still running, for tests.
    var hasReconnectLoop: Bool { reconnectTask != nil }

    /// Awaited by the receiver status watcher right after it reads the
    /// client's latest status, so tests can land a loss in that suspension.
    @ObservationIgnored var onReceiverStatusRead: (@MainActor (ReceiverStatus) async -> Void)?

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
        // Bumped before the teardown suspends, so anything that completes
        // during it, or a newer connect or disconnect, already sees it as stale.
        epoch += 1
        let currentEpoch = epoch
        await teardown(stopApplication: false)
        guard currentEpoch == epoch else { throw CancellationError() }
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
        let currentEpoch = epoch
        await teardown(stopApplication: stopApplication)
        // A connect that ran while the old client was closing owns the state now.
        guard currentEpoch == epoch else { return }
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

    private func establish(_ device: CastDevice, epoch currentEpoch: Int) async throws {
        let client = makeClient(device)
        let status = try await Self.open(client) { [weak self] in self?.epoch == currentEpoch }
        adopt(client, status: status, device: device, epoch: currentEpoch)
        if let app = status.application(appID) {
            _ = try? await attachMedia(to: app, client: client, epoch: currentEpoch)
        }
    }

    /// Connects `client` and reads the receiver status, disconnecting it
    /// again if that fails or `isCurrent` turns false along the way.
    private static func open(_ client: CastClient, isCurrent: @MainActor () -> Bool) async throws -> ReceiverStatus {
        try await client.connect()
        do {
            guard isCurrent() else { throw CancellationError() }
            let status = try await client.receiver.getStatus()
            guard isCurrent() else { throw CancellationError() }
            return status
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private func adopt(_ client: CastClient, status: ReceiverStatus, device: CastDevice, epoch currentEpoch: Int) {
        self.client = client
        receiverStatus = status
        connectionState = .connected(device)
        observe(client, device: device, epoch: currentEpoch)
    }

    private func observe(_ client: CastClient, device: CastDevice, epoch currentEpoch: Int) {
        stateTask?.cancel()
        receiverStatusTask?.cancel()
        stateTask = Task { [weak self] in
            for await state in await client.stateUpdates() {
                guard let self, !Task.isCancelled, currentEpoch == self.epoch else { return }
                if case .closed(let error?) = state {
                    self.connectionLost(device: device, error: error, epoch: currentEpoch)
                    return
                }
            }
        }
        receiverStatusTask = Task { [weak self] in
            for await update in await client.receiverStatusUpdates() {
                guard let self, !Task.isCancelled, currentEpoch == self.epoch else { return }
                // Stream elements can be delivered after newer statuses have
                // arrived (for example the pre-launch status after a LAUNCH
                // reply), so act on the client's latest status instead.
                let status = await client.receiverStatus ?? update
                if let onReceiverStatusRead = self.onReceiverStatusRead { await onReceiverStatusRead(status) }
                // A loss keeps the epoch, so only the cancellation it makes
                // marks this status as stale.
                guard !Task.isCancelled, currentEpoch == self.epoch else { return }
                self.receiverStatus = status
                if let app = status.application(self.appID) {
                    if self.mediaController == nil, self.allowsAutoAttach(to: app) {
                        _ = try? await self.attachMedia(to: app, client: client, epoch: currentEpoch)
                    }
                } else {
                    // While a rejoin runs, the receiver may not list the app
                    // yet, so only a status seen outside one ends the session.
                    // Attaching ends a rejoin, so this also covers a controller
                    // that has already detached itself on this same status.
                    if self.rejoinTask == nil {
                        self.attachedSessionID = nil
                    }
                    if self.mediaController != nil { self.detachMedia() }
                }
            }
        }
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
                guard next <= deadline else {
                    // The app did not come back, so a later loss has nothing to
                    // rejoin. Whatever ends a rejoin early cancels it first.
                    if let self, !Task.isCancelled { self.attachedSessionID = nil }
                    return
                }
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

    private func connectionLost(device: CastDevice, error: CastError, epoch lostEpoch: Int) {
        // This runs on the state watcher, which returns as soon as this does,
        // so it is released rather than cancelled.
        stateTask = nil
        receiverStatusTask?.cancel()
        receiverStatusTask = nil
        rejoinTask?.cancel()
        reconnectTask?.cancel()
        detachMedia()
        client = nil
        guard reconnectsAutomatically else {
            connectionState = .failed(device, error)
            return
        }
        let lost = ContinuousClock.now
        let policy = reconnectPolicy
        let makeClient = self.makeClient
        connectionState = .reconnecting(device, attempt: 1)
        reconnectGeneration += 1
        let generation = reconnectGeneration
        // Holds the session only between suspensions, so a session dropped
        // without disconnect() is freed and the loop ends at its next step.
        // It ends without touching the session once cancelled, which
        // disconnect(stopApplication:), connect(to:) and a newer loss do.
        reconnectTask = Task { [weak self] in
            defer { if let self, self.reconnectGeneration == generation { self.reconnectTask = nil } }
            let deadline = lost.advanced(by: policy.window)
            var nextAttempt = lost.advanced(by: policy.attemptInterval)
            var attempt = 1
            while true {
                try? await Task.sleep(until: nextAttempt, clock: .continuous)
                guard !Task.isCancelled, self?.epoch == lostEpoch else { return }
                let client = makeClient(device)
                if let status = try? await Self.open(client, isCurrent: { !Task.isCancelled && self?.epoch == lostEpoch }) {
                    guard let self, !Task.isCancelled, self.epoch == lostEpoch else {
                        await client.disconnect()
                        return
                    }
                    self.adopt(client, status: status, device: device, epoch: lostEpoch)
                    if self.attachedSessionID != nil, self.autoJoinPolicy != .never {
                        self.startRejoin(client: client, epoch: lostEpoch)
                    }
                    return
                }
                guard let self, !Task.isCancelled, self.epoch == lostEpoch else { return }
                nextAttempt = ContinuousClock.now.advanced(by: policy.attemptInterval)
                guard nextAttempt <= deadline else {
                    self.connectionState = .failed(device, error)
                    return
                }
                attempt += 1
                self.connectionState = .reconnecting(device, attempt: attempt)
            }
        }
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
        guard currentEpoch == epoch, self.client === client else { throw CastError.notConnected }
        mediaTask?.cancel()
        mediaController = controller
        attachedSessionID = app.sessionId
        rejoinTask?.cancel()
        rejoinTask = nil
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
        stateTask?.cancel()
        stateTask = nil
        receiverStatusTask?.cancel()
        receiverStatusTask = nil
        rejoinTask?.cancel()
        rejoinTask = nil
        reconnectTask?.cancel()
        attachedSessionID = nil
        let controller = mediaController
        detachMedia()
        // Cleared before suspending so a newer connect that finishes while
        // this one waits on the old client is not undone when it resumes.
        let client = self.client
        self.client = nil
        receiverStatus = nil
        if let client {
            if stopApplication, let app = controller?.application {
                try? await client.receiver.stop(app)
            }
            await client.disconnect()
        }
    }
}
