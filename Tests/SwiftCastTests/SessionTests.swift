import Foundation
import Testing
@testable import SwiftCast

@Suite("CastSession", .timeLimit(.minutes(1)))
@MainActor
struct SessionTests {
    let device = CastDevice(host: "192.0.2.1", name: "Test TV")

    @Test func connectLoadAndControl() async throws {
        let mock = MockReceiver()
        Fixtures.installDefaultReceiver(on: mock)
        let session = CastSession { _ in CastClient { mock } }

        try await session.connect(to: device)
        #expect(session.isConnected)
        #expect(session.volume == 0.5)
        #expect(session.mediaController == nil)

        try await session.load(MediaInformation(url: URL(string: "https://example.com/v.mp4")!, contentType: "video/mp4"))
        #expect(session.mediaStatus?.mediaSessionId == 1)
        #expect(session.duration == 596.5)

        try await session.pause()
        #expect(session.mediaStatus?.playerState == .paused)
        #expect(session.estimatedTime() == 42)
        try await session.togglePlayPause()
        #expect(session.isPlaying)

        await session.disconnect()
        #expect(session.connectionState == .disconnected)
        #expect(session.mediaStatus == nil)
    }

    @Test func joinsRunningApplicationOnConnect() async throws {
        let mock = MockReceiver()
        Fixtures.installDefaultReceiver(on: mock, appRunning: true)
        let session = CastSession { _ in CastClient { mock } }
        try await session.connect(to: device)
        #expect(session.mediaController != nil)
        #expect(mock.sentMessages(ofType: "LAUNCH").isEmpty)
    }

    @Test func reconnectsAfterConnectionLoss() async throws {
        let mocks = [MockReceiver(), MockReceiver()]
        mocks.forEach { Fixtures.installDefaultReceiver(on: $0, appRunning: true) }
        let session = CastSession(makeClient: Self.clients(mocks))
        session.reconnectPolicy = CastSession.ReconnectPolicy(attemptInterval: .milliseconds(50), window: .seconds(5))
        try await session.connect(to: device)
        #expect(session.isConnected)

        mocks[0].drop(with: CastError.connectionFailed("wifi blip"))
        try await eventually { await MainActor.run { session.connectionState == .reconnecting(device, attempt: 1) } }
        try await eventually { await MainActor.run { session.isConnected && session.mediaController != nil } }
        #expect(mocks[1].sentMessages(ofType: "CONNECT").count >= 2) // platform + app
    }

    @Test func resumesWhenDeviceReturnsInsideWindow() async throws {
        let first = MockReceiver()
        Fixtures.installDefaultReceiver(on: first, appRunning: true)
        let unreachable = (0..<2).map { _ in MockReceiver() }
        unreachable.forEach { $0.failOpen(with: .connectionFailed("unreachable")) }
        let back = MockReceiver()
        Fixtures.installDefaultReceiver(on: back, appRunning: true)
        let session = CastSession(makeClient: Self.clients([first] + unreachable + [back]))
        session.reconnectPolicy = CastSession.ReconnectPolicy(attemptInterval: .milliseconds(50), window: .seconds(5))
        try await session.connect(to: device)

        first.drop(with: CastError.connectionFailed("gone"))
        try await eventually { await MainActor.run { session.connectionState == .reconnecting(device, attempt: 3) } }
        try await eventually { await MainActor.run { session.isConnected && session.mediaController != nil } }
        #expect(back.sentMessages(ofType: "CONNECT").count >= 2)
    }

    @Test func failsOnceReconnectWindowPasses() async throws {
        let first = MockReceiver()
        Fixtures.installDefaultReceiver(on: first)
        let attempts = AttemptLog()
        let session = CastSession { _ in
            if attempts.record() == 1 { return CastClient { first } }
            let failing = MockReceiver()
            failing.failOpen(with: .connectionFailed("unreachable"))
            return CastClient { failing }
        }
        session.reconnectPolicy = CastSession.ReconnectPolicy(attemptInterval: .milliseconds(50), window: .milliseconds(300))
        try await session.connect(to: device)
        first.drop(with: CastError.connectionFailed("gone"))
        try await eventually {
            await MainActor.run { if case .failed = session.connectionState { true } else { false } }
        }
        #expect(session.connectionState == .failed(device, .connectionFailed("gone")))
        #expect((2...7).contains(attempts.count - 1))
    }

