import Foundation

/// Errors produced by SwiftCast.
public enum CastError: Error, Sendable, Equatable, LocalizedError {
    /// The client is not connected (or the connection was lost).
    case notConnected
    /// The underlying transport failed.
    case connectionFailed(String)
    /// The Cast device closed the platform connection.
    case closedByReceiver
    /// The receiver stopped responding to heartbeats.
    case heartbeatTimeout
    /// A request did not receive a response in time.
    case timeout
    /// A message could not be framed for sending or decoded after receipt.
    case malformedMessage(String)
    /// An outbound message body of the given byte count exceeds the Cast frame limit.
    case messageTooLarge(Int)
    /// The receiver refused to launch an application, or its reply did not
    /// list the application. See ``launchErrorReason`` for the typed reasons.
    case launchFailed(reason: String?)
    /// A request payload was rejected locally, before anything was sent.
    case invalidPayload(String)
    /// The receiver or application rejected a request.
    case invalidRequest(MediaErrorInfo)
    /// Media failed to load on the receiver.
    case loadFailed(MediaErrorInfo)
    /// A media load was cancelled by a subsequent load.
    case loadCancelled(MediaErrorInfo)
    /// The media command is not valid in the current player state.
    case invalidPlayerState(MediaErrorInfo)
    /// The receiver application reported a generic media error.
    case mediaError(MediaErrorInfo)
    /// No media session exists to send a media command to.
    case noMediaSession
    /// The application session closed (e.g. stopped by another sender).
    case sessionClosed
    /// The requested application is not running on the receiver.
    case applicationNotRunning
    /// A response arrived but could not be interpreted.
    case unexpectedResponse(String)
    /// A request of the given type, such as `LAUNCH` or `STOP`, is already
    /// pending on this connection and only one may be in flight at a time.
    case requestInFlight(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the Cast device."
        case .connectionFailed(let message): "Connection failed: \(message.displaySanitized)"
        case .closedByReceiver: "The Cast device closed the connection."
        case .heartbeatTimeout: "The Cast device stopped responding."
        case .timeout: "The Cast device did not respond in time."
        case .malformedMessage(let message): "Malformed message: \(message.displaySanitized)"
        case .messageTooLarge(let byteCount): "Message body of \(byteCount) bytes exceeds the \(FrameCodec.maximumOutboundBodyLength) byte limit"
        case .launchFailed(let reason): "Failed to launch app\(reason.map { ": \($0.displaySanitized)" } ?? ".")"
        case .invalidPayload(let message): "Invalid payload: \(message.displaySanitized)"
        case .invalidRequest(let info): "Invalid request\(Self.suffix(info))"
        case .loadFailed(let info): "Media failed to load\(Self.suffix(info))"
        case .loadCancelled(let info): "The media load was cancelled\(Self.suffix(info))"
        case .invalidPlayerState(let info): "The command is not valid in the current player state\(Self.suffix(info))"
        case .mediaError(let info): "The receiver reported a media error\(Self.suffix(info))"
        case .noMediaSession: "There is no active media session."
        case .sessionClosed: "The Cast session was closed."
        case .applicationNotRunning: "The application is not running on the Cast device."
        case .unexpectedResponse(let message): "Unexpected response: \(message.displaySanitized)"
        case .requestInFlight(let type): "A \(type.displaySanitized) request is already in flight."
        }
    }

    /// The receiver's error details, for errors decoded from a media or receiver error reply.
    public var mediaErrorInfo: MediaErrorInfo? {
        switch self {
        case .invalidRequest(let info), .loadFailed(let info), .loadCancelled(let info),
             .invalidPlayerState(let info), .mediaError(let info):
            info
        default:
            nil
        }
    }

    /// The reason a ``launchFailed(reason:)`` error carries, typed so the
    /// known codes can be matched without comparing strings.
    public var launchErrorReason: LaunchErrorReason? {
        guard case .launchFailed(let reason?) = self else { return nil }
        return LaunchErrorReason(rawValue: reason)
    }

    private static func suffix(_ info: MediaErrorInfo) -> String {
        info.summary.map { ": \($0.displaySanitized)" } ?? "."
    }
}

/// Why a launch failed: the reason a receiver gives in a `LAUNCH_ERROR`
/// reply, taken from its `extendedError`, else its `error`, else its
/// `reason` field, or ``applicationNotListed``.
public enum LaunchErrorReason: OpenStringEnum {
    /// The user declined the launch prompt on the device.
    case userNotAllowed
    /// The device could not ask the user because its launch prompts are turned off.
    case notificationDisabled
    /// Produced locally, not by a receiver: the reply to the launch listed
    /// no matching application.
    case applicationNotListed
    case unknown(String)

    public static let knownCases: [LaunchErrorReason] = [.userNotAllowed, .notificationDisabled, .applicationNotListed]

    public var rawValue: String {
        switch self {
        case .userNotAllowed: "USER_NOT_ALLOWED"
        case .notificationDisabled: "NOTIFICATION_DISABLED"
        case .applicationNotListed: "APPLICATION_NOT_LISTED"
        case .unknown(let value): value
        }
    }
}
