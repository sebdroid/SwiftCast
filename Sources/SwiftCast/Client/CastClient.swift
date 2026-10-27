import Foundation
import Network
import os

/// A connection to a single Cast device.
///
/// `CastClient` owns the TLS connection, frames and routes messages,
/// maintains the heartbeat, manages virtual connections and correlates
/// requests with their responses.
///
/// ```swift
/// let client = CastClient(device: device)
/// try await client.connect()
/// let media = try await client.launchMediaReceiver()
/// try await media.load(MediaInformation(url: videoURL, contentType: "video/mp4"))
/// ```
public actor CastClient {
    /// Connection lifecycle.
    public enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        /// The connection ended. `error` is `nil` for a deliberate disconnect.
        case closed(CastError?)
    }

    /// The version of SwiftCast, reported to receivers in the `CONNECT` message.
    public static let version = "1.0.1"

    /// How an application virtual connection is presented to the receiver.
    public enum ConnectionType: Int, Sendable {
        /// A regular sender connection, visible to the application as a connected sender.
        case strong = 0
        /// A connection the application is not told about as a connected sender.
        case invisible = 2
    }

    /// Tunable client behavior.
    public struct Configuration: Sendable {
        /// Interval between heartbeat `PING`s. Non-positive values use the
        /// default of 5 seconds.
        public var heartbeatInterval: Duration = Self.defaultHeartbeatInterval
        /// The connection is considered dead when nothing at all arrives
        /// within this long of a `PING` being sent. Any inbound message, not
        /// only `PONG`, counts as a sign of life.
        ///
        /// A dead receiver is noticed within this long of the next `PING`, so
        /// at most ``heartbeatInterval`` plus this long after its last message.
        /// Non-positive values use the default of 10 seconds.
        public var inactivityTimeout: Duration = Self.defaultInactivityTimeout
        /// Default time to wait for a response to a request, such as a
        /// platform receiver request or a request on a custom namespace.
        public var requestTimeout: Duration = .seconds(5)
        /// Default time to wait for a response to a ``MediaController``
        /// request. Loads use their own, longer timeout.
        public var mediaRequestTimeout: Duration = .seconds(10)
        /// Sent in the `CONNECT` message. Defaults to
        /// `SwiftCast/<version> (<os name> <os version>)`.
        public var userAgent: String = CastClient.defaultUserAgent
        /// The connection type requested when opening a virtual connection to an
        /// application. The platform receiver connection is always ``ConnectionType/strong``.
        public var applicationConnectionType: ConnectionType = .strong

        public init() {}

        static let defaultHeartbeatInterval: Duration = .seconds(5)
        static let defaultInactivityTimeout: Duration = .seconds(10)

        var effectiveHeartbeatInterval: Duration {
            heartbeatInterval > .zero ? heartbeatInterval : Self.defaultHeartbeatInterval
        }

        var effectiveInactivityTimeout: Duration {
            inactivityTimeout > .zero ? inactivityTimeout : Self.defaultInactivityTimeout
        }

        @available(*, deprecated, renamed: "inactivityTimeout")
        public var heartbeatTimeout: Duration {
            get { inactivityTimeout }
            set { inactivityTimeout = newValue }
        }
    }

    /// The source ID used for messages sent by this client.
    ///
    /// Defaults to `sender-` followed by a lowercase UUID, unique to each
    /// client. `sender-0` and `*` are reserved by the protocol and should not
    /// be used.
    public nonisolated let senderID: String
    public nonisolated let configuration: Configuration

    public private(set) var state: State = .disconnected
    /// The most recent receiver status (from a request or broadcast).
    public private(set) var receiverStatus: ReceiverStatus?

    /// Replies are matched on the namespace and peer a request went to as
    /// well as its id, so a stray message reusing the id cannot answer it.
    private struct PendingKey: Hashable {
        let namespace: CastNamespace
        let destination: String
        let requestID: Int
    }

    /// The client's one pending launch. Each caller waiting on it is keyed
    /// by a token and keeps its own `LaunchWaiter`. A launch with no waiters left
    /// has been cancelled and stays recorded until its `LAUNCH` leaves
    /// `pending`, so a new launch cannot collide with it.
    private struct LaunchInFlight {
        let id: Int
        let appID: CastAppID
        let task: Task<CastApplication, any Error>
        var waiters: [Int: LaunchWaiter]
    }

    private struct OpenInFlight {
        let write: Task<Void, any Error>
        let completion: OpenCompletion
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<InboundMessage, any Error>
        let timeoutTask: Task<Void, Never>
        let type: String?
        let options: RequestOptions
    }

    /// How a request is correlated with its replies and when it completes.
    struct RequestOptions: Sendable {
        /// Only one request of this payload's `type` may be pending per
        /// namespace and destination at a time.
        var exclusive = false
        /// Replies may echo the id as `launchRequestId` instead of `requestId`.
        var acceptsLaunchRequestID = false
        /// Whether a correlated reply completes the request.
        var isFinal: @Sendable (InboundMessage) -> Bool = { _ in true }
        /// Runs on the client for each correlated reply that does not complete the request.
        var onUpdate: (@Sendable (isolated CastClient, InboundMessage) -> Void)?
        /// Runs on the client as the request leaves `pending`, whatever the
        /// outcome, before its caller resumes.
        var onSettled: (@Sendable (isolated CastClient) -> Void)?
        /// Runs on the client once the request is registered and its write
        /// scheduled, before that write runs. Tests use it to land a
        /// cancellation in that gap.
        var onRegistered: (@Sendable (isolated CastClient) -> Void)?
    }

    private let makeTransport: @Sendable () -> any CastTransport
    private var transport: (any CastTransport)?
    private var generation = 0
    private var decoder = FrameDecoder()
    private var pending: [PendingKey: PendingRequest] = [:]
    private var nextRequestID = 1
    private var connectedDestinations: Set<String> = []
    private var connectsInFlight: [String: OpenInFlight] = [:]
    private var virtualConnectionIntents: [String: Int] = [:]
    private(set) var closesAwaitingOpen = 0
    private var launchInFlight: LaunchInFlight?
    private var nextLaunchID = 0
    private var nextLaunchWaiter = 0
    private var protocolVersions: [String: Int] = [:]
    /// The timeout the latest request of each payload `type` was given, for tests.
    private(set) var lastTimeoutByRequestType: [String: Duration] = [:]
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var nextPing = ContinuousClock.now
    private var inactivityDeadline: ContinuousClock.Instant?

    private let messageBroadcaster = Broadcaster<InboundMessage>()
    private let stateBroadcaster = Broadcaster<State>()
    private let receiverStatusBroadcaster = Broadcaster<ReceiverStatus>()

    // MARK: - Initialization

    /// Creates a client whose transport is produced by `makeTransport` on each
    /// call to ``connect()``, allowing the client to reconnect.
    public init(
        senderID: String = CastClient.makeSenderID(),
        configuration: Configuration = Configuration(),
        makeTransport: @escaping @Sendable () -> any CastTransport
    ) {
        self.senderID = senderID
        self.configuration = configuration
        self.makeTransport = makeTransport
    }

    /// Creates a client for a discovered device.
    public init(device: CastDevice, senderID: String = CastClient.makeSenderID(), configuration: Configuration = Configuration()) {
        let endpoint = device.endpoint
        self.init(senderID: senderID, configuration: configuration) {
            NetworkTransport(endpoint: endpoint)
        }
    }

    /// Creates a client for a device at a known host and port.
    public init(host: String, port: UInt16 = 8009, senderID: String = CastClient.makeSenderID(), configuration: Configuration = Configuration()) {
        self.init(senderID: senderID, configuration: configuration) {
            NetworkTransport(host: host, port: port)
        }
    }

    // MARK: - Lifecycle

    /// Connects to the device and opens the platform virtual connection.
    ///
    /// Calling `connect()` while connected does nothing. A client may be
    /// reconnected after it has closed.
    public func connect() async throws {
        switch state {
        case .connected, .connecting: return
        case .disconnected, .closed: break
        }
        generation += 1
        let currentGeneration = generation
        reopenStreams()
        setState(.connecting)
        decoder = FrameDecoder()
        connectedDestinations = []
        connectsInFlight = [:]
        launchInFlight = nil
        protocolVersions = [:]

        let transport = makeTransport()
        self.transport = transport
        do {
            try await transport.open()
        } catch {
            guard generation == currentGeneration else { throw CastError.notConnected }
            let castError = (error as? CastError) ?? .connectionFailed(error.localizedDescription)
            self.transport = nil
            transport.close()
            setState(.closed(castError))
            finishStreams()
            throw error is CancellationError ? error : castError
        }
        guard generation == currentGeneration else {
            transport.close()
            throw CastError.notConnected
        }

        inactivityDeadline = nil
        receiveTask = Task { [weak self] in
            do {
                for try await chunk in transport.inbound {
                    guard let self else { return }
                    await self.ingest(chunk, generation: currentGeneration)
                }
                await self?.teardown(error: .connectionFailed("Connection closed by device"), generation: currentGeneration)
            } catch {
                let castError = (error as? CastError) ?? .connectionFailed(error.localizedDescription)
                await self?.teardown(error: castError, generation: currentGeneration)
            }
        }

        do {
            try await openVirtualConnection(to: CastEndpoint.platformReceiver)
        } catch {
            teardown(error: (error as? CastError) ?? .connectionFailed(error.localizedDescription), generation: currentGeneration)
            throw error
        }
        guard generation == currentGeneration, state == .connecting else { throw CastError.notConnected }
        setState(.connected)
        startHeartbeat(generation: currentGeneration)
    }

    /// Closes the underlying connection, leaving running applications (and
    /// their playback) untouched.
    ///
    /// Only the platform receiver's virtual connection is closed explicitly.
    /// Web receivers treat an explicit `CLOSE` from their last sender as a
    /// request to shut down, so application connections are dropped with the
    /// socket instead. To end playback, stop the application first with
    /// ``ReceiverController/stop(_:)``.
    public func disconnect() async {
        guard let transport, state == .connected || state == .connecting else { return }
        for destination in connectedDestinations where destination == CastEndpoint.platformReceiver {
            if let close = try? Self.makeMessage(Self.closePayload, source: senderID, namespace: .connection, destination: destination) {
                try? await transport.send(FrameCodec.frame(close))
            }
        }
        teardown(error: nil, generation: generation)
    }

    // MARK: - Observation

    /// Streams connection state changes, starting with the current state.
    ///
    /// A stream made before the connection closes ends right after it
    /// delivers the `.closed` state, and one made while the client is closed
    /// delivers that state and ends at once. To follow a reconnect, subscribe
    /// again after calling ``connect()``.
    public func stateUpdates() -> AsyncStream<State> {
        stateBroadcaster.subscribe(initial: state)
    }

    /// Streams receiver status updates, starting with the latest known status.
    ///
    /// A stream made before the connection closes ends when it closes, and
    /// one made while the client is closed delivers the latest known status,
    /// if any, and ends at once. To follow a reconnect, subscribe again after
    /// calling ``connect()``.
    public func receiverStatusUpdates() -> AsyncStream<ReceiverStatus> {
        receiverStatusBroadcaster.subscribe(initial: receiverStatus)
    }

    /// Streams inbound messages, optionally filtered to one namespace.
    ///
    /// Only messages addressed to this client's ``senderID`` or to the
    /// broadcast id `*` are delivered. Apart from the transport namespaces
    /// (`tp.connection`, `tp.heartbeat` and `tp.deviceauth`), a message is only
    /// delivered when it comes from a peer with an open virtual connection,
    /// so open one with ``openVirtualConnection(to:)`` before listening to an
    /// application. On `urn:x-cast:com.google.cast.*` namespaces, payloads that
    /// are not a JSON object are dropped; custom namespaces receive every
    /// payload as is, with ``InboundMessage/json`` `nil` when it is not JSON.
    ///
    /// Streams end when the connection closes. A stream made while the client
    /// is closed ends at once; subscribe again after calling ``connect()``.
    public nonisolated func messages(in namespace: CastNamespace? = nil) -> AsyncStream<InboundMessage> {
        let all = messageBroadcaster.subscribe()
        guard let namespace else { return all }
        let (stream, continuation) = AsyncStream<InboundMessage>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let task = Task {
            for await message in all where message.namespace == namespace {
                continuation.yield(message)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - Sending

    /// Sends a JSON message without waiting for a response.
    public func send(_ payload: some Encodable & Sendable, namespace: CastNamespace, to destination: String) async throws {
        let json = try JSONValue(encoding: payload)
        try await sendJSON(json, namespace: namespace, to: destination)
    }

    /// Sends a binary message.
    public func send(binary data: Data, namespace: CastNamespace, to destination: String) async throws {
        try await sendRaw(CastMessage(sourceID: senderID, destinationID: destination, namespace: namespace.rawValue, payload: .binary(data)))
    }

    /// Sends a JSON request and waits for the response carrying the same `requestId`.
    ///
    /// Only a reply on `namespace` from `destination` answers the request.
    /// `until` decides whether such a reply completes it: a reply it rejects
    /// is an intermediate update, still delivered through ``messages(in:)``,
    /// and the request stays pending until a later reply is accepted or
    /// `timeout` passes. The timeout covers the whole exchange, not each reply.
    ///
    /// Standard Cast error responses (`LAUNCH_ERROR`, `LOAD_FAILED`,
    /// `INVALID_REQUEST`, …) are thrown as ``CastError``.
    ///
    /// A request cancelled before its message is written is not written at all.
    public func request(
        _ payload: some Encodable & Sendable,
        namespace: CastNamespace,
        to destination: String,
        timeout: Duration? = nil,
        until isFinal: @escaping @Sendable (InboundMessage) -> Bool = { _ in true }
    ) async throws -> InboundMessage {
        try await request(payload, namespace: namespace, to: destination, timeout: timeout, options: RequestOptions(isFinal: isFinal))
    }

    func request(
        _ payload: some Encodable & Sendable,
        namespace: CastNamespace,
        to destination: String,
        timeout: Duration?,
        options: RequestOptions
    ) async throws -> InboundMessage {
        guard state == .connected || state == .connecting else { throw CastError.notConnected }
        guard case .object(var object) = try JSONValue(encoding: payload) else {
            throw CastError.invalidPayload("Request payload must be a JSON object")
        }
        let type = object["type"]?.stringValue
        let requestID = nextRequestID
        nextRequestID = nextRequestID == Int32.max ? 1 : nextRequestID + 1
        let key = PendingKey(namespace: namespace, destination: destination, requestID: requestID)
        object["requestId"] = .number(Double(requestID))
        let message = try Self.makeMessage(JSONValue.object(object), source: senderID, namespace: namespace, destination: destination)
        let timeout = timeout ?? configuration.requestTimeout
        if let type { lastTimeoutByRequestType[type] = timeout }
        let cancelled = OSAllocatedUnfairLock(initialState: false)

        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<InboundMessage, any Error>) in
                // Checked here, where registration happens, so two callers cannot both pass.
                if options.exclusive, let type, isPending(type, namespace: namespace, destination: destination) {
                    continuation.resume(throwing: CastError.requestInFlight(type))
                    return
                }
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.resolve(key, with: .failure(CastError.timeout))
                }
                pending[key] = PendingRequest(continuation: continuation, timeoutTask: timeoutTask, type: type, options: options)
                if Task.isCancelled {
                    // The cancellation handler may have run before registration.
                    resolve(key, with: .failure(CancellationError()))
                    return
                }
                Task {
                    // The caller may have been cancelled, or the request
                    // settled, after registration; it is then never written.
                    // The flag covers a cancellation whose resolve has not
                    // reached the client yet.
                    guard self.pending[key] != nil else { return }
                    guard !cancelled.withLock({ $0 }) else {
                        return self.resolve(key, with: .failure(CancellationError()))
                    }
                    do {
                        try await self.sendRaw(message)
                    } catch {
                        self.resolve(key, with: .failure(error))
                    }
                }
                options.onRegistered?(self)
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
            Task { await self.resolve(key, with: .failure(CancellationError())) }
        }

        if let error = Self.standardError(in: response) { throw error }
        return response
    }

    // MARK: - Virtual connections

    /// Opens a virtual connection to `destination` (e.g. an app's `transportId`).
    /// Does nothing if one is already open. A call made while another is still
    /// opening the same connection waits for it and shares its result, then
    /// opens again if the connection was closed before it resumed and no later
    /// open or close has been issued.
    public func openVirtualConnection(to destination: String) async throws {
        try await openConnection(to: destination)
    }

    /// Returns the intent this call recorded when it wrote the `CONNECT`
    /// itself, or `nil` when it found the connection open or shared the
    /// write of another call.
    @discardableResult
    private func openConnection(to destination: String) async throws -> Int? {
        let intent = recordIntent(for: destination)
        for _ in 0..<2 {
            guard let inFlight = connectsInFlight[destination] else { break }
            let generation = generation
            try await inFlight.write.value
            guard self.generation == generation, virtualConnectionIntents[destination] == intent,
                  !connectedDestinations.contains(destination) else { return nil }
        }
        guard !connectedDestinations.contains(destination) else { return nil }
        let generation = generation
        // Registered before the write so a message the peer sends as soon as
        // it sees CONNECT is not dropped as coming from an unknown peer.
        connectedDestinations.insert(destination)
        let payload = connectPayload(to: destination)
        let completion = OpenCompletion()
        let write = Task {
            let result: Result<Void, any Error>
            do {
                try await sendJSON(payload, namespace: .connection, to: destination)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            // Settled here, before any waiter resumes, so nothing can observe
            // a finished open that is still listed as in flight. After a
            // reconnect the entries belong to the new connection.
            if self.generation == generation {
                if connectsInFlight[destination]?.completion === completion { connectsInFlight[destination] = nil }
                if case .failure = result {
                    connectedDestinations.remove(destination)
                    protocolVersions[destination] = nil
                }
            }
            completion.finish(result)
            try result.get()
        }
        connectsInFlight[destination] = OpenInFlight(write: write, completion: completion)
        try await write.value
        return intent
    }

    /// Closes the virtual connection to `destination`.
    ///
    /// A close issued while the connection is still opening takes effect
    /// only after that open completes, so the wire order is always `CONNECT`
    /// then `CLOSE`. If that open fails, or another open or close of the same
    /// destination is issued while it waits, it does nothing: the later call
    /// decides the outcome. A close cancelled while it waits returns at once
    /// and changes nothing: the connection stays as the open leaves it, and
    /// it does not count as a later call for closes that are still waiting.
    public func closeVirtualConnection(to destination: String) async {
        let intent = recordIntent(for: destination)
        if let inFlight = connectsInFlight[destination] {
            let generation = generation
            closesAwaitingOpen += 1
            defer { closesAwaitingOpen -= 1 }
            do {
                try await inFlight.completion.wait()
            } catch {
                // A cancelled close decides nothing, so it must not supersede
                // an earlier close still waiting. Only the latest call can be
                // undone, so a later call keeps superseding as before.
                if error is CancellationError, virtualConnectionIntents[destination] == intent {
                    virtualConnectionIntents[destination] = intent - 1
                }
                return
            }
            guard self.generation == generation, virtualConnectionIntents[destination] == intent else { return }
        }
        guard connectedDestinations.remove(destination) != nil else { return }
        protocolVersions[destination] = nil
        try? await sendJSON(Self.closePayload, namespace: .connection, to: destination)
    }

    private func recordIntent(for destination: String) -> Int {
        let intent = virtualConnectionIntents[destination, default: 0] + 1
        virtualConnectionIntents[destination] = intent
        return intent
    }

    /// How many open and close calls have been issued for `destination`.
    func virtualConnectionIntent(for destination: String) -> Int {
        virtualConnectionIntents[destination, default: 0]
    }

    /// How many closes are suspended on the in-flight open of `destination`.
    func closesWaitingOnOpen(to destination: String) -> Int {
        connectsInFlight[destination]?.completion.waiterCount ?? 0
    }

    /// Whether a virtual connection to `destination` is currently open.
    public func isConnected(to destination: String) -> Bool {
        connectedDestinations.contains(destination)
    }

    // MARK: - Controllers

    /// Controls the device's platform receiver (apps and volume).
    public nonisolated var receiver: ReceiverController { ReceiverController(client: self) }

    /// Returns a media controller for a running application, opening a
    /// virtual connection to it and fetching its current media status.
    ///
    /// A failed status fetch still returns the controller, but a cancelled
    /// call throws `CancellationError`. A cancelled call that wrote the
    /// application's `CONNECT` itself closes that virtual connection again
    /// before it throws, unless another open or close of it has been issued
    /// since, as by a concurrent call for the same application. A cancelled
    /// call that found the connection already open, or shared another
    /// call's `CONNECT`, leaves it as it is. As with
    /// ``MediaController/detach()``, that `CLOSE` can end an application
    /// whose last connected sender this client was.
    public func mediaController(for application: CastApplication) async throws -> MediaController {
        let destination = application.transportId
        let generation = generation
        let openedIntent = try await openConnection(to: destination)
        let controller = MediaController(client: self, application: application)
        await controller.start()
        _ = try? await controller.refreshStatus()
        if Task.isCancelled {
            // Checked and closed without suspending in between, so an open
            // issued meanwhile always keeps the connection.
            if let openedIntent, self.generation == generation, virtualConnectionIntents[destination] == openedIntent {
                await closeVirtualConnection(to: destination)
            }
            throw CancellationError()
        }
        return controller
    }

    /// Joins `appID` if it is already running, otherwise launches it, and
    /// returns a media controller for it.
    ///
    /// A launch shared with other callers (see ``ReceiverController/launch(_:timeout:onStatus:)``)
    /// is cancelled only when every caller waiting on it has been cancelled.
    /// A cancelled call throws `CancellationError` straight away, at any
    /// stage, and stops receiving that launch's `LAUNCH_STATUS` updates.
    /// Cancelled while it attaches, it first closes the application's
    /// virtual connection as ``mediaController(for:)`` does, waiting only for
    /// that write. It never stops an application it launched.
    public func launchMediaApp(_ appID: CastAppID = .defaultMediaReceiver) async throws -> MediaController {
        let status = try await receiver.getStatus()
        let application: CastApplication
        if let running = status.application(appID) {
            application = running
        } else {
            application = try await receiver.launch(appID)
        }
        return try await mediaController(for: application)
    }

    /// Runs `start` as the client's one pending launch, or joins the pending
    /// launch of the same app. `start` must send its request with the
    /// options it is given, which tie the launch to that request.
    ///
    /// A cancelled caller, whether it started the launch or joined it,
    /// throws `CancellationError` straight away and stops waiting; the
    /// launch itself is cancelled only when every caller waiting on it has
    /// been cancelled. `onStatus` receives each `LAUNCH_STATUS` update that
    /// arrives while its caller is still waiting: none handled after its
    /// cancellation has been requested.
    func coalescedLaunch(
        _ appID: CastAppID,
        onStatus: (@Sendable (String) -> Void)?,
        _ start: @escaping @Sendable (RequestOptions) async throws -> CastApplication
    ) async throws -> CastApplication {
        try Task.checkCancellation()
        while let abandoned = launchInFlight, abandoned.waiters.isEmpty {
            _ = try? await awaitingCancellation(of: abandoned.task)
            try Task.checkCancellation()
        }
        nextLaunchWaiter += 1
        let waiter = nextLaunchWaiter
        let launchWaiter = LaunchWaiter(onStatus: onStatus)
        let id: Int
        let task: Task<CastApplication, any Error>
        if let launchInFlight {
            guard launchInFlight.appID == appID else { throw CastError.requestInFlight("LAUNCH") }
            id = launchInFlight.id
            task = launchInFlight.task
            self.launchInFlight?.waiters[waiter] = launchWaiter
        } else {
            nextLaunchID += 1
            id = nextLaunchID
            let options = launchRequestOptions(id)
            task = Task { [weak self] in
                do {
                    let application = try await start(options)
                    await self?.endLaunch(id)
                    return application
                } catch {
                    await self?.endLaunch(id)
                    throw error
                }
            }
            launchInFlight = LaunchInFlight(id: id, appID: appID, task: task, waiters: [waiter: launchWaiter])
        }
        defer { leaveLaunch(id, waiter: waiter) }
        return try await withTaskCancellationHandler {
            try await awaitingCancellation(of: task)
        } onCancel: {
            // `leaveLaunch` only runs once this caller is back on the client,
            // so statuses handled before then must already pass it by.
            launchWaiter.depart()
        }
    }

    /// The task of the pending launch, for tests.
    var pendingLaunch: Task<CastApplication, any Error>? { launchInFlight?.task }

    /// How many callers are waiting on the pending launch, for tests.
    var pendingLaunchWaiters: Int { launchInFlight?.waiters.count ?? 0 }

    /// The launch ends as its reply settles the `LAUNCH`, on the same actor
    /// turn, so a call queued behind that reply starts a new launch instead
    /// of joining one whose result is already decided.
    private func launchRequestOptions(_ id: Int) -> RequestOptions {
        RequestOptions(
            exclusive: true,
            acceptsLaunchRequestID: true,
            isFinal: { $0.type != "LAUNCH_STATUS" },
            onUpdate: { client, message in
                guard let status = message.json?["status"]?.stringValue else { return }
                client.deliverLaunchStatus(status, launch: id)
            },
            onSettled: { client in client.endLaunch(id) }
        )
    }

    private func deliverLaunchStatus(_ status: String, launch id: Int) {
        guard let launch = launchInFlight, launch.id == id else { return }
        for waiter in launch.waiters.values where !waiter.hasDeparted { waiter.onStatus?(status) }
    }

    /// Also run from the launch task, for a `start` that fails before its request settles.
    private func endLaunch(_ id: Int) {
        if launchInFlight?.id == id { launchInFlight = nil }
    }

    /// A launch still pending when its last waiter leaves has only cancelled
    /// waiters, since a launch ends before its result is delivered.
    private func leaveLaunch(_ id: Int, waiter: Int) {
        guard launchInFlight?.id == id else { return }
        launchInFlight?.waiters[waiter] = nil
        if launchInFlight?.waiters.isEmpty == true { launchInFlight?.task.cancel() }
    }

    /// Convenience for ``launchMediaApp(_:)`` with the Default Media Receiver.
    public func launchMediaReceiver() async throws -> MediaController {
        try await launchMediaApp(.defaultMediaReceiver)
    }

    // MARK: - Internal

    /// `reasonCode` 5 tells the receiver the sender closed the connection on purpose.
    static let closePayload: JSONValue = ["type": "CLOSE", "reasonCode": 5]

    /// Namespaces that work below virtual connections, so they are accepted from any peer.
    static let transportNamespaces: Set<CastNamespace> = [.connection, .heartbeat, .deviceAuth]

    private static let logger = Logger(subsystem: "SwiftCast", category: "CastClient")

    /// The protocol version the receiver reported in `CONNECTED` for `destination`.
    func negotiatedProtocolVersion(for destination: String) -> Int? {
        protocolVersions[destination]
    }

    /// Only protocol version 0 is advertised because message chunking is not implemented.
    func connectPayload(to destination: String) -> JSONValue {
        let connectionType = destination == CastEndpoint.platformReceiver ? .strong : configuration.applicationConnectionType
        return [
            "type": "CONNECT",
            "userAgent": .string(configuration.userAgent),
            "origin": [:],
            "connType": .number(Double(connectionType.rawValue)),
            "protocolVersion": 0,
            "protocolVersionList": [0],
            "senderInfo": [
                "sdkType": 2,
                "version": .string(Self.version),
                "browserVersion": .string(Self.version),
                "platform": .number(Double(Self.senderPlatform)),
                "systemVersion": .string(Self.systemVersion),
                "connectionType": 1,
            ],
        ]
    }

    @usableFromInline
    static func makeSenderID() -> String {
        "sender-" + UUID().uuidString.lowercased()
    }

    static var defaultUserAgent: String {
        "SwiftCast/\(version) (\(osName) \(systemVersion))"
    }

    static var systemVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    private static var osName: String {
        #if os(macOS)
        "macOS"
        #elseif os(visionOS)
        "visionOS"
        #elseif os(tvOS)
        "tvOS"
        #elseif os(watchOS)
        "watchOS"
        #elseif os(iOS)
        "iOS"
        #elseif os(Linux)
        "Linux"
        #else
        "unknown"
        #endif
    }

    /// The `senderInfo.platform` value. Open screen's message_util.cc uses 2 for iOS,
    /// 4 for macOS and 6 for linux; chromium sends 4 for every apple build and also
    /// uses 6 for linux.
    static var senderPlatform: Int {
        #if os(iOS) || os(tvOS) || os(visionOS)
        2
        #elseif os(macOS)
        4
        #elseif os(Linux)
        6
        #else
        0
        #endif
    }

    func sendJSON(_ json: JSONValue, namespace: CastNamespace, to destination: String) async throws {
        try await sendRaw(Self.makeMessage(json, source: senderID, namespace: namespace, destination: destination))
    }

    func updateReceiverStatus(_ status: ReceiverStatus) {
        receiverStatus = status
        receiverStatusBroadcaster.yield(status)
    }

    private func sendRaw(_ message: CastMessage) async throws {
        guard let transport, state == .connected || state == .connecting else { throw CastError.notConnected }
        try await transport.send(FrameCodec.frame(message))
    }

    private static func makeMessage(_ json: JSONValue, source: String, namespace: CastNamespace, destination: String) throws -> CastMessage {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(json)
        return CastMessage(
            sourceID: source,
            destinationID: destination,
            namespace: namespace.rawValue,
            payload: .string(String(decoding: data, as: UTF8.self))
        )
    }

    private func setState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        stateBroadcaster.yield(newState)
    }

    private func isPending(_ type: String, namespace: CastNamespace, destination: String) -> Bool {
        pending.contains { $0.key.namespace == namespace && $0.key.destination == destination && $0.value.type == type }
    }

    /// Completes the pending request a reply answers, unless its completion
    /// rule treats the reply as an intermediate update.
    private func correlate(_ message: InboundMessage) {
        for case let (id?, isLaunchEcho) in [(message.requestID, false), (message.launchRequestID, true)] where id != 0 {
            let key = PendingKey(namespace: message.namespace, destination: message.sourceID, requestID: id)
            guard let request = pending[key], !isLaunchEcho || request.options.acceptsLaunchRequestID else { continue }
            if request.options.isFinal(message) {
                resolve(key, with: .success(message))
            } else {
                request.options.onUpdate?(self, message)
            }
            return
        }
    }

    private func resolve(_ key: PendingKey, with result: Result<InboundMessage, any Error>) {
        guard let request = pending.removeValue(forKey: key) else { return }
        request.timeoutTask.cancel()
        request.options.onSettled?(self)
        request.continuation.resume(with: result)
    }

    private func ingest(_ chunk: Data, generation: Int) {
        guard generation == self.generation else { return }
        inactivityDeadline = nil
        let output = decoder.append(chunk)
        for message in output.messages {
            handle(InboundMessage(message))
            guard generation == self.generation else { return }
        }
        if let error = output.error {
            teardown(error: error, generation: generation)
        }
    }

    private func handle(_ message: InboundMessage) {
        guard accepts(message) else { return }
        switch message.namespace {
        case .heartbeat:
            if message.type == "PING" {
                let generation = generation
                Task { await sendHeartbeat("PONG", to: message.sourceID, generation: generation) }
            }
            return
        case .connection:
            switch message.type {
            case "CONNECTED":
                if connectedDestinations.contains(message.sourceID), let version = message.json?["protocolVersion"]?.intValue {
                    protocolVersions[message.sourceID] = version
                }
            case "CLOSE":
                connectedDestinations.remove(message.sourceID)
                protocolVersions[message.sourceID] = nil
                if message.sourceID == CastEndpoint.platformReceiver {
                    messageBroadcaster.yield(message)
                    teardown(error: .closedByReceiver, generation: generation)
                    return
                }
            default:
                break
            }
        case .receiver where message.sourceID == CastEndpoint.platformReceiver:
            if message.type == "RECEIVER_STATUS", let status = try? message.json?["status"]?.decode(ReceiverStatus.self) {
                updateReceiverStatus(status)
            }
        default:
            break
        }

        correlate(message)
        messageBroadcaster.yield(message)
    }

    /// Whether an inbound message may be routed at all. Messages for other
    /// senders, or with a payload a Google namespace cannot carry, are dropped
    /// as chromium's and open screen's cast channel code do. Messages from
    /// peers without a virtual connection are dropped too, `*` broadcasts
    /// included. That is stricter than open screen's
    /// virtual_connection_router.cc, which still delivers broadcasts to every
    /// endpoint, but no controller here needs a broadcast from a peer it has
    /// not connected to.
    private func accepts(_ message: InboundMessage) -> Bool {
        let namespace = message.namespace
        guard message.destinationID == senderID || message.destinationID == CastEndpoint.broadcast else {
            Self.logger.debug("Dropping \(namespace.rawValue, privacy: .public) message addressed to \(message.destinationID, privacy: .public)")
            return false
        }
        guard Self.transportNamespaces.contains(namespace) || connectedDestinations.contains(message.sourceID) else {
            Self.logger.debug("Dropping \(namespace.rawValue, privacy: .public) message from \(message.sourceID, privacy: .public), which has no virtual connection")
            return false
        }
        // Device auth is binary by design; every other Google namespace speaks JSON objects.
        if namespace.rawValue.hasPrefix("urn:x-cast:com.google.cast."), namespace != .deviceAuth, message.json?.objectValue == nil {
            Self.logger.debug("Dropping \(namespace.rawValue, privacy: .public) message from \(message.sourceID, privacy: .public) whose payload is not a JSON object")
            return false
        }
        return true
    }

    private func startHeartbeat(generation: Int) {
        heartbeatTask?.cancel()
        nextPing = .now + configuration.effectiveHeartbeatInterval
        let firstWake = nextPing
        heartbeatTask = Task { [weak self] in
            var wake = firstWake
            while !Task.isCancelled {
                try? await Task.sleep(until: wake, clock: .continuous)
                guard !Task.isCancelled, let self, let next = await self.heartbeatTick(generation: generation) else { return }
                wake = next
            }
        }
    }

    /// Sends a `PING` when one is due and enforces the inactivity deadline.
    /// Returns when the heartbeat loop should wake next, or `nil` to stop it.
    ///
    /// The `PING` is written from its own task so a write that never
    /// completes cannot hold up the deadline check.
    private func heartbeatTick(generation: Int) -> ContinuousClock.Instant? {
        guard generation == self.generation, state == .connected else { return nil }
        let now = ContinuousClock.now
        if let inactivityDeadline, now >= inactivityDeadline {
            teardown(error: .heartbeatTimeout, generation: generation)
            return nil
        }
        if now >= nextPing {
            nextPing = now + configuration.effectiveHeartbeatInterval
            if inactivityDeadline == nil {
                inactivityDeadline = now + configuration.effectiveInactivityTimeout
            }
            Task { await sendHeartbeat("PING", to: CastEndpoint.platformReceiver, generation: generation) }
        }
        guard let inactivityDeadline else { return nextPing }
        return min(nextPing, inactivityDeadline)
    }

    /// A failed heartbeat write means the socket is unusable, so the client
    /// is torn down at once instead of waiting for the inactivity timeout.
    ///
    /// The send is dropped when the connection it was scheduled for has
    /// already been replaced, so it never goes out on a newer transport.
    private func sendHeartbeat(_ type: String, to destination: String, generation: Int) async {
        guard generation == self.generation else { return }
        do {
            try await sendJSON(["type": .string(type)], namespace: .heartbeat, to: destination)
        } catch {
            let reason = if case .connectionFailed(let message)? = error as? CastError { message } else { error.localizedDescription }
            teardown(error: .connectionFailed("heartbeat write failed: \(reason)"), generation: generation)
        }
    }

    private func teardown(error: CastError?, generation: Int) {
        guard generation == self.generation, state == .connected || state == .connecting else { return }
        self.generation += 1
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        transport?.close()
        transport = nil
        connectedDestinations = []
        connectsInFlight = [:]
        launchInFlight = nil
        protocolVersions = [:]
        let failures = pending
        pending = [:]
        for request in failures.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error ?? CastError.notConnected)
        }
        setState(.closed(error))
        finishStreams()
    }

    /// Ends every current subscription once `.closed` has been yielded, so a
    /// watcher left on a dead connection does not keep the client alive.
    /// Subscriptions made before the next ``connect()`` end at once too, as
    /// nothing would ever end them otherwise.
    private func finishStreams() {
        messageBroadcaster.close()
        guard !keepsObservationStreamsOpenOnClose else { return }
        stateBroadcaster.close()
        receiverStatusBroadcaster.close()
    }

    private func reopenStreams() {
        messageBroadcaster.reopen()
        stateBroadcaster.reopen()
        receiverStatusBroadcaster.reopen()
    }

    /// Leaves ``stateUpdates()`` and ``receiverStatusUpdates()`` streams open
    /// across a close, so tests can check that a watcher is released by
    /// whoever owns it rather than by the stream ending.
    private(set) var keepsObservationStreamsOpenOnClose = false

    func keepObservationStreamsOpenOnClose() {
        keepsObservationStreamsOpenOnClose = true
    }

    /// How many ``stateUpdates()`` and ``receiverStatusUpdates()`` streams are open, for tests.
    var observationSubscriberCount: Int {
        stateBroadcaster.subscriberCount + receiverStatusBroadcaster.subscriberCount
    }

    static func standardError(in message: InboundMessage) -> CastError? {
        guard message.namespace == .receiver || message.namespace == .media, let type = message.type else { return nil }
        switch type {
        case "LAUNCH_ERROR":
            let reason = ["extendedError", "error", "reason"].lazy.compactMap { message.json?[$0]?.stringValue }.first
            return .launchFailed(reason: reason)
        case "INVALID_REQUEST": return .invalidRequest(MediaErrorInfo(message))
        case "LOAD_FAILED": return .loadFailed(MediaErrorInfo(message))
        case "LOAD_CANCELLED": return .loadCancelled(MediaErrorInfo(message))
        case "INVALID_PLAYER_STATE": return .invalidPlayerState(MediaErrorInfo(message))
        case "ERROR" where message.namespace == .media: return .mediaError(MediaErrorInfo(message))
        default: return nil
        }
    }
}

