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

    static func field(_ number: UInt8, _ string: String) -> [UInt8] {
        let bytes = Array(string.utf8)
        return [number << 3 | 2, UInt8(bytes.count)] + bytes
    }

    static func encoded(
        source: String = "s",
        destination: String = "d",
        namespace: String = "ns",
        payloadType: UInt8 = 0,
        payload: [UInt8]? = nil
    ) -> Data {
        var bytes: [UInt8] = [0x08, 0x00]
        bytes += field(2, source) + field(3, destination) + field(4, namespace)
        bytes += [0x28, payloadType]
        bytes += payload ?? []
        return Data(bytes)
    }

    static func expectMalformed(_ data: Data, _ reason: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: CastError.malformedMessage(reason), sourceLocation: sourceLocation) {
            try CastMessage(serializedData: data)
        }
    }

    @Test func acceptsMinimalValidMessages() throws {
        let string = try CastMessage(serializedData: Self.encoded(payload: Self.field(6, "")))
        #expect(string.payload == .string(""))
        let binary = try CastMessage(serializedData: Self.encoded(payloadType: 1, payload: [0x3a, 0x00]))
        #expect(binary.payload == .binary(Data()))
    }

    @Test func rejectsEmptyRequiredStrings() {
        let payload = Self.field(6, "{}")
        Self.expectMalformed(Self.encoded(source: "", payload: payload), "Empty source_id")
        Self.expectMalformed(Self.encoded(destination: "", payload: payload), "Empty destination_id")
        Self.expectMalformed(Self.encoded(namespace: "", payload: payload), "Empty namespace")
    }

    @Test func rejectsPayloadTypeWithoutMatchingPayloadField() {
        Self.expectMalformed(Self.encoded(payloadType: 0), "STRING message without payload_utf8")
        Self.expectMalformed(Self.encoded(payloadType: 0, payload: [0x3a, 0x00]), "STRING message without payload_utf8")
        Self.expectMalformed(Self.encoded(payloadType: 1), "BINARY message without payload_binary")
        Self.expectMalformed(Self.encoded(payloadType: 1, payload: Self.field(6, "{}")), "BINARY message without payload_binary")
    }

    @Test func rejectsUnknownPayloadType() {
        Self.expectMalformed(Self.encoded(payloadType: 2, payload: Self.field(6, "{}")), "Unknown payload type 2")
    }

    @Test func rejectsFieldNumberZero() {
        var data = Self.ping.serialized()
        data.append(contentsOf: [0x00, 0x00])
        Self.expectMalformed(data, "Invalid field number 0")
        Self.expectMalformed(Data([0x02, 0x00]) + Self.ping.serialized(), "Invalid field number 0")
    }

    @Test func framesAndReassemblesAcrossArbitraryChunks() throws {
        let messages = (0..<20).map { i in
            CastMessage(sourceID: "s\(i)", destinationID: "d", namespace: "ns", payload: .string(String(repeating: "x", count: i * 37)))
        }
        let stream = try messages.reduce(into: Data()) { $0.append(try FrameCodec.frame($1)) }

        for chunkSize in [1, 2, 3, 7, 64, 1000, stream.count] {
            var decoder = FrameDecoder()
            var decoded: [CastMessage] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                let output = decoder.append(stream.subdata(in: offset..<end))
                #expect(output.error == nil)
                decoded += output.messages
                offset = end
            }
            #expect(decoded == messages, "chunk size \(chunkSize)")
            #expect(decoder.bufferedByteCount == 0)
        }
    }

    @Test func rejectsOversizedFrames() {
        var decoder = FrameDecoder()
        #expect(decoder.append(Data([0x7F, 0xFF, 0xFF, 0xFF])).error != nil)
    }

    static func message(_ i: Int) -> CastMessage {
        CastMessage(sourceID: "s\(i)", destinationID: "d", namespace: "ns", payload: .string("\(i)"))
    }

    @Test func decodesManyTinyFramesFromOneChunkInOrder() throws {
        let messages = (0..<5000).map(Self.message)
        let stream = try messages.reduce(into: Data()) { $0.append(try FrameCodec.frame($1)) }
        var decoder = FrameDecoder()
        let output = decoder.append(stream)
        #expect(output.error == nil)
        #expect(output.messages == messages)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func decodesFrameSplitAcrossChunks() throws {
        let frame = try FrameCodec.frame(Self.ping)
        let split = frame.count / 2
        var decoder = FrameDecoder()
        let first = decoder.append(frame.prefix(2) + frame[2..<split])
        #expect(first.messages.isEmpty)
        #expect(first.error == nil)
        #expect(decoder.bufferedByteCount == split)
        let second = decoder.append(frame.suffix(from: split))
        #expect(second.messages == [Self.ping])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func acceptsInboundBodyAtLimitAndRejectsOneByteMore() {
        var atLimit = FrameDecoder()
        let length = UInt32(FrameCodec.maximumInboundBodyLength)
        let header = withUnsafeBytes(of: length.bigEndian) { Data($0) }
        let partial = atLimit.append(header)
        #expect(partial.error == nil)
        #expect(partial.messages.isEmpty)

        var overLimit = FrameDecoder()
        let overHeader = withUnsafeBytes(of: (length + 1).bigEndian) { Data($0) }
        #expect(overLimit.append(overHeader).error != nil)
    }

    @Test func deliversEarlierFramesBeforeOversizeHeaderAndStaysFailed() throws {
        var stream = try FrameCodec.frame(Self.message(0))
        stream.append(try FrameCodec.frame(Self.message(1)))
        stream.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        stream.append(try FrameCodec.frame(Self.message(2)))

        var decoder = FrameDecoder()
        let output = decoder.append(stream)
        #expect(output.messages == [Self.message(0), Self.message(1)])
        let error = try #require(output.error)
        #expect(decoder.error == error)

        let later = decoder.append(try FrameCodec.frame(Self.message(3)))
        #expect(later.messages.isEmpty)
        #expect(later.error == error)
    }

    @Test func deliversEarlierFramesBeforeMalformedMessageAndStaysFailed() throws {
        var stream = try FrameCodec.frame(Self.message(0))
        stream.append(contentsOf: [0, 0, 0, 1, 0x0B])
        var decoder = FrameDecoder()
        let output = decoder.append(stream)
        #expect(output.messages == [Self.message(0)])
        #expect(output.error != nil)
        #expect(decoder.append(try FrameCodec.frame(Self.ping)).error != nil)
    }

    @Test func rejectsEmptyOrOversizeOutboundBodies() throws {
        let probe = CastMessage(sourceID: "s", destinationID: "d", namespace: "ns", payload: .binary(Data(count: 60_000)))
        let overhead = probe.serialized().count - 60_000
        func binary(bodyLength: Int) -> CastMessage {
            CastMessage(sourceID: "s", destinationID: "d", namespace: "ns", payload: .binary(Data(count: bodyLength - overhead)))
        }

        let exact = binary(bodyLength: FrameCodec.maximumOutboundBodyLength)
        #expect(exact.serialized().count == 65_536)
        let framed = try FrameCodec.frame(exact)
        #expect(framed.count == 65_536 + 4)
        #expect(framed.prefix(4) == Data([0x00, 0x01, 0x00, 0x00]))

        let oversize = binary(bodyLength: FrameCodec.maximumOutboundBodyLength + 1)
        let oversizeError = #expect(throws: CastError.self) { try FrameCodec.frame(oversize) }
        #expect(oversizeError.map { if case .invalidRequest = $0 { true } else { false } } == true)

        let emptyError = #expect(throws: CastError.self) { try FrameCodec.frame(body: Data()) }
        #expect(emptyError.map { if case .invalidRequest = $0 { true } else { false } } == true)
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
            _ = decoder.append(framed)
        }
    }

    @Test func survivesTruncatedValidMessages() {
        let valid = ProtocolTests.ping.serialized()
        for length in 0..<valid.count {
            _ = try? CastMessage(serializedData: valid.prefix(length))
        }
    }
}

