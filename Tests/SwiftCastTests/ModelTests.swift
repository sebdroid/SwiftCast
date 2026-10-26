import Foundation
import Testing
@testable import SwiftCast

@Suite("Models")
struct ModelTests {
    @Test func decodesRealWorldReceiverStatus() throws {
        let json = """
        {"requestId":1,"status":{"applications":[{"appId":"E8C28D3C","appType":"ANDROID_TV","displayName":"Backdrop","iconUrl":"","isIdleScreen":true,"launchedFromCloud":false,"namespaces":[{"name":"urn:x-cast:com.google.cast.sse"}],"sessionId":"a8d2-4f","statusText":"","transportId":"a8d2-4f","universalAppId":"E8C28D3C"}],"userEq":{},"volume":{"controlType":"master","level":0.35,"muted":false,"stepInterval":0.01}},"type":"RECEIVER_STATUS"}
        """
        let message = InboundMessage(CastMessage(sourceID: "receiver-0", destinationID: "sender-0", namespace: CastNamespace.receiver.rawValue, payload: .string(json)))
        #expect(message.type == "RECEIVER_STATUS")
        #expect(message.requestID == 1)
        let status = try #require(try message.json?["status"]?.decode(ReceiverStatus.self))
        #expect(status.volume?.controlType == .master)
        #expect(status.volume?.level == 0.35)
        #expect(status.applications?.first?.isIdleScreen == true)
        #expect(status.foregroundApplication == nil)
        #expect(status.application(.backdrop)?.displayName == "Backdrop")
    }

    @Test func decodesMediaStatusWithTracksAndUnknownEnums() throws {
        let json = """
        {"mediaSessionId":3,"playbackRate":1,"playerState":"PLAYING","currentTime":12.5,"supportedMediaCommands":274447,
         "volume":{"level":1,"muted":false},"activeTrackIds":[1],"repeatMode":"REPEAT_SOMETHING_NEW",
         "media":{"contentId":"https://x/y.m3u8","streamType":"BUFFERED","contentType":"application/x-mpegurl","duration":120,
           "hlsSegmentFormat":"fmp4","metadata":{"metadataType":2,"title":"Pilot","seriesTitle":"Show","season":1,"episode":1,"images":[{"url":"https://x/i.jpg","width":320}]},
           "tracks":[{"trackId":1,"type":"TEXT","trackContentId":"https://x/en.vtt","trackContentType":"text/vtt","subtype":"SUBTITLES","language":"en","name":"English"}]}}
        """
        let status = try JSONDecoder().decode(MediaStatus.self, from: Data(json.utf8))
        #expect(status.playerState == .playing)
        #expect(status.repeatMode == .unknown("REPEAT_SOMETHING_NEW"))
        #expect(status.supportedMediaCommands?.contains([.pause, .seek]) == true)
        #expect(status.media?.hlsSegmentFormat == .fmp4)
        #expect(status.media?.metadata?.kind == .tvShow)
        #expect(status.media?.metadata?.seriesTitle == "Show")
        #expect(status.media?.tracks?.first?.subtype == .subtitles)
        #expect(status.media?.metadata?.images?.first?.width == 320)
    }

    @Test func encodesLoadableMediaWithoutNilFields() throws {
        let media = MediaInformation(
            url: URL(string: "https://example.com/v.mp4")!,
            contentType: "video/mp4",
            metadata: .movie(title: "Movie"),
            tracks: [.webVTTSubtitles(id: 1, url: URL(string: "https://example.com/en.vtt")!, name: "English", language: "en")]
        )
        let json = try JSONValue(encoding: media)
        #expect(json["contentId"]?.stringValue == "https://example.com/v.mp4")
        #expect(json["contentUrl"]?.stringValue == "https://example.com/v.mp4")
        #expect(json["streamType"]?.stringValue == "BUFFERED")
        #expect(json["metadata"]?["metadataType"]?.intValue == 1)
        #expect(json["metadata"]?["season"] == nil)
        #expect(json["tracks"]?.arrayValue?.first?["trackContentType"]?.stringValue == "text/vtt")
        #expect(json["duration"] == nil)
        // Round-trips.
        #expect(try json.decode(MediaInformation.self) == media)
    }

