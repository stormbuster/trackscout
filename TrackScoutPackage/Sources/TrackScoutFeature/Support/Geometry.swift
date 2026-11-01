import CoreLocation
import Foundation

/// Small geo helpers shared across the app.
public enum Geo {
    /// Round to 5 decimal places (~1 m). Places are keyed by the rounded pair.
    public static func round5(_ value: Double) -> Double {
        (value * 100_000).rounded() / 100_000
    }

    /// Stable key for a place, e.g. "52.52354,13.41346".
    public static func key(lat: Double, lon: Double) -> String {
        String(format: "%.5f,%.5f", round5(lat), round5(lon))
    }

    /// Great-circle distance in metres (WGS84, as CoreLocation computes it).
    public static func distance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Compass bearing in degrees, 0 = north, 90 = east, from `a` to `b`.
    public static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude * .pi / 180
        let φ2 = b.latitude * .pi / 180
        let Δλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Parse a "lat,lon" place key back into coordinates.
    public static func coordinate(forKey key: String) -> CLLocationCoordinate2D? {
        let parts = key.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }
}
