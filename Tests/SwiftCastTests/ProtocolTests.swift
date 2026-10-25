import Foundation
import Testing
@testable import SwiftCast

@Suite("Wire protocol")
struct ProtocolTests {
    static let pingHex = "0800120873656e6465722d301a0a72656365697665722d30222775726e3a782d636173743a636f6d2e676f6f676c652e636173742e74702e6865617274626561742800320f7b2274797065223a2250494e47227d"

    static let ping = CastMessage(
        sourceID: "sender-0",
        destinationID: "receiver-0",
        namespace: CastNamespace.heartbeat.rawValue,
        payload: .string(#"{"type":"PING"}"#)
    )

    @Test func serializesToReferenceProtobufBytes() {
        #expect(Self.ping.serialized().hexString == Self.pingHex)
    }

    @Test func parsesReferenceProtobufBytes() throws {
        let parsed = try CastMessage(serializedData: Data(hex: Self.pingHex))
        #expect(parsed == Self.ping)
    }

    @Test func roundTripsBinaryPayloadAndLongStrings() throws {
        let long = String(repeating: "é", count: 500) // multi-byte varint length
        let message = CastMessage(sourceID: long, destinationID: "d", namespace: "ns", payload: .binary(Data([0, 1, 2, 255])))
        #expect(try CastMessage(serializedData: message.serialized()) == message)
    }

    @Test func skipsUnknownFields() throws {
        var data = Self.ping.serialized()
        data.append(contentsOf: [0x40, 0x96, 0x01])             // field 8 varint
        data.append(contentsOf: [0x4a, 0x02, 0xAA, 0xBB])       // field 9 bytes
        data.append(contentsOf: [0x55, 1, 2, 3, 4])             // field 10 fixed32
        data.append(contentsOf: [0x59, 1, 2, 3, 4, 5, 6, 7, 8]) // field 11 fixed64
        #expect(try CastMessage(serializedData: data) == Self.ping)
    }

    @Test func rejectsTruncatedAndIncompleteMessages() {
        let full = Self.ping.serialized()
        #expect(throws: CastError.self) { try CastMessage(serializedData: full.prefix(full.count - 3)) }
        #expect(throws: CastError.self) { try CastMessage(serializedData: Data([0x08, 0x00])) }
        #expect(throws: CastError.self) { try CastMessage(serializedData: Data([0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F])) }
        #expect(throws: CastError.self) { try CastMessage(serializedData: Data([0x0B])) } // group wire type
    }

    @Test func framesAndReassemblesAcrossArbitraryChunks() throws {
        let messages = (0..<20).map { i in
            CastMessage(sourceID: "s\(i)", destinationID: "d", namespace: "ns", payload: .string(String(repeating: "x", count: i * 37)))
        }
        let stream = messages.reduce(into: Data()) { $0.append(FrameCodec.frame($1)) }

        for chunkSize in [1, 2, 3, 7, 64, 1000, stream.count] {
            var decoder = FrameDecoder()
            var decoded: [CastMessage] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                decoded += try decoder.append(stream.subdata(in: offset..<end))
                offset = end
            }
            #expect(decoded == messages, "chunk size \(chunkSize)")
            #expect(decoder.bufferedByteCount == 0)
        }
    }

    @Test func rejectsOversizedFrames() {
        var decoder = FrameDecoder()
        #expect(throws: CastError.self) { try decoder.append(Data([0x7F, 0xFF, 0xFF, 0xFF])) }
    }
}

extension Data {
    init(hex: String) {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = data
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

@Suite("Fuzzing")
struct WireFuzzTests {
    /// Arbitrary bytes must never crash the frame decoder or protobuf parser.
    @Test func survivesRandomBytes() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            let count = Int.random(in: 0..<200, using: &generator)
            let bytes = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
            _ = try? CastMessage(serializedData: bytes)
            var decoder = FrameDecoder()
            var framed = Data([0, 0, 0, UInt8(min(count, 255))])
            framed.append(bytes)
            _ = try? decoder.append(framed)
        }
    }

