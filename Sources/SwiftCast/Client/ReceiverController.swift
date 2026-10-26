import Foundation

/// Controls the platform receiver of a Cast device: launching and stopping
/// applications, device volume and status.
public struct ReceiverController: Sendable {
    let client: CastClient

    private var destination: String { CastEndpoint.platformReceiver }

    /// Fetches the current receiver status.
    @discardableResult
    public func getStatus() async throws -> ReceiverStatus {
        let response = try await client.request(Request(type: "GET_STATUS"), namespace: .receiver, to: destination)
        return try decodeStatus(response)
    }

    /// How long ``launch(_:timeout:onStatus:)`` waits by default.
    public static let defaultLaunchTimeout: Duration = .seconds(60)
    /// The longest a launch waits; longer timeouts are clamped to this.
    public static let maximumLaunchTimeout: Duration = .seconds(120)

    /// Launches an application and returns it once it is running.
    ///
    /// The launch completes when the receiver answers it with a
    /// `RECEIVER_STATUS` listing the application, or fails with a
    /// `LAUNCH_ERROR` (see ``CastError/launchErrorReason``). While the device
    /// waits for the user to allow the launch it sends `LAUNCH_STATUS`
    /// updates such as `USER_PENDING_AUTHORIZATION`, which are passed to
    /// `onStatus` and keep the launch waiting. Unsolicited status broadcasts
    /// never complete a launch, since they can describe an older instance of
    /// the application.
    ///
    /// Only one launch may be pending per client at a time. A call for the
    /// same application meanwhile joins the pending launch instead of sending
    /// another `LAUNCH`: it shares that launch's reply, timeout and result,
    /// and its own `timeout` and `onStatus` are ignored, so only the first
    /// caller sees `LAUNCH_STATUS` updates. Cancelling the first caller
    /// cancels the launch for every caller; cancelling a joined caller only
    /// makes that call throw `CancellationError`. A call for a different
    /// application meanwhile throws ``CastError/requestInFlight(_:)``. If the application
    /// is already running it is relaunched by the receiver; use
    /// ``CastClient/launchMediaApp(_:)`` to join instead.
    ///
    /// - Parameters:
    ///   - timeout: How long to wait for the whole launch, at most ``maximumLaunchTimeout``.
    ///   - onStatus: Called on the client's actor with the `status` of each
    ///     `LAUNCH_STATUS` update, so it should return quickly.
    public func launch(
        _ appID: CastAppID,
        timeout: Duration = ReceiverController.defaultLaunchTimeout,
        onStatus: (@Sendable (String) -> Void)? = nil
    ) async throws -> CastApplication {
        try await client.coalescedLaunch(appID) {
            try await sendLaunch(appID, timeout: timeout, onStatus: onStatus)
        }
    }

    private func sendLaunch(
        _ appID: CastAppID,
        timeout: Duration,
        onStatus: (@Sendable (String) -> Void)?
    ) async throws -> CastApplication {
        let options = CastClient.RequestOptions(exclusive: true, acceptsLaunchRequestID: true) { message in
            guard message.type == "LAUNCH_STATUS" else { return true }
            if let status = message.json?["status"]?.stringValue { onStatus?(status) }
            return false
        }
        let response = try await client.request(
            LaunchRequest(appId: appID),
            namespace: .receiver,
            to: destination,
            timeout: Self.clampedLaunchTimeout(timeout),
            options: options
        )
        let status = try decodeStatus(response)
        guard let app = status.applications?.first(where: { $0.appId == appID && $0.transportId != CastEndpoint.platformReceiver }) else {
            throw CastError.launchFailed(reason: "application not listed after launch")
        }
        return app
    }

    static func clampedLaunchTimeout(_ timeout: Duration) -> Duration {
        min(timeout, maximumLaunchTimeout)
    }

    /// Stops a running application session.
    ///
    /// Only one stop may be pending per client at a time; a second call
    /// meanwhile throws ``CastError/requestInFlight(_:)``.
    @discardableResult
    public func stop(sessionID: String) async throws -> ReceiverStatus {
        let response = try await client.request(
            StopRequest(sessionId: sessionID),
            namespace: .receiver,
            to: destination,
            timeout: nil,
            options: CastClient.RequestOptions(exclusive: true)
        )
        return try decodeStatus(response)
    }

    /// Stops the given application if it is running.
    public func stop(_ application: CastApplication) async throws {
        try await stop(sessionID: application.sessionId)
    }

    /// Sets the device volume level (0.0–1.0).
    @discardableResult
    public func setVolume(_ level: Double) async throws -> ReceiverStatus {
        let clamped = min(max(level, 0), 1)
        let response = try await client.request(VolumeRequest(volume: CastVolume(level: clamped)), namespace: .receiver, to: destination)
        return try decodeStatus(response)
    }

    /// Mutes or unmutes the device.
    @discardableResult
    public func setMuted(_ muted: Bool) async throws -> ReceiverStatus {
        let response = try await client.request(VolumeRequest(volume: CastVolume(muted: muted)), namespace: .receiver, to: destination)
        return try decodeStatus(response)
    }

    /// Queries whether the device can run the given applications.
    public func availability(of appIDs: [CastAppID]) async throws -> [CastAppID: CastAppAvailability] {
        let response = try await client.request(AvailabilityRequest(appId: appIDs), namespace: .receiver, to: destination)
        guard let object = response.json?["availability"]?.objectValue else {
            throw CastError.unexpectedResponse("Missing availability")
        }
        var result: [CastAppID: CastAppAvailability] = [:]
        for (key, value) in object {
            if let raw = value.stringValue, let availability = CastAppAvailability(rawValue: raw) {
                result[CastAppID(key)] = availability
            }
        }
        return result
    }

    private func decodeStatus(_ message: InboundMessage) throws -> ReceiverStatus {
        guard message.type == "RECEIVER_STATUS", let json = message.json?["status"] else {
            throw CastError.unexpectedResponse(message.type ?? "untyped message")
        }
        return try json.decode(ReceiverStatus.self)
    }

    private struct Request: Encodable, Sendable { let type: String }
    private struct LaunchRequest: Encodable, Sendable { let type = "LAUNCH"; let appId: CastAppID }
    private struct StopRequest: Encodable, Sendable { let type = "STOP"; let sessionId: String }
    private struct VolumeRequest: Encodable, Sendable { let type = "SET_VOLUME"; let volume: CastVolume }
    private struct AvailabilityRequest: Encodable, Sendable { let type = "GET_APP_AVAILABILITY"; let appId: [CastAppID] }
}
