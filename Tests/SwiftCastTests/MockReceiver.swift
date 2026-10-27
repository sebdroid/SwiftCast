import Foundation
import os
@testable import SwiftCast

/// An in-memory Cast device that speaks the framed protocol.
final class MockReceiver: CastTransport, @unchecked Sendable {
    typealias Handler = @Sendable (InboundMessage, MockReceiver) -> Void

    private struct State {
        var decoder = FrameDecoder()
        var sent: [InboundMessage] = []
        var handlers: [String: Handler] = [:]
        var openError: CastError?
        var sendFailures: [String: CastError] = [:]
        var heldTypes: Set<String> = []
        var heldSends: [CheckedContinuation<Void, any Error>] = []
        var isOpen = false
        var clientID: String?
        var isClosed = false
        var answersPings = true
        var failsHeldSendsOnClose = true
    }

    private enum HoldOutcome { case proceed, fail, held }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    let inbound: AsyncThrowingStream<Data, any Error>
    /// Automatically answer heartbeat PINGs from the client.
    var answersPings: Bool {
        get { state.withLock { $0.answersPings } }
        set { state.withLock { $0.answersPings = newValue } }
    }

    /// Whether ``close()`` fails held sends straight away. `NWConnection`
    /// completes outstanding sends with an error some time after it is
    /// cancelled; turning this off leaves them held until
    /// ``releaseHeldSends()`` so a test can choose when that failure lands.
    var failsHeldSendsOnClose: Bool {
        get { state.withLock { $0.failsHeldSendsOnClose } }
        set { state.withLock { $0.failsHeldSendsOnClose = newValue } }
    }

    /// What `NetworkTransport` surfaces for a send that `NWConnection`
    /// cancels (`ECANCELED`).
    static let cancelledSendError = CastError.connectionFailed("Operation canceled")

    init() {
        (inbound, continuation) = AsyncThrowingStream.makeStream()
    }

    var isOpen: Bool { state.withLock { $0.isOpen } }

    /// Messages the client sent to the device, in order.
    var sentMessages: [InboundMessage] { state.withLock { $0.sent } }

    func sentMessages(ofType type: String) -> [InboundMessage] {
        sentMessages.filter { $0.type == type }
    }

    /// Registers a handler for requests of the given `type`.
    func on(_ type: String, _ handler: @escaping Handler) {
        state.withLock { $0.handlers[type] = handler }
    }

    func failOpen(with error: CastError) {
        state.withLock { $0.openError = error }
    }

    /// Makes sends of messages of the given `type` throw `error`. The failed
    /// message is still recorded in ``sentMessages``.
    func failSends(ofType type: String, with error: CastError) {
        state.withLock { $0.sendFailures[type] = error }
    }

    /// Makes sends of messages of the given `type` wait, after being
    /// recorded, until ``releaseHeldSends()`` or ``close()`` is called.
    func holdSends(ofType type: String) {
        state.withLock { _ = $0.heldTypes.insert(type) }
    }

    /// The number of sends currently parked by ``holdSends(ofType:)``. A send
    /// is recorded in ``sentMessages`` before it parks, so tests that need a
    /// send to be held wait on this rather than on the message count.
    var heldSendCount: Int {
        state.withLock { $0.heldSends.count }
    }

    /// Completes every held send, failing them with ``cancelledSendError``
    /// once the mock has been closed. `evenIfClosed` completes them
    /// successfully regardless, like a write that finished just before the
    /// connection was cancelled but whose completion arrives late.
    func releaseHeldSends(evenIfClosed: Bool = false) {
        let (held, closed) = state.withLock { state in
            state.heldTypes = []
            defer { state.heldSends = [] }
            return (state.heldSends, state.isClosed)
        }
        for continuation in held {
            if closed, !evenIfClosed { continuation.resume(throwing: Self.cancelledSendError) } else { continuation.resume() }
        }
    }

    // MARK: CastTransport

    func open() async throws {
        if let error = state.withLock({ $0.openError }) { throw error }
        state.withLock { $0.isOpen = true }
    }

