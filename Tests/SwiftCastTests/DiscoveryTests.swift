import Foundation
import Network
import Testing
@testable import SwiftCast

@Suite("Discovery")
struct DiscoveryTests {
    private func service(_ name: String) -> NWEndpoint {
        .service(name: name, type: "_googlecast._tcp", domain: "local.", interface: nil)
    }

    private func device(_ txt: [String: String], service name: String = "Chromecast-abc") -> CastDevice? {
        CastDevice(serviceEndpoint: service(name), txt: txt)
    }

    private func device(id: String, name: String, service serviceName: String = "Chromecast-abc") -> CastDevice {
        CastDevice(id: id, name: name, endpoint: service(serviceName))
    }

    @Test(arguments: [
        ("uuid:ABC-123", "abc123"),
        ("UUID:abc-123", "abc123"),
        ("Uuid:A-B-C", "abc"),
        ("0123-4567-89AB-CDEF", "0123456789abcdef"),
        ("abc123", "abc123"),
        ("xuuid:abc", "xuuid:abc"),
    ])
    func normalisesDeviceID(raw: String, expected: String) throws {
        let device = try #require(device(["id": raw, "fn": "TV"]))
        #expect(device.id == expected)
        #expect(device.txtRecord["id"] == raw)
    }

    @Test(arguments: ["", "uuid:", "-", "UUID:--"])
    func dropsRecordsWithEmptyID(raw: String) {
        #expect(device(["id": raw, "fn": "TV"]) == nil)
    }

    @Test func fallsBackToServiceNameWithoutIDOrName() throws {
        let missing = try #require(device(["ca": "5"], service: "Google-Cast-Group-1"))
        #expect(missing.id == "Google-Cast-Group-1")
        #expect(missing.name == "Google-Cast-Group-1")
        let empty = try #require(device(["id": "abc", "fn": ""], service: "Chromecast-xyz"))
        #expect(empty.name == "Chromecast-xyz")
    }

    @Test func parsesCapabilitiesAsUnsigned() throws {
        #expect(try #require(device(["ca": "-1"])).capabilities == [])
        #expect(try #require(device(["ca": "lots"])).capabilities == [])
        #expect(try #require(device([:])).capabilities == [])

        let caps = try #require(device(["ca": "4101"])).capabilities
        #expect(caps == [.videoOut, .audioOut, .attenuationOrFixedVolume])
        #expect(caps.rawValue == 4101)

        let wide = try #require(device(["ca": "18446744073709551615"])).capabilities
        #expect(wide.rawValue == .max)
    }

    @Test func capabilityBitsMatchTheCastSDK() {
        typealias C = CastDevice.Capabilities
        #expect(C.dynamicGroup.rawValue == 1 << 6)
        #expect(C.multiChannelGroup.rawValue == 1 << 7)
        #expect(C.multiChannelMember.rawValue == 1 << 8)
        #expect(C.masterOrFixedVolume.rawValue == 1 << 11)
        #expect(C.attenuationOrFixedVolume.rawValue == 1 << 12)
        #expect(C.dynamicGroupingSupported.rawValue == 1 << 16)
        #expect(C.castConnectSupported.rawValue == 1 << 18)
    }