    @Test func estimatesPlaybackPosition() {
        var status = MediaStatus(mediaSessionId: 1, playerState: .playing, currentTime: 10, playbackRate: 2)
        status.media = MediaInformation(contentId: "x", contentType: "video/mp4", duration: 20)
        #expect(status.estimatedTime(after: 3) == 16)
        #expect(status.estimatedTime(after: 100) == 20) // clamped to duration
        status.playerState = .paused
        #expect(status.estimatedTime(after: 3) == 10)
    }

    @Test func jsonValueLiteralsAndAccessors() throws {
        let value: JSONValue = ["a": [1, 2.5, "x", true, nil], "b": ["c": "d"]]
        #expect(value["a"]?.arrayValue?.count == 5)
        #expect(value["a"]?.arrayValue?[0].intValue == 1)
        #expect(value["a"]?.arrayValue?[1].intValue == nil)
        #expect(value["b"]?["c"]?.stringValue == "d")
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test func intValueRejectsValuesOutsideInt() {
        #expect(JSONValue.number(42.0).intValue == 42)
        #expect(JSONValue.number(-0.0).intValue == 0)
        #expect(JSONValue.number(9223372036854775808.0).intValue == nil)
        #expect(JSONValue.number(Double(Int.max)).intValue == nil)
        #expect(JSONValue.number(-9223372036854775808.0).intValue == Int.min)
        #expect(JSONValue.number(1e19).intValue == nil)
        #expect(JSONValue.number(-1e19).intValue == nil)
        #expect(JSONValue.number(0.5).intValue == nil)
        #expect(JSONValue.number(.nan).intValue == nil)
        #expect(JSONValue.number(.infinity).intValue == nil)
        #expect(JSONValue.number(-.infinity).intValue == nil)
        #expect(JSONValue.string("1").intValue == nil)
    }

    @Test func intValueOfDecodedHugeIntegersDoesNotTrap() throws {
        for literal in ["9223372036854775807", "9223372036854775808", "-9223372036854777856", "18446744073709551616"] {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(literal.utf8))
            #expect(value.intValue == nil, "\(literal)")
        }
    }

    func inbound(_ json: String) -> InboundMessage {
        InboundMessage(CastMessage(sourceID: "receiver-0", destinationID: "sender-0", namespace: CastNamespace.receiver.rawValue, payload: .string(json)))
    }

    @Test func requestIDAcceptsOnlyInt32() {
        #expect(inbound(#"{"requestId":2147483647}"#).requestID == 2147483647)
        #expect(inbound(#"{"requestId":-2147483648}"#).requestID == -2147483648)
        #expect(inbound(#"{"requestId":2147483648}"#).requestID == nil)
        #expect(inbound(#"{"requestId":-2147483649}"#).requestID == nil)
        #expect(inbound(#"{"requestId":9223372036854775808}"#).requestID == nil)
        #expect(inbound(#"{"requestId":1.5}"#).requestID == nil)
        #expect(inbound(#"{"requestId":"7"}"#).requestID == nil)
        #expect(inbound(#"{"requestId":0}"#).requestID == 0)
    }

    @Test func requestIDMissingIsNil() {
        #expect(inbound(#"{"type":"RECEIVER_STATUS"}"#).requestID == nil)
        #expect(inbound(#"[1,2,3]"#).requestID == nil)
        #expect(inbound("not json").requestID == nil)
        let binary = InboundMessage(CastMessage(sourceID: "a", destinationID: "b", namespace: "ns", payload: .binary(Data([1, 2]))))
        #expect(binary.requestID == nil)
    }

    @Test func parsesDeviceTXTRecord() {
        let device = CastDevice(
            serviceEndpoint: .service(name: "Chromecast-abc", type: "_googlecast._tcp", domain: "local.", interface: nil),
            txt: ["id": "abc123", "fn": "Living Room", "md": "Chromecast Ultra", "ca": "201221", "rs": "YouTube"]
        )
        #expect(device.id == "abc123")
        #expect(device.name == "Living Room")
        #expect(device.modelName == "Chromecast Ultra")
        #expect(device.supportsVideo)
        #expect(!device.isGroup)
        #expect(device.statusText == "YouTube")

        let group = CastDevice(
            serviceEndpoint: .service(name: "Google-Cast-Group-1", type: "_googlecast._tcp", domain: "local.", interface: nil),
            txt: ["ca": "2084", "fn": ""]
        )
        #expect(group.id == "Google-Cast-Group-1")
        #expect(group.name == "Google-Cast-Group-1")
        #expect(group.isGroup)
    }
}
