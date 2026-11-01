import Foundation
import Testing
@testable import TrackScoutFeature

struct AlertPolicyTests {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Noon on 2026-06-15, UTC — outside the 22:00–08:00 quiet window.
    var noon: Date {
        utc.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
    }

    func at(_ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: hour, minute: minute))!
    }

    @Test func quietHoursWrapMidnight() {
        let policy = AlertPolicy() // 22:00–08:00
        #expect(policy.isQuiet(at(23), calendar: utc))
        #expect(policy.isQuiet(at(0), calendar: utc))
        #expect(policy.isQuiet(at(7, 59), calendar: utc))
        #expect(!policy.isQuiet(at(8), calendar: utc))
        #expect(!policy.isQuiet(at(21, 59), calendar: utc))
        #expect(!policy.isQuiet(at(12), calendar: utc))
    }

    @Test func sameStartAndEndMeansNoQuietHours() {
        let policy = AlertPolicy(quietStartHour: 8, quietEndHour: 8)
        #expect(!policy.isQuiet(at(8), calendar: utc))
        #expect(!policy.isQuiet(at(12), calendar: utc))
    }

    @Test func nonWrappingWindow() {
        let policy = AlertPolicy(quietStartHour: 1, quietEndHour: 3)
        #expect(policy.isQuiet(at(1, 30), calendar: utc))
        #expect(!policy.isQuiet(at(3), calendar: utc))
        #expect(!policy.isQuiet(at(22), calendar: utc))
    }

    @Test func dailyCap() {
        let policy = AlertPolicy(dailyCap: 3)
        #expect(!policy.canAlert(placeLastAlerted: nil, alertsToday: 3, lastAlertAt: nil, now: noon, calendar: utc))
        #expect(!policy.canAlert(placeLastAlerted: nil, alertsToday: 4, lastAlertAt: nil, now: noon, calendar: utc))
        #expect(policy.canAlert(placeLastAlerted: nil, alertsToday: 2, lastAlertAt: nil, now: noon, calendar: utc))
    }

    @Test func minimumGap() {
        let policy = AlertPolicy(minimumGap: 30 * 60)
        let tenMinutesAgo = noon.addingTimeInterval(-10 * 60)
        let thirtyOneMinutesAgo = noon.addingTimeInterval(-31 * 60)
        #expect(!policy.canAlert(placeLastAlerted: nil, alertsToday: 0, lastAlertAt: tenMinutesAgo, now: noon, calendar: utc))
        #expect(policy.canAlert(placeLastAlerted: nil, alertsToday: 0, lastAlertAt: thirtyOneMinutesAgo, now: noon, calendar: utc))
    }

    @Test func quietHoursBlock() {
        let policy = AlertPolicy()
        #expect(!policy.canAlert(placeLastAlerted: nil, alertsToday: 0, lastAlertAt: nil, now: at(23), calendar: utc))
        #expect(!policy.canAlert(placeLastAlerted: nil, alertsToday: 0, lastAlertAt: nil, now: at(3), calendar: utc))
        #expect(policy.canAlert(placeLastAlerted: nil, alertsToday: 0, lastAlertAt: nil, now: noon, calendar: utc))
    }

    @Test func sevenDayPerPlaceRepeat() {
        let policy = AlertPolicy()
        let sixDaysAgo = noon.addingTimeInterval(-6 * 86_400)
        let eightDaysAgo = noon.addingTimeInterval(-8 * 86_400)
        #expect(!policy.canAlert(placeLastAlerted: sixDaysAgo, alertsToday: 0, lastAlertAt: nil, now: noon, calendar: utc))
        #expect(policy.canAlert(placeLastAlerted: eightDaysAgo, alertsToday: 0, lastAlertAt: nil, now: noon, calendar: utc))
    }

    // MARK: canFire — the gates every alert kind shares (photo PRD 4.4)

    @Test func canFireAppliesDailyCapAndGap() {
        let policy = AlertPolicy(dailyCap: 3, minimumGap: 30 * 60)
        let tenMinutesAgo = noon.addingTimeInterval(-10 * 60)
        let thirtyOneMinutesAgo = noon.addingTimeInterval(-31 * 60)
        #expect(!policy.canFire(alertsToday: 3, lastAlertAt: nil, now: noon))
        #expect(!policy.canFire(alertsToday: 4, lastAlertAt: nil, now: noon))
        #expect(!policy.canFire(alertsToday: 0, lastAlertAt: tenMinutesAgo, now: noon))
        #expect(policy.canFire(alertsToday: 2, lastAlertAt: thirtyOneMinutesAgo, now: noon))
        #expect(policy.canFire(alertsToday: 0, lastAlertAt: thirtyOneMinutesAgo, now: noon))
    }

    // MARK: canAlertIgnoringQuiet — the night-photo nudge (photo PRD 4.4)

    /// The whole point of a night nudge is that it fires during the hours the
    /// quiet window covers: `canAlert` must not swallow it.
    @Test func nightNudgeFiresDuringQuietHours() {
        let policy = AlertPolicy() // quiet 22:00–08:00
        #expect(!policy.canAlert(placeLastAlerted: nil, alertsToday: 0, lastAlertAt: nil, now: at(23), calendar: utc))
        #expect(policy.canAlertIgnoringQuiet(placeLastAlerted: nil, alertsToday: 0, lastAlertAt: nil, now: at(23)))
        #expect(policy.canAlertIgnoringQuiet(placeLastAlerted: nil, alertsToday: 0, lastAlertAt: nil, now: at(3)))
    }

    /// …but the shared caps still apply (acceptance 7: "the caps hold").
    @Test func nightNudgeStillRespectsCapGapAndSevenDayRepeat() {
        let policy = AlertPolicy()
        let tenMinutesAgo = at(23).addingTimeInterval(-10 * 60)
        let sixDaysAgo = at(23).addingTimeInterval(-6 * 86_400)
        let eightDaysAgo = at(23).addingTimeInterval(-8 * 86_400)
        // Daily cap…
        #expect(!policy.canAlertIgnoringQuiet(placeLastAlerted: nil, alertsToday: 3, lastAlertAt: nil, now: at(23)))
        #expect(!policy.canAlertIgnoringQuiet(placeLastAlerted: nil, alertsToday: 5, lastAlertAt: nil, now: at(23)))
        // …the 30-minute gap…
        #expect(!policy.canAlertIgnoringQuiet(placeLastAlerted: nil, alertsToday: 0, lastAlertAt: tenMinutesAgo, now: at(23)))
        // …and the 7-day per-place repeat all hold.
        #expect(!policy.canAlertIgnoringQuiet(placeLastAlerted: sixDaysAgo, alertsToday: 0, lastAlertAt: nil, now: at(23)))
        #expect(policy.canAlertIgnoringQuiet(placeLastAlerted: eightDaysAgo, alertsToday: 0, lastAlertAt: nil, now: at(23)))
    }
}
