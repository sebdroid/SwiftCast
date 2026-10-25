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

    @Test func receiverStatusDropsPlatformTransportButKeepsLenientFields() throws {
        let json = """
        {"applications":[
          {"appId":"CC1AD845","displayName":"Default Media Receiver","sessionId":"s1","transportId":"t1","namespaces":[{"name":"urn:x-cast:com.google.cast.media"},{"bogus":1}],
           "appType":"WEB","senderApps":[{"packageId":"x"}],"appImages":[{"url":"https://x/i.png"}]},
          {"appId":"ABCDEF12","displayName":"Impostor","sessionId":"s3","transportId":"receiver-0"}
        ],"volume":{"controlType":"attenuation","level":0.5,"muted":false},"isStandBy":"nope","isActiveInput":true}
        """
        let status = try JSONDecoder().decode(ReceiverStatus.self, from: Data(json.utf8))
        let apps = try #require(status.applications)
        #expect(apps.count == 1)
        let app = try #require(apps.first)
        #expect(app.appId == .defaultMediaReceiver)
        #expect(app.supports(.media))
        #expect(app.namespaces?.count == 1)
        #expect(app.appType == "WEB")
        #expect(app.senderApps?.first?["packageId"]?.stringValue == "x")
        #expect(app.appImages?.first?.url == URL(string: "https://x/i.png"))
        #expect(status.volume?.level == 0.5)
        #expect(status.isActiveInput == true)
        #expect(status.isStandBy == nil)
    }

    @Test(arguments: [
        #"{"applications":[{"appId":"CC1AD845","sessionId":"s1","transportId":"t1"},{"appId":"233637DE","displayName":"YouTube","sessionId":"s2"}]}"#,
        #"{"applications":[{"appId":"CC1AD845","sessionId":"","transportId":"t1"}]}"#,
        #"{"applications":[{"appId":"CC1AD845","sessionId":"s1","transportId":""}]}"#,
        #"{"applications":{"appId":"CC1AD845","sessionId":"s1","transportId":"t1"},"volume":{"level":0.5}}"#,
    ])
    func receiverStatusWithIncompleteApplicationsFailsToDecode(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ReceiverStatus.self, from: Data(json.utf8))
        }
    }

    @Test func receiverStatusWithoutApplicationsDecodes() throws {
        let status = try JSONDecoder().decode(ReceiverStatus.self, from: Data(#"{"volume":{"level":0.5}}"#.utf8))
        #expect(status.applications == nil)
        #expect(status.volume?.level == 0.5)
    }

    @Test func applicationWithUnexpectedNamespacesShapeDecodesWithNone() throws {
        let json = #"{"appId":"CC1AD845","sessionId":"s1","transportId":"t1","namespaces":"urn:x-cast:com.google.cast.media"}"#
        let app = try JSONDecoder().decode(CastApplication.self, from: Data(json.utf8))
        #expect(app.namespaces == [])
        #expect(!app.supports(.media))
    }

    @Test func volumeControlTypeIsOpen() throws {
        let weird = try JSONDecoder().decode(CastVolume.self, from: Data(#"{"controlType":"weird","level":1}"#.utf8))
        #expect(weird.controlType == .unknown("weird"))
        #expect(weird.canSetVolume)

        let fixed = try JSONDecoder().decode(CastVolume.self, from: Data(#"{"controlType":"fixed"}"#.utf8))
        #expect(fixed.controlType == .fixed)
        #expect(!fixed.canSetVolume)

        #expect(CastVolume().canSetVolume)
        #expect(try JSONValue(encoding: CastVolume(controlType: .master))["controlType"]?.stringValue == "master")
    }

    @Test func volumeWithBadFieldKeepsTheRest() throws {
        let volume = try JSONDecoder().decode(CastVolume.self, from: Data(#"{"level":0.25,"muted":"yes","controlType":3,"stepInterval":0.05}"#.utf8))
        #expect(volume.level == 0.25)
        #expect(volume.muted == nil)
        #expect(volume.controlType == nil)
        #expect(volume.stepInterval == 0.05)
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
