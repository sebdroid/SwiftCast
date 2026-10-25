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
    /// An outbound message body of the given byte count exceeds the Cast frame limit.
    case messageTooLarge(Int)
    /// The receiver refused to launch an application.
    case launchFailed(reason: String?)
    /// The receiver or application rejected a request.
    case invalidRequest(reason: String?)
    /// Media failed to load on the receiver.
    case loadFailed(reason: String?, detailedErrorCode: Int?)
    /// A media load was cancelled by a subsequent load.
    case loadCancelled
    /// The media command is not valid in the current player state.
    case invalidPlayerState
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
        case .messageTooLarge(let byteCount): "Message body of \(byteCount) bytes exceeds the \(FrameCodec.maximumOutboundBodyLength) byte limit"
        case .launchFailed(let reason): "Failed to launch app\(reason.map { ": \($0)" } ?? ".")"
        case .invalidRequest(let reason): "Invalid request\(reason.map { ": \($0)" } ?? ".")"
        case .loadFailed(let reason, _): "Media failed to load\(reason.map { ": \($0)" } ?? ".")"
        case .loadCancelled: "The media load was cancelled."
        case .invalidPlayerState: "The command is not valid in the current player state."
        case .noMediaSession: "There is no active media session."
        case .sessionClosed: "The Cast session was closed."
        case .applicationNotRunning: "The application is not running on the Cast device."
        case .unexpectedResponse(let message): "Unexpected response: \(message)"
        }
    }
}