    func send(_ data: Data) async throws {
        let output = state.withLock { $0.decoder.append(data) }
        for message in output.messages {
            let inbound = InboundMessage(message)
            let type = inbound.type ?? ""
            let (handler, failure, held, answersPings) = state.withLock { state -> (Handler?, CastError?, Bool, Bool) in
                state.sent.append(inbound)
                if state.clientID == nil { state.clientID = inbound.sourceID }
                return (state.handlers[type], state.sendFailures[type], state.heldTypes.contains(type), state.answersPings)
            }
            if held {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    // `held` is only a hint: a close or release can land before
                    // this point, so the outcome is decided and the continuation
                    // registered in one transition against the current state.
                    let outcome = state.withLock { state -> HoldOutcome in
                        if state.isClosed, state.failsHeldSendsOnClose { return .fail }
                        if state.heldTypes.contains(type) {
                            state.heldSends.append(continuation)
                            return .held
                        }
                        return state.isClosed ? .fail : .proceed
                    }
                    switch outcome {
                    case .proceed: continuation.resume()
                    case .fail: continuation.resume(throwing: Self.cancelledSendError)
                    case .held: break
                    }
                }
            }
            if let failure { throw failure }
            if inbound.namespace == .heartbeat, inbound.type == "PING", answersPings {
                reply(to: inbound, ["type": "PONG"])
            }
            handler?(inbound, self)
        }
        if let error = output.error { throw error }
    }

    func close() {
        let held = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.isOpen = false
            state.isClosed = true
            guard state.failsHeldSendsOnClose else { return [] }
            defer { state.heldSends = [] }
            return state.heldSends
        }
        for continuation in held { continuation.resume(throwing: Self.cancelledSendError) }
        continuation.finish()
    }

    // MARK: Device → client

    /// The sender id the client uses, learned from the first message it sent.
    var clientID: String? { state.withLock { $0.clientID } }

    /// Sends a JSON message from `source` to the client. `destination`
    /// defaults to the client's own sender id, or `*` before it is known.
    func push(_ json: JSONValue, namespace: CastNamespace, from source: String = CastEndpoint.platformReceiver, to destination: String? = nil) {
        let data = try! JSONEncoder().encode(json)
        push(payload: .string(String(decoding: data, as: UTF8.self)), namespace: namespace, from: source, to: destination)
    }

    /// Sends a message with an arbitrary payload, such as malformed JSON or binary data.
    func push(payload: CastMessage.Payload, namespace: CastNamespace, from source: String = CastEndpoint.platformReceiver, to destination: String? = nil) {
        let destination = destination ?? clientID ?? CastEndpoint.broadcast
        let message = CastMessage(sourceID: source, destinationID: destination, namespace: namespace.rawValue, payload: payload)
        continuation.yield(try! FrameCodec.frame(message))
    }

    /// Replies to a request, echoing its `requestId`.
    func reply(to request: InboundMessage, _ json: JSONValue) {
        var object = json.objectValue ?? [:]
        if let id = request.requestID { object["requestId"] = .number(Double(id)) }
        push(.object(object), namespace: request.namespace, from: request.destinationID, to: request.sourceID)
    }

    /// Simulates the connection dropping.
    func drop(with error: (any Error)? = nil) {
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }

    /// Sends raw bytes to the client.
    func pushRaw(_ data: Data) {
        continuation.yield(data)
    }
}

// MARK: - Fixtures

enum Fixtures {
    static let transportID = "web-5"
    static let sessionID = "8F9D1A2B-0000-4E1F-B6C1-6D4B9C1A5E77"

    static let mediaApp: JSONValue = [
        "appId": "CC1AD845",
        "displayName": "Default Media Receiver",
        "sessionId": .string(sessionID),
        "transportId": .string(transportID),
        "statusText": "Ready To Cast",
        "isIdleScreen": false,
        "namespaces": [["name": "urn:x-cast:com.google.cast.media"], ["name": "urn:x-cast:com.google.cast.cac"]],
    ]

    static func receiverStatus(apps: [JSONValue] = [], level: Double = 0.5) -> JSONValue {
        var status: [String: JSONValue] = ["volume": ["level": .number(level), "muted": false, "controlType": "attenuation", "stepInterval": 0.05]]
        if !apps.isEmpty { status["applications"] = .array(apps) }
        return ["type": "RECEIVER_STATUS", "status": .object(status)]
    }

    static func mediaStatus(sessionID: Int = 1, state: String = "PLAYING", time: Double = 0, includeMedia: Bool = true) -> JSONValue {
        var status: [String: JSONValue] = [
            "mediaSessionId": .number(Double(sessionID)),
            "playbackRate": 1,
            "playerState": .string(state),
            "currentTime": .number(time),
            "supportedMediaCommands": 12303,
            "volume": ["level": 1, "muted": false],
        ]
        if includeMedia {
            status["media"] = [
                "contentId": "https://example.com/video.mp4",
                "streamType": "BUFFERED",
                "contentType": "video/mp4",
                "duration": 596.5,
                "metadata": ["metadataType": 1, "title": "Big Buck Bunny"],
            ]
        }
        return ["type": "MEDIA_STATUS", "status": [.object(status)]]
    }

    /// Installs handlers that emulate a device running the Default Media Receiver.
    static func installDefaultReceiver(on mock: MockReceiver, appRunning: Bool = false) {
        let running = OSAllocatedUnfairLock(initialState: appRunning)
        let mediaSession = OSAllocatedUnfairLock(initialState: 0)
        mock.on("GET_STATUS") { request, mock in
            if request.namespace == .receiver {
                mock.reply(to: request, receiverStatus(apps: running.withLock { $0 } ? [mediaApp] : []))
            } else if request.namespace == .media {
                let id = mediaSession.withLock { $0 }
                mock.reply(to: request, id == 0 ? ["type": "MEDIA_STATUS", "status": []] : mediaStatus(sessionID: id, includeMedia: true))
            }
        }
        mock.on("LAUNCH") { request, mock in
            running.withLock { $0 = true }
            mock.reply(to: request, receiverStatus(apps: [mediaApp]))
        }
        mock.on("LOAD") { request, mock in
            let id = mediaSession.withLock { $0 += 1; return $0 }
            mock.reply(to: request, mediaStatus(sessionID: id, state: "BUFFERING", time: request.json?["currentTime"]?.doubleValue ?? 0))
        }
        mock.on("PAUSE") { request, mock in
            mock.reply(to: request, mediaStatus(sessionID: mediaSession.withLock { $0 }, state: "PAUSED", time: 42, includeMedia: false))
        }
        mock.on("PLAY") { request, mock in
            mock.reply(to: request, mediaStatus(sessionID: mediaSession.withLock { $0 }, state: "PLAYING", time: 42, includeMedia: false))
        }
        mock.on("SEEK") { request, mock in
            mock.reply(to: request, mediaStatus(sessionID: mediaSession.withLock { $0 }, state: "PLAYING", time: request.json?["currentTime"]?.doubleValue ?? 0, includeMedia: false))
        }
    }
}