private enum JoinState<Success: Sendable>: Sendable {
    case waiting
    case suspended(CheckedContinuation<Success, any Error>)
    case finished
}

/// Waits for `task` without owning it, since `Task.value` ignores the
/// waiter's cancellation: a cancelled waiter throws `CancellationError`
/// promptly and `task` keeps running for its other callers.
@discardableResult
private func awaitingCancellation<Success: Sendable>(of task: Task<Success, any Error>) async throws -> Success {
    let state = OSAllocatedUnfairLock<JoinState<Success>>(initialState: .waiting)
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Success, any Error>) in
            let cancelled = state.withLock { state -> Bool in
                guard case .waiting = state else { return true }
                state = .suspended(continuation)
                return false
            }
            guard !cancelled else { return continuation.resume(throwing: CancellationError()) }
            Task {
                let result = await task.result
                state.withLock { state -> CheckedContinuation<Success, any Error>? in
                    guard case .suspended(let continuation) = state else { return nil }
                    state = .finished
                    return continuation
                }?.resume(with: result)
            }
        }
    } onCancel: {
        state.withLock { state -> CheckedContinuation<Success, any Error>? in
            defer { state = .finished }
            guard case .suspended(let continuation) = state else { return nil }
            return continuation
        }?.resume(throwing: CancellationError())
    }
}

