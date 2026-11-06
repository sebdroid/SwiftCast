import Foundation

/// A message received from a Cast device, with its JSON payload pre-parsed.
public struct InboundMessage: Sendable, Hashable {
    /// The raw protocol message.
    public let raw: CastMessage
    /// The parsed JSON payload, or `nil` for binary or non-JSON payloads.
    public let json: JSONValue?

    public init(_ raw: CastMessage) {
        self.raw = raw
        if let string = raw.stringPayload, let data = string.data(using: .utf8) {
            json = try? JSONDecoder().decode(JSONValue.self, from: data)
        } else {
            json = nil
        }
    }

    public var namespace: CastNamespace { CastNamespace(raw.namespace) }
    public var sourceID: String { raw.sourceID }
    public var destinationID: String { raw.destinationID }

    /// The `type` field of the JSON payload, e.g. `RECEIVER_STATUS`.
    public var type: String? { json?["type"]?.stringValue }

    /// The `requestId` the message responds to; `0` or `nil` for unsolicited messages.
    /// Only 32-bit integers are accepted.
    public var requestID: Int? { int32Field("requestId") }

    /// The `launchRequestId` some receivers use instead of `requestId` to
    /// echo the id of a `LAUNCH` request. Only 32-bit integers are accepted.
    public var launchRequestID: Int? { int32Field("launchRequestId") }

    /// Decodes the payload as `T`.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        guard let string = raw.stringPayload, let data = string.data(using: .utf8) else {
            throw CastError.unexpectedResponse("Message has no string payload")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func int32Field(_ key: String) -> Int? {
        guard let number = json?[key]?.doubleValue, let id = Int32(exactly: number) else { return nil }
        return Int(id)
    }
}
