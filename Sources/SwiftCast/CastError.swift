import Foundation

/// Errors produced by SwiftCast.
public enum CastError: Error, Sendable, Equatable, LocalizedError {
    /// The client is not connected (or the connection was lost).
    case notConnected
    /// The underlying transport failed.
    case connectionFailed(String)
    /// The receiver stopped responding to heartbeats.
    case heartbeatTimeout
    /// A request did not receive a response in time.
    case timeout
    /// Bytes received from the device could not be decoded.
    case malformedMessage(String)
    /// The receiver refused to launch an application.
    case launchFailed(reason: String?)
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

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the Cast device."
        case .connectionFailed(let message): "Connection failed: \(message)"
        case .heartbeatTimeout: "The Cast device stopped responding."
        case .timeout: "The Cast device did not respond in time."
        case .malformedMessage(let message): "Malformed message: \(message)"
        case .launchFailed(let reason): "Failed to launch app\(reason.map { ": \($0)" } ?? ".")"
        case .invalidRequest(let info): "Invalid request\(Self.suffix(info))"
        case .loadFailed(let info): "Media failed to load\(Self.suffix(info))"
        case .loadCancelled(let info): "The media load was cancelled\(Self.suffix(info))"
        case .invalidPlayerState(let info): "The command is not valid in the current player state\(Self.suffix(info))"
        case .mediaError(let info): "The receiver reported a media error\(Self.suffix(info))"
        case .noMediaSession: "There is no active media session."
        case .sessionClosed: "The Cast session was closed."
        case .applicationNotRunning: "The application is not running on the Cast device."
        case .unexpectedResponse(let message): "Unexpected response: \(message)"
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

    private static func suffix(_ info: MediaErrorInfo) -> String {
        info.summary.map { ": \($0)" } ?? "."
    }
}
