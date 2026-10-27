import Foundation
import os
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

    @Test func requestCancelledBeforeItsWriteIsNeverWritten() async throws {
        let mock = MockReceiver()
        Fixtures.installDefaultReceiver(on: mock)
        let client = makeClient(mock)
        try await client.connect()
        // Cancels the request in the same turn that registers it, after its write is scheduled.
        let options = CastClient.RequestOptions(onRegistered: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        let result = await Task {
            try await client.request(["type": "PROBE"] as JSONValue, namespace: .receiver, to: CastEndpoint.platformReceiver, timeout: .seconds(30), options: options)
        }.result
        #expect(throws: CancellationError.self) { try result.get() }
        // A full round trip, so a write scheduled before it would have reached the mock by now.
        try await client.receiver.getStatus()
        #expect(mock.sentMessages(ofType: "PROBE").isEmpty)
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
        try await eventually { first.heldSendCount >= 1 }

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

    // MARK: - Launch lifecycle

    /// Names the case itself, since `==` on an open enum compares raw values
    /// and would also accept `.unknown` carrying a known code.
    func reasonCase(_ reason: LaunchErrorReason?) -> String? {
        switch reason {
        case nil: nil
        case .userNotAllowed?: "userNotAllowed"
        case .notificationDisabled?: "notificationDisabled"
        case .applicationNotListed?: "applicationNotListed"
        case .unknown(let raw)?: "unknown(\(raw))"
        }
    }

    static func appJSON(_ appID: String = "CC1AD845", sessionID: String, transportID: String) -> JSONValue {
        ["appId": .string(appID), "displayName": "App", "sessionId": .string(sessionID), "transportId": .string(transportID)]
    }

    @Test func launchRequestIDAcceptsOnlyInt32() {
        func message(_ json: String) -> InboundMessage {
            InboundMessage(CastMessage(sourceID: "receiver-0", destinationID: "sender-0", namespace: CastNamespace.receiver.rawValue, payload: .string(json)))
        }
        #expect(message(#"{"launchRequestId":2147483647}"#).launchRequestID == 2147483647)
        #expect(message(#"{"launchRequestId":2147483648}"#).launchRequestID == nil)
        #expect(message(#"{"launchRequestId":1.5}"#).launchRequestID == nil)
        #expect(message(#"{"launchRequestId":"7"}"#).launchRequestID == nil)
        #expect(message(#"{"requestId":7}"#).launchRequestID == nil)
        #expect(message(#"{"launchRequestId":7}"#).requestID == nil)
    }

    @Test func launchStaysPendingThroughLaunchStatus() async throws {
        let mock = MockReceiver()
        mock.on("LAUNCH") { request, mock in
            mock.reply(to: request, ["type": "LAUNCH_STATUS", "status": "USER_PENDING_AUTHORIZATION"], echoingIDAs: "launchRequestId")
            mock.reply(to: request, ["type": "LAUNCH_STATUS", "status": "USER_ALLOWED"])
            mock.reply(to: request, Fixtures.receiverStatus(apps: [Fixtures.mediaApp]))
        }
        let client = makeClient(mock)
        try await client.connect()
        let statuses = OSAllocatedUnfairLock<[String]>(initialState: [])
        let app = try await client.receiver.launch(.defaultMediaReceiver) { status in
            statuses.withLock { $0.append(status) }
        }
        #expect(app.transportId == Fixtures.transportID)
        #expect(statuses.withLock { $0 } == ["USER_PENDING_AUTHORIZATION", "USER_ALLOWED"])
    }

    @Test func launchErrorEchoedAsLaunchRequestIDFailsTheLaunch() async throws {
        let mock = MockReceiver()
        mock.on("LAUNCH") { request, mock in
            mock.reply(to: request, ["type": "LAUNCH_ERROR", "extendedError": "NOTIFICATION_DISABLED"], echoingIDAs: "launchRequestId")
        }
        let client = makeClient(mock)
        try await client.connect()
        let error = await #expect(throws: CastError.self) { _ = try await client.receiver.launch(.defaultMediaReceiver) }
        #expect(reasonCase(error?.launchErrorReason) == "notificationDisabled")
    }

    @Test func launchRequestIDDoesNotAnswerOtherRequests() async throws {
        let mock = MockReceiver()
        mock.on("GET_STATUS") { request, mock in
            mock.reply(to: request, Fixtures.receiverStatus(), echoingIDAs: "launchRequestId")
        }
        let client = makeClient(mock)
        try await client.connect()
        await #expect(throws: CastError.timeout) {
            _ = try await client.request(["type": "GET_STATUS"] as JSONValue, namespace: .receiver, to: "receiver-0", timeout: .milliseconds(200))
        }
    }

    @Test func launchStatusAloneTimesOutOnce() async throws {
        let mock = MockReceiver()
        mock.on("LAUNCH") { request, mock in
            mock.reply(to: request, ["type": "LAUNCH_STATUS", "status": "USER_PENDING_AUTHORIZATION"], echoingIDAs: "launchRequestId")
        }
        let client = makeClient(mock)
        try await client.connect()
        let start = ContinuousClock.now
        await #expect(throws: CastError.timeout) {
            _ = try await client.receiver.launch(.defaultMediaReceiver, timeout: .milliseconds(300))
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(300))
        #expect(elapsed < .milliseconds(600))
    }

    @Test func launchErrorUserNotAllowedIsTyped() async throws {
        let mock = MockReceiver()
        mock.on("LAUNCH") { request, mock in
            mock.reply(to: request, ["type": "LAUNCH_ERROR", "reason": "CANCELLED", "extendedError": "USER_NOT_ALLOWED"])
        }
        let client = makeClient(mock)
        try await client.connect()
        let error = await #expect(throws: CastError.self) { _ = try await client.receiver.launch(.defaultMediaReceiver) }
        #expect(error == .launchFailed(reason: "USER_NOT_ALLOWED"))
        #expect(reasonCase(error?.launchErrorReason) == "userNotAllowed")
    }

    @Test func launchErrorReasonDecodesDocumentedCodes() {
        #expect(reasonCase(CastError.launchFailed(reason: "USER_NOT_ALLOWED").launchErrorReason) == "userNotAllowed")
        #expect(reasonCase(CastError.launchFailed(reason: "NOTIFICATION_DISABLED").launchErrorReason) == "notificationDisabled")
        #expect(reasonCase(CastError.launchFailed(reason: "APPLICATION_NOT_LISTED").launchErrorReason) == "applicationNotListed")
        #expect(reasonCase(CastError.launchFailed(reason: "NOT_FOUND").launchErrorReason) == "unknown(NOT_FOUND)")
        #expect(CastError.launchFailed(reason: nil).launchErrorReason == nil)
        #expect(CastError.timeout.launchErrorReason == nil)
    }

    @Test func replyWithoutTheAppFailsWithoutWaitingForBroadcasts() async throws {
        let mock = MockReceiver()
        mock.on("LAUNCH") { request, mock in
            mock.reply(to: request, Fixtures.receiverStatus(apps: [Self.appJSON("E8C28D3C", sessionID: "old-backdrop", transportID: "web-1")]))
            mock.push(Fixtures.receiverStatus(apps: [Fixtures.mediaApp]), namespace: .receiver, to: "*")
        }
        let client = makeClient(mock)
        try await client.connect()
        let start = ContinuousClock.now
        let error = await #expect(throws: CastError.launchFailed(reason: "APPLICATION_NOT_LISTED")) {
            _ = try await client.receiver.launch(.defaultMediaReceiver, timeout: .seconds(10))
        }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(reasonCase(error?.launchErrorReason) == "applicationNotListed")
    }

    @Test func applicationOnThePlatformTransportIsNotALaunchedApp() async throws {
        let mock = MockReceiver()
        mock.on("LAUNCH") { request, mock in
            mock.reply(to: request, Fixtures.receiverStatus(apps: [Self.appJSON(sessionID: "s-1", transportID: "receiver-0")]))
        }
        let client = makeClient(mock)
        try await client.connect()
        await #expect(throws: CastError.launchFailed(reason: "APPLICATION_NOT_LISTED")) {
            _ = try await client.receiver.launch(.defaultMediaReceiver)
        }
    }

    @Test func staleBroadcastNeverCompletesLaunch() async throws {
        let mock = MockReceiver()
        mock.on("LAUNCH") { _, mock in
            mock.push(Fixtures.receiverStatus(apps: [Self.appJSON(sessionID: "stale", transportID: "web-1")]), namespace: .receiver, to: "*")
        }
        let client = makeClient(mock)
        try await client.connect()
        await #expect(throws: CastError.timeout) {
            _ = try await client.receiver.launch(.defaultMediaReceiver, timeout: .milliseconds(300))
        }
        #expect(await client.receiverStatus?.application(.defaultMediaReceiver)?.sessionId == "stale")
    }

    @Test func launchReturnsTheInstanceFromItsOwnReply() async throws {
        let mock = MockReceiver()
        mock.on("LAUNCH") { request, mock in
            mock.push(Fixtures.receiverStatus(apps: [Self.appJSON(sessionID: "stale", transportID: "web-1")]), namespace: .receiver, to: "*")
            mock.reply(to: request, Fixtures.receiverStatus(apps: [Self.appJSON(sessionID: "fresh", transportID: "web-2")]))
        }
        let client = makeClient(mock)
        try await client.connect()
        let app = try await client.receiver.launch(.defaultMediaReceiver)
        #expect(app.sessionId == "fresh")
        #expect(app.transportId == "web-2")
    }

    @Test func concurrentLaunchOfTheSameAppSharesOneLaunch() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        let firstStatuses = OSAllocatedUnfairLock<[String]>(initialState: [])
        let secondStatuses = OSAllocatedUnfairLock<[String]>(initialState: [])
        let first = Task {
            try await client.receiver.launch(.defaultMediaReceiver, timeout: .seconds(10)) { status in
                firstStatuses.withLock { $0.append(status) }
            }
        }
        try await eventually { mock.sentMessages(ofType: "LAUNCH").count == 1 }
        let second = Task {
            try await client.receiver.launch(.defaultMediaReceiver, timeout: .milliseconds(100)) { status in
                secondStatuses.withLock { $0.append(status) }
            }
        }
        try await eventually { await client.pendingLaunchWaiters == 2 }
        let launch = try #require(mock.sentMessages(ofType: "LAUNCH").first)
        // Longer than the joined caller's own timeout, which it does not use.
        try await Task.sleep(for: .milliseconds(300))
        mock.reply(to: launch, ["type": "LAUNCH_STATUS", "status": "USER_ALLOWED"])
        mock.reply(to: launch, Fixtures.receiverStatus(apps: [Fixtures.mediaApp]))
        let firstApp = try await first.value
        let secondApp = try await second.value
        #expect(firstApp == secondApp)
        #expect(firstApp.transportId == Fixtures.transportID)
        #expect(mock.sentMessages(ofType: "LAUNCH").count == 1)
        #expect(firstStatuses.withLock { $0 } == ["USER_ALLOWED"])
        #expect(secondStatuses.withLock { $0 } == ["USER_ALLOWED"])
    }

    @Test func concurrentLaunchOfAnotherAppThrowsRequestInFlight() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        let first = Task { try await client.receiver.launch(.defaultMediaReceiver, timeout: .seconds(10)) }
        try await eventually { mock.sentMessages(ofType: "LAUNCH").count == 1 }
        await #expect(throws: CastError.requestInFlight("LAUNCH")) {
            _ = try await client.receiver.launch(.youTube)
        }
        let launch = try #require(mock.sentMessages(ofType: "LAUNCH").first)
        mock.reply(to: launch, Fixtures.receiverStatus(apps: [Fixtures.mediaApp]))
        let app = try await first.value
        #expect(app.transportId == Fixtures.transportID)
        #expect(mock.sentMessages(ofType: "LAUNCH").count == 1)
    }

    @Test func launchAfterACompletedLaunchSendsAgain() async throws {
        let mock = MockReceiver()
        Fixtures.installDefaultReceiver(on: mock)
        let client = makeClient(mock)
        try await client.connect()
        _ = try await client.receiver.launch(.defaultMediaReceiver)
        _ = try await client.receiver.launch(.defaultMediaReceiver)
        #expect(mock.sentMessages(ofType: "LAUNCH").count == 2)
    }

    @Test func cancellingAJoinedLaunchLeavesTheLaunchRunning() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        let first = Task { try await client.receiver.launch(.defaultMediaReceiver, timeout: .seconds(10)) }
        try await eventually { mock.sentMessages(ofType: "LAUNCH").count == 1 }
        let joined = Task { try await client.receiver.launch(.defaultMediaReceiver, timeout: .seconds(10)) }
        try await eventually { await client.pendingLaunchWaiters == 2 }
        joined.cancel()
        let joinedResult = await joined.result
        #expect(throws: CancellationError.self) { try joinedResult.get() }
        let launch = try #require(mock.sentMessages(ofType: "LAUNCH").first)
        mock.reply(to: launch, Fixtures.receiverStatus(apps: [Fixtures.mediaApp]))
        let app = try await first.value
        #expect(app.transportId == Fixtures.transportID)
        #expect(mock.sentMessages(ofType: "LAUNCH").count == 1)
    }

    @Test func cancellingTheOnlyLaunchCallerEndsTheLaunch() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        let first = Task { try await client.receiver.launch(.defaultMediaReceiver, timeout: .seconds(10)) }
        try await eventually { mock.sentMessages(ofType: "LAUNCH").count == 1 }
        let start = ContinuousClock.now
        first.cancel()
        let firstResult = await first.result
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(throws: CancellationError.self) { try firstResult.get() }
        Fixtures.installDefaultReceiver(on: mock)
        let app = try await client.receiver.launch(.defaultMediaReceiver)
        #expect(app.transportId == Fixtures.transportID)
        #expect(mock.sentMessages(ofType: "LAUNCH").count == 2)
    }

    @Test func cancellingTheFirstLaunchCallerLeavesTheLaunchForAJoinedCaller() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        let first = Task { try await client.receiver.launch(.defaultMediaReceiver, timeout: .seconds(10)) }
        try await eventually { mock.sentMessages(ofType: "LAUNCH").count == 1 }
        let joined = Task { try await client.receiver.launch(.defaultMediaReceiver, timeout: .seconds(10)) }
        try await eventually { await client.pendingLaunchWaiters == 2 }
        first.cancel()
        let firstResult = await first.result
        #expect(throws: CancellationError.self) { try firstResult.get() }
        let launch = try #require(mock.sentMessages(ofType: "LAUNCH").first)
        mock.reply(to: launch, Fixtures.receiverStatus(apps: [Fixtures.mediaApp]))
        let app = try await joined.value
        #expect(app.transportId == Fixtures.transportID)
        #expect(mock.sentMessages(ofType: "LAUNCH").count == 1)
    }

    @Test func cancellingEveryLaunchCallerEndsTheLaunch() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        let first = Task { try await client.receiver.launch(.defaultMediaReceiver, timeout: .seconds(10)) }
        try await eventually { mock.sentMessages(ofType: "LAUNCH").count == 1 }
        let joined = Task { try await client.receiver.launch(.defaultMediaReceiver, timeout: .seconds(10)) }
        try await eventually { await client.pendingLaunchWaiters == 2 }
        first.cancel()
        let firstResult = await first.result
        #expect(throws: CancellationError.self) { try firstResult.get() }
        let pending = await client.pendingLaunch
        let shared = try #require(pending)
        let start = ContinuousClock.now
        joined.cancel()
        let joinedResult = await joined.result
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(throws: CancellationError.self) { try joinedResult.get() }
        let sharedResult = await shared.result
        #expect(throws: CancellationError.self) { try sharedResult.get() }
        #expect(await client.pendingLaunch == nil)
        Fixtures.installDefaultReceiver(on: mock)
        _ = try await client.receiver.launch(.defaultMediaReceiver)
        #expect(mock.sentMessages(ofType: "LAUNCH").count == 2)
    }

    @Test func launchIssuedAsTheSharedLaunchFinishesSendsANewLaunch() async throws {
        let mock = MockReceiver()
        Fixtures.installDefaultReceiver(on: mock)
        mock.holdSends(ofType: "LAUNCH")
        let client = makeClient(mock)
        try await client.connect()
        let first = Task { try await client.receiver.launch(.defaultMediaReceiver) }
        try await eventually { mock.sentMessages(ofType: "LAUNCH").count == 1 }
        let pending = await client.pendingLaunch
        let shared = try #require(pending)
        mock.releaseHeldSends()
        _ = try await shared.value
        // The first caller may not have resumed yet; the finished launch must not be joined.
        _ = try await client.receiver.launch(.defaultMediaReceiver)
        _ = try await first.value
        #expect(mock.sentMessages(ofType: "LAUNCH").count == 2)
    }

    @Test func alreadyCancelledLaunchSendsNothing() async throws {
        let mock = MockReceiver()
        Fixtures.installDefaultReceiver(on: mock)
        let client = makeClient(mock)
        try await client.connect()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.receiver.launch(.defaultMediaReceiver)
        }
        let cancelledResult = await cancelled.result
        #expect(throws: CancellationError.self) { try cancelledResult.get() }
        // A full round trip, so a LAUNCH started behind the cancelled call would have reached the client by now.
        try await client.receiver.getStatus()
        #expect(await client.lastTimeoutByRequestType["LAUNCH"] == nil)
        #expect(mock.sentMessages(ofType: "LAUNCH").isEmpty)
        #expect(await client.pendingLaunch == nil)
        _ = try await client.receiver.launch(.defaultMediaReceiver)
        #expect(mock.sentMessages(ofType: "LAUNCH").count == 1)
    }

    @Test func launchRightAfterTheLastWaiterCancelsSendsAFreshLaunch() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        for iteration in 1...50 {
            let only = Task(priority: .background) { try await client.receiver.launch(.defaultMediaReceiver, timeout: .seconds(10)) }
            try await eventually { mock.sentMessages(ofType: "LAUNCH").count == 2 * iteration - 1 }
            // The cancelled LAUNCH settles from a task at the waiter's low priority,
            // so the relaunch tends to reach the client before it has.
            let relaunch = Task(priority: .high) {
                _ = await only.result
                return try await client.receiver.launch(.defaultMediaReceiver, timeout: .seconds(10))
            }
            only.cancel()
            let cancelledResult = await only.result
            #expect(throws: CancellationError.self) { try cancelledResult.get() }
            try await eventually { mock.sentMessages(ofType: "LAUNCH").count == 2 * iteration }
            let fresh = try #require(mock.sentMessages(ofType: "LAUNCH").last)
            mock.reply(to: fresh, Fixtures.receiverStatus(apps: [Fixtures.mediaApp]))
            let app = try await relaunch.value
            #expect(app.transportId == Fixtures.transportID)
        }
        #expect(Set(mock.sentMessages(ofType: "LAUNCH").compactMap(\.requestID)).count == 100)
    }

    @Test func launchStatusReachesOnlyCallersStillWaiting() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        let starterStatuses = OSAllocatedUnfairLock<[String]>(initialState: [])
        let joinerStatuses = OSAllocatedUnfairLock<[String]>(initialState: [])
        let starter = Task {
            try await client.receiver.launch(.defaultMediaReceiver, timeout: .seconds(10)) { status in
                starterStatuses.withLock { $0.append(status) }
            }
        }
        try await eventually { mock.sentMessages(ofType: "LAUNCH").count == 1 }
        let joiner = Task {
            try await client.receiver.launch(.defaultMediaReceiver, timeout: .seconds(10)) { status in
                joinerStatuses.withLock { $0.append(status) }
            }
        }
        try await eventually { await client.pendingLaunchWaiters == 2 }
        starter.cancel()
        let starterResult = await starter.result
        #expect(throws: CancellationError.self) { try starterResult.get() }
        let launch = try #require(mock.sentMessages(ofType: "LAUNCH").first)
        mock.reply(to: launch, ["type": "LAUNCH_STATUS", "status": "USER_ALLOWED"])
        mock.reply(to: launch, Fixtures.receiverStatus(apps: [Fixtures.mediaApp]))
        _ = try await joiner.value
        #expect(joinerStatuses.withLock { $0 } == ["USER_ALLOWED"])
        #expect(starterStatuses.withLock { $0 }.isEmpty)
    }

    @Test func launchStatusSkipsAWaiterCancelledEarlierInTheSameTurn() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        let joinerTask = OSAllocatedUnfairLock<Task<CastApplication, any Error>?>(initialState: nil)
        let starterStatuses = OSAllocatedUnfairLock<[String]>(initialState: [])
        let joinerStatuses = OSAllocatedUnfairLock<[String]>(initialState: [])
        let starter = Task {
            try await client.receiver.launch(.defaultMediaReceiver, timeout: .seconds(10)) { status in
                starterStatuses.withLock { $0.append(status) }
                // Runs on the client while it handles the chunk, so the joiner
                // cannot leave the launch before the second status is handled.
                if status == "USER_PENDING_AUTHORIZATION" { joinerTask.withLock { $0 }?.cancel() }
            }
        }
        try await eventually { mock.sentMessages(ofType: "LAUNCH").count == 1 }
        let joiner = Task {
            try await client.receiver.launch(.defaultMediaReceiver, timeout: .seconds(10)) { status in
                joinerStatuses.withLock { $0.append(status) }
            }
        }
        joinerTask.withLock { $0 = joiner }
        try await eventually { await client.pendingLaunchWaiters == 2 }
        let launch = try #require(mock.sentMessages(ofType: "LAUNCH").first)
        mock.replyInOneChunk(to: launch, [
            ["type": "LAUNCH_STATUS", "status": "USER_PENDING_AUTHORIZATION"],
            ["type": "LAUNCH_STATUS", "status": "USER_ALLOWED"],
        ])
        let joinerResult = await joiner.result
        #expect(throws: CancellationError.self) { try joinerResult.get() }
        mock.reply(to: launch, Fixtures.receiverStatus(apps: [Fixtures.mediaApp]))
        _ = try await starter.value
        #expect(starterStatuses.withLock { $0 } == ["USER_PENDING_AUTHORIZATION", "USER_ALLOWED"])
        // The joiner may or may not have been reached by the first status, depending on fan-out order.
        #expect(!joinerStatuses.withLock { $0 }.contains("USER_ALLOWED"))
    }

    @Test func launchQueuedBehindTheFinalReplySendsANewLaunch() async throws {
        let mock = MockReceiver()
        let launches = Counter()
        mock.on("LAUNCH") { request, mock in
            if launches.increment() == 1 {
                // In one chunk, so the late launch below is queued on the client until after the final reply.
                mock.replyInOneChunk(to: request, [["type": "LAUNCH_STATUS", "status": "USER_ALLOWED"], Fixtures.receiverStatus(apps: [Fixtures.mediaApp])])
            } else {
                mock.reply(to: request, Fixtures.receiverStatus(apps: [Fixtures.mediaApp]))
            }
        }
        let client = makeClient(mock)
        try await client.connect()
        let late = OSAllocatedUnfairLock<Task<CastApplication, any Error>?>(initialState: nil)
        _ = try await client.receiver.launch(.defaultMediaReceiver) { _ in
            late.withLock { $0 = $0 ?? Task { try await client.receiver.launch(.defaultMediaReceiver) } }
        }
        let lateTask = late.withLock { $0 }
        let lateLaunch = try #require(lateTask)
        _ = try await lateLaunch.value
        #expect(mock.sentMessages(ofType: "LAUNCH").count == 2)
    }

    @Test func cancelledLaunchMediaAppThrowsEvenWhenTheStatusFetchIsCancelled() async throws {
        let mock = MockReceiver()
        mock.on("GET_STATUS") { request, mock in
            guard request.namespace == .receiver else { return }
            mock.reply(to: request, Fixtures.receiverStatus(apps: [Fixtures.mediaApp]))
        }
        let client = makeClient(mock)
        try await client.connect()
        let task = Task { try await client.launchMediaApp() }
        try await eventually { mock.sentMessages(ofType: "GET_STATUS").contains { $0.namespace == .media } }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    /// Answers receiver status requests with the media app running, and the
    /// media status requests whose 1-based position `answers` accepts.
    func installMediaApp(on mock: MockReceiver, answeringMediaStatus answers: @escaping @Sendable (Int) -> Bool) {
        let mediaRequests = Counter()
        mock.on("GET_STATUS") { request, mock in
            if request.namespace == .receiver {
                mock.reply(to: request, Fixtures.receiverStatus(apps: [Fixtures.mediaApp]))
            } else if request.namespace == .media, answers(mediaRequests.increment()) {
                mock.reply(to: request, ["type": "MEDIA_STATUS", "status": []])
            }
        }
    }

    func mediaStatusRequests(_ mock: MockReceiver) -> Int {
        mock.sentMessages(ofType: "GET_STATUS").filter { $0.namespace == .media }.count
    }

    func closes(to destination: String, _ mock: MockReceiver) -> Int {
        mock.sentMessages(ofType: "CLOSE").filter { $0.destinationID == destination }.count
    }

    @Test func cancelledSoleMediaControllerCallClosesItsConnection() async throws {
        let mock = MockReceiver()
        installMediaApp(on: mock) { _ in false }
        let client = makeClient(mock)
        try await client.connect()
        let status = try await client.receiver.getStatus()
        let app = try #require(status.application(.defaultMediaReceiver))
        let task = Task { try await client.mediaController(for: app) }
        try await eventually { mediaStatusRequests(mock) == 1 }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(await !client.isConnected(to: Fixtures.transportID))
        #expect(closes(to: Fixtures.transportID, mock) == 1)
    }

    @Test func cancelledSecondMediaControllerCallLeavesTheFirstIntact() async throws {
        let mock = MockReceiver()
        installMediaApp(on: mock) { $0 == 1 }
        let client = makeClient(mock)
        try await client.connect()
        let status = try await client.receiver.getStatus()
        let app = try #require(status.application(.defaultMediaReceiver))
        let first = try await client.mediaController(for: app)
        let second = Task { try await client.mediaController(for: app) }
        try await eventually { mediaStatusRequests(mock) == 2 }
        second.cancel()
        let result = await second.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(await client.isConnected(to: Fixtures.transportID))
        #expect(closes(to: Fixtures.transportID, mock) == 0)
        #expect(await !first.isClosed)
        mock.push(Fixtures.mediaStatus(sessionID: 7), namespace: .media, from: Fixtures.transportID)
        try await eventually { await first.status?.mediaSessionId == 7 }
    }

    @Test func cancelledOpenerLeavesAConnectionALaterCallJoined() async throws {
        let mock = MockReceiver()
        installMediaApp(on: mock) { $0 >= 2 }
        let client = makeClient(mock)
        try await client.connect()
        let status = try await client.receiver.getStatus()
        let app = try #require(status.application(.defaultMediaReceiver))
        let opener = Task { try await client.mediaController(for: app) }
        try await eventually { mediaStatusRequests(mock) == 1 }
        let joined = try await client.mediaController(for: app)
        opener.cancel()
        let result = await opener.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(await client.isConnected(to: Fixtures.transportID))
        #expect(closes(to: Fixtures.transportID, mock) == 0)
        #expect(mock.sentMessages(ofType: "CONNECT").filter { $0.destinationID == Fixtures.transportID }.count == 1)
        #expect(await !joined.isClosed)
    }

    @Test func launchPassesTheDefaultAndClampedTimeoutToItsRequest() async throws {
        let mock = MockReceiver()
        Fixtures.installDefaultReceiver(on: mock)
        let client = makeClient(mock)
        try await client.connect()
        _ = try await client.receiver.launch(.defaultMediaReceiver)
        #expect(await client.lastTimeoutByRequestType["LAUNCH"] == .seconds(60))
        _ = try await client.receiver.launch(.defaultMediaReceiver, timeout: .seconds(1000))
        #expect(await client.lastTimeoutByRequestType["LAUNCH"] == .seconds(120))
    }

    @Test func stopWhileStopPendingThrowsRequestInFlight() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        let first = Task { try await client.receiver.stop(sessionID: Fixtures.sessionID) }
        try await eventually { mock.sentMessages(ofType: "STOP").count == 1 }
        await #expect(throws: CastError.requestInFlight("STOP")) {
            try await client.receiver.stop(sessionID: "another")
        }
        // Other receiver requests are not serialised behind it.
        Fixtures.installDefaultReceiver(on: mock)
        _ = try await client.receiver.getStatus()
        let stop = try #require(mock.sentMessages(ofType: "STOP").first)
        mock.reply(to: stop, Fixtures.receiverStatus())
        _ = try await first.value
        #expect(mock.sentMessages(ofType: "STOP").count == 1)
    }

    @Test func requestInFlightDescription() {
        #expect(CastError.requestInFlight("LAUNCH").errorDescription == "A LAUNCH request is already in flight.")
    }

    @Test func launchTimeoutDefaultsAndClamp() {
        #expect(ReceiverController.defaultLaunchTimeout == .seconds(60))
        #expect(ReceiverController.maximumLaunchTimeout == .seconds(120))
        #expect(ReceiverController.clampedLaunchTimeout(.seconds(60)) == .seconds(60))
        #expect(ReceiverController.clampedLaunchTimeout(.seconds(120)) == .seconds(120))
        #expect(ReceiverController.clampedLaunchTimeout(.seconds(600)) == .seconds(120))
        #expect(ReceiverController.clampedLaunchTimeout(.milliseconds(200)) == .milliseconds(200))
    }

    @Test func customRequestCanWaitPastIntermediateReplies() async throws {
        let mock = MockReceiver()
        let custom = CastNamespace("urn:x-cast:com.example.custom")
        mock.on("work") { request, mock in
            mock.reply(to: request, ["type": "progress"])
            mock.reply(to: request, ["type": "done"])
        }
        let client = makeClient(mock)
        try await client.connect()
        try await client.openVirtualConnection(to: "web-1")
        let reply = try await client.request(["type": "work"] as JSONValue, namespace: custom, to: "web-1") { $0.type != "progress" }
        #expect(reply.type == "done")
    }

    @Test func customNamespaceMessaging() async throws {
        let mock = MockReceiver()
        let custom = CastNamespace("urn:x-cast:com.example.custom")
        mock.on("hello") { request, mock in mock.reply(to: request, ["type": "world"]) }
        let client = makeClient(mock)
        try await client.connect()
        try await client.openVirtualConnection(to: "web-1")
        let messages = client.messages(in: custom)
        let reply = try await client.request(["type": "hello"] as JSONValue, namespace: custom, to: "web-1")
        #expect(reply.type == "world")
        for await message in messages {
            #expect(message.type == "world")
            break
        }
    }

    // MARK: - Inbound routing

    @Test func replyOnAnotherNamespaceDoesNotResolveRequest() async throws {
        let mock = MockReceiver()
        mock.on("GET_STATUS") { request, mock in
            var stray = Fixtures.receiverStatus(level: 0.9).objectValue ?? [:]
            stray["requestId"] = request.json?["requestId"]
            mock.push(.object(stray), namespace: .media, from: request.destinationID)
            mock.reply(to: request, Fixtures.receiverStatus(level: 0.5))
        }
        let client = makeClient(mock)
        try await client.connect()
        let status = try await client.receiver.getStatus()
        #expect(status.volume?.level == 0.5)
    }

    @Test func replyOnAnotherNamespaceAloneTimesOut() async throws {
        let mock = MockReceiver()
        mock.on("GET_STATUS") { request, mock in
            var stray: [String: JSONValue] = ["type": "MEDIA_STATUS", "status": []]
            stray["requestId"] = request.json?["requestId"]
            mock.push(.object(stray), namespace: .media, from: request.destinationID)
        }
        let client = makeClient(mock)
        try await client.connect()
        await #expect(throws: CastError.timeout) {
            _ = try await client.request(["type": "GET_STATUS"] as JSONValue, namespace: .receiver, to: "receiver-0", timeout: .milliseconds(200))
        }
    }

    @Test func replyFromAnotherSourceDoesNotResolveRequest() async throws {
        let mock = MockReceiver()
        mock.on("GET_STATUS") { request, mock in
            var stray = Fixtures.receiverStatus(level: 0.9).objectValue ?? [:]
            stray["requestId"] = request.json?["requestId"]
            mock.push(.object(stray), namespace: .receiver, from: Fixtures.transportID)
        }
        let client = makeClient(mock)
        try await client.connect()
        try await client.openVirtualConnection(to: Fixtures.transportID)
        await #expect(throws: CastError.timeout) {
            _ = try await client.request(["type": "GET_STATUS"] as JSONValue, namespace: .receiver, to: "receiver-0", timeout: .milliseconds(200))
        }
        #expect(await client.receiverStatus == nil)
    }

    @Test func messageForAnotherSenderIsNotDelivered() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        var messages = client.messages(in: .receiver).makeAsyncIterator()
        mock.push(Fixtures.receiverStatus(level: 0.9), namespace: .receiver, to: "sender-someone-else")
        mock.push(Fixtures.receiverStatus(level: 0.4), namespace: .receiver)
        let delivered = try #require(await messages.next())
        #expect(delivered.destinationID == client.senderID)
        #expect(await client.receiverStatus?.volume?.level == 0.4)
    }

    @Test func mediaFromUnopenedTransportIsNotDelivered() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        try await client.openVirtualConnection(to: Fixtures.transportID)
        var messages = client.messages(in: .media).makeAsyncIterator()
        mock.push(Fixtures.mediaStatus(sessionID: 9), namespace: .media, from: "web-9", to: "*")
        mock.push(Fixtures.mediaStatus(sessionID: 1), namespace: .media, from: Fixtures.transportID, to: "*")
        let delivered = try #require(await messages.next())
        #expect(delivered.sourceID == Fixtures.transportID)
    }

    @Test func receiverStatusFromAnotherSourceIsIgnored() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        try await client.openVirtualConnection(to: Fixtures.transportID)
        var updates = await client.receiverStatusUpdates().makeAsyncIterator()
        mock.push(Fixtures.receiverStatus(level: 0.9), namespace: .receiver, from: Fixtures.transportID, to: "*")
        mock.push(Fixtures.receiverStatus(level: 0.4), namespace: .receiver, to: "*")
        let first = try #require(await updates.next())
        #expect(first.volume?.level == 0.4)
    }

    @Test func nonObjectPayloadsOnGoogleNamespacesAreDropped() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        var messages = client.messages(in: .receiver).makeAsyncIterator()
        mock.push(payload: .string("not json"), namespace: .receiver)
        mock.push(payload: .string("[1, 2]"), namespace: .receiver)
        mock.push(payload: .string(#""RECEIVER_STATUS""#), namespace: .receiver)
        mock.push(payload: .binary(Data([1, 2, 3])), namespace: .receiver)
        mock.push(Fixtures.receiverStatus(level: 0.4), namespace: .receiver)
        let delivered = try #require(await messages.next())
        #expect(delivered.type == "RECEIVER_STATUS")
        #expect(await client.state == .connected)
    }

    @Test func customNamespacesReceiveRawPayloads() async throws {
        let mock = MockReceiver()
        let custom = CastNamespace("urn:x-cast:com.example.custom")
        let client = makeClient(mock)
        try await client.connect()
        try await client.openVirtualConnection(to: "web-1")
        var messages = client.messages(in: custom).makeAsyncIterator()
        mock.push(payload: .string("not json"), namespace: custom, from: "web-1")
        mock.push(payload: .binary(Data([1, 2, 3])), namespace: custom, from: "web-1")
        let text = try #require(await messages.next())
        let binary = try #require(await messages.next())
        #expect(text.json == nil)
        #expect(text.raw.stringPayload == "not json")
        #expect(binary.raw.payload == .binary(Data([1, 2, 3])))
    }

    @Test func failedConnectLeavesNoVirtualConnection() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.failSends(ofType: "CONNECT", with: .connectionFailed("broken pipe"))
        await #expect(throws: CastError.connectionFailed("broken pipe")) {
            try await client.openVirtualConnection(to: Fixtures.transportID)
        }
        #expect(await !client.isConnected(to: Fixtures.transportID))
    }

    @Test func concurrentConnectsToOneDestinationShareOneWrite() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.holdSends(ofType: "CONNECT")
        let first = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { mock.sentMessages(ofType: "CONNECT").count == 2 }
        let returns = Counter()
        let second = Task {
            try await client.openVirtualConnection(to: Fixtures.transportID)
            _ = returns.increment()
        }
        try await Task.sleep(for: .milliseconds(100))
        let returnsBeforeRelease = returns.increment() - 1
        #expect(returnsBeforeRelease == 0)
        mock.releaseHeldSends()
        try await first.value
        try await second.value
        #expect(mock.sentMessages(ofType: "CONNECT").filter { $0.destinationID == Fixtures.transportID }.count == 1)
        #expect(await client.isConnected(to: Fixtures.transportID))
    }

    @Test func concurrentConnectsAllFailWhenTheWriteFails() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.holdSends(ofType: "CONNECT")
        mock.failSends(ofType: "CONNECT", with: .connectionFailed("broken pipe"))
        let first = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { mock.sentMessages(ofType: "CONNECT").count == 2 }
        let second = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await Task.sleep(for: .milliseconds(100))
        mock.releaseHeldSends()
        await #expect(throws: CastError.connectionFailed("broken pipe")) { try await first.value }
        await #expect(throws: CastError.connectionFailed("broken pipe")) { try await second.value }
        #expect(mock.sentMessages(ofType: "CONNECT").filter { $0.destinationID == Fixtures.transportID }.count == 1)
        #expect(await !client.isConnected(to: Fixtures.transportID))

        await #expect(throws: CastError.connectionFailed("broken pipe")) {
            try await client.openVirtualConnection(to: Fixtures.transportID)
        }
        #expect(mock.sentMessages(ofType: "CONNECT").filter { $0.destinationID == Fixtures.transportID }.count == 2)
    }

    @Test func closeDuringOpenWaitsForTheOpen() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.holdSends(ofType: "CONNECT")
        let opener = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { mock.sentMessages(ofType: "CONNECT").count == 2 }
        let closer = Task { await client.closeVirtualConnection(to: Fixtures.transportID) }
        try await eventually { await client.closesAwaitingOpen == 1 }
        #expect(mock.sentMessages(ofType: "CLOSE").isEmpty)
        mock.releaseHeldSends()
        try await opener.value
        await closer.value

        let wire = mock.sentMessages.filter { $0.destinationID == Fixtures.transportID }.compactMap(\.type)
        #expect(wire == ["CONNECT", "CLOSE"])
        #expect(await !client.isConnected(to: Fixtures.transportID))

        try await client.openVirtualConnection(to: Fixtures.transportID)
        #expect(mock.sentMessages(ofType: "CONNECT").filter { $0.destinationID == Fixtures.transportID }.count == 2)
        #expect(await client.isConnected(to: Fixtures.transportID))
    }

    @Test func staleConnectFailureKeepsTheReconnectedConnection() async throws {
        let mocks = [MockReceiver(), MockReceiver()]
        let index = Counter()
        let client = CastClient { mocks[min(index.increment(), mocks.count) - 1] }
        try await client.connect()
        mocks[0].failsHeldSendsOnClose = false
        mocks[0].holdSends(ofType: "CONNECT")
        let staleOpen = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { mocks[0].sentMessages(ofType: "CONNECT").count == 2 }

        mocks[0].drop(with: CastError.connectionFailed("wifi blip"))
        try await eventually { await client.state != .connected }
        try await client.connect()
        try await client.openVirtualConnection(to: Fixtures.transportID)

        mocks[0].releaseHeldSends()
        await #expect(throws: MockReceiver.cancelledSendError) { try await staleOpen.value }
        #expect(await client.isConnected(to: Fixtures.transportID))
    }

    @Test func closeAfterAFailedOpenSendsNoClose() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.holdSends(ofType: "CONNECT")
        mock.failSends(ofType: "CONNECT", with: .connectionFailed("broken pipe"))
        let opener = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { mock.sentMessages(ofType: "CONNECT").count == 2 }
        let closer = Task { await client.closeVirtualConnection(to: Fixtures.transportID) }
        try await eventually { await client.closesAwaitingOpen == 1 }

        mock.releaseHeldSends()
        await #expect(throws: CastError.connectionFailed("broken pipe")) { try await opener.value }
        await closer.value
        #expect(mock.sentMessages(ofType: "CLOSE").isEmpty)
        #expect(await !client.isConnected(to: Fixtures.transportID))
    }

    @Test func cancelledCloseDuringOpenLeavesTheConnectionOpen() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.holdSends(ofType: "CONNECT")
        let opener = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { mock.sentMessages(ofType: "CONNECT").count == 2 }
        let closer = Task { await client.closeVirtualConnection(to: Fixtures.transportID) }
        try await eventually { await client.closesAwaitingOpen == 1 }

        try await eventually { await client.closesWaitingOnOpen(to: Fixtures.transportID) == 1 }
        closer.cancel()
        await closer.value
        #expect(await client.closesAwaitingOpen == 0)
        #expect(await client.closesWaitingOnOpen(to: Fixtures.transportID) == 0)
        mock.releaseHeldSends()
        try await opener.value
        #expect(await client.isConnected(to: Fixtures.transportID))
        #expect(mock.sentMessages(ofType: "CLOSE").isEmpty)
    }

    @Test func cancelledLaterCloseLeavesTheEarlierCloseInCharge() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.holdSends(ofType: "CONNECT")
        let opener = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { mock.sentMessages(ofType: "CONNECT").count == 2 }
        let firstClose = Task { await client.closeVirtualConnection(to: Fixtures.transportID) }
        try await eventually { await client.closesWaitingOnOpen(to: Fixtures.transportID) == 1 }
        let cancelledClose = Task { await client.closeVirtualConnection(to: Fixtures.transportID) }
        try await eventually { await client.closesWaitingOnOpen(to: Fixtures.transportID) == 2 }

        cancelledClose.cancel()
        await cancelledClose.value
        #expect(await client.virtualConnectionIntent(for: Fixtures.transportID) == 2)
        mock.releaseHeldSends()
        try await opener.value
        await firstClose.value
        let wire = mock.sentMessages.filter { $0.destinationID == Fixtures.transportID }.compactMap(\.type)
        #expect(wire == ["CONNECT", "CLOSE"])
        #expect(await !client.isConnected(to: Fixtures.transportID))
    }

    @Test func closeCancelledBeforeItStartsLeavesTheEarlierCloseInCharge() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.holdSends(ofType: "CONNECT")
        let opener = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { mock.sentMessages(ofType: "CONNECT").count == 2 }
        let firstClose = Task { await client.closeVirtualConnection(to: Fixtures.transportID) }
        try await eventually { await client.closesWaitingOnOpen(to: Fixtures.transportID) == 1 }

        let cancelledClose = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await client.closeVirtualConnection(to: Fixtures.transportID)
        }
        await cancelledClose.value
        #expect(await client.virtualConnectionIntent(for: Fixtures.transportID) == 2)
        mock.releaseHeldSends()
        try await opener.value
        await firstClose.value
        let wire = mock.sentMessages.filter { $0.destinationID == Fixtures.transportID }.compactMap(\.type)
        #expect(wire == ["CONNECT", "CLOSE"])
        #expect(await !client.isConnected(to: Fixtures.transportID))
    }

    @Test func openRightAfterAWaitingCloseWritesItsOwnConnect() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.holdSends(ofType: "CONNECT")
        let opener = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { mock.sentMessages(ofType: "CONNECT").count == 2 }
        let closer = Task { await client.closeVirtualConnection(to: Fixtures.transportID) }
        try await eventually { await client.closesAwaitingOpen == 1 }

        mock.releaseHeldSends()
        await closer.value
        try await client.openVirtualConnection(to: Fixtures.transportID)
        try await opener.value
        let wire = mock.sentMessages.filter { $0.destinationID == Fixtures.transportID }.compactMap(\.type)
        #expect(wire == ["CONNECT", "CLOSE", "CONNECT"])
        #expect(await client.isConnected(to: Fixtures.transportID))
    }

    @Test func closesIssuedBeforeALaterOpenDoNotUndoIt() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.holdSends(ofType: "CONNECT")
        let opener = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { mock.sentMessages(ofType: "CONNECT").count == 2 }
        let firstClose = Task { await client.closeVirtualConnection(to: Fixtures.transportID) }
        try await eventually { await client.closesAwaitingOpen == 1 }
        let secondClose = Task { await client.closeVirtualConnection(to: Fixtures.transportID) }
        try await eventually { await client.closesAwaitingOpen == 2 }
        let laterOpen = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { await client.virtualConnectionIntent(for: Fixtures.transportID) == 4 }

        mock.releaseHeldSends()
        try await opener.value
        await firstClose.value
        await secondClose.value
        try await laterOpen.value
        let wire = mock.sentMessages.filter { $0.destinationID == Fixtures.transportID }.compactMap(\.type)
        #expect(wire == ["CONNECT"])
        #expect(await client.isConnected(to: Fixtures.transportID))
    }

    @Test func onlyTheLatestWaitingCloseIsSent() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.holdSends(ofType: "CONNECT")
        let opener = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { mock.sentMessages(ofType: "CONNECT").count == 2 }
        let firstClose = Task { await client.closeVirtualConnection(to: Fixtures.transportID) }
        try await eventually { await client.closesAwaitingOpen == 1 }
        let joiningOpen = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { await client.virtualConnectionIntent(for: Fixtures.transportID) == 3 }
        let lastClose = Task { await client.closeVirtualConnection(to: Fixtures.transportID) }
        try await eventually { await client.closesAwaitingOpen == 2 }

        mock.releaseHeldSends()
        try await opener.value
        try await joiningOpen.value
        await firstClose.value
        await lastClose.value
        let wire = mock.sentMessages.filter { $0.destinationID == Fixtures.transportID }.compactMap(\.type)
        #expect(wire == ["CONNECT", "CLOSE"])
        #expect(await !client.isConnected(to: Fixtures.transportID))
    }

    @Test func joinedOpenReopensAfterThePeerClosesMidOpen() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.holdSends(ofType: "CONNECT")
        let opener = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { mock.sentMessages(ofType: "CONNECT").count == 2 }
        let joiner = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { await client.virtualConnectionIntent(for: Fixtures.transportID) == 2 }
        mock.push(["type": "CLOSE"], namespace: .connection, from: Fixtures.transportID)
        try await eventually { await !client.isConnected(to: Fixtures.transportID) }

        mock.releaseHeldSends()
        try await opener.value
        try await joiner.value
        #expect(mock.sentMessages(ofType: "CONNECT").filter { $0.destinationID == Fixtures.transportID }.count == 2)
        #expect(await client.isConnected(to: Fixtures.transportID))
    }

    @Test func closeWaitingAcrossAReconnectLeavesTheReopenedConnection() async throws {
        let mocks = [MockReceiver(), MockReceiver()]
        let index = Counter()
        let client = CastClient { mocks[min(index.increment(), mocks.count) - 1] }
        try await client.connect()
        mocks[0].failsHeldSendsOnClose = false
        mocks[0].holdSends(ofType: "CONNECT")
        let staleOpen = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { mocks[0].sentMessages(ofType: "CONNECT").count == 2 }
        let staleClose = Task { await client.closeVirtualConnection(to: Fixtures.transportID) }
        try await eventually { await client.closesAwaitingOpen == 1 }

        mocks[0].drop(with: CastError.connectionFailed("wifi blip"))
        try await eventually { await client.state != .connected }
        try await client.connect()
        try await client.openVirtualConnection(to: Fixtures.transportID)

        mocks[0].releaseHeldSends(evenIfClosed: true)
        try await staleOpen.value
        await staleClose.value
        #expect(await client.isConnected(to: Fixtures.transportID))
        #expect(mocks[1].sentMessages(ofType: "CLOSE").isEmpty)
    }

    @Test func joinedOpenAcrossAReconnectThrowsAndLeavesTheNewConnectionAlone() async throws {
        let mocks = [MockReceiver(), MockReceiver()]
        let index = Counter()
        let client = CastClient { mocks[min(index.increment(), mocks.count) - 1] }
        try await client.connect()
        mocks[0].failsHeldSendsOnClose = false
        mocks[0].holdSends(ofType: "CONNECT")
        let staleOpen = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { mocks[0].heldSendCount == 1 }
        let staleJoiner = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { await client.virtualConnectionIntent(for: Fixtures.transportID) == 2 }

        mocks[0].drop(with: CastError.connectionFailed("wifi blip"))
        try await eventually { await client.state != .connected }
        try await client.connect()

        mocks[0].releaseHeldSends(evenIfClosed: true)
        _ = await staleOpen.result
        await #expect(throws: CastError.notConnected) { try await staleJoiner.value }
        #expect(mocks[1].sentMessages(ofType: "CONNECT").filter { $0.destinationID == Fixtures.transportID }.isEmpty)
        #expect(await !client.isConnected(to: Fixtures.transportID))

        try await client.openVirtualConnection(to: Fixtures.transportID)
        #expect(mocks[1].sentMessages(ofType: "CONNECT").filter { $0.destinationID == Fixtures.transportID }.count == 1)
        #expect(await client.isConnected(to: Fixtures.transportID))
    }

    @Test func destinationIsConnectedBeforeTheConnectWriteCompletes() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        mock.holdSends(ofType: "CONNECT")
        let opener = Task { try await client.openVirtualConnection(to: Fixtures.transportID) }
        try await eventually { mock.sentMessages(ofType: "CONNECT").count == 2 }

        mock.push(["type": "CONNECTED", "protocolVersion": 1], namespace: .connection, from: Fixtures.transportID)
        try await eventually { await client.negotiatedProtocolVersion(for: Fixtures.transportID) == 1 }
        mock.releaseHeldSends()
        try await opener.value
        #expect(await client.negotiatedProtocolVersion(for: Fixtures.transportID) == 1)
    }

    @Test func deviceAuthAcceptsBinaryPayloads() async throws {
        let mock = MockReceiver()
        let client = makeClient(mock)
        try await client.connect()
        var messages = client.messages().filter { $0.namespace != .heartbeat }.makeAsyncIterator()
        mock.push(payload: .binary(Data([1, 2, 3])), namespace: .deviceAuth)
        mock.push(payload: .binary(Data([4, 5, 6])), namespace: .receiver)
        mock.push(Fixtures.receiverStatus(level: 0.4), namespace: .receiver)
        var beforeSentinel: [InboundMessage] = []
        while let message = await messages.next(), message.type != "RECEIVER_STATUS" {
            beforeSentinel.append(message)
        }
        #expect(beforeSentinel.map(\.namespace) == [.deviceAuth])
        #expect(beforeSentinel.map(\.raw.payload) == [.binary(Data([1, 2, 3]))])
    }

    @Test func requestIDsAreSequentialPerClient() async throws {
        let mock = MockReceiver()
        Fixtures.installDefaultReceiver(on: mock)
        let client = makeClient(mock)
        try await client.connect()
        _ = try await client.receiver.getStatus()
        _ = try await client.receiver.getStatus()
        let otherMock = MockReceiver()
        Fixtures.installDefaultReceiver(on: otherMock)
        let second = makeClient(otherMock)
        try await second.connect()
        _ = try await second.receiver.getStatus()
        #expect(mock.sentMessages(ofType: "GET_STATUS").compactMap(\.requestID) == [1, 2])
        #expect(otherMock.sentMessages(ofType: "GET_STATUS").compactMap(\.requestID) == [1])
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
        try await eventually { mock.heldSendCount == 1 }
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
