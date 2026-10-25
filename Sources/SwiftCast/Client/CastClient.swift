import Foundation
import Network

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

    /// Tunable client behavior.
    public struct Configuration: Sendable {
        /// Interval between heartbeat `PING`s.
        public var heartbeatInterval: Duration = .seconds(5)
        /// The connection is considered dead after this long without any inbound traffic.
        public var heartbeatTimeout: Duration = .seconds(16)
        /// Default time to wait for a response to a request.
        public var requestTimeout: Duration = .seconds(15)
        /// Sent in the `CONNECT` message.
        public var userAgent: String = "SwiftCast/1.0"

        public init() {}
    }

    /// The source ID used for messages sent by this client.
    public nonisolated let senderID: String
    public nonisolated let configuration: Configuration

    public private(set) var state: State = .disconnected
    /// The most recent receiver status (from a request or broadcast).
    public private(set) var receiverStatus: ReceiverStatus?

    private struct PendingRequest {
        let continuation: CheckedContinuation<InboundMessage, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private let makeTransport: @Sendable () -> any CastTransport
    private var transport: (any CastTransport)?
    private var generation = 0
    private var decoder = FrameDecoder()
    private var pending: [Int: PendingRequest] = [:]
    private var nextRequestID = 1
    private var connectedDestinations: Set<String> = []
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var lastInbound = ContinuousClock.now

    private let messageBroadcaster = Broadcaster<InboundMessage>()
    private let stateBroadcaster = Broadcaster<State>()
    private let receiverStatusBroadcaster = Broadcaster<ReceiverStatus>()

    // MARK: - Initialization

    /// Creates a client whose transport is produced by `makeTransport` on each
    /// call to ``connect()``, allowing the client to reconnect.
    public init(
        senderID: String = "sender-0",
        configuration: Configuration = Configuration(),
        makeTransport: @escaping @Sendable () -> any CastTransport
    ) {
        self.senderID = senderID
        self.configuration = configuration
        self.makeTransport = makeTransport
    }

    /// Creates a client for a discovered device.
    public init(device: CastDevice, senderID: String = "sender-0", configuration: Configuration = Configuration()) {
        let endpoint = device.endpoint
        self.init(senderID: senderID, configuration: configuration) {
            NetworkTransport(endpoint: endpoint)
        }
    }

    /// Creates a client for a device at a known host and port.
    public init(host: String, port: UInt16 = 8009, senderID: String = "sender-0", configuration: Configuration = Configuration()) {
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

        lastInbound = .now
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
            let close = CastMessage(
                sourceID: senderID,
                destinationID: destination,
                namespace: CastNamespace.connection.rawValue,
                payload: .string(#"{"type":"CLOSE"}"#)
            )
            try? await transport.send(FrameCodec.frame(close))
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

    /// Streams every inbound message, optionally filtered to one namespace.
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
        object["requestId"] = .number(Double(requestID))
        let message = try Self.makeMessage(JSONValue.object(object), source: senderID, namespace: namespace, destination: destination)
        let timeout = timeout ?? configuration.requestTimeout

        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<InboundMessage, any Error>) in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.resolve(requestID, with: .failure(CastError.timeout))
                }
                pending[requestID] = PendingRequest(continuation: continuation, timeoutTask: timeoutTask)
                if Task.isCancelled {
                    // The cancellation handler may have run before registration.
                    resolve(requestID, with: .failure(CancellationError()))
                    return
                }
                Task {
                    do {
                        try await self.sendRaw(message)
                    } catch {
                        self.resolve(requestID, with: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { await self.resolve(requestID, with: .failure(CancellationError())) }
        }

        if let error = Self.standardError(in: response) { throw error }
        return response
    }

    // MARK: - Virtual connections

    /// Opens a virtual connection to `destination` (e.g. an app's `transportId`).
    /// Does nothing if one is already open.
    public func openVirtualConnection(to destination: String) async throws {
        guard !connectedDestinations.contains(destination) else { return }
        let payload: JSONValue = [
            "type": "CONNECT",
            "origin": [:],
            "userAgent": .string(configuration.userAgent),
            "senderInfo": [
                "sdkType": 2,
                "version": "15.605.1.3",
                "browserVersion": "44.0.2403.30",
                "platform": 4,
                "connectionType": 1,
            ],
        ]
        try await sendJSON(payload, namespace: .connection, to: destination)
        connectedDestinations.insert(destination)
    }

    /// Closes the virtual connection to `destination`.
    public func closeVirtualConnection(to destination: String) async {
        guard connectedDestinations.remove(destination) != nil else { return }
        try? await sendJSON(["type": "CLOSE"], namespace: .connection, to: destination)
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

    private func resolve(_ requestID: Int, with result: Result<InboundMessage, any Error>) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(with: result)
    }

    private func ingest(_ chunk: Data, generation: Int) {
        guard generation == self.generation else { return }
        lastInbound = .now
        let messages: [CastMessage]
        do {
            messages = try decoder.append(chunk)
        } catch {
            teardown(error: (error as? CastError) ?? .malformedMessage("\(error)"), generation: generation)
            return
        }
        for message in messages {
            handle(InboundMessage(message))
            guard generation == self.generation else { return }
        }
    }

    private func handle(_ message: InboundMessage) {
        switch message.namespace {
        case .heartbeat:
            if message.type == "PING" {
                Task { try? await sendJSON(["type": "PONG"], namespace: .heartbeat, to: message.sourceID) }
            }
            return
        case .connection:
            if message.type == "CLOSE" {
                connectedDestinations.remove(message.sourceID)
                if message.sourceID == CastEndpoint.platformReceiver {
                    messageBroadcaster.yield(message)
                    teardown(error: .connectionFailed("Connection closed by device"), generation: generation)
                    return
                }
            }
        case .receiver:
            if message.type == "RECEIVER_STATUS", let status = try? message.json?["status"]?.decode(ReceiverStatus.self) {
                updateReceiverStatus(status)
            }
        default:
            break
        }

        if let requestID = message.requestID, requestID != 0, pending[requestID] != nil {
            resolve(requestID, with: .success(message))
        }
        messageBroadcaster.yield(message)
    }

    private func startHeartbeat(generation: Int) {
        heartbeatTask?.cancel()
        let interval = configuration.heartbeatInterval
        let timeout = configuration.heartbeatTimeout
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                guard await self.heartbeatTick(generation: generation, timeout: timeout) else { return }
            }
        }
    }

    /// Returns `false` when the heartbeat loop should stop.
    private func heartbeatTick(generation: Int, timeout: Duration) async -> Bool {
        guard generation == self.generation, state == .connected else { return false }
        if ContinuousClock.now - lastInbound > timeout {
            teardown(error: .heartbeatTimeout, generation: generation)
            return false
        }
        try? await sendJSON(["type": "PING"], namespace: .heartbeat, to: CastEndpoint.platformReceiver)
        return true
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
