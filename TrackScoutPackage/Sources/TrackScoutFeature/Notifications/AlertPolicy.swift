import Foundation

/// Pure alert gating (PRD 4.2). Kept dependency-free so every rule is
/// unit-testable: daily cap, minimum gap, quiet hours, 7-day per-place repeat.
public struct AlertPolicy: Sendable {
    public var dailyCap: Int = 3
    public var minimumGap: TimeInterval = 30 * 60
    public var quietStartHour: Int = 22 // inclusive
    public var quietEndHour: Int = 8 // exclusive
    public var placeRepeatWindow: TimeInterval = 7 * 24 * 3600

    public init(
        dailyCap: Int = 3,
        minimumGap: TimeInterval = 30 * 60,
        quietStartHour: Int = 22,
        quietEndHour: Int = 8,
        placeRepeatWindow: TimeInterval = 7 * 24 * 3600
    ) {
        self.dailyCap = dailyCap
        self.minimumGap = minimumGap
        self.quietStartHour = quietStartHour
        self.quietEndHour = quietEndHour
        self.placeRepeatWindow = placeRepeatWindow
    }

    /// The gates every alert kind shares (photo PRD 4.4: night nudges use
    /// "the same per-day cap and 30-minute gap as answer alerts"): the daily
    /// cap and the minimum gap between any two alerts.
    public func canFire(
        alertsToday: Int,
        lastAlertAt: Date?,
        now: Date
    ) -> Bool {
        if alertsToday >= dailyCap { return false }
        if let last = lastAlertAt, now.timeIntervalSince(last) < minimumGap { return false }
        return true
    }

    /// Whether a place-entry (answer) alert may fire at `now`.
    /// - Parameters:
    ///   - placeLastAlerted: when this place was last alerted (nil = never).
    ///   - alertsToday: how many alerts were sent today.
    ///   - lastAlertAt: when any alert was last sent (nil = never).
    public func canAlert(
        placeLastAlerted: Date?,
        alertsToday: Int,
        lastAlertAt: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard canFire(alertsToday: alertsToday, lastAlertAt: lastAlertAt, now: now) else { return false }
        if isQuiet(now, calendar: calendar) { return false }
        if let placeLast = placeLastAlerted, now.timeIntervalSince(placeLast) < placeRepeatWindow { return false }
        return true
    }

    /// Whether a night-photo nudge may fire at `now` (photo PRD 4.4): the
    /// shared daily cap and gap, and the 7-day repeat — but *without* quiet
    /// hours. Night nudges fire at exactly the hours quiet hours cover (the
    /// night window is their own gate, enforced by `Sun.isNightWindow`);
    /// suppressing them here would suppress all of them.
    public func canAlertIgnoringQuiet(
        placeLastAlerted: Date?,
        alertsToday: Int,
        lastAlertAt: Date?,
        now: Date
    ) -> Bool {
        guard canFire(alertsToday: alertsToday, lastAlertAt: lastAlertAt, now: now) else { return false }
        if let placeLast = placeLastAlerted, now.timeIntervalSince(placeLast) < placeRepeatWindow { return false }
        return true
    }

    /// Whether `date` falls inside the quiet window. The window may cross
    /// midnight (22:00–08:00); start == end means "no quiet hours".
    public func isQuiet(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        let start = quietStartHour
        let end = quietEndHour
        if start == end { return false }
        if start < end {
            return hour >= start && hour < end
        }
        // Wraps midnight: 22:00–08:00 means 22, 23, 0…7.
        return hour >= start || hour < end
    }
}
