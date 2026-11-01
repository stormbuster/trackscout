import Foundation
import SwiftData
import UserNotifications

/// Decides — and sends — place-entry notifications (PRD 4.2).
///
/// Every rule from the PRD lives here, evaluated in one place, against one
/// `now`: the daily cap, the minimum gap between alerts, quiet hours, and
/// the 7-day per-place repeat window. The pure logic is `AlertPolicy`
/// (unit-tested); this class owns the state that feeds it (the daily
/// counter, the last-alert time, the per-place records) and the actual
/// `UNNotification` delivery.
@MainActor
@Observable
public final class AlertScheduler {
    /// How many alerts were sent on the current day (the cap counter).
    public private(set) var alertsToday = 0
    /// When the last alert of any kind went out (the gap timer).
    public private(set) var lastAlertAt: Date?

    private let context: ModelContext
    private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let center: UNUserNotificationCenter

    private enum Keys {
        static let dayStamp = "alerts.dayStamp" // "2026-10-30"
        static let count = "alerts.sentByDay"
        static let lastAt = "alerts.lastAt"
    }

    public init(context: ModelContext, settings: AppSettings, defaults: UserDefaults = .standard) {
        self.context = context
        self.settings = settings
        self.defaults = defaults
        self.center = UNUserNotificationCenter.current()
        rollOverDayIfNeeded(now: .now)
        self.alertsToday = defaults.integer(forKey: Keys.count)
        self.lastAlertAt = defaults.object(forKey: Keys.lastAt) as? Date
    }

    /// A monitored place was entered (`PlaceMonitor.onEntry`). Applies all
    /// gating; sends a time-sensitive notification when it passes.
    public func handleEntry(placeKey: String) async {
        guard settings.alertsEnabled else { return }
        let now = Date()
        rollOverDayIfNeeded(now: now)

        let policy = AlertPolicy(
            dailyCap: settings.alertsPerDay,
            quietStartHour: settings.quietStartHour,
            quietEndHour: settings.quietEndHour
        )
        let alertsToday = defaults.integer(forKey: Keys.count)
        let lastAlertAt = defaults.object(forKey: Keys.lastAt) as? Date
        let placeLast = fetchPlaceAlertRecord(placeKey)?.lastAlertedAt

        guard policy.canAlert(
            placeLastAlerted: placeLast,
            alertsToday: alertsToday,
            lastAlertAt: lastAlertAt,
            now: now
        ) else { return }

        // The body needs the live open count — the monitor entry can arrive
        // right after the place's last question was answered, in which case
        // there is nothing left to nudge about.
        // The `#Predicate` macro cannot evaluate the enum case itself, so
        // the raw value is captured as a plain constant first.
        let pendingRaw = OutboxState.pending.rawValue
        let pendingItems = (try? context.fetch(FetchDescriptor<OutboxItem>(
            predicate: #Predicate { $0.stateRaw == pendingRaw }
        ))) ?? []
        let pending = Set(pendingItems.map(\.questionID))
        guard let place = fetchPlace(placeKey) else { return }
        let open = fetchQuestions(in: place).filter { !$0.isAnswered(outboxQuestionIDs: pending) }
        guard !open.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = place.building
        content.body = "\(open.count) open question\(open.count == 1 ? "" : "s") here: \(Self.truncate(open.first?.text ?? "", to: 60))"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = NotificationRouter.categoryID
        content.userInfo["placeKey"] = placeKey
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            // Presentation can fail (e.g. the user disabled notifications
            // mid-flight). Do not record it: the gates should re-fire next
            // time.
            return
        }