    @Test func flappingDeviceIsRetriedAtIntervalsUntilWindowPasses() async throws {
        let first = MockReceiver()
        Fixtures.installDefaultReceiver(on: first)
        let attempts = AttemptLog()
        let session = CastSession { _ in
            if attempts.record() == 1 { return CastClient { first } }
            let flapping = MockReceiver()
            flapping.on("GET_STATUS") { _, mock in mock.drop(with: CastError.connectionFailed("reset")) }
            return CastClient { flapping }
        }
        let interval = Duration.milliseconds(200)
        session.reconnectPolicy = CastSession.ReconnectPolicy(attemptInterval: interval, window: .milliseconds(900))
        try await session.connect(to: device)
        let lost = ContinuousClock.now
        first.drop(with: CastError.connectionFailed("gone"))
        try await eventually {
            await MainActor.run { if case .failed = session.connectionState { true } else { false } }
        }
        let failedAt = ContinuousClock.now
        #expect(session.connectionState == .failed(device, .connectionFailed("gone")))

        let starts = attempts.instants.dropFirst()
        #expect((3...4).contains(starts.count))
        #expect(try #require(starts.first) - lost >= interval)
        for (previous, next) in zip(starts, starts.dropFirst()) {
            #expect(next - previous >= interval)
        }
        #expect(failedAt - lost <= .milliseconds(900) + interval)

        try await Task.sleep(for: interval * 2)
        #expect(attempts.count == starts.count + 1)
    }

    @Test func windowEqualToIntervalMakesExactlyOneAttempt() async throws {
        let first = MockReceiver()
        Fixtures.installDefaultReceiver(on: first)
        let attempts = AttemptLog()
        let session = CastSession { _ in
            if attempts.record() == 1 { return CastClient { first } }
            let failing = MockReceiver()
            failing.failOpen(with: .connectionFailed("unreachable"))
            return CastClient { failing }
        }
        let interval = Duration.milliseconds(100)
        session.reconnectPolicy = CastSession.ReconnectPolicy(attemptInterval: interval, window: interval)
        try await session.connect(to: device)
        first.drop(with: CastError.connectionFailed("gone"))
        try await eventually { await MainActor.run { session.connectionState == .reconnecting(device, attempt: 1) } }
        try await eventually {
            await MainActor.run { if case .failed = session.connectionState { true } else { false } }
        }
        #expect(session.connectionState == .failed(device, .connectionFailed("gone")))
        try await Task.sleep(for: interval * 2)
        #expect(attempts.count == 2)
    }

    @Test func windowShorterThanIntervalStillMakesOneAttempt() async throws {
        let first = MockReceiver()
        Fixtures.installDefaultReceiver(on: first)
        let attempts = AttemptLog()
        let session = CastSession { _ in
            if attempts.record() == 1 { return CastClient { first } }
            let failing = MockReceiver()
            failing.failOpen(with: .connectionFailed("unreachable"))
            return CastClient { failing }
        }
        let interval = Duration.milliseconds(100)
        session.reconnectPolicy = CastSession.ReconnectPolicy(attemptInterval: interval, window: .milliseconds(10))
        try await session.connect(to: device)
        first.drop(with: CastError.connectionFailed("gone"))
        try await eventually {
            await MainActor.run { if case .failed = session.connectionState { true } else { false } }
        }
        #expect(session.connectionState == .failed(device, .connectionFailed("gone")))
        try await Task.sleep(for: interval * 2)
        #expect(attempts.count == 2)
    }

