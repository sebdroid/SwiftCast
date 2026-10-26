import Foundation
import Network
import os
import Testing
@testable import SwiftCast

@Suite("Discovery")
struct DiscoveryTests {
    private func service(_ name: String) -> NWEndpoint {
        .service(name: name, type: "_googlecast._tcp", domain: "local.", interface: nil)
    }

    private func makeDevice(_ txt: [String: String], service name: String = "Chromecast-abc") -> CastDevice? {
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
        let device = try #require(makeDevice(["id": raw, "fn": "TV"]))
        #expect(device.id == expected)
        #expect(device.txtRecord["id"] == raw)
    }

    @Test(arguments: ["", "uuid:", "-", "UUID:--"])
    func dropsRecordsWithEmptyID(raw: String) {
        #expect(makeDevice(["id": raw, "fn": "TV"]) == nil)
    }

    @Test func fallsBackToServiceNameWithoutIDOrName() throws {
        let missing = try #require(makeDevice(["ca": "5"], service: "Google-Cast-Group-1"))
        #expect(missing.id == "Google-Cast-Group-1")
        #expect(missing.name == "Google-Cast-Group-1")
        let empty = try #require(makeDevice(["id": "abc", "fn": ""], service: "Chromecast-xyz"))
        #expect(empty.name == "Chromecast-xyz")
    }

    @Test func parsesCapabilitiesAsUnsigned() throws {
        #expect(try #require(makeDevice(["ca": "-1"])).capabilities == [])
        #expect(try #require(makeDevice(["ca": "lots"])).capabilities == [])
        #expect(try #require(makeDevice([:])).capabilities == [])

        let caps = try #require(makeDevice(["ca": "4101"])).capabilities
        #expect(caps == [.videoOut, .audioOut, .attenuationOrFixedVolume])
        #expect(caps.rawValue == 4101)

        let wide = try #require(makeDevice(["ca": "18446744073709551615"])).capabilities
        #expect(wide.rawValue == .max)
    }

