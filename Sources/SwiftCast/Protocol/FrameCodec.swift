import Foundation

/// Cast V2 framing: every message is prefixed with a 4-byte big-endian length.
enum FrameCodec {
    static let headerLength = 4

    /// Largest body sent to a receiver (Chromium's `max_body_size`, which
    /// receivers enforce).
    static let maximumOutboundBodyLength = 65_536

    /// Largest body accepted from a receiver: a 128 KiB frame less the 4-byte
    /// length prefix, so a device that overshoots Chromium's 64 KiB limit gets
    /// headroom while memory stays bounded.
    static let maximumInboundBodyLength = 131_068

    /// Frames a message, throwing ``CastError/malformedMessage(_:)`` when its
    /// body is empty or ``CastError/messageTooLarge(_:)`` when it is larger
    /// than ``maximumOutboundBodyLength``.
    static func frame(_ message: CastMessage) throws -> Data {
        try frame(body: message.serialized())
    }

    static func frame(body: Data) throws -> Data {
        guard !body.isEmpty else {
            throw CastError.malformedMessage("Empty message body")
        }
        guard body.count <= maximumOutboundBodyLength else {
            throw CastError.messageTooLarge(body.count)
        }
        var out = Data(capacity: body.count + headerLength)
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }
}

/// Incrementally reassembles length-prefixed frames from an arbitrary
/// sequence of byte chunks.
///
/// Once a frame or message fails to decode the decoder stays failed and every
/// later ``append(_:)`` reports the same error.
struct FrameDecoder {
    /// The outcome of one ``FrameDecoder/append(_:)``: the messages decoded
    /// before any failure, in order, and the failure if one occurred.
    struct Output {
        var messages: [CastMessage] = []
        var error: CastError?
    }

    private var buffer: [UInt8] = []
    private var offset = 0
    private(set) var error: CastError?

    /// Appends received bytes and returns every complete message now available.
    mutating func append(_ chunk: Data) -> Output {
        var output = Output()
        if let error {
            output.error = error
            return output
        }
        buffer.append(contentsOf: chunk)
        while buffer.count - offset >= FrameCodec.headerLength {
            let length = buffer[offset..<offset + FrameCodec.headerLength].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard length <= UInt32(FrameCodec.maximumInboundBodyLength) else {
                fail(.malformedMessage("Frame length \(length) exceeds \(FrameCodec.maximumInboundBodyLength)"), output: &output)
                return output
            }
            let start = offset + FrameCodec.headerLength
            let end = start + Int(length)
            guard buffer.count >= end else { break }
            do {
                output.messages.append(try CastMessage(serializedData: Data(buffer[start..<end])))
            } catch {
                fail((error as? CastError) ?? .malformedMessage("\(error)"), output: &output)
                return output
            }
            offset = end
        }
        compact()
        return output
    }

    var bufferedByteCount: Int { buffer.count - offset }

    private mutating func fail(_ error: CastError, output: inout Output) {
        self.error = error
        output.error = error
        buffer = []
        offset = 0
    }

    private mutating func compact() {
        if offset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else if offset > 0 {
            buffer.removeSubrange(0..<offset)
        }
        offset = 0
    }
}
