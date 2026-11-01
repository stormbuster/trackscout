import CoreLocation
import Foundation
import Observation

/// The app's single `CLLocationManager` wrapper.
///
/// Two flavours of fixes at the same time, toggled by the scene phase
/// (PRD: live map in the foreground, cheap updates in the background, and
/// "no constant GPS" — the background uses significant-change monitoring,
/// the one background API that fits that rule):
///
/// - **Foreground**: `startUpdatingLocation()` + `startUpdatingHeading()`
///   for the map, the distance rows, and the compass arrow.
/// - **Background** (always authorization only): `startMonitoringSignificantLocationChanges()`,
///   which wakes the app roughly every 500 m — that is what lets the 20-place
///   monitor set track the user while suspended.
///
/// Authorization is requested from onboarding, which offers "Allow Always"
/// (PRD 4.2: background alerts need it). With only when-in-use, the system
/// simply will not deliver background entries, so the alert gate is
/// `allowsBackgroundAlerts` == `.authorizedAlways`.
@MainActor
@Observable
public final class LocationService: NSObject {
    /// The most recent fix, for the map and the distance rows.
    public private(set) var lastLocation: CLLocation?
    /// The most recent compass heading, degrees (0 = north).
    public private(set) var heading: Double?
    /// The current authorization, as reported by the manager.
    public private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// True only for `.authorizedAlways` — the gate for background alerts.
    public var allowsBackgroundAlerts: Bool { authorization == .authorizedAlways }

    /// Called on every fix, foreground or background.
    public var onLiveLocation: ((CLLocation) -> Void)?
    /// Called when the user has moved ≥ 50 m since the last such callback
    /// (every significant-change delivery counts). The monitored-set refresh
    /// listens to this, throttled, rather than to every fix.
    public var onSignificantChange: ((CLLocation) -> Void)?
    /// Called when the authorization changes.
    public var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private var lastSignificant: CLLocation?

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        // Only significant changes run in the background (not continuous
        // updates), so the background location indicator never appears;
        // keep it off to stay out of the way in the foreground too.
        manager.showsBackgroundLocationIndicator = false
    }

    private var isAuthorized: Bool {
        authorization == .authorizedAlways || authorization == .authorizedWhenInUse
    }

    /// Ask for authorization. `always` offers the background-capable grant
    /// (onboarding, PRD 4.2); the answer arrives via `onAuthorizationChange`.
    public func requestAuthorization(always: Bool) {
        if always {
            manager.requestAlwaysAuthorization()
        } else {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Re-read the authorization (after the user returns from Settings).
    public func refreshAuthorization() {
        authorization = manager.authorizationStatus
    }

    /// Switch between the foreground (live) and background (significant
    /// changes) modes. Called on scene phase changes.
    public func setForeground(_ foreground: Bool) {
        guard foreground != isForeground else { return }
        isForeground = foreground
        applyMode()
    }

    /// Re-assert the current mode. Call after an authorization change:
    /// `setForeground` alone would be a no-op because the phase did not
    /// change, but the update loop may need (re)starting.
    public func applyAuthorization() {
        applyMode()
    }

    /// One precise sample, for the photo meta at capture time (photo PRD
    /// 5.2: "one precise `CLLocationUpdate` sample. No background
    /// location."). The live-updates stream ends when the consuming task is
    /// cancelled, so "stop" is the `cancelAll()` below — nothing keeps
    /// running after the capture. A foreground fix loop is already active
    /// while the camera is open, so if nothing arrives within `timeout`
    /// seconds the last fix is returned instead of blocking the shutter.
    public func samplePreciseLocation(timeout: TimeInterval = 10) async -> CLLocation? {
        guard isAuthorized else { return lastLocation }
        let updates = CLLocationUpdate.liveUpdates(.otherNavigation)
        let sample = await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in updates {
                        if let location = update.location {
                            return location
                        }
                    }
                } catch {
                    // The timeout won and cancelled the stream — fall
                    // through to the last-fix fallback.
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first
        }
        return sample ?? lastLocation
    }

    private func applyMode() {
        if isForeground {
            manager.stopMonitoringSignificantLocationChanges()
            if isAuthorized {
                manager.startUpdatingLocation()
                manager.startUpdatingHeading()
            } else {
                manager.stopUpdatingLocation()
                manager.stopUpdatingHeading()
            }
        } else {
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
            if authorization == .authorizedAlways {
                manager.startMonitoringSignificantLocationChanges()
            } else {
                manager.stopMonitoringSignificantLocationChanges()
            }
        }
    }
}

// MARK: CLLocationManagerDelegate
//
// The delegate is called on the main thread. The methods are `nonisolated`
// (the NSObject-based protocol requires it) and hop to the MainActor before
// touching the observable state or the callbacks.

extension LocationService: CLLocationManagerDelegate {
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let new = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = new
            self.onAuthorizationChange?(new)
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.handle(location: location, foreground: self.isForeground)
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // Nothing to do — the offline-first design tolerates network/position
        // errors; the next update (or sync) recovers.
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in
            self.heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        }
    }

    nonisolated public func locationManagerDidStopUpdatingLocation(_ manager: CLLocationManager) {
        // The update loop stopped (authorization change, background). The
        // next mode switch restarts it; there is no state to reconcile.
    }
}

private extension LocationService {
    /// Common path for a fix. A fix counts as "significant" when it arrived
    /// from significant-change monitoring (by definition) or, in the
    /// foreground, after ≥ 50 m of real movement — so the 20-place monitor
    /// set is not churned by meter-level jitter.
    func handle(location: CLLocation, foreground: Bool) {
        lastLocation = location
        onLiveLocation?(location)

        let significant: Bool
        if !foreground {
            significant = true
        } else if let last = lastSignificant {
            significant = location.distance(from: last) >= 50
        } else {
            significant = true
        }
        if significant {
            lastSignificant = location
            onSignificantChange?(location)
        }
    }
}