    @Test func capabilityBitsMatchTheTXTRecordFlags() {
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
        let device = try #require(makeDevice([
            "id": "abc", "ve": "05", "st": "1", "rr": "CC1AD845", "ic": "/setup/icon.png", "rs": "Default Media Receiver",
        ]))
        #expect(device.deviceVersion == 5)
        #expect(device.status == .busy)
        #expect(device.runningApplicationID == "CC1AD845")
        #expect(device.iconPath == "/setup/icon.png")
        #expect(device.statusText == "Default Media Receiver")

        #expect(makeDevice(["st": "0"])?.status == .idle)
        #expect(makeDevice(["st": "2"])?.status == nil)
        #expect(makeDevice(["st": "busy"])?.status == nil)

        let bare = try #require(makeDevice(["ve": "", "rr": "", "ic": ""]))
        #expect(bare.deviceVersion == nil)
        #expect(bare.status == nil)
        #expect(bare.runningApplicationID == nil)
        #expect(bare.iconPath == nil)
    }

    @Test func kindPrefersGroupThenVideoThenAudio() {
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

    @Test func keepsThePreviouslyChosenEndpointForAnID() {
        func candidate(_ serviceName: String, id: String = "abc") -> CastDiscovery.BrowseCandidate {
            .init(device: device(id: id, name: serviceName, service: serviceName), interfaceTypes: [.wifi], interfaceNames: ["en0"])
        }
        var chosen: [String: NWEndpoint] = [:]
        let first = CastDiscovery.devices(from: [candidate("Real")], keeping: &chosen)
        #expect(first.map(\.name) == ["Real"])
        #expect(chosen["abc"] == service("Real"))

        let contested = CastDiscovery.devices(from: [candidate("A"), candidate("Real")], keeping: &chosen)
        #expect(contested.map(\.name) == ["Real"])
        let reordered = CastDiscovery.devices(from: [candidate("Real"), candidate("A")], keeping: &chosen)
        #expect(reordered.map(\.name) == ["Real"])

        let fresh = CastDiscovery.devices(
            from: [candidate("Real"), candidate("Y", id: "def"), candidate("X", id: "def")], keeping: &chosen
        )
        #expect(fresh.map(\.name) == ["Real", "X"])
        #expect(chosen["def"] == service("X"))

        let afterLoss = CastDiscovery.devices(from: [candidate("B"), candidate("A")], keeping: &chosen)
        #expect(afterLoss.map(\.name) == ["A"])
        #expect(chosen == ["abc": service("Real"), "def": service("X")])

        let returned = CastDiscovery.devices(from: [candidate("Real"), candidate("A")], keeping: &chosen)
        #expect(returned.map(\.name) == ["Real"])
    }

    @Test func aMissedCallbackDoesNotHandTheIDToALookalike() {
        func candidate(_ serviceName: String) -> CastDiscovery.BrowseCandidate {
            .init(device: device(id: "X", name: serviceName, service: serviceName), interfaceTypes: [.wifi], interfaceNames: ["en0"])
        }
        var chosen: [String: NWEndpoint] = [:]
        let first = CastDiscovery.devices(from: [candidate("Living-Room")], keeping: &chosen)
        #expect(first.map(\.endpoint) == [service("Living-Room")])

        let missed = CastDiscovery.devices(from: [candidate("0")], keeping: &chosen)
        #expect(missed.map(\.endpoint) == [service("0")])
        #expect(chosen == ["X": service("Living-Room")])

        let both = CastDiscovery.devices(from: [candidate("0"), candidate("Living-Room")], keeping: &chosen)
        #expect(both.map(\.endpoint) == [service("Living-Room")])
    }

    @Test func sortsByNameThenID() {
        let devices = CastDiscovery.sorted([
            device(id: "b", name: "TV"), device(id: "a", name: "tv"), device(id: "c", name: "Bedroom"),
        ])
        #expect(devices.map(\.id) == ["c", "a", "b"])
    }

    @Test func rosterTreatsEverythingAsUnseenOnRestart() {
        let start = ContinuousClock.now
        var roster = DeviceRoster<ContinuousClock.Instant>(gracePeriod: .seconds(30))
        roster.update([device(id: "tv", name: "TV"), device(id: "speaker", name: "Speaker")], at: start)
        roster.markAllMissing(at: start + .seconds(60))
        roster.update([device(id: "tv", name: "TV")], at: start + .seconds(61))
        let expiredEarly = roster.expire(at: start + .seconds(80))
        #expect(!expiredEarly)
        #expect(roster.devices.map(\.id) == ["speaker", "tv"])
        let expiredLate = roster.expire(at: start + .seconds(90))
        #expect(expiredLate)
        #expect(roster.devices.map(\.id) == ["tv"])
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
        let browser = CastDeviceBrowser(gracePeriod: .seconds(1), sweepInterval: .milliseconds(20)) { _ in stream }
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
    @Test func browserKeepsChosenEndpointsAcrossRestarts() async throws {
        func candidate(_ serviceName: String, id: String = "X") -> CastDiscovery.BrowseCandidate {
            .init(device: device(id: id, name: serviceName, service: serviceName), interfaceTypes: [.wifi], interfaceNames: ["en0"])
        }
        let fixtures = OSAllocatedUnfairLock(initialState: [
            [candidate("Living-Room")],
            [candidate("0"), candidate("Living-Room"), candidate("Kitchen", id: "Y")],
        ])
        let browser = CastDeviceBrowser(gracePeriod: .seconds(30), sweepInterval: .seconds(30)) { chosen in
            let candidates = fixtures.withLock { $0.removeFirst() }
            let found = chosen.withLock { CastDiscovery.devices(from: candidates, keeping: &$0) }
            return AsyncStream { $0.yield(.devices(found)) }
        }

        let first = Task { await browser.run() }
        try await waitUntil { browser.devices.map(\.endpoint) == [service("Living-Room")] }
        first.cancel()
        await first.value

        let second = Task { await browser.run() }
        defer { second.cancel() }
        try await waitUntil { browser.devices.count == 2 }
        #expect(browser.devices.first { $0.id == "X" }?.endpoint == service("Living-Room"))
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
