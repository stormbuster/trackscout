import Foundation

/// Day / dusk / night classification (photo PRD 5.1): the sun elevation above
/// 0° is `day`, 0° to −6° is `dusk`, below −6° is `night`.
public enum LightKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case day = "day"
    case dusk = "dusk"
    case night = "night"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .day: return "Day"
        case .dusk: return "Dusk"
        case .night: return "Night"
        }
    }

    public var symbol: String {
        switch self {
        case .day: return "sun.max"
        case .dusk: return "sunset"
        case .night: return "moon.stars"
        }
    }
}

/// Which photo a question asks for (photo PRD 3: the optional
/// `photo_wanted` field of the questions file).
public enum PhotoWanted: String, CaseIterable, Codable, Sendable {
    case day = "day"
    case night = "night"
    case both = "both"

    public var label: String {
        switch self {
        case .day: return "Day photo wanted"
        case .night: return "Night photo wanted"
        case .both: return "Day and night photos wanted"
        }
    }
}

/// The standard NOAA solar-position formulas, computed on device without any
/// network (photo PRD 5.1). The implementation follows the published NOAA
/// "solar position" algorithm (mean/equation-of-center/obliquity/declination/
/// right ascension / equation of time / hour angle), the same one the NOAA
/// spreadsheet and SunCalc use.
public enum Sun {
    /// Elevation of the sun above the horizon in degrees (< 0 = below).
    public static func elevation(
        time: Date,
        lat: Double,
        lon: Double,
        timeZone: TimeZone = .current
    ) -> Double {
        let φ = lat * .pi / 180
        let d = declination(julianCentury(time))
        let hourAngle = hourAngle(time: time, lon: lon, timeZone: timeZone)
        let sinElev = sin(φ) * sin(d) + cos(φ) * cos(d) * cos(hourAngle)
        return asin(min(1, max(-1, sinElev))) * 180 / .pi
    }

    /// The PRD 5.1 classification of `elevation`: > 0 day, −6 to 0 dusk,
    /// below −6 night.
    public static func kind(forElevationDegrees elevation: Double) -> LightKind {
        if elevation > 0 { return .day }
        if elevation >= -6 { return .dusk }
        return .night
    }

    /// The day / dusk / night kind for a time and position.
    public static func kind(
        time: Date,
        lat: Double,
        lon: Double,
        timeZone: TimeZone = .current
    ) -> LightKind {
        kind(forElevationDegrees: elevation(time: time, lat: lat, lon: lon, timeZone: timeZone))
    }

    /// Sunset (or sunrise) as a local `Date`: the moment the geometric sun
    /// crosses the horizon (`elevation == 0`). `nil` on polar days where the
    /// sun never crosses the horizon.
    public static func sunset(
        time: Date,
        lat: Double,
        lon: Double,
        timeZone: TimeZone = .current
    ) -> Date? {
        halfDay(event: .sunset, time: time, lat: lat, lon: lon, timeZone: timeZone)
    }

    public static func sunrise(
        time: Date,
        lat: Double,
        lon: Double,
        timeZone: TimeZone = .current
    ) -> Date? {
        halfDay(event: .sunrise, time: time, lat: lat, lon: lon, timeZone: timeZone)
    }

    /// The night-nudge window (photo PRD 4.4): from sunset +
    /// `startOffsetMinutes` until `endHour` local (the shipped defaults:
    /// 30 / 23.5 = 23:30, overridable per project via `trackscout.json`),
    /// and only while it is actually night (elevation < −6°). A night nudge
    /// may fire only inside this window — and deliberately *outside* the
    /// normal quiet hours, because night is its whole point.
    public static func isNightWindow(
        time: Date,
        lat: Double,
        lon: Double,
        timeZone: TimeZone = .current,
        startOffsetMinutes: Double = 30,
        endHour: Double = 23.5
    ) -> Bool {
        guard kind(time: time, lat: lat, lon: lon, timeZone: timeZone) == .night else { return false }
        // Polar night: the sun never sets, so there is no sunset to wait out
        // — once it is below −6°, the window is simply open.
        guard let sunset = sunset(time: time, lat: lat, lon: lon, timeZone: timeZone) else {
            return true
        }
        let start = sunset.addingTimeInterval(startOffsetMinutes * 60)
        let end = dateAtLocalHours(endHour, on: time, timeZone: timeZone)
        return time >= start && time <= end
    }

