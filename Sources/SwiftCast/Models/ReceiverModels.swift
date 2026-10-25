import Foundation

/// Well-known Cast receiver application identifiers.
public struct CastAppID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Google's Default Media Receiver — plays audio, video and images
    /// supported by the device without a custom receiver app.
    public static let defaultMediaReceiver: CastAppID = "CC1AD845"
    /// The Backdrop / idle-screen application.
    public static let backdrop: CastAppID = "E8C28D3C"
    /// YouTube.
    public static let youTube: CastAppID = "233637DE"
    /// Jellyfin's stable custom receiver.
    public static let jellyfin: CastAppID = "F007D354"
    /// Jellyfin's unstable (development) custom receiver.
    public static let jellyfinUnstable: CastAppID = "6F511C87"
}

/// The volume of a Cast device or stream.
public struct CastVolume: Codable, Sendable, Hashable {
    public enum ControlType: OpenStringEnum {
        /// The device volume can be set to any level.
        case attenuation
        /// The volume cannot be changed.
        case fixed
        /// The volume of the TV or audio device the receiver is attached to is driven.
        case master
        case unknown(String)

        public static let knownCases: [ControlType] = [.attenuation, .fixed, .master]

        public var rawValue: String {
            switch self {
            case .attenuation: "attenuation"
            case .fixed: "fixed"
            case .master: "master"
            case .unknown(let value): value
            }
        }
    }

    /// Level between 0.0 and 1.0.
    public var level: Double?
    public var muted: Bool?
    public var controlType: ControlType?
    /// The size of a single volume step, if provided.
    public var stepInterval: Double?

    /// Whether the volume can be changed by the sender.
    public var canSetVolume: Bool { controlType != .fixed }

    public init(level: Double? = nil, muted: Bool? = nil, controlType: ControlType? = nil, stepInterval: Double? = nil) {
        self.level = level
        self.muted = muted
        self.controlType = controlType
        self.stepInterval = stepInterval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        level = try? container.decodeIfPresent(Double.self, forKey: .level)
        muted = try? container.decodeIfPresent(Bool.self, forKey: .muted)
        controlType = try? container.decodeIfPresent(ControlType.self, forKey: .controlType)
        stepInterval = try? container.decodeIfPresent(Double.self, forKey: .stepInterval)
    }
}

/// A running application on the receiver.
public struct CastApplication: Codable, Sendable, Hashable, Identifiable {
    public struct Namespace: Codable, Sendable, Hashable {
        public var name: String
    }

    public var appId: CastAppID
    public var displayName: String?
    public var sessionId: String
    /// The virtual-connection destination for talking to this app.
    public var transportId: String
    public var statusText: String?
    public var namespaces: [Namespace]?
    public var isIdleScreen: Bool?
    public var launchedFromCloud: Bool?
    public var iconUrl: String?
    public var universalAppId: String?
    /// The senders connected to this application, as reported by the receiver.
    public var senderApps: [JSONValue]?
    public var appImages: [CastImage]?
    /// The kind of application, such as `WEB` or `ANDROID_TV`.
    public var appType: String?

    public var id: String { sessionId }

    /// Whether the application advertises support for a namespace.
    public func supports(_ namespace: CastNamespace) -> Bool {
        namespaces?.contains { $0.name == namespace.rawValue } ?? false
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appId = try container.decode(CastAppID.self, forKey: .appId)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        transportId = try container.decode(String.self, forKey: .transportId)
        displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
        statusText = try? container.decodeIfPresent(String.self, forKey: .statusText)
        if container.contains(.namespaces) {
            namespaces = (try? container.decodeIfPresent([Lenient<Namespace>].self, forKey: .namespaces))?.compactMap(\.value) ?? []
        }
        isIdleScreen = try? container.decodeIfPresent(Bool.self, forKey: .isIdleScreen)
        launchedFromCloud = try? container.decodeIfPresent(Bool.self, forKey: .launchedFromCloud)
        iconUrl = try? container.decodeIfPresent(String.self, forKey: .iconUrl)
        universalAppId = try? container.decodeIfPresent(String.self, forKey: .universalAppId)
        senderApps = try? container.decodeIfPresent([JSONValue].self, forKey: .senderApps)
        appImages = (try? container.decodeIfPresent([Lenient<CastImage>].self, forKey: .appImages))?.compactMap(\.value)
        appType = try? container.decodeIfPresent(String.self, forKey: .appType)
    }
}

/// The status of the Cast device's platform receiver.
public struct ReceiverStatus: Codable, Sendable, Hashable {
    public var applications: [CastApplication]?
    public var volume: CastVolume?
    public var isActiveInput: Bool?
    public var isStandBy: Bool?

    public init(applications: [CastApplication]? = nil, volume: CastVolume? = nil, isActiveInput: Bool? = nil, isStandBy: Bool? = nil) {
        self.applications = applications
        self.volume = volume
        self.isActiveInput = isActiveInput
        self.isStandBy = isStandBy
    }

    /// Decodes leniently: applications that fail to decode, or that claim the
    /// platform receiver's transport, are dropped instead of failing the whole status.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        applications = (try? container.decodeIfPresent([Lenient<CastApplication>].self, forKey: .applications))?
            .compactMap(\.value)
            .filter { $0.transportId != CastEndpoint.platformReceiver }
        volume = try? container.decodeIfPresent(CastVolume.self, forKey: .volume)
        isActiveInput = try? container.decodeIfPresent(Bool.self, forKey: .isActiveInput)
        isStandBy = try? container.decodeIfPresent(Bool.self, forKey: .isStandBy)
    }

    /// The first non-idle-screen application, if any.
    public var foregroundApplication: CastApplication? {
        applications?.first { $0.isIdleScreen != true }
    }

    /// Returns the running application with the given identifier.
    public func application(_ appID: CastAppID) -> CastApplication? {
        applications?.first { $0.appId == appID }
    }
}

private struct Lenient<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: any Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

/// App availability as reported by `GET_APP_AVAILABILITY`.
public enum CastAppAvailability: String, Codable, Sendable, Hashable {
    case available = "APP_AVAILABLE"
    case unavailable = "APP_UNAVAILABLE"
}
