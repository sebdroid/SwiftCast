/// Why a receiver rejected a media request.
public enum MediaErrorReason: OpenStringEnum {
    case invalidCommand
    case invalidParams
    case invalidMediaSessionId
    case invalidRequestId
    case skipLimitReached
    case notSupported
    case languageNotSupported
    case endOfQueue
    case duplicateRequestId
    case videoDeviceRequired
    case premiumAccountRequired
    case appError
    case authenticationExpired
    case concurrentStreamLimit
    case parentalControlRestricted
    case contentFiltered
    case notAvailableInRegion
    case contentAlreadyPlaying
    case invalidRequest
    case genericLoadError
    case unknown(String)

    public static let knownCases: [MediaErrorReason] = [
        .invalidCommand, .invalidParams, .invalidMediaSessionId, .invalidRequestId, .skipLimitReached,
        .notSupported, .languageNotSupported, .endOfQueue, .duplicateRequestId, .videoDeviceRequired,
        .premiumAccountRequired, .appError, .authenticationExpired, .concurrentStreamLimit,
        .parentalControlRestricted, .contentFiltered, .notAvailableInRegion, .contentAlreadyPlaying,
        .invalidRequest, .genericLoadError,
    ]

    public init(rawValue: String) {
        // The legacy media protocol spells this DUPLICATE_REQUESTID.
        let canonical = rawValue == "DUPLICATE_REQUESTID" ? "DUPLICATE_REQUEST_ID" : rawValue
        self = Self.knownCases.first { $0.rawValue == canonical } ?? .unknown(rawValue)
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public var rawValue: String {
        switch self {
        case .invalidCommand: "INVALID_COMMAND"
        case .invalidParams: "INVALID_PARAMS"
        case .invalidMediaSessionId: "INVALID_MEDIA_SESSION_ID"
        case .invalidRequestId: "INVALID_REQUEST_ID"
        case .skipLimitReached: "SKIP_LIMIT_REACHED"
        case .notSupported: "NOT_SUPPORTED"
        case .languageNotSupported: "LANGUAGE_NOT_SUPPORTED"
        case .endOfQueue: "END_OF_QUEUE"
        case .duplicateRequestId: "DUPLICATE_REQUEST_ID"
        case .videoDeviceRequired: "VIDEO_DEVICE_REQUIRED"
        case .premiumAccountRequired: "PREMIUM_ACCOUNT_REQUIRED"
        case .appError: "APP_ERROR"
        case .authenticationExpired: "AUTHENTICATION_EXPIRED"
        case .concurrentStreamLimit: "CONCURRENT_STREAM_LIMIT"
        case .parentalControlRestricted: "PARENTAL_CONTROL_RESTRICTED"
        case .contentFiltered: "CONTENT_FILTERED"
        case .notAvailableInRegion: "NOT_AVAILABLE_IN_REGION"
        case .contentAlreadyPlaying: "CONTENT_ALREADY_PLAYING"
        case .invalidRequest: "INVALID_REQUEST"
        case .genericLoadError: "GENERIC_LOAD_ERROR"
        case .unknown(let value): value
        }
    }
}

/// The details of an error reply from a receiver application.
public struct MediaErrorInfo: Sendable, Hashable {
    /// The reply's `type`, e.g. `LOAD_FAILED` or `ERROR`.
    public var type: String
    public var reason: MediaErrorReason?
    /// A receiver-specific error code, such as a CAF `DetailedErrorCode`.
    public var detailedErrorCode: Int?
    /// The queue item the error relates to.
    public var itemId: Int?
    /// Application-defined data attached to the error.
    public var customData: JSONValue?

    public init(
        type: String,
        reason: MediaErrorReason? = nil,
        detailedErrorCode: Int? = nil,
        itemId: Int? = nil,
        customData: JSONValue? = nil
    ) {
        self.type = type
        self.reason = reason
        self.detailedErrorCode = detailedErrorCode
        self.itemId = itemId
        self.customData = customData
    }

    init(_ message: InboundMessage) {
        let json = message.json
        self.init(
            type: message.type ?? "",
            reason: json?["reason"]?.stringValue.map(MediaErrorReason.init(rawValue:)),
            detailedErrorCode: json?["detailedErrorCode"]?.intValue,
            itemId: json?["itemId"]?.intValue,
            customData: json?["customData"]
        )
    }

    var summary: String? {
        switch (reason, detailedErrorCode) {
        case let (reason?, code?): "\(reason.rawValue) (code \(code))"
        case let (reason?, nil): reason.rawValue
        case let (nil, code?): "code \(code)"
        case (nil, nil): nil
        }
    }
}