    // MARK: Components

    private enum Event { case sunset, sunrise }

    private static func halfDay(
        event: Event,
        time: Date,
        lat: Double,
        lon: Double,
        timeZone: TimeZone
    ) -> Date? {
        let φ = lat * .pi / 180
        let d = declination(julianCentury(time))
        let cosH = -tan(φ) * tan(d)
        guard abs(cosH) <= 1 else { return nil } // polar day / night
        let H0 = acos(cosH) // radians, 0 at solar noon
        let H = (event == .sunset ? H0 : -H0) * 180 / .pi // degrees
        let hours = localSolarNoon(time: time, lon: lon, timeZone: timeZone) + H / 15
        return dateAtLocalHours(hours, on: time, timeZone: timeZone)
    }

    /// Local clock hours at solar noon: 12 − EqT/60 − lon/15 + timezone.
    private static func localSolarNoon(time: Date, lon: Double, timeZone: TimeZone) -> Double {
        12 - equationOfTimeMinutes(julianCentury(time)) / 60 - lon / 15
            + Double(timeZone.secondsFromGMT(for: time)) / 3600
    }

    private static func hourAngle(time: Date, lon: Double, timeZone: TimeZone) -> Double {
        let h = localSolarNoon(time: time, lon: lon, timeZone: timeZone)
        return 15 * (localClockHours(time, timeZone: timeZone) - h) * .pi / 180
    }

    /// Fractional local clock hours (e.g. 13.5 = 13:30) for `time`.
    private static func localClockHours(_ time: Date, timeZone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: time)
        return Double(parts.hour ?? 0)
            + Double(parts.minute ?? 0) / 60
            + Double(parts.second ?? 0) / 3600
    }

    /// A `Date` for a fractional local clock hour on the local day of `time`.
    static func dateAtLocalHours(_ hours: Double, on time: Date, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: time)
        guard let midnight = calendar.date(from: day) else { return time }
        return midnight.addingTimeInterval(hours * 3600)
    }

    /// Sun declination in radians.
    private static func declination(_ t: Double) -> Double {
        let ε = obliquity(t)
        let λ = apparentLongitude(t)
        return asin(sin(ε) * sin(λ))
    }

    // MARK: NOAA formula pieces (all angles in radians unless noted)

    private static func julianCentury(_ time: Date) -> Double {
        let epoch = Date(timeIntervalSince1970: 0)
        let jd = time.timeIntervalSince(epoch) / 86_400 + 2_440_587.5
        return (jd - 2_451_545.0) / 36_525
    }

    private static func meanAnomaly(_ t: Double) -> Double {
        radians(mod360(357.528 + 35999.050 * t))
    }

    private static func meanLongitude(_ t: Double) -> Double {
        radians(mod360(280.460 + 36000.769 * t))
    }

    private static func equationOfCenter(_ t: Double) -> Double {
        let m = meanAnomaly(t)
        return radians(1.915 * sin(m) + 0.020 * sin(2 * m) + 0.0003 * sin(3 * m))
    }

    private static func obliquity(_ t: Double) -> Double {
        let Ω = radians(125.04 - 1934.394 * t)
        return radians(23.439 - 0.0130 * t - 0.00569 * sin(Ω))
    }

    private static func apparentLongitude(_ t: Double) -> Double {
        let λ = meanLongitude(t) + equationOfCenter(t)
        let Ω = radians(125.04 - 1934.394 * t)
        return radians(mod360(degrees(λ) - 0.00569 - 0.00478 * sin(Ω)))
    }

    /// Equation of time in minutes (sundial minus clock).
    private static func equationOfTimeMinutes(_ t: Double) -> Double {
        let λ = apparentLongitude(t)
        let y = pow(tan(obliquity(t) / 2), 2)
        let lPlusC = meanLongitude(t) + equationOfCenter(t)
        let raHours = mod24(degrees(
            atan2((1 + y) * sin(λ), sqrt(1 + y * y) * (cos(λ) + y * cos(lPlusC)))
        ) / 15)
        return 4 * (degrees(lPlusC) - 15 * raHours)
    }

    // MARK: Angle helpers

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
    private static func mod360(_ degrees: Double) -> Double {
        (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }
    private static func mod24(_ hours: Double) -> Double {
        (hours.truncatingRemainder(dividingBy: 24) + 24).truncatingRemainder(dividingBy: 24)
    }
}