@Suite("Framing limits on a live client", .timeLimit(.minutes(1)))
struct ClientFramingTests {
    @Test func oversizeSendFailsWithoutDroppingTheConnection() async throws {
        let mock = MockReceiver()
        let client = CastClient { mock }
        try await client.connect()
        let error = await #expect(throws: CastError.self) {
            try await client.send(binary: Data(count: FrameCodec.maximumOutboundBodyLength), namespace: .media, to: "receiver-0")
        }
        #expect(error.map { if case .invalidRequest = $0 { true } else { false } } == true)
        #expect(await client.state == .connected)
        try await client.send(binary: Data([1]), namespace: .media, to: "receiver-0")
    }

    @Test func deliversMessagesDecodedBeforeABadFrameThenCloses() async throws {
        let mock = MockReceiver()
        let client = CastClient { mock }
        try await client.connect()
        var messages = client.messages(in: .media).makeAsyncIterator()

        let message = CastMessage(sourceID: "receiver-0", destinationID: "sender-0", namespace: CastNamespace.media.rawValue, payload: .string(#"{"type":"MEDIA_STATUS","status":[]}"#))
        var stream = try FrameCodec.frame(message)
        stream.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        mock.pushRaw(stream)

        let delivered = try #require(await messages.next())
        #expect(delivered.type == "MEDIA_STATUS")
        try await eventually { await client.state != .connected }
        guard case .closed(.malformedMessage) = await client.state else {
            Issue.record("Expected malformedMessage, got \(await client.state)")
            return
        }
    }
}