/// A caller waiting on a launch. It is marked departed by its cancellation
/// handler, synchronously, so status fan-out skips it at once.
private final class LaunchWaiter: Sendable {
    let onStatus: (@Sendable (String) -> Void)?
    private let departed = OSAllocatedUnfairLock(initialState: false)

    init(onStatus: (@Sendable (String) -> Void)?) {
        self.onStatus = onStatus
    }

    var hasDeparted: Bool { departed.withLock { $0 } }

    func depart() { departed.withLock { $0 = true } }
}

/// Lets closes wait for an in-flight open without owning its write.
/// `Task.value` ignores the waiter's cancellation, so a cancelled waiter is
/// resumed and dropped here at once instead of lingering until the write ends.
private final class OpenCompletion: Sendable {
    private struct State: Sendable {
        var result: Result<Void, any Error>?
        var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
        var cancelled: Set<Int> = []
        var nextID = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var waiterCount: Int { state.withLock { $0.waiters.count } }

    func finish(_ result: Result<Void, any Error>) {
        let waiters = state.withLock { state in
            state.result = result
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume(with: result) }
    }

    func wait() async throws {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let ready = state.withLock { state -> Result<Void, any Error>? in
                    if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if let result = state.result { return result }
                    state.waiters[id] = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            // Each continuation is taken out under the lock exactly once, by
            // either this handler or `finish`, so it is never resumed twice.
            state.withLock { state -> CheckedContinuation<Void, any Error>? in
                if let waiter = state.waiters.removeValue(forKey: id) { return waiter }
                state.cancelled.insert(id)
                return nil
            }?.resume(throwing: CancellationError())
        }
    }
}
