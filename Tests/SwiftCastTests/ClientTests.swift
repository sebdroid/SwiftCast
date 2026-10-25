import Foundation
import Testing
@testable import SwiftCast

@Suite("CastClient", .timeLimit(.minutes(1)))
struct ClientTests {
    func makeClient(_ mock: MockReceiver, configure: (inout CastClient.Configuration) -> Void = { _ in }) -> CastClient {
        var configuration = CastClient.Configuration()
        configure(&configuration)
        return CastClient(configuration: configuration) { mock }
    }

    @Test func connectOpensPlatformVirtualConnection() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        #expect(await client.state == .connected)
        let connect = try #require(mock.sentMessages(ofType: "CONNECT").first)
        #expect(connect.destinationID == "receiver-0")
        #expect(connect.namespace == .connection)
        #expect(await client.isConnected(to: "receiver-0"))
    }

    @Test func connectFailurePropagatesAndAllowsRetry() async throws {
        let failing = MockReceiver()
        failing.failOpen(with: .connectionFailed("refused"))
        let working = MockReceiver()
        let attempts = Counter()
        let client = CastClient { attempts.increment() == 1 ? failing : working }

        await #expect(throws: CastError.connectionFailed("refused")) { try await client.connect() }
        #expect(await client.state == .closed(.connectionFailed("refused")))
        try await client.connect()
        #expect(await client.state == .connected)
    }

    @Test func requestsAreCorrelatedByRequestID() async throws {
        let mock = MockReceiver()
        Fixtures.installDefaultReceiver(on: mock)
        let client = makeClient(mock)
        try await client.connect()

        // Unrelated broadcast in between must not satisfy the request.
        mock.push(Fixtures.receiverStatus(level: 0.9), namespace: .receiver, to: "*")
        async let a = client.receiver.getStatus()
        async let b = client.receiver.getStatus()
        let (first, second) = try await (a, b)
        #expect(first.volume?.level == 0.5)
        #expect(second.volume?.level == 0.5)
        let ids = Set(mock.sentMessages(ofType: "GET_STATUS").compactMap(\.requestID))
        #expect(ids.count == 2)
    }

    @Test func requestTimesOut() async throws {
        let mock = MockReceiver() // no handlers → never replies
        let client = makeClient(mock)
        try await client.connect()
        await #expect(throws: CastError.timeout) {
            _ = try await client.request(["type": "GET_STATUS"] as JSONValue, namespace: .receiver, to: "receiver-0", timeout: .milliseconds(100))
        }
        #expect(await client.state == .connected)
    }

    @Test func requestIsCancellable() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        let task = Task {
            try await client.request(["type": "GET_STATUS"] as JSONValue, namespace: .receiver, to: "receiver-0", timeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func respondsToReceiverPings() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.push(["type": "PING"], namespace: .heartbeat)
        try await eventually { mock.sentMessages(ofType: "PONG").count == 1 }
        #expect(mock.sentMessages(ofType: "PONG").first?.destinationID == "receiver-0")
    }

    @Test func sendsHeartbeatsAndDetectsDeadConnection() async throws {
        let mock = MockReceiver()
        mock.answersPings = false
        let client = makeClient(mock) {
            $0.heartbeatInterval = .milliseconds(50)
            $0.heartbeatTimeout = .milliseconds(300)
        }
        try await client.connect()
        let states = await client.stateUpdates()
        try await eventually { mock.sentMessages(ofType: "PING").count >= 2 }
        var sawTimeout = false
        for await state in states where state == .closed(.heartbeatTimeout) {
            sawTimeout = true
            break
        }
        #expect(sawTimeout)
    }

    @Test func heartbeatKeepsHealthyConnectionAlive() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock) {
            $0.heartbeatInterval = .milliseconds(30)
            $0.heartbeatTimeout = .milliseconds(200)
        }
        try await client.connect()
        try await Task.sleep(for: .milliseconds(600))
        #expect(await client.state == .connected)
        #expect(mock.sentMessages(ofType: "PING").count >= 5)
    }

    @Test func connectionLossFailsPendingRequests() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        let request = Task {
            try await client.request(["type": "GET_STATUS"] as JSONValue, namespace: .receiver, to: "receiver-0")
        }
        try await Task.sleep(for: .milliseconds(50))
        mock.drop(with: CastError.connectionFailed("reset"))
        await #expect(throws: CastError.connectionFailed("reset")) { try await request.value }
        #expect(await client.state == .closed(.connectionFailed("reset")))
        await #expect(throws: CastError.notConnected) { try await client.receiver.getStatus() }
    }

    @Test func receiverCloseTearsDownClient() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.push(["type": "CLOSE"], namespace: .connection)
        try await eventually { await client.state != .connected }
        #expect(await client.state == .closed(.connectionFailed("Connection closed by device")))
    }

    @Test func malformedFrameClosesConnection() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.pushRaw(Data([0, 0, 0, 3, 0xFF, 0xFF, 0xFF]))
        try await eventually { await client.state != .connected }
        guard case .closed(.malformedMessage) = await client.state else {
            Issue.record("Expected malformedMessage, got \(await client.state)")
            return
        }
    }

    @Test func disconnectClosesVirtualConnectionsAndCanReconnect() async throws {
        let mocks = [MockReceiver(), MockReceiver()]
        let index = Counter()
        let client = CastClient { mocks[index.increment() - 1] }
        try await client.connect()
        await client.disconnect()
        #expect(await client.state == .closed(nil))
        #expect(mocks[0].sentMessages(ofType: "CLOSE").first?.destinationID == "receiver-0")
        try await client.connect()
        #expect(await client.state == .connected)
        #expect(mocks[1].sentMessages(ofType: "CONNECT").count == 1)
    }

    @Test func receiverStatusBroadcastsUpdateCache() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        let updates = await client.receiverStatusUpdates()
        mock.push(Fixtures.receiverStatus(level: 0.25), namespace: .receiver, to: "*")
        for await status in updates {
            #expect(status.volume?.level == 0.25)
            break
        }
        #expect(await client.receiverStatus?.volume?.level == 0.25)
    }

    @Test func outOfRangeRequestIDDoesNotCrashClient() async throws {
        let mock = MockReceiver()
        Fixtures.installDefaultReceiver(on: mock)
        let client = makeClient(mock)
        try await client.connect()
        let updates = await client.receiverStatusUpdates()
        let payload = #"{"requestId":9223372036854775808,"type":"RECEIVER_STATUS","status":{"volume":{"level":0.75,"muted":false}}}"#
        let message = CastMessage(sourceID: CastEndpoint.platformReceiver, destinationID: "*", namespace: CastNamespace.receiver.rawValue, payload: .string(payload))
        mock.pushRaw(FrameCodec.frame(message))
        for await status in updates {
            #expect(status.volume?.level == 0.75)
            break
        }
        #expect(await client.state == .connected)
        let status = try await client.receiver.getStatus()
        #expect(status.volume?.level == 0.5)
    }

    @Test func launchRequestIDResolvesRequest() async throws {
        let mock = MockReceiver()
        mock.on("LAUNCH") { request, mock in
            var status = Fixtures.receiverStatus(apps: [Fixtures.mediaApp]).objectValue ?? [:]
            if let id = request.requestID { status["launchRequestId"] = .number(Double(id)) }
            mock.push(.object(status), namespace: .receiver, to: "*")
        }
        let client = makeClient(mock)
        try await client.connect()
        let reply = try await client.request(["type": "LAUNCH", "appId": "CC1AD845"] as JSONValue, namespace: .receiver, to: "receiver-0", timeout: .seconds(2))
        #expect(reply.type == "RECEIVER_STATUS")
        #expect(reply.json?["requestId"] == nil)
    }

    @Test func mapsStandardErrorResponses() async throws {
        let mock = MockReceiver()
        mock.on("LAUNCH") { request, mock in
            mock.reply(to: request, ["type": "LAUNCH_ERROR", "reason": "NOT_FOUND"])
        }
        let client = makeClient(mock)
        try await client.connect()
        await #expect(throws: CastError.launchFailed(reason: "NOT_FOUND")) {
            _ = try await client.receiver.launch("BADAPP00")
        }
    }

    @Test func launchWaitsForLateApplicationStatus() async throws {
        let mock = MockReceiver()
        mock.on("LAUNCH") { request, mock in
            // Reply without the app, then broadcast once it has started.
            mock.reply(to: request, Fixtures.receiverStatus())
            mock.push(Fixtures.receiverStatus(apps: [Fixtures.mediaApp]), namespace: .receiver, to: "*")
        }
        let client = makeClient(mock)
        try await client.connect()
        let app = try await client.receiver.launch(.defaultMediaReceiver)
        #expect(app.transportId == Fixtures.transportID)
    }

    @Test func customNamespaceMessaging() async throws {
        let mock = MockReceiver()
        let custom = CastNamespace("urn:x-cast:com.example.custom")
        mock.on("hello") { request, mock in mock.reply(to: request, ["type": "world"]) }
        let client = makeClient(mock)
        try await client.connect()
        let messages = client.messages(in: custom)
        let reply = try await client.request(["type": "hello"] as JSONValue, namespace: custom, to: "web-1")
        #expect(reply.type == "world")
        for await message in messages {
            #expect(message.type == "world")
            break
        }
    }

    @Test func availability() async throws {
        let mock = MockReceiver()
        mock.on("GET_APP_AVAILABILITY") { request, mock in
            mock.reply(to: request, ["availability": ["CC1AD845": "APP_AVAILABLE", "F007D354": "APP_UNAVAILABLE"]])
        }
        let client = makeClient(mock)
        try await client.connect()
        let result = try await client.receiver.availability(of: [.defaultMediaReceiver, .jellyfin])
        #expect(result[.defaultMediaReceiver] == .available)
        #expect(result[.jellyfin] == .unavailable)
    }
}

/// Polls `condition` until it holds or the deadline passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Condition not met within \(timeout)")
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
