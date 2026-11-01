import Foundation
import Testing
@testable import TrackScoutFeature

/// Sun classification (photo PRD 5.1, acceptance 4): the three simulator
/// times of Berlin, 30 Oct 2026, must come out day / dusk / night, and the
/// night-nudge window (photo PRD 4.4) must follow the sunset + the 23:30
/// cutoff. 30 Oct is after German DST ends, so Berlin is UTC+1 (CET).
struct SunTests {
    /// Berlin centre (the simulator location the acceptance walk uses).
    var lat: Double { 52.52 }
    var lon: Double { 13.405 }
    var berlin: TimeZone { TimeZone(identifier: "Europe/Berlin")! }

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = berlin
        return c
    }

    /// A 2026-10-30 local time.
    func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: hour, minute: minute))!
    }

    /// The NOAA sunset of that day (geometric horizon crossing, local time).
    var sunset: Date? {
        Sun.sunset(time: at(12), lat: lat, lon: lon, timeZone: berlin)
    }

    // MARK: Acceptance 4 — the three simulator times

    @Test func noonIsDay() {
        #expect(Sun.kind(time: at(14), lat: lat, lon: lon, timeZone: berlin) == .day)
    }

    @Test func sunsetPlus30MinutesIsDusk() {
        // 30 min after the horizon crossing the sun is only a few degrees
        // down (late October, 52°N): below 0° but not below −6°, so dusk.
        let t = sunset!.addingTimeInterval(30 * 60)
        #expect(Sun.kind(time: t, lat: lat, lon: lon, timeZone: berlin) == .dusk)
    }

    @Test func lateNightIsNight() {
        #expect(Sun.kind(time: at(23), lat: lat, lon: lon, timeZone: berlin) == .night)
    }

    // MARK: The night-nudge window (photo PRD 4.4)

    @Test func nightWindowFollowsSunsetAndCutoff() {
        // Daytime: the sun is up, no window.
        #expect(!Sun.isNightWindow(time: at(14), lat: lat, lon: lon, timeZone: berlin))
        // Sunset + 30: inside the clock window, but the sun has not dropped
        // below −6° yet — the elevation gate wins.
        #expect(!Sun.isNightWindow(time: sunset!.addingTimeInterval(30 * 60),
                                   lat: lat, lon: lon, timeZone: berlin))
        // Sunset + 60: below −6° now, so the window is open.
        #expect(Sun.isNightWindow(time: sunset!.addingTimeInterval(60 * 60),
                                  lat: lat, lon: lon, timeZone: berlin))
        // 23:00: open.
        #expect(Sun.isNightWindow(time: at(23), lat: lat, lon: lon, timeZone: berlin))
        // Past 23:30: night, but the window has closed.
        #expect(!Sun.isNightWindow(time: at(23, 45), lat: lat, lon: lon, timeZone: berlin))
    }

    /// The geometric horizon crossing for Berlin on 30 Oct 2026. The city is
    /// on standard time (CET, UTC+1) after the 25 Oct clock change, solar
    /// noon is 12:06, and the day's half-day angle puts the crossing at
    /// ~16:51 local; an almanac "sunset" that includes atmospheric
    /// refraction lands a few minutes earlier, and a summer-time almanac an
    /// hour later still. The window below is a plausibility guard: wide
    /// enough for the refraction convention, narrow enough to catch a DST
    /// or sign error.
    @Test func sunsetIsInTheEvening() {
        let s = sunset!
        let h = calendar.component(.hour, from: s)
        #expect(h == 16)
        let minutes = calendar.component(.minute, from: s)
        #expect((40...59).contains(minutes))
        #expect(s > at(16, 40) && s < at(17, 10))
    }

    // MARK: Polar night (photo PRD 4.4 edge case)

    /// Svalbard in December: the sun never crosses the horizon, so there is
    /// no sunset to wait out — once it is below −6° the window is simply open.
    @Test func polarNightWindowIsAlwaysOpen() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Oslo")!
        let t = c.date(from: DateComponents(year: 2026, month: 12, day: 21, hour: 12))!
        let (lat, lon) = (78.9, 11.9)
        #expect(Sun.kind(time: t, lat: lat, lon: lon, timeZone: c.timeZone) == .night)
        #expect(Sun.sunset(time: t, lat: lat, lon: lon, timeZone: c.timeZone) == nil)
        #expect(Sun.isNightWindow(time: t, lat: lat, lon: lon, timeZone: c.timeZone))
    }

    // MARK: The classification boundaries

    @Test func classificationBoundaries() {
        #expect(Sun.kind(forElevationDegrees: 0.0001) == .day)
        #expect(Sun.kind(forElevationDegrees: 0) == .dusk)
        #expect(Sun.kind(forElevationDegrees: -3) == .dusk)
        #expect(Sun.kind(forElevationDegrees: -6) == .dusk)
        #expect(Sun.kind(forElevationDegrees: -6.0001) == .night)
        #expect(Sun.kind(forElevationDegrees: -30) == .night)
    }
}