    @Test func deviceThatDropsAfterConnectingGetsAFreshWindowPerLoss() async throws {
        let healthy = (0..<5).map { _ in MockReceiver() }
        healthy.forEach { Fixtures.installDefaultReceiver(on: $0) }
        let attempts = AttemptLog()
        let session = CastSession { _ in
            let index = attempts.record()
            if index <= healthy.count { return CastClient { healthy[index - 1] } }
            let silent = MockReceiver()
            silent.failOpen(with: .connectionFailed("unreachable"))
            return CastClient { silent }
        }
        let interval = Duration.milliseconds(100)
        let window = Duration.milliseconds(250)
        session.reconnectPolicy = CastSession.ReconnectPolicy(attemptInterval: interval, window: window)
        try await session.connect(to: device)

        var losses: [ContinuousClock.Instant] = []
        for (index, mock) in healthy.dropLast().enumerated() {
            losses.append(.now)
            mock.drop(with: CastError.connectionFailed("reset"))
            try await eventually { attempts.count >= index + 2 }
            try await eventually { await MainActor.run { session.isConnected } }
        }
        let starts = attempts.instants
        #expect(starts.count == healthy.count)
        for (loss, start) in zip(losses, starts.dropFirst()) {
            #expect(start - loss >= interval)
        }
        // Each loss opens its own window, so reconnecting continues past the first one.
        #expect(starts[healthy.count - 1] - losses[0] > window)
        #expect(healthy.dropFirst().allSatisfy { !$0.sentMessages(ofType: "GET_STATUS").isEmpty })

        let finalLoss = ContinuousClock.now
        healthy[healthy.count - 1].drop(with: CastError.connectionFailed("reset"))
        try await eventually {
            await MainActor.run { if case .failed = session.connectionState { true } else { false } }
        }
        let failedAt = ContinuousClock.now
        #expect(session.connectionState == .failed(device, .connectionFailed("reset")))
        #expect(failedAt - finalLoss <= window + interval)

        let retries = attempts.instants.dropFirst(healthy.count)
        #expect((1...3).contains(retries.count))
        if let firstRetry = retries.first { #expect(firstRetry - finalLoss >= interval) }
        for (previous, next) in zip(retries, retries.dropFirst()) {
            #expect(next - previous >= interval)
        }
    }

    @Test func rejoinsAppThatAppearsAfterReconnect() async throws {
        let first = MockReceiver()
        Fixtures.installDefaultReceiver(on: first, appRunning: true)
        let second = MockReceiver()
        let running = Fixtures.installDefaultReceiver(on: second, appRunning: false)
        let session = CastSession(makeClient: Self.clients([first, second]))
        var policy = CastSession.ReconnectPolicy(attemptInterval: .milliseconds(50), window: .seconds(5))
        policy.rejoinInterval = .milliseconds(50)
        policy.rejoinWindow = .seconds(5)
        session.reconnectPolicy = policy
        try await session.connect(to: device)

        first.drop(with: CastError.connectionFailed("blip"))
        try await reconnected(session)
        try await eventually { second.sentMessages(ofType: "GET_STATUS").count >= 3 }
        #expect(session.mediaController == nil)

        running.withLock { $0 = true }
        try await eventually { await MainActor.run { session.mediaController != nil } }
        #expect(session.mediaController?.application.sessionId == Fixtures.sessionID)
        #expect(session.isConnected)
    }

    @Test func stopsRejoiningAfterRejoinWindow() async throws {
        let first = MockReceiver()
        Fixtures.installDefaultReceiver(on: first, appRunning: true)
        let second = MockReceiver()
        Fixtures.installDefaultReceiver(on: second, appRunning: false)
        let session = CastSession(makeClient: Self.clients([first, second]))
        var policy = CastSession.ReconnectPolicy(attemptInterval: .milliseconds(50), window: .seconds(5))
        policy.rejoinInterval = .milliseconds(50)
        policy.rejoinWindow = .milliseconds(200)
        session.reconnectPolicy = policy
        try await session.connect(to: device)

        first.drop(with: CastError.connectionFailed("blip"))
        try await reconnected(session)
        try await Task.sleep(for: .milliseconds(400))
        let polls = second.sentMessages(ofType: "GET_STATUS").count
        try await Task.sleep(for: .milliseconds(200))
        #expect(second.sentMessages(ofType: "GET_STATUS").count == polls)
        #expect(session.isConnected)
        #expect(session.mediaController == nil)
    }

    @Test func appThatLeavesWhileDetachedIsNotRejoinedAfterReconnect() async throws {
        let first = MockReceiver()
        let firstRunning = Fixtures.installDefaultReceiver(on: first, appRunning: true)
        let second = MockReceiver()
        Fixtures.installDefaultReceiver(on: second, appRunning: false)
        let session = CastSession(makeClient: Self.clients([first, second]))
        var policy = CastSession.ReconnectPolicy(attemptInterval: .milliseconds(50), window: .seconds(5))
        policy.rejoinInterval = .milliseconds(50)
        policy.rejoinWindow = .seconds(5)
        session.reconnectPolicy = policy
        try await session.connect(to: device)
        #expect(session.mediaController != nil)

        first.push(["type": "CLOSE"], namespace: .connection, from: Fixtures.transportID)
        try await eventually { await MainActor.run { session.mediaController == nil } }
        firstRunning.withLock { $0 = false }
        first.push(Fixtures.receiverStatus(apps: []), namespace: .receiver, to: "*")
        try await eventually { await MainActor.run { session.receiverStatus.map { $0.application(session.appID) == nil } ?? false } }

        first.drop(with: CastError.connectionFailed("blip"))
        try await reconnected(session)
        try await Task.sleep(for: .milliseconds(300))
        #expect(second.sentMessages(ofType: "GET_STATUS").count == 1)
        #expect(session.isConnected)
        #expect(session.mediaController == nil)
    }

    @Test func failedStatusDuringConnectLeavesNoClientBehind() async throws {
        let mock = MockReceiver()
        mock.on("GET_STATUS") { request, mock in
            mock.reply(to: request, ["type": "INVALID_REQUEST", "reason": "INVALID_COMMAND"])
        }
        let session = CastSession { _ in CastClient { mock } }
        await #expect(throws: CastError.self) { try await session.connect(to: device) }
        #expect(session.client == nil)
        #expect(!session.isConnected)
        if case .failed = session.connectionState {} else {
            Issue.record("expected failed, got \(session.connectionState)")
        }
        #expect(mock.sentMessages(ofType: "CLOSE").map(\.destinationID) == [CastEndpoint.platformReceiver])
    }

    @Test(arguments: [CastSession.AutoJoinPolicy.sameSession, .sameApp, .never])
    func autoJoinAfterReconnectWithDifferentSession(policy: CastSession.AutoJoinPolicy) async throws {
        let first = MockReceiver()
        Fixtures.installDefaultReceiver(on: first, appRunning: true)
        let second = MockReceiver()
        Fixtures.installDefaultReceiver(on: second, appRunning: true, sessionID: "another-sender-session")
        let session = CastSession(makeClient: Self.clients([first, second]))
        session.reconnectPolicy = CastSession.ReconnectPolicy(attemptInterval: .milliseconds(50), window: .seconds(5))
        session.autoJoinPolicy = policy
        try await session.connect(to: device)
        #expect(session.mediaController != nil)

        first.drop(with: CastError.connectionFailed("blip"))
        try await reconnected(session)
        if policy == .sameApp {
            try await eventually { await MainActor.run { session.mediaController != nil } }
            #expect(session.mediaController?.application.sessionId == "another-sender-session")
        } else {
            try await Task.sleep(for: .milliseconds(200))
            #expect(session.mediaController == nil)
            #expect(second.sentMessages(ofType: "CONNECT").map(\.destinationID) == [CastEndpoint.platformReceiver])
        }
    }

    @Test func rejoinsSameSessionAfterReconnect() async throws {
        let mocks = [MockReceiver(), MockReceiver()]
        mocks.forEach { Fixtures.installDefaultReceiver(on: $0, appRunning: true) }
        let session = CastSession(makeClient: Self.clients(mocks))
        session.reconnectPolicy = CastSession.ReconnectPolicy(attemptInterval: .milliseconds(50), window: .seconds(5))
        try await session.connect(to: device)

        mocks[0].drop(with: CastError.connectionFailed("blip"))
        try await reconnected(session)
        try await eventually { await MainActor.run { session.mediaController != nil } }
        #expect(session.mediaController?.application.sessionId == Fixtures.sessionID)
    }

    @Test func neverPolicyLeavesRejoiningToTheCaller() async throws {
        let mocks = [MockReceiver(), MockReceiver()]
        mocks.forEach { Fixtures.installDefaultReceiver(on: $0, appRunning: true) }
        let session = CastSession(makeClient: Self.clients(mocks))
        session.reconnectPolicy = CastSession.ReconnectPolicy(attemptInterval: .milliseconds(50), window: .seconds(5))
        session.autoJoinPolicy = .never
        try await session.connect(to: device)
        #expect(session.mediaController != nil)

        mocks[0].drop(with: CastError.connectionFailed("blip"))
        try await reconnected(session)
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.mediaController == nil)

        try await session.load(MediaInformation(url: URL(string: "https://example.com/v.mp4")!, contentType: "video/mp4"))
        #expect(session.mediaController?.application.sessionId == Fixtures.sessionID)
        #expect(mocks[1].sentMessages(ofType: "LAUNCH").isEmpty)
    }

