import CoreLocation
import Foundation
import Observation
import UIKit

/// Circles the places the user can be alerted at, using `CLMonitor`
/// (PRD 4.2: iOS allows at most 20 monitored conditions).
///
/// The monitor is a *named* system resource: its conditions persist in
/// `~/Library/CoreLocation/<bundle>/TrackScoutPlaces.monitor` across app
/// launches, and only one process may have a given name open at a time.
/// That persistence is a feature — after a relaunch we can re-attach and
/// re-add conditions with `assuming: <last known state>` so the system does
/// not fire a spurious entry/exit for the user's current position.
///
/// Apple requires the app to observe
/// `UIApplicationProtectedDataDidBecomeAvailable` before creating a named
/// monitor; `start()` defers until the data is available after, e.g., an
/// unencrypted-at-rest unlock.
@MainActor
@Observable
public final class PlaceMonitor {
    public private(set) var isRunning = false
    /// How many places the last selection is monitoring (the settings
    /// "Nudge status" card shows this; a healthy fresh sync is ≤ 20).
    public private(set) var monitoredCount = 0

    /// A monitored place was entered (identifier = place key).
    public var onEntry: ((String) async -> Void)?
    /// A monitored place was left (identifier = place key).
    public var onExit: ((String) async -> Void)?

    @ObservationIgnored private var monitor: CLMonitor?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var protectedDataObserver: NSObjectProtocol?
    /// `open()` is async, so `isRunning` is only set when it completes —
    /// this flag closes the window between "decided to open" and "opened"
    /// so two rapid `start()` calls (launch + scene activation) cannot open
    /// the named monitor twice.
    @ObservationIgnored private var isStarting = false

    static let monitorName = "TrackScoutPlaces"

    /// Creates or re-opens the named monitor and starts observing its events.
    /// Safe to call repeatedly; a no-op once running.
    public func start() {
        guard !isRunning, !isStarting, protectedDataObserver == nil else { return }
        guard Self.protectedDataAvailable else {
            protectedDataObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.start() }
            }
            return
        }
        isStarting = true
        Task {
            await open()
            isStarting = false
        }
    }

    /// Replaces the monitored circles with `places` (the 20 nearest open
    /// places, selected upstream). Conditions that are already identical are
    /// left alone; changed ones are re-added `assuming` their last state so
    /// no spurious entry/exit is generated (the user may be inside one of
    /// them right now).
    public func update(places: [MonitoredPlace], radius: Double) async {
        guard isRunning, let monitor else { return }
        let wanted = Dictionary(uniqueKeysWithValues: places.map { ($0.key, $0) })
        let current = await monitor.identifiers

        for identifier in current where wanted[identifier] == nil {
            await monitor.remove(identifier)
        }
        for (key, place) in wanted {
            let center = CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)
            let condition = CLMonitor.CircularGeographicCondition(center: center, radius: radius)
            let record = await monitor.record(for: key)
            if let record,
               let circular = record.condition as? CLMonitor.CircularGeographicCondition,
               Self.samePoint(circular.center, center),
               abs(circular.radius - radius) < 0.01 {
                continue // unchanged — the persisted condition is still right
            }
            // `assuming:` keeps the last observed state so re-adding while
            // the user is inside the circle does not replay an entry event.
            let assume = record?.lastEvent.state ?? .unknown
            await monitor.add(condition, identifier: key, assuming: assume)
        }
        monitoredCount = wanted.count
    }

    /// Removes every circle (e.g. when alerts are switched off).
    public func clear() async {
        guard isRunning, let monitor else { return }
        for identifier in await monitor.identifiers {
            await monitor.remove(identifier)
        }
        monitoredCount = 0
    }

    private func open() async {
        let monitor = await CLMonitor(Self.monitorName)
        self.monitor = monitor
        self.isRunning = true
        let events = await monitor.events
        eventsTask = Task {
            try? await consume(events)
            // The event stream can end (the system closes a named monitor on
            // a hiccup). Reset so the next `start()` — launch or scene
            // activation — re-opens it; otherwise a dead stream would
            // silently swallow every entry event for the rest of the
            // session, with no error and no way to recover short of a
            // relaunch.
            isRunning = false
        }
    }

    /// Maps monitor events to place entry/exit. `async throws` because the
    /// event stream is a throwing AsyncSequence (see `clprobe_v5.swift`);
    /// if the stream ends, the next `start()` re-opens the monitor.
    private func consume(_ events: CLMonitor.Events) async throws {
        for try await event in events {
            switch event.state {
            case .satisfied:
                await onEntry?(event.identifier)
            case .unsatisfied:
                await onExit?(event.identifier)
            default:
                // `.unknown` / `.unmonitored` (17.2+) — nothing to do.
                break
            }
        }
    }

    private static func samePoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, tolerance: Double = 0.0000005) -> Bool {
        // ≈ 5 cm; condition centers round-trip exactly, but the guard costs
        // nothing and protects against a resync that nudges a coordinate.
        abs(a.latitude - b.latitude) < tolerance && abs(a.longitude - b.longitude) < tolerance
    }

    /// Whether the app's protected files are readable right now.
    ///
    /// Apple requires observing
    /// `protectedDataDidBecomeAvailable` before creating a named monitor
    /// (its state file lives in protected `~/Library/CoreLocation`). The
    /// modern Foundation no longer exposes `isProtectedDataAvailable`, so we
    /// probe it the robust way: keep a tiny file with
    /// `.complete` protection in Caches — reading it succeeds exactly when
    /// the data is unsealed, and fails (seals) when the app was woken in the
    /// background on a locked device.
    static var protectedDataAvailable: Bool {
        let fm = FileManager.default
        let url = URL.cachesDirectory.appendingPathComponent("TrackScoutProtectedProbe")
        if !fm.fileExists(atPath: url.path) {
            _ = fm.createFile(
                atPath: url.path, contents: Data(),
                attributes: [.protectionKey: URLFileProtection.complete]
            )
        }
        return fm.contents(atPath: url.path) != nil
    }
}
