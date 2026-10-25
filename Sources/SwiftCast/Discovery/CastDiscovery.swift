import Foundation
import Network
import Observation
import os

/// Discovers Cast devices on the local network using Bonjour (`_googlecast._tcp`).
///
/// On iOS, tvOS and visionOS your app's Info.plist must include
/// `NSLocalNetworkUsageDescription` and list `_googlecast._tcp` under
/// `NSBonjourServices`.
public enum CastDiscovery {
    /// The Bonjour service type advertised by Cast devices.
    public static let serviceType = "_googlecast._tcp"

    /// Browser status reported through ``events()``.
    public enum Event: Sendable {
        /// The complete, current set of devices, sorted by name.
        case devices([CastDevice])
        /// The browser is blocked, typically because Local Network access was
        /// denied. Browsing resumes automatically if access is granted.
        case waiting(String)
        /// The browser failed and stopped.
        case failed(String)
    }

    /// Browses for devices. Each call starts an independent browser that
    /// stops when the consumer stops iterating.
    public static func events(domain: String? = nil) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: serviceType, domain: domain),
                using: parameters
            )
            browser.stateUpdateHandler = { state in
                switch state {
                case .waiting(let error):
                    continuation.yield(.waiting(error.localizedDescription))
                case .failed(let error):
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                default:
                    break
                }
            }
            let chosen = OSAllocatedUnfairLock<[String: NWEndpoint]>(initialState: [:])
            browser.browseResultsChangedHandler = { results, _ in
                let candidates = candidates(from: results)
                let found = chosen.withLock { devices(from: candidates, keeping: &$0) }
                continuation.yield(.devices(found))
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: DispatchQueue(label: "SwiftCast.CastDiscovery"))
        }
    }

    /// Streams the current set of devices whenever it changes.
    public static func devices(domain: String? = nil) -> AsyncStream<[CastDevice]> {
        let events = events(domain: domain)
        return AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    if case .devices(let devices) = event { continuation.yield(devices) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Browses for `duration` and returns every device found.
    public static func scan(for duration: Duration = .seconds(3)) async -> [CastDevice] {
        await withTaskGroup(of: [CastDevice]?.self) { group in
            group.addTask {
                var latest: [CastDevice] = []
                for await devices in devices() {
                    latest = devices
                    if Task.isCancelled { break }
                }
                return latest
            }
            group.addTask {
                try? await Task.sleep(for: duration)
                return nil
            }
            // The timer finishes first; cancelling ends the browse loop.
            _ = await group.next()
            group.cancelAll()
            var result: [CastDevice] = []
            while let next = await group.next() {
                if let next { result = next }
            }
            return result
        }
    }

    struct BrowseCandidate: Sendable {
        let device: CastDevice
        let interfaceTypes: [NWInterface.InterfaceType]
        let interfaceNames: [String]

        var serviceName: String {
            if case .service(let name, _, _, _) = device.endpoint { return name }
            return ""
        }

        var isOnPrimaryNetwork: Bool {
            interfaceTypes.contains(.wifi) || interfaceTypes.contains(.wiredEthernet)
        }

        func isPreferred(over other: BrowseCandidate) -> Bool {
            if isOnPrimaryNetwork != other.isOnPrimaryNetwork { return isOnPrimaryNetwork }
            if serviceName != other.serviceName { return serviceName < other.serviceName }
            return interfaceNames.joined(separator: ",") < other.interfaceNames.joined(separator: ",")
        }
    }

    static func candidates(from results: Set<NWBrowser.Result>) -> [BrowseCandidate] {
        results.compactMap { result -> BrowseCandidate? in
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata {
                for (key, entry) in record {
                    if case .string(let value) = entry { txt[key] = value } else { txt[key] = "" }
                }
            }
            guard let device = CastDevice(serviceEndpoint: result.endpoint, txt: txt) else { return nil }
            return BrowseCandidate(
                device: device,
                interfaceTypes: result.interfaces.map(\.type),
                interfaceNames: result.interfaces.map(\.name)
            )
        }
    }

    static func devices(from candidates: [BrowseCandidate]) -> [CastDevice] {
        var chosen: [String: NWEndpoint] = [:]
        return devices(from: candidates, keeping: &chosen)
    }

    /// The same device can be reported once per network interface, or under
    /// several service names, so one result per `id` is kept. The endpoint
    /// kept last time wins while it is still reported, so a newcomer copying
    /// a known device's `id` cannot displace it; otherwise a fixed rule picks.
    /// `chosen` is updated to the endpoints kept this time.
    static func devices(from candidates: [BrowseCandidate], keeping chosen: inout [String: NWEndpoint]) -> [CastDevice] {
        var byID: [String: BrowseCandidate] = [:]
        for candidate in candidates {
            let id = candidate.device.id
            if let current = byID[id] {
                let previous = chosen[id]
                let keepsPrevious = current.device.endpoint == previous
                let isPrevious = candidate.device.endpoint == previous
                if keepsPrevious != isPrevious {
                    if keepsPrevious { continue }
                } else if !candidate.isPreferred(over: current) {
                    continue
                }
            }
            byID[id] = candidate
        }
        chosen = byID.mapValues(\.device.endpoint)
        return sorted(byID.values.map(\.device))
    }

    static func sorted(_ devices: [CastDevice]) -> [CastDevice] {
        devices.sorted {
            switch $0.name.localizedStandardCompare($1.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: $0.id < $1.id
            }
        }
    }
}

/// Keeps devices listed for a grace period after they drop out of the browse
/// results, so a brief mDNS gap does not make them flicker out of a list.
struct DeviceRoster<Instant: InstantProtocol> {
    private struct Entry {
        var device: CastDevice
        var missingSince: Instant?
    }

    let gracePeriod: Instant.Duration
    private var entries: [String: Entry] = [:]

    init(gracePeriod: Instant.Duration) {
        self.gracePeriod = gracePeriod
    }

    var devices: [CastDevice] { CastDiscovery.sorted(entries.values.map(\.device)) }

    mutating func update(_ found: [CastDevice], at now: Instant) {
        let foundIDs = Set(found.map(\.id))
        for id in entries.keys where !foundIDs.contains(id) && entries[id]?.missingSince == nil {
            entries[id]?.missingSince = now
        }
        for device in found {
            entries[device.id] = Entry(device: device, missingSince: nil)
        }
    }

    /// Marks every listed device as unseen, so devices left over from a previous
    /// browse expire unless the new browse reports them again.
    mutating func markAllMissing(at now: Instant) {
        for id in entries.keys where entries[id]?.missingSince == nil {
            entries[id]?.missingSince = now
        }
    }

    /// Removes devices missing for at least the grace period, returning
    /// whether any were removed.
    mutating func expire(at now: Instant) -> Bool {
        let expired = entries.filter { _, entry in
            entry.missingSince.map { $0.duration(to: now) >= gracePeriod } ?? false
        }
        for id in expired.keys { entries[id] = nil }
        return !expired.isEmpty
    }
}

/// An observable Cast device browser for SwiftUI.
///
/// A device that drops out of the browse results stays listed for 30 seconds
/// in case it comes back, so a lossy mDNS announcement does not make it flicker.
///
/// ```swift
/// @State private var browser = CastDeviceBrowser()
///
/// List(browser.devices) { Text($0.name) }
///     .task { await browser.run() }
/// ```
@MainActor
@Observable
public final class CastDeviceBrowser {
    /// Devices currently visible on the network, or seen within the grace period.
    public private(set) var devices: [CastDevice] = []
    /// A message describing why browsing is blocked or failed, if it is.
    public private(set) var problem: String?
    /// Whether the browser is running.
    public private(set) var isBrowsing = false

    private let events: @Sendable () -> AsyncStream<CastDiscovery.Event>
    private let sweepInterval: Duration
    private let clock = ContinuousClock()
    private var roster: DeviceRoster<ContinuousClock.Instant>

    public convenience init() {
        self.init(gracePeriod: .seconds(30), sweepInterval: .seconds(5)) { CastDiscovery.events() }
    }

    init(
        gracePeriod: Duration,
        sweepInterval: Duration,
        events: @escaping @Sendable () -> AsyncStream<CastDiscovery.Event>
    ) {
        self.events = events
        self.sweepInterval = sweepInterval
        self.roster = DeviceRoster(gracePeriod: gracePeriod)
    }

    /// Browses until the calling task is cancelled (e.g. from `.task {}`).
    public func run() async {
        isBrowsing = true
        roster.markAllMissing(at: clock.now)
        let sweeper = Task { [weak self, clock, sweepInterval] in
            while !Task.isCancelled {
                try? await clock.sleep(for: sweepInterval)
                self?.sweep()
            }
        }
        defer {
            sweeper.cancel()
            isBrowsing = false
        }
        for await event in events() {
            switch event {
            case .devices(let found):
                roster.update(found, at: clock.now)
                devices = roster.devices
                problem = nil
            case .waiting(let message):
                problem = message
            case .failed(let message):
                problem = message
            }
        }
    }

    private func sweep() {
        if roster.expire(at: clock.now) { devices = roster.devices }
    }
}