    @Test func clearsMediaWhenAppStopsRemotely() async throws {
        let mock = MockReceiver()
        Fixtures.installDefaultReceiver(on: mock, appRunning: true)
        let session = CastSession { _ in CastClient { mock } }
        try await session.connect(to: device)
        try await session.load(MediaInformation(url: URL(string: "https://example.com/v.mp4")!, contentType: "video/mp4"))
        mock.push(Fixtures.receiverStatus(apps: []), namespace: .receiver, to: "*")
        try await eventually { await MainActor.run { session.mediaController == nil && session.mediaStatus == nil } }
        #expect(session.isConnected)
    }

    private func reconnected(_ session: CastSession) async throws {
        try await eventually { await MainActor.run { if case .reconnecting = session.connectionState { true } else { false } } }
        try await eventually { await MainActor.run { session.isConnected } }
    }

    private static func clients(_ mocks: [MockReceiver]) -> @Sendable (CastDevice) -> CastClient {
        let index = Counter()
        return { _ in
            let mock = mocks[min(index.increment(), mocks.count) - 1]
            return CastClient { mock }
        }
    }
}

/// Records when each client is created, which is when each connection attempt starts.
final class AttemptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [ContinuousClock.Instant] = []

    func record() -> Int {
        lock.lock(); defer { lock.unlock() }
        starts.append(.now)
        return starts.count
    }

    var instants: [ContinuousClock.Instant] {
        lock.lock(); defer { lock.unlock() }
        return starts
    }

    var count: Int { instants.count }
}
