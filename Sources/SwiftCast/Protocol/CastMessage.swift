import Foundation

/// A single Cast V2 protocol message.
///
/// This is a hand-written, dependency-free implementation of the `CastMessage`
/// protobuf (proto2) used by the Cast V2 wire protocol:
///
/// ```proto
/// message CastMessage {
///   enum ProtocolVersion { CASTV2_1_0 = 0; ... }
///   required ProtocolVersion protocol_version = 1;
///   required string source_id = 2;
///   required string destination_id = 3;
///   required string namespace = 4;
///   enum PayloadType { STRING = 0; BINARY = 1; }
///   required PayloadType payload_type = 5;
///   optional string payload_utf8 = 6;
///   optional bytes payload_binary = 7;
/// }
/// ```
public struct CastMessage: Sendable, Hashable {
    /// The payload carried by a message.
    public enum Payload: Sendable, Hashable {
        case string(String)
        case binary(Data)
    }

    public var protocolVersion: Int
    public var sourceID: String
    public var destinationID: String
    public var namespace: String
    public var payload: Payload

    public init(
        protocolVersion: Int = 0,
        sourceID: String,
        destinationID: String,
        namespace: String,
        payload: Payload
    ) {
        self.protocolVersion = protocolVersion
        self.sourceID = sourceID
        self.destinationID = destinationID
        self.namespace = namespace
        self.payload = payload
    }

    /// The UTF-8 payload, if this is a string message.
    public var stringPayload: String? {
        if case .string(let s) = payload { return s }
        return nil
    }
}

// MARK: - Protobuf wire encoding

extension CastMessage {
    private enum WireType: UInt8 {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    /// Serializes the message using the protobuf wire format.
    public func serialized() -> Data {
        var out = Data()
        out.reserveCapacity(64 + sourceID.utf8.count + destinationID.utf8.count + namespace.utf8.count)
        Self.appendTag(1, .varint, to: &out)
        Self.appendVarint(UInt64(max(0, protocolVersion)), to: &out)
        Self.appendTag(2, .lengthDelimited, to: &out)
        Self.appendBytes(Data(sourceID.utf8), to: &out)
        Self.appendTag(3, .lengthDelimited, to: &out)
        Self.appendBytes(Data(destinationID.utf8), to: &out)
        Self.appendTag(4, .lengthDelimited, to: &out)
        Self.appendBytes(Data(namespace.utf8), to: &out)
        switch payload {
        case .string(let string):
            Self.appendTag(5, .varint, to: &out)
            Self.appendVarint(0, to: &out)
            Self.appendTag(6, .lengthDelimited, to: &out)
            Self.appendBytes(Data(string.utf8), to: &out)
        case .binary(let data):
            Self.appendTag(5, .varint, to: &out)
            Self.appendVarint(1, to: &out)
            Self.appendTag(7, .lengthDelimited, to: &out)
            Self.appendBytes(data, to: &out)
        }
        return out
    }

    /// Parses a message from its protobuf wire representation.
    ///
    /// Unknown fields are skipped. Messages Chromium's `IsCastMessageValid`
    /// rejects (missing or empty required fields, a payload type without its
    /// matching payload field) throw ``CastError/malformedMessage(_:)``.
    public init(serializedData data: Data) throws {
        var reader = ByteReader(data)
        var protocolVersion: Int?
        var source: String?
        var destination: String?
        var namespace: String?
        var payloadType: UInt64?
        var utf8: String?
        var binary: Data?

        while !reader.isAtEnd {
            let key = try reader.readVarint()
            let field = key >> 3
            guard field != 0 else {
                throw CastError.malformedMessage("Invalid field number 0")
            }
            guard let wire = WireType(rawValue: UInt8(key & 0x7)) else {
                throw CastError.malformedMessage("Unsupported wire type \(key & 0x7)")
            }
            switch (field, wire) {
            case (1, .varint): protocolVersion = Int(truncatingIfNeeded: try reader.readVarint())
            case (2, .lengthDelimited): source = try reader.readString()
            case (3, .lengthDelimited): destination = try reader.readString()
            case (4, .lengthDelimited): namespace = try reader.readString()
            case (5, .varint): payloadType = try reader.readVarint()
            case (6, .lengthDelimited): utf8 = try reader.readString()
            case (7, .lengthDelimited): binary = try reader.readLengthDelimited()
            default: try reader.skip(wire.rawValue)
            }
        }

        guard let protocolVersion, let source, let destination, let namespace, let payloadType else {
            throw CastError.malformedMessage("Missing required CastMessage field")
        }
        guard !source.isEmpty else { throw CastError.malformedMessage("Empty source_id") }
        guard !destination.isEmpty else { throw CastError.malformedMessage("Empty destination_id") }
        guard !namespace.isEmpty else { throw CastError.malformedMessage("Empty namespace") }
        let payload: Payload
        switch payloadType {
        case 0:
            guard let utf8 else { throw CastError.malformedMessage("STRING message without payload_utf8") }
            payload = .string(utf8)
        case 1:
            guard let binary else { throw CastError.malformedMessage("BINARY message without payload_binary") }
            payload = .binary(binary)
        default:
            throw CastError.malformedMessage("Unknown payload type \(payloadType)")
        }
        self.init(
            protocolVersion: protocolVersion,
            sourceID: source,
            destinationID: destination,
            namespace: namespace,
            payload: payload
        )
    }

    private static func appendTag(_ field: UInt64, _ wire: WireType, to out: inout Data) {
        appendVarint(field << 3 | UInt64(wire.rawValue), to: &out)
    }

    private static func appendVarint(_ value: UInt64, to out: inout Data) {
        var v = value
        while v >= 0x80 {
            out.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    private static func appendBytes(_ bytes: Data, to out: inout Data) {
        appendVarint(UInt64(bytes.count), to: &out)
        out.append(bytes)
    }
}

/// A bounds-checked cursor over protobuf bytes.
struct ByteReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count else { throw CastError.malformedMessage("Truncated varint") }
            guard shift < 64 else { throw CastError.malformedMessage("Varint overflow") }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func readLengthDelimited() throws -> Data {
        let length = try readVarint()
        guard length <= UInt64(bytes.count - index) else {
            throw CastError.malformedMessage("Length-delimited field exceeds message bounds")
        }
        let end = index + Int(length)
        defer { index = end }
        return Data(bytes[index..<end])
    }

    mutating func readString() throws -> String {
        let data = try readLengthDelimited()
        guard let string = String(data: data, encoding: .utf8) else {
            throw CastError.malformedMessage("Invalid UTF-8 in string field")
        }
        return string
    }

    mutating func skip(_ wireType: UInt8) throws {
        switch wireType {
        case 0: _ = try readVarint()
        case 1: try advance(8)
        case 2: _ = try readLengthDelimited()
        case 5: try advance(4)
        default: throw CastError.malformedMessage("Cannot skip wire type \(wireType)")
        }
    }

    private mutating func advance(_ count: Int) throws {
        guard bytes.count - index >= count else { throw CastError.malformedMessage("Truncated fixed field") }
        index += count
    }
}