        defaults.set(alertsToday + 1, forKey: Keys.count)
        defaults.set(now, forKey: Keys.lastAt)
        upsertPlaceAlertRecord(placeKey, at: now)
        try? context.save()
        self.alertsToday = alertsToday + 1
        self.lastAlertAt = now
    }

    /// A monitored place was entered (photo PRD 4.4). A place that still
    /// lacks the night photo one of its questions wants is nudged — but only
    /// inside the night window (`Sun.isNightWindow`: sunset + 30 → 23:30,
    /// sun below −6°), *outside* quiet hours, under the shared daily cap and
    /// 30-min gap, and at most once per place *and light* per 7 days (the
    /// record is keyed `"<placeKey>|night"`, so it never collides with the
    /// answer-alert record of the same place).
    public func handleNightNudge(placeKey: String) async {
        guard settings.alertsEnabled, settings.nightAlertsEnabled else { return }
        let now = Date()
        rollOverDayIfNeeded(now: now)
        guard let place = fetchPlace(placeKey) else { return }

        // The place still needs a night photo: a question wants night/both
        // and no night photo exists for it (local or server). This is
        // independent of the answer state — a question answered in text can
        // still lack its wanted night photo, and it should still be nudged.
        guard fetchQuestions(in: place).contains(where: { question in
            guard let wanted = question.photoWanted,
                  wanted == .night || wanted == .both
            else { return false }
            return !Set(question.photoLights).contains(LightKind.night.rawValue)
        }) else { return }

        // The window (photo PRD 4.4; project-overridable via trackscout.json),
        // evaluated at the place's position.
        guard Sun.isNightWindow(
            time: now,
            lat: place.lat,
            lon: place.lon,
            startOffsetMinutes: settings.nightWindowStartOffsetMinutes,
            endHour: settings.nightWindowEndHour
        ) else { return }

        // The shared gates, minus quiet hours (see `canAlertIgnoringQuiet`).
        let policy = AlertPolicy(
            dailyCap: settings.alertsPerDay,
            quietStartHour: settings.quietStartHour,
            quietEndHour: settings.quietEndHour
        )
        let alertsToday = defaults.integer(forKey: Keys.count)
        let lastAlertAt = defaults.object(forKey: Keys.lastAt) as? Date
        let recordKey = placeKey + "|" + LightKind.night.rawValue
        let placeLast = fetchPlaceAlertRecord(recordKey)?.lastAlertedAt
        guard policy.canAlertIgnoringQuiet(
            placeLastAlerted: placeLast,
            alertsToday: alertsToday,
            lastAlertAt: lastAlertAt,
            now: now
        ) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Night photo wanted"
        content.body = "\(place.building): is the neon lit?"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = NotificationRouter.categoryID
        content.userInfo["placeKey"] = placeKey
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            // As with entry alerts: do not record a failed presentation.
            return
        }

        defaults.set(alertsToday + 1, forKey: Keys.count)
        defaults.set(now, forKey: Keys.lastAt)
        upsertPlaceAlertRecord(recordKey, at: now)
        try? context.save()
        self.alertsToday = alertsToday + 1
        self.lastAlertAt = now
    }

    /// "N open questions here: <first, truncated>" — keep the body short
    /// enough for the banner (PRD 4.2: first question, truncated).
    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    // MARK: State

    private func rollOverDayIfNeeded(now: Date) {
        let stamp = Self.stamp(for: now)
        guard defaults.string(forKey: Keys.dayStamp) != stamp else { return }
        defaults.set(stamp, forKey: Keys.dayStamp)
        defaults.set(0, forKey: Keys.count)
    }

    static func stamp(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func fetchPlace(_ key: String) -> Place? {
        let descriptor = FetchDescriptor<Place>(predicate: #Predicate { $0.key == key })
        return try? context.fetch(descriptor).first
    }

    private func fetchQuestions(in place: Place) -> [Question] {
        let ids = place.questionIDs
        let descriptor = FetchDescriptor<Question>(predicate: #Predicate { ids.contains($0.id) })
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchPlaceAlertRecord(_ placeKey: String) -> PlaceAlertRecord? {
        let descriptor = FetchDescriptor<PlaceAlertRecord>(predicate: #Predicate { $0.placeKey == placeKey })
        return try? context.fetch(descriptor).first
    }

    private func upsertPlaceAlertRecord(_ placeKey: String, at date: Date) {
        if let record = fetchPlaceAlertRecord(placeKey) {
            record.lastAlertedAt = date
        } else {
            context.insert(PlaceAlertRecord(placeKey: placeKey, lastAlertedAt: date))
        }
    }
}