    /// Arbitrary JSON payloads must never crash `InboundMessage` or the `JSONValue` accessors.
    @Test func survivesRandomJSONPayloads() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<3000 {
            var fields: [String] = []
            if Bool.random(using: &generator) { fields.append(#""requestId":"# + Self.randomNumber(using: &generator)) }
            if Bool.random(using: &generator) { fields.append(#""launchRequestId":"# + Self.randomValue(depth: 1, using: &generator)) }
            if Bool.random(using: &generator) { fields.append(#""type":"# + Self.randomValue(depth: 1, using: &generator)) }
            for index in 0..<Int.random(in: 0..<4, using: &generator) {
                fields.append("\"f\(index)\":" + Self.randomValue(depth: 3, using: &generator))
            }
            let payload = "{" + fields.shuffled(using: &generator).joined(separator: ",") + "}"
            let message = InboundMessage(CastMessage(sourceID: "receiver-0", destinationID: "sender-0", namespace: CastNamespace.receiver.rawValue, payload: .string(payload)))
            _ = message.type
            if let id = message.requestID { #expect(Int32(exactly: id) != nil, "\(payload)") }
            if let json = message.json { Self.touch(json) }
        }
    }

    static func touch(_ value: JSONValue) {
        _ = value.intValue
        _ = value.doubleValue
        _ = value.stringValue
        _ = value.boolValue
        value.arrayValue?.forEach(touch)
        value.objectValue?.values.forEach(touch)
    }

    static func randomNumber(using generator: inout some RandomNumberGenerator) -> String {
        let literals = [
            "0", "-0", "1", "-1", "42", "2147483647", "2147483648", "-2147483648", "-2147483649",
            "9223372036854775807", "9223372036854775808", "-9223372036854775808", "-9223372036854775809",
            "18446744073709551616", "99999999999999999999999999999", "1e19", "-1e19", "1E308", "1e400", "-1e400",
            "0.5", "-0.5", "42.0", "1.0e2", "4.2E-1", "1e-400", "123456789012345678901234567890.5",
        ]
        switch Int.random(in: 0..<4, using: &generator) {
        case 0: return literals.randomElement(using: &generator)!
        case 1: return String(Int64.random(in: .min ... .max, using: &generator))
        case 2: return String(Double.random(in: -1e30...1e30, using: &generator))
        default:
            let mantissa = Int.random(in: -999...999, using: &generator)
            let exponent = Int.random(in: -400...400, using: &generator)
            return "\(mantissa)e\(exponent)"
        }
    }

    static func randomValue(depth: Int, using generator: inout some RandomNumberGenerator) -> String {
        let kinds = depth > 0 ? 7 : 5
        switch Int.random(in: 0..<kinds, using: &generator) {
        case 0: return randomNumber(using: &generator)
        case 1: return ["null", "true", "false"].randomElement(using: &generator)!
        case 2: return ["\"RECEIVER_STATUS\"", "\"MEDIA_STATUS\"", "\"\"", "\"\\u0000\"", "\"é\""].randomElement(using: &generator)!
        case 3: return ["", "{", "]", "\"", "nul", "0x10", "+1", "01", "--1", "1e"].randomElement(using: &generator)!
        case 4: return "\"" + String(Int.random(in: 0...1000, using: &generator)) + "\""
        case 5:
            let items = (0..<Int.random(in: 0..<4, using: &generator)).map { _ in randomValue(depth: depth - 1, using: &generator) }
            return "[" + items.joined(separator: ",") + "]"
        default:
            let items = (0..<Int.random(in: 0..<4, using: &generator)).map { index in
                "\"k\(index)\":" + randomValue(depth: depth - 1, using: &generator)
            }
            return "{" + items.joined(separator: ",") + "}"
        }
    }

    @Test func survivesTruncatedValidMessages() {
        let valid = ProtocolTests.ping.serialized()
        for length in 0..<valid.count {
            _ = try? CastMessage(serializedData: valid.prefix(length))
        }
    }
}
