import Foundation
import UserNotifications

/// Bridges `UNUserNotificationCenter` to the app: makes the place-entry
/// banner appear (instead of the default suppress) and routes taps on it —
/// from the banner or the Notification Center — to the place pager (PRD 4.2:
/// "tapping the notification opens that place's question screen").
///
/// Taps are queued, not acted on immediately: when the app is suspended,
/// tapping a notification launches it without a `didReceive` callback, so the
/// pending notifications are collected on launch and handed over the next
/// time the app becomes active.
@MainActor
public final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    /// The user opened a place notification (argument: the place key).
    public var onOpenPlace: ((String) async -> Void)?

    static let categoryID = "TRACKSCOUT_PLACE"

    /// The shared center. A stored property (rather than re-fetching
    /// `current()` per call) so the permission and pending-requests helpers
    /// all address the same instance.
    private let center = UNUserNotificationCenter.current()

    private var pendingPlaceKeys: [String] = []

    public override init() {
        super.init()
        center.delegate = self
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }

    /// Asks for permission to show banners (called from onboarding, PRD 4.2).
    public func requestNotificationAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// The current permission state, for the onboarding status line.
    public func isNotificationAuthorizationGranted() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    /// Collects notifications the user tapped while the app was not running
    /// (a tap on a suspended app does not fire `didReceive`).
    func collectPendingNotifications() async {
        // The SDK has no async `pendingNotifications()` — only the
        // completion-handler variant.
        let pending = await withCheckedContinuation {
            (continuation: CheckedContinuation<[UNNotificationRequest], Never>) in
            center.getPendingNotificationRequests {
                continuation.resume(returning: $0)
            }
        }
        for request in pending {
            appendPlaceKey(from: request.content)
        }
    }

    /// Called when the app becomes active: hands over queued place taps, in
    /// order, to `onOpenPlace`.
    func flushPendingOpenPlaces() async {
        guard !pendingPlaceKeys.isEmpty else { return }
        let keys = pendingPlaceKeys
        pendingPlaceKeys = []
        for key in keys {
            await onOpenPlace?(key)
        }
    }

    // MARK: UNUserNotificationCenterDelegate
    //
    // The UserNotifications SDK has completion-handler delegate methods only
    // (no async variants). The delegate is called on the main thread; the
    // methods are `nonisolated` and hop to the MainActor before touching
    // state.

    /// The banner is the nudge (PRD 1) — present it, with sound, even while
    /// the app is in the foreground.
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        completionHandler()
        Task { @MainActor in
            self.appendPlaceKey(from: content)
        }
    }

    // MARK:

    private func appendPlaceKey(from content: UNNotificationContent) {
        guard let placeKey = content.userInfo["placeKey"] as? String else { return }
        if !pendingPlaceKeys.contains(placeKey) {
            pendingPlaceKeys.append(placeKey)
        }
    }
}