    @Test func parsesStatusVersionAppAndIcon() throws {
        let device = try #require(device([
            "id": "abc", "ve": "05", "st": "1", "rr": "CC1AD845", "ic": "/setup/icon.png", "rs": "Default Media Receiver",
        ]))
        #expect(device.deviceVersion == 5)
        #expect(device.status == .busy)
        #expect(device.runningApplicationID == "CC1AD845")
        #expect(device.iconPath == "/setup/icon.png")
        #expect(device.statusText == "Default Media Receiver")

        #expect(self.device(["st": "0"])?.status == .idle)
        #expect(self.device(["st": "2"])?.status == nil)
        #expect(self.device(["st": "busy"])?.status == nil)

        let bare = try #require(self.device(["ve": "", "rr": "", "ic": ""]))
        #expect(bare.deviceVersion == nil)
        #expect(bare.status == nil)
        #expect(bare.runningApplicationID == nil)
        #expect(bare.iconPath == nil)
    }

    @Test func kindFollowsCastSDKPrecedence() {
        func kind(_ caps: CastDevice.Capabilities) -> CastDevice.Kind {
            CastDevice(id: "x", name: "x", capabilities: caps, endpoint: service("x")).kind
        }
        #expect(kind([.multizoneGroup, .videoOut, .audioOut]) == .group)
        #expect(kind([.videoOut, .audioOut]) == .tv)
        #expect(kind([.audioOut, .audioIn]) == .speaker)
        #expect(kind([.developerMode]) == .generic)
        #expect(kind([]) == .generic)
    }

    @Test func picksTheSameDuplicateRegardlessOfOrder() {
        let cellular = CastDiscovery.BrowseCandidate(
            device: device(id: "abc", name: "Cellular", service: "A"), interfaceTypes: [.cellular], interfaceNames: ["pdp_ip0"]
        )
        let wifiB = CastDiscovery.BrowseCandidate(
            device: device(id: "abc", name: "Wifi B", service: "B"), interfaceTypes: [.wifi], interfaceNames: ["en0"]
        )
        let wiredC = CastDiscovery.BrowseCandidate(
            device: device(id: "abc", name: "Wired C", service: "C"), interfaceTypes: [.wiredEthernet], interfaceNames: ["en1"]
        )
        let other = CastDiscovery.BrowseCandidate(
            device: device(id: "def", name: "Kitchen", service: "D"), interfaceTypes: [.wifi], interfaceNames: ["en0"]
        )
        let candidates = [cellular, wifiB, wiredC, other]
        for order in [candidates, candidates.reversed(), [wiredC, other, cellular, wifiB]] {
            let devices = CastDiscovery.devices(from: order)
            #expect(devices.map(\.name) == ["Kitchen", "Wifi B"])
        }

        let en1 = CastDiscovery.BrowseCandidate(
            device: device(id: "abc", name: "en1", service: "B"), interfaceTypes: [.wifi], interfaceNames: ["en1"]
        )
        #expect(CastDiscovery.devices(from: [en1, wifiB]).map(\.name) == ["Wifi B"])
        #expect(CastDiscovery.devices(from: [wifiB, en1]).map(\.name) == ["Wifi B"])
    }

    @Test func sortsByNameThenID() {
        let devices = CastDiscovery.sorted([
            device(id: "b", name: "TV"), device(id: "a", name: "tv"), device(id: "c", name: "Bedroom"),
        ])
        #expect(devices.map(\.id) == ["c", "a", "b"])
    }

    @Test func rosterKeepsMissingDevicesForTheGracePeriod() {
        let start = ContinuousClock.now
        var roster = DeviceRoster<ContinuousClock.Instant>(gracePeriod: .seconds(30))
        let tv = device(id: "tv", name: "TV")
        let speaker = device(id: "speaker", name: "Speaker")

        roster.update([tv, speaker], at: start)
        roster.update([tv], at: start + .seconds(1))
        #expect(roster.devices.map(\.id) == ["speaker", "tv"])
        var expired = roster.expire(at: start + .seconds(30))
        #expect(!expired)
        #expect(roster.devices.map(\.id) == ["speaker", "tv"])

        roster.update([tv], at: start + .seconds(20))
        expired = roster.expire(at: start + .seconds(31))
        #expect(expired)
        #expect(roster.devices.map(\.id) == ["tv"])
        expired = roster.expire(at: start + .seconds(60))
        #expect(!expired)
    }

    @Test func rosterRestoresAndUpdatesDevicesInPlace() {
        let start = ContinuousClock.now
        var roster = DeviceRoster<ContinuousClock.Instant>(gracePeriod: .seconds(30))
        roster.update([device(id: "tv", name: "TV")], at: start)
        roster.update([], at: start + .seconds(1))
        roster.update([device(id: "tv", name: "Lounge TV")], at: start + .seconds(25))
        var expired = roster.expire(at: start + .seconds(40))
        #expect(!expired)
        #expect(roster.devices.map(\.id) == ["tv"])
        #expect(roster.devices.map(\.name) == ["Lounge TV"])

        roster.update([], at: start + .seconds(41))
        expired = roster.expire(at: start + .seconds(70))
        #expect(!expired)
        expired = roster.expire(at: start + .seconds(71))
        #expect(expired)
        #expect(roster.devices.isEmpty)
    }

    @MainActor
    @Test func browserExpiresDevicesAfterTheGracePeriod() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: CastDiscovery.Event.self)
        let browser = CastDeviceBrowser(gracePeriod: .seconds(1), sweepInterval: .milliseconds(20)) { stream }
        let run = Task { await browser.run() }
        defer { run.cancel() }

        let tv = device(id: "tv", name: "TV")
        let speaker = device(id: "speaker", name: "Speaker")
        continuation.yield(.devices([tv, speaker]))
        try await waitUntil { browser.devices.count == 2 }
        #expect(browser.isBrowsing)

        continuation.yield(.devices([tv]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(browser.devices.map(\.id) == ["speaker", "tv"])

        continuation.yield(.devices([tv, device(id: "speaker", name: "Kitchen")]))
        try await waitUntil { browser.devices.map(\.name) == ["Kitchen", "TV"] }

        continuation.yield(.devices([tv]))
        try await waitUntil { browser.devices.map(\.id) == ["tv"] }

        continuation.finish()
        await run.value
        #expect(!browser.isBrowsing)
    }

    @MainActor
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
