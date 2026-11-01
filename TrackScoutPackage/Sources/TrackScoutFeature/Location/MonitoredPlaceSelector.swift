import CoreLocation
import Foundation

/// A place as seen by the location monitor: just enough to decide what to
/// circle. (Derived from the stored Place + open state; kept as a plain
/// struct so the selection logic is pure and unit-testable.)
public struct MonitoredPlace: Hashable, Sendable {
    public var key: String
    public var lat: Double
    public var lon: Double
    public var isOpen: Bool

    public init(key: String, lat: Double, lon: Double, isOpen: Bool) {
        self.key = key
        self.lat = lat
        self.lon = lon
        self.isOpen = isOpen
    }
}

/// Chooses the places to hand to `CLMonitor` (PRD 4.2: iOS allows only 20
/// monitored conditions, so the 20 nearest *open* places).
public enum MonitoredPlaceSelector {
    /// Up to `max` open places, nearest to `center` first. Closed places are
    /// never monitored; if fewer than `max` are open, all of them are.
    public static func select(_ places: [MonitoredPlace], center: CLLocationCoordinate2D, max: Int = 20) -> [MonitoredPlace] {
        let open = places.filter(\.isOpen)
        let ordered = open.sorted {
            Geo.distance(from: center, to: coordinate($0)) < Geo.distance(from: center, to: coordinate($1))
        }
        return Array(ordered.prefix(max))
    }

    private static func coordinate(_ place: MonitoredPlace) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)
    }
}
