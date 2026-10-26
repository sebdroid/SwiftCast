import Foundation
import Network

/// A Cast device discovered on the local network (or specified manually).
public struct CastDevice: Sendable, Hashable, Identifiable, CustomStringConvertible {
    /// Device capabilities advertised in the `ca` TXT record.
    public struct Capabilities: OptionSet, Sendable, Hashable {
        public let rawValue: UInt64
        public init(rawValue: UInt64) { self.rawValue = rawValue }

        public static let videoOut = Capabilities(rawValue: 1 << 0)
        public static let videoIn = Capabilities(rawValue: 1 << 1)
        public static let audioOut = Capabilities(rawValue: 1 << 2)
        public static let audioIn = Capabilities(rawValue: 1 << 3)
        public static let developerMode = Capabilities(rawValue: 1 << 4)
        public static let multizoneGroup = Capabilities(rawValue: 1 << 5)
        public static let dynamicGroup = Capabilities(rawValue: 1 << 6)
        public static let multiChannelGroup = Capabilities(rawValue: 1 << 7)
        public static let multiChannelMember = Capabilities(rawValue: 1 << 8)
        public static let masterOrFixedVolume = Capabilities(rawValue: 1 << 11)
        public static let attenuationOrFixedVolume = Capabilities(rawValue: 1 << 12)
        public static let dynamicGroupingSupported = Capabilities(rawValue: 1 << 16)
        public static let castConnectSupported = Capabilities(rawValue: 1 << 18)
    }

    /// Whether the device is idle or busy, from the `st` TXT record.
    public enum Status: Sendable, Hashable {
        case idle
        case busy
    }

    /// The broad category of device, for choosing an icon.
    public enum Kind: Sendable, Hashable {
        case group
        case tv
        case speaker
        case generic
    }

    /// Stable device identifier. For discovered devices this is the `id` TXT
    /// record normalised to lowercase hex without dashes or a `uuid:` prefix,
    /// or the service name when the record has no `id`.
    public let id: String
    /// User-visible device name, e.g. "Living Room TV".
    public let name: String
    /// Hardware model, e.g. "Chromecast Ultra".
    public let modelName: String?
    public let capabilities: Capabilities
    /// Text describing what the device is currently doing (e.g. the app name).
    public let statusText: String?
    /// Whether the device is idle or busy, from the `st` TXT record.
    public let status: Status?
    /// The `ve` TXT record (the Cast protocol version the device advertises).
    public let deviceVersion: Int?
    /// The ID of the receiver application currently running, from the `rr` TXT record.
    public let runningApplicationID: String?
    /// The raw `ic` TXT record. Usually a path such as `/setup/icon.png`, which
    /// is served at `http://<device address>:8008<path>`; an absolute `http`
    /// or `https` URL is used as is.
    public let iconPath: String?
    /// How to connect to the device.
    public let endpoint: NWEndpoint
    /// All TXT record entries advertised by the device.
    public let txtRecord: [String: String]

    public init(
        id: String,
        name: String,
        modelName: String? = nil,
        capabilities: Capabilities = [.videoOut, .audioOut],
        statusText: String? = nil,
        status: Status? = nil,
        deviceVersion: Int? = nil,
        runningApplicationID: String? = nil,
        iconPath: String? = nil,
        endpoint: NWEndpoint,
        txtRecord: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.modelName = modelName
        self.capabilities = capabilities
        self.statusText = statusText
        self.status = status
        self.deviceVersion = deviceVersion
        self.runningApplicationID = runningApplicationID
        self.iconPath = iconPath
        self.endpoint = endpoint
        self.txtRecord = txtRecord
    }

    /// A device at a known address.
    public init(host: String, port: UInt16 = 8009, name: String? = nil) {
        self.init(
            id: "\(host):\(port)",
            name: name ?? host,
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 8009)
        )
    }

    /// Builds a device from a Bonjour service and its TXT record, or returns
    /// `nil` when the record carries an empty `id`.
    init?(serviceEndpoint: NWEndpoint, txt: [String: String]) {
        var serviceName = ""
        if case .service(let name, _, _, _) = serviceEndpoint { serviceName = name }
        let id: String
        if let rawID = txt["id"] {
            id = Self.normalizedID(rawID)
            guard !id.isEmpty else { return nil }
        } else {
            id = serviceName
        }
        func nonEmpty(_ key: String) -> String? { txt[key].flatMap { $0.isEmpty ? nil : $0 } }
        self.init(
            id: id,
            name: nonEmpty("fn") ?? serviceName,
            modelName: nonEmpty("md"),
            capabilities: txt["ca"].flatMap { UInt64($0) }.map(Capabilities.init(rawValue:)) ?? [],
            statusText: nonEmpty("rs"),
            status: txt["st"].flatMap { Int($0) }.flatMap { $0 == 0 ? .idle : $0 == 1 ? .busy : nil },
            deviceVersion: txt["ve"].flatMap { Int($0) },
            runningApplicationID: nonEmpty("rr"),
            iconPath: nonEmpty("ic"),
            endpoint: serviceEndpoint,
            txtRecord: txt
        )
    }

    static func normalizedID(_ raw: String) -> String {
        var id = Substring(raw)
        if id.prefix(5).lowercased() == "uuid:" { id = id.dropFirst(5) }
        return id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Whether the device is a speaker group rather than a single device.
    public var isGroup: Bool { capabilities.contains(.multizoneGroup) }

    /// Whether the device can display video.
    public var supportsVideo: Bool { capabilities.contains(.videoOut) }

    /// The device's category, derived from its capabilities.
    public var kind: Kind {
        if capabilities.contains(.multizoneGroup) { return .group }
        if capabilities.contains(.videoOut) { return .tv }
        if capabilities.contains(.audioOut) { return .speaker }
        return .generic
    }

    public var description: String {
        "\(name)\(modelName.map { " (\($0))" } ?? "")"
    }
}
