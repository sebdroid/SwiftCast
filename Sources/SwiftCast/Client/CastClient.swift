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

    private struct PendingRequest {
        let continuation: CheckedContinuation<InboundMessage, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private let makeTransport: @Sendable () -> any CastTransport
    private var transport: (any CastTransport)?
    private var generation = 0
    private var decoder = FrameDecoder()
    private var pending: [PendingKey: PendingRequest] = [:]
    private var nextRequestID = 1
    private var connectedDestinations: Set<String> = []
    private var connectsInFlight: [String: Task<Void, any Error>] = [:]
    private var protocolVersions: [String: Int] = [:]
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
        setState(.connecting)
        decoder = FrameDecoder()
        connectedDestinations = []
        connectsInFlight = [:]
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
    public func stateUpdates() -> AsyncStream<State> {
        stateBroadcaster.subscribe(initial: state)
    }

    /// Streams receiver status updates, starting with the latest known status.
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
    /// Streams end when the connection closes.
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
    /// Standard Cast error responses (`LAUNCH_ERROR`, `LOAD_FAILED`,
    /// `INVALID_REQUEST`, …) are thrown as ``CastError``.
    public func request(
        _ payload: some Encodable & Sendable,
        namespace: CastNamespace,
        to destination: String,
        timeout: Duration? = nil
    ) async throws -> InboundMessage {
        guard state == .connected || state == .connecting else { throw CastError.notConnected }
        guard case .object(var object) = try JSONValue(encoding: payload) else {
            throw CastError.invalidPayload("Request payload must be a JSON object")
        }
        let requestID = nextRequestID
        nextRequestID = nextRequestID == Int32.max ? 1 : nextRequestID + 1
        let key = PendingKey(namespace: namespace, destination: destination, requestID: requestID)
        object["requestId"] = .number(Double(requestID))
        let message = try Self.makeMessage(JSONValue.object(object), source: senderID, namespace: namespace, destination: destination)
        let timeout = timeout ?? configuration.requestTimeout

        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<InboundMessage, any Error>) in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.resolve(key, with: .failure(CastError.timeout))
                }
                pending[key] = PendingRequest(continuation: continuation, timeoutTask: timeoutTask)
                if Task.isCancelled {
                    // The cancellation handler may have run before registration.
                    resolve(key, with: .failure(CancellationError()))
                    return
                }
                Task {
                    do {
                        try await self.sendRaw(message)
                    } catch {
                        self.resolve(key, with: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { await self.resolve(key, with: .failure(CancellationError())) }
        }

        if let error = Self.standardError(in: response) { throw error }
        return response
    }

    // MARK: - Virtual connections

    /// Opens a virtual connection to `destination` (e.g. an app's `transportId`).
    /// Does nothing if one is already open. A call made while another is still
    /// opening the same connection waits for it and shares its result.
    public func openVirtualConnection(to destination: String) async throws {
        if let inFlight = connectsInFlight[destination] {
            return try await inFlight.value
        }
        guard !connectedDestinations.contains(destination) else { return }
        let generation = generation
        // Registered before the write so a message the peer sends as soon as
        // it sees CONNECT is not dropped as coming from an unknown peer.
        connectedDestinations.insert(destination)
        let payload = connectPayload(to: destination)
        let write = Task { try await sendJSON(payload, namespace: .connection, to: destination) }
        connectsInFlight[destination] = write
        defer {
            if self.generation == generation, connectsInFlight[destination] == write { connectsInFlight[destination] = nil }
        }
        do {
            try await write.value
        } catch {
            // After a reconnect the entry belongs to the new connection.
            if self.generation == generation {
                connectedDestinations.remove(destination)
                protocolVersions[destination] = nil
            }
            throw error
        }
    }

    /// Closes the virtual connection to `destination`. If the connection is
    /// still opening, this waits for the open to finish first.
    public func closeVirtualConnection(to destination: String) async {
        if let inFlight = connectsInFlight[destination] {
            let generation = generation
            _ = try? await inFlight.value
            guard self.generation == generation else { return }
        }
        guard connectedDestinations.remove(destination) != nil else { return }
        protocolVersions[destination] = nil
        try? await sendJSON(Self.closePayload, namespace: .connection, to: destination)
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
    public func mediaController(for application: CastApplication) async throws -> MediaController {
        try await openVirtualConnection(to: application.transportId)
        let controller = MediaController(client: self, application: application)
        await controller.start()
        _ = try? await controller.refreshStatus()
        return controller
    }

    /// Joins `appID` if it is already running, otherwise launches it, and
    /// returns a media controller for it.
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

    private func resolve(_ key: PendingKey, with result: Result<InboundMessage, any Error>) {
        guard let request = pending.removeValue(forKey: key) else { return }
        request.timeoutTask.cancel()
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

        if let requestID = message.requestID, requestID != 0 {
            resolve(PendingKey(namespace: message.namespace, destination: message.sourceID, requestID: requestID), with: .success(message))
        }
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
        protocolVersions = [:]
        let failures = pending
        pending = [:]
        for request in failures.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error ?? CastError.notConnected)
        }
        setState(.closed(error))
        messageBroadcaster.finishAll()
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
