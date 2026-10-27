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

    @Test func nonObjectPayloadIsRejectedLocally() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        let sentBefore = mock.sentMessages.count
        await #expect(throws: CastError.invalidPayload("Request payload must be a JSON object")) {
            _ = try await client.request(["GET_STATUS"] as JSONValue, namespace: .receiver, to: "receiver-0")
        }
        #expect(mock.sentMessages.count == sentBefore)
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
            $0.inactivityTimeout = .milliseconds(300)
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
            $0.inactivityTimeout = .milliseconds(100)
        }
        try await client.connect()
        try await Task.sleep(for: .milliseconds(600))
        #expect(await client.state == .connected)
        #expect(mock.sentMessages(ofType: "PING").count >= 5)
    }

    @Test func deadConnectionIsDetectedWithinIntervalPlusTimeoutOfLastInbound() async throws {
        let mock = MockReceiver()
        mock.answersPings = false
        let client = makeClient(mock) {
            $0.heartbeatInterval = .milliseconds(200)
            $0.inactivityTimeout = .milliseconds(400)
        }
        try await client.connect()
        // The first PING arms the deadline; inbound traffic right after it
        // clears it, so the next PING arms a fresh one.
        try await eventually { mock.sentMessages(ofType: "PING").count >= 1 }
        mock.push(Fixtures.receiverStatus(level: 0.3), namespace: .receiver, to: "*")
        try await eventually { await client.receiverStatus?.volume?.level == 0.3 }
        let lastInbound = ContinuousClock.now
        try await eventually(timeout: .seconds(5)) { await client.state != .connected }
        let elapsed = ContinuousClock.now - lastInbound
        #expect(await client.state == .closed(.heartbeatTimeout))
        #expect(elapsed < .milliseconds(1100))
    }

    @Test func intervalLongerThanTimeoutStillDetectsSilence() async throws {
        let answering = MockReceiver()
        let silent = MockReceiver()
        silent.answersPings = false
        let configure: (inout CastClient.Configuration) -> Void = {
            $0.heartbeatInterval = .milliseconds(300)
            $0.inactivityTimeout = .milliseconds(100)
        }
        let healthy = makeClient(answering, configure: configure)
        let dead = makeClient(silent, configure: configure)
        try await healthy.connect()
        try await dead.connect()

        try await eventually { await dead.state != .connected }
        #expect(await dead.state == .closed(.heartbeatTimeout))
        try await eventually { answering.sentMessages(ofType: "PING").count >= 3 }
        #expect(await healthy.state == .connected)
    }

    @Test func stalledPingWriteStillTimesOut() async throws {
        let mock = MockReceiver()
        mock.holdSends(ofType: "PING")
        let client = makeClient(mock) {
            $0.heartbeatInterval = .milliseconds(50)
            $0.inactivityTimeout = .milliseconds(200)
        }
        try await client.connect()
        try await eventually { await client.state != .connected }
        #expect(await client.state == .closed(.heartbeatTimeout))
        #expect(mock.sentMessages(ofType: "PING").count >= 1)
    }

    @Test func anyInboundTrafficKeepsConnectionAlive() async throws {
        let mock = MockReceiver()
        mock.answersPings = false
        let client = makeClient(mock) {
            $0.heartbeatInterval = .milliseconds(50)
            $0.inactivityTimeout = .milliseconds(200)
        }
        try await client.connect()
        for step in 1...16 {
            mock.push(Fixtures.receiverStatus(level: Double(step) / 100), namespace: .receiver, to: "*")
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await client.state == .connected)
        #expect(mock.sentMessages(ofType: "PING").count >= 5)
        #expect(mock.sentMessages(ofType: "PONG").isEmpty)
    }

    @Test func failedPingWriteTearsDownPromptly() async throws {
        let mock = MockReceiver()
        mock.failSends(ofType: "PING", with: .connectionFailed("broken pipe"))
        let client = makeClient(mock) {
            $0.heartbeatInterval = .milliseconds(50)
            $0.inactivityTimeout = .seconds(30)
        }
        let start = ContinuousClock.now
        try await client.connect()
        try await eventually { await client.state != .connected }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(await client.state == .closed(.connectionFailed("heartbeat write failed: broken pipe")))
        #expect(mock.sentMessages(ofType: "PING").count >= 1)
    }

    @Test func failedPongWriteTearsDown() async throws {
        let mock = MockReceiver()
        mock.failSends(ofType: "PONG", with: .connectionFailed("broken pipe"))
        let client = makeClient(mock)
        try await client.connect()
        mock.push(["type": "PING"], namespace: .heartbeat)
        try await eventually { await client.state != .connected }
        #expect(await client.state == .closed(.connectionFailed("heartbeat write failed: broken pipe")))
    }

    @Test func lateHeartbeatWriteFailureLeavesReconnectedClientAlone() async throws {
        let first = MockReceiver()
        first.holdSends(ofType: "PING")
        first.failsHeldSendsOnClose = false
        let mocks = [first, MockReceiver()]
        let index = Counter()
        var configuration = CastClient.Configuration()
        configuration.heartbeatInterval = .milliseconds(50)
        configuration.inactivityTimeout = .milliseconds(150)
        let client = CastClient(configuration: configuration) { mocks[index.increment() - 1] }

        try await client.connect()
        try await eventually { await client.state != .connected }
        #expect(await client.state == .closed(.heartbeatTimeout))
        let heldPings = first.sentMessages(ofType: "PING").count
        #expect(heldPings >= 1)

        try await client.connect()
        let states = await client.stateUpdates()
        first.releaseHeldSends()
        try await eventually { mocks[1].sentMessages(ofType: "PING").count >= 3 }
        #expect(await client.state == .connected)
        #expect(mocks[1].isOpen)

        await client.disconnect()
        var seen: [CastClient.State] = []
        for await state in states {
            seen.append(state)
            if case .closed = state { break }
        }
        #expect(seen == [.connected, .closed(nil)])
    }

    @Test func inactivityCloseWakesAtTheDeadlineNotTheNextTick() async throws {
        let mock = MockReceiver()
        mock.answersPings = false
        let client = makeClient(mock) {
            $0.heartbeatInterval = .milliseconds(600)
            $0.inactivityTimeout = .milliseconds(700)
        }
        try await client.connect()
        let start = ContinuousClock.now
        try await eventually { await client.state != .connected }
        let elapsed = ContinuousClock.now - start
        #expect(await client.state == .closed(.heartbeatTimeout))
        // The first PING at 600 ms arms a deadline at 1300 ms; the tick after
        // that deadline would be at 1800 ms.
        #expect(elapsed < .milliseconds(1700))
    }

    @Test func nonPositiveIntervalUsesTheDefaultCadence() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock) { $0.heartbeatInterval = .zero }
        try await client.connect()
        try await Task.sleep(for: .milliseconds(300))
        #expect(mock.sentMessages(ofType: "PING").count <= 1)
        #expect(await client.state == .connected)
    }

    @Test func nonPositiveTimeoutUsesTheDefault() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock) {
            $0.heartbeatInterval = .milliseconds(30)
            $0.inactivityTimeout = .zero
        }
        try await client.connect()
        try await eventually { mock.sentMessages(ofType: "PING").count >= 5 }
        #expect(await client.state == .connected)
    }

    @Test func defaultTimeouts() {
        let configuration = CastClient.Configuration()
        #expect(configuration.heartbeatInterval == .seconds(5))
        #expect(configuration.inactivityTimeout == .seconds(10))
        #expect(configuration.requestTimeout == .seconds(5))
        #expect(configuration.mediaRequestTimeout == .seconds(10))
    }

    @Test func receiverAndMediaRequestsUseTheirOwnTimeouts() async throws {
        let mock = MockReceiver() // never replies to requests
        let client = makeClient(mock) {
            $0.requestTimeout = .milliseconds(100)
            $0.mediaRequestTimeout = .milliseconds(600)
        }
        try await client.connect()

        var start = ContinuousClock.now
        await #expect(throws: CastError.timeout) { try await client.receiver.getStatus() }
        let receiverElapsed = ContinuousClock.now - start
        #expect(receiverElapsed >= .milliseconds(100))
        #expect(receiverElapsed < .milliseconds(500))

        let application = try Fixtures.mediaApp.decode(CastApplication.self)
        let media = try await client.mediaController(for: application)
        start = ContinuousClock.now
        await #expect(throws: CastError.timeout) { try await media.refreshStatus() }
        let mediaElapsed = ContinuousClock.now - start
        #expect(mediaElapsed >= .milliseconds(600))
        #expect(mediaElapsed < .seconds(3))
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
        #expect(await client.state == .closed(.closedByReceiver))
    }

    @Test func applicationCloseOnlyDropsThatConnection() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        try await client.openVirtualConnection(to: Fixtures.transportID)
        mock.push(["type": "CLOSE"], namespace: .connection, from: Fixtures.transportID)
        try await eventually { await !client.isConnected(to: Fixtures.transportID) }
        #expect(await client.state == .connected)
    }

    @Test func defaultSenderIDIsUniquePerClient() {
        let first = makeClient(MockReceiver())
        let second = makeClient(MockReceiver())
        #expect(first.senderID.hasPrefix("sender-"))
        #expect(first.senderID != "sender-0")
        #expect(first.senderID == first.senderID.lowercased())
        #expect(UUID(uuidString: String(first.senderID.dropFirst("sender-".count))) != nil)
        #expect(first.senderID != second.senderID)
    }

    @Test func messagesUseTheClientSenderID() async throws {
        let mock = MockReceiver()
        let client = CastClient(senderID: "sender-custom") { mock }
        try await client.connect()
        mock.push(["type": "PING"], namespace: .heartbeat)
        try await eventually { mock.sentMessages(ofType: "PONG").count == 1 }
        let connect = try #require(mock.sentMessages(ofType: "CONNECT").first)
        let pong = try #require(mock.sentMessages(ofType: "PONG").first)
        #expect(connect.sourceID == "sender-custom")
        #expect(pong.sourceID == "sender-custom")
        #expect(pong.destinationID == "receiver-0")
    }

    @Test func connectPayloadDescribesThisSender() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock) { $0.userAgent = "TestApp/2.0" }
        try await client.connect()
        let connect = try #require(mock.sentMessages(ofType: "CONNECT").first)
        let rawPayload = try #require(connect.raw.stringPayload)
        let payload = try #require(connect.json?.objectValue)
        let senderInfo = try #require(payload["senderInfo"]?.objectValue)

        #expect(Set(payload.keys) == ["type", "userAgent", "origin", "connType", "protocolVersion", "protocolVersionList", "senderInfo"])
        #expect(payload["userAgent"] == "TestApp/2.0")
        #expect(payload["origin"] == [:])
        #expect(payload["connType"] == 0)
        #expect(payload["protocolVersion"] == 0)
        #expect(payload["protocolVersionList"] == [0])

        #expect(Set(senderInfo.keys) == ["sdkType", "version", "browserVersion", "platform", "systemVersion", "connectionType"])
        #expect(senderInfo["sdkType"] == 2)
        #expect(senderInfo["version"] == .string(CastClient.version))
        #expect(senderInfo["browserVersion"] == .string(CastClient.version))
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #expect(senderInfo["systemVersion"] == .string("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"))
        #expect(senderInfo["connectionType"] == 1)
        #if os(iOS) || os(tvOS) || os(visionOS)
        #expect(senderInfo["platform"] == 2)
        #elseif os(macOS)
        #expect(senderInfo["platform"] == 4)
        #elseif os(Linux)
        #expect(senderInfo["platform"] == 6)
        #else
        #expect(senderInfo["platform"] == 0)
        #endif

        #expect(!rawPayload.contains("15.605.1.3"))
        #expect(!rawPayload.contains("44.0.2403.30"))
    }

    @Test func defaultUserAgentNamesSwiftCastAndTheOS() {
        let userAgent = CastClient.Configuration().userAgent
        #expect(userAgent.hasPrefix("SwiftCast/\(CastClient.version) ("))
        #expect(userAgent.hasSuffix(")"))
    }

    @Test func applicationConnectUsesConfiguredConnectionType() async throws {
        for (type, expected) in [(CastClient.ConnectionType.strong, JSONValue(0)), (.invisible, JSONValue(2))] {
            let mock = MockReceiver()
            let client = makeClient(mock) { $0.applicationConnectionType = type }
            try await client.connect()
            try await client.openVirtualConnection(to: Fixtures.transportID)
            let connects = mock.sentMessages(ofType: "CONNECT")
            let platformConnect = connects.first { $0.destinationID == "receiver-0" }
            let applicationConnect = connects.first { $0.destinationID == Fixtures.transportID }
            let platform = try #require(platformConnect)
            let application = try #require(applicationConnect)
            #expect(platform.json?["connType"] == 0)
            #expect(application.json?["connType"] == expected)
        }
    }

    @Test func connectedRecordsNegotiatedProtocolVersion() async throws {
        let mock = MockReceiver()
        mock.on("CONNECT") { request, mock in
            mock.push(["type": "CONNECTED", "protocolVersion": 0], namespace: .connection, from: request.destinationID, to: request.sourceID)
        }
        let client = makeClient(mock)
        try await client.connect()
        try await client.openVirtualConnection(to: Fixtures.transportID)
        mock.push(["type": "CONNECTED", "protocolVersion": 1], namespace: .connection, from: Fixtures.transportID)
        try await eventually { await client.negotiatedProtocolVersion(for: Fixtures.transportID) == 1 }
        #expect(await client.negotiatedProtocolVersion(for: "receiver-0") == 0)
        #expect(await client.state == .connected)

        await client.closeVirtualConnection(to: Fixtures.transportID)
        #expect(await client.negotiatedProtocolVersion(for: Fixtures.transportID) == nil)
    }

    @Test func connectedFromUnknownSourceIsIgnored() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.push(["type": "CONNECTED", "protocolVersion": 1], namespace: .connection, from: "web-unknown")
        mock.push(Fixtures.receiverStatus(level: 0.3), namespace: .receiver, to: "*")
        try await eventually { await client.receiverStatus?.volume?.level == 0.3 }
        #expect(await client.negotiatedProtocolVersion(for: "web-unknown") == nil)
        #expect(await !client.isConnected(to: "web-unknown"))
    }

    @Test func connectedAfterCloseIsIgnored() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        try await client.openVirtualConnection(to: Fixtures.transportID)
        await client.closeVirtualConnection(to: Fixtures.transportID)
        mock.push(["type": "CONNECTED", "protocolVersion": 1], namespace: .connection, from: Fixtures.transportID)
        mock.push(Fixtures.receiverStatus(level: 0.3), namespace: .receiver, to: "*")
        try await eventually { await client.receiverStatus?.volume?.level == 0.3 }
        #expect(await client.negotiatedProtocolVersion(for: Fixtures.transportID) == nil)
    }

    @Test func connectDoesNotWaitForConnected() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        try await client.openVirtualConnection(to: Fixtures.transportID)
        #expect(await client.isConnected(to: Fixtures.transportID))
        #expect(await client.negotiatedProtocolVersion(for: Fixtures.transportID) == nil)
    }

    @Test func unknownConnectionMessagesAreIgnored() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.push(["type": "SOMETHING_NEW"], namespace: .connection)
        mock.push(Fixtures.receiverStatus(level: 0.3), namespace: .receiver, to: "*")
        try await eventually { await client.receiverStatus?.volume?.level == 0.3 }
        #expect(await client.state == .connected)
        #expect(await client.isConnected(to: "receiver-0"))
    }

    @Test func closeCarriesGracefulReasonCode() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        try await client.openVirtualConnection(to: Fixtures.transportID)
        await client.closeVirtualConnection(to: Fixtures.transportID)
        await client.disconnect()
        let closes = mock.sentMessages(ofType: "CLOSE")
        #expect(closes.map(\.destinationID) == [Fixtures.transportID, "receiver-0"])
        for close in closes {
            #expect(close.json == ["type": "CLOSE", "reasonCode": 5])
        }
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
        mock.pushRaw(try FrameCodec.frame(message))
        for await status in updates {
            #expect(status.volume?.level == 0.75)
            break
        }
        #expect(await client.state == .connected)
        let status = try await client.receiver.getStatus()
        #expect(status.volume?.level == 0.5)
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

    @Test func launchErrorPrefersExtendedError() async throws {
        let replies: [(JSONValue, String)] = [
            (["type": "LAUNCH_ERROR", "reason": "CANCELLED", "error": "X", "extendedError": "APP_NOT_FOUND"], "APP_NOT_FOUND"),
            (["type": "LAUNCH_ERROR", "reason": "CANCELLED", "error": "TIMEOUT"], "TIMEOUT"),
        ]
        for (reply, reason) in replies {
            let mock = MockReceiver()
            mock.on("LAUNCH") { request, mock in mock.reply(to: request, reply) }
            let client = makeClient(mock)
            try await client.connect()
            await #expect(throws: CastError.launchFailed(reason: reason)) {
                _ = try await client.receiver.launch("BADAPP00")
            }
        }
    }

    @Test func genericErrorIsOnlyMappedOnMediaNamespace() {
        func message(_ namespace: CastNamespace) -> InboundMessage {
            InboundMessage(CastMessage(sourceID: "web-5", destinationID: "sender-0", namespace: namespace.rawValue, payload: .string(#"{"type":"ERROR","reason":"NOT_SUPPORTED"}"#)))
        }
        #expect(CastClient.standardError(in: message(.media)) == .mediaError(MediaErrorInfo(type: "ERROR", reason: .notSupported)))
        #expect(CastClient.standardError(in: message(.receiver)) == nil)
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

@Suite("MockReceiver", .timeLimit(.minutes(1)))
struct MockReceiverTests {
    func ping() throws -> Data {
        let message = CastMessage(sourceID: "sender-0", destinationID: "receiver-0", namespace: CastNamespace.heartbeat.rawValue, payload: .string(#"{"type":"PING"}"#))
        return try FrameCodec.frame(message)
    }

    func heldPing(on mock: MockReceiver) async throws -> Task<Void, any Error> {
        let frame = try ping()
        let send = Task { try await mock.send(frame) }
        try await eventually { mock.sentMessages(ofType: "PING").count == 1 }
        return send
    }

    @Test func closeFailsHeldSendsByDefault() async throws {
        let mock = MockReceiver()
        mock.holdSends(ofType: "PING")
        let send = try await heldPing(on: mock)
        mock.close()
        await #expect(throws: MockReceiver.cancelledSendError) { try await send.value }
    }

    @Test func heldSendReleasedBeforeCloseSucceeds() async throws {
        let mock = MockReceiver()
        mock.holdSends(ofType: "PING")
        let send = try await heldPing(on: mock)
        mock.releaseHeldSends()
        try await send.value
        mock.close()
    }

    @Test func heldSendReleasedAfterCloseFails() async throws {
        let mock = MockReceiver()
        mock.holdSends(ofType: "PING")
        let send = try await heldPing(on: mock)
        mock.failsHeldSendsOnClose = false
        mock.close()
        mock.releaseHeldSends()
        await #expect(throws: MockReceiver.cancelledSendError) { try await send.value }
    }

    @Test func answersPingsCanChangeAfterOpen() async throws {
        let mock = MockReceiver()
        try await mock.open()
        mock.answersPings = false
        try await mock.send(ping())
        mock.answersPings = true
        try await mock.send(ping())
        mock.drop()
        var replies = 0
        for try await _ in mock.inbound { replies += 1 }
        #expect(replies == 1)
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
