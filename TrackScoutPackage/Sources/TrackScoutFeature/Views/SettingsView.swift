import CoreLocation
import SwiftUI

/// The Settings screen (PRD 4.5): server URL; sync now / last sync / outbox
/// list (including rejected items); nudge status; alert toggles; map style.
public struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// The URL field edits locally and applies on Save, so a half-typed URL
    /// never becomes the live setting.
    @State private var urlText: String?
    /// The notification permission, as reported by the system (the router's
    /// check is async, so the card snapshots it).
    @State private var notificationsGranted = false

    public init() {}

    public var body: some View {
        @Bindable var settings = appState.settings
        Form {
            syncSection
            nudgeStatusSection
            Section("Server") {
                if settings.demoMode {
                    Label("Running on the built-in demo data — no server.", systemImage: "wand.and.stars")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
                TextField("http://your-server:8765", text: Binding(
                    get: { urlText ?? settings.serverURL },
                    set: { urlText = $0 }
                ))
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.done)
                .onSubmit(saveURL)
                if urlText != nil {
                    Button("Save URL", action: saveURL)
                        .disabled(OnboardingView.usableServerURL(urlText ?? "") == nil)
                }
                Text("Used for syncing questions, answers, and images. Saving a URL leaves demo mode.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !settings.demoMode {
                    Button("Use demo data instead") {
                        settings.demoMode = true
                        urlText = nil
                        Task { await appState.loadDemoData() }
                    }
                }
            }

            Section("Location alerts") {
                Toggle("Alerts", isOn: $settings.alertsEnabled)
                Stepper(
                    "Up to \(settings.alertsPerDay) per day",
                    value: $settings.alertsPerDay,
                    in: 0...5
                )
                Stepper(value: $settings.quietStartHour, in: 0...23) {
                    Label {
                        Text("Quiet from \(settings.quietStartHour):00")
                    } icon: {
                        Image(systemName: "moon")
                    }
                }
                Stepper(value: $settings.quietEndHour, in: 0...23) {
                    Label {
                        Text("until \(settings.quietEndHour):00")
                    } icon: {
                        Image(systemName: "sunrise")
                    }
                }
                Slider(value: $settings.monitorRadiusMeters, in: 25...100, step: 5) {
                    Text("Radius")
                } minimumValueLabel: {
                    Text("25 m")
                        .font(.caption2)
                } maximumValueLabel: {
                    Text("100 m")
                        .font(.caption2)
                }
                Text("\(Int(settings.monitorRadiusMeters)) m")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            photoSection

            Section("Map") {
                Picker("Style", selection: $settings.mapStyle) {
                    ForEach(AppSettings.MapStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("Settings")
        .task {
            await refreshNotifications()
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the system Settings screen — re-check.
            guard phase == .active else { return }
            Task { await refreshNotifications() }
        }
    }

    // MARK: Nudge status (field diagnostics)

    /// The PRD 4.2 alert gates, surfaced as status: when a nudge does not
    /// arrive, this shows which gate stopped it — without a cable.
    private var nudgeStatusSection: some View {
        Section("Nudge status") {
            locationRow
            notificationsRow
            monitoredRow
            alertsTodayRow
            lastSyncRow
            if !appState.location.allowsBackgroundAlerts || !notificationsGranted {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                }
            }
            Text("Nudges fire when you enter the \(Int(appState.settings.monitorRadiusMeters)) m circle of one of the 20 nearest places with open questions, outside quiet hours, up to \(appState.settings.alertsPerDay) per day.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var locationRow: some View {
        let authorization = appState.location.authorization
        return HStack {
            Text("Location")
            Spacer()
            Text(Self.locationStatusText(authorization))
                .foregroundStyle(Self.locationStatusColor(authorization))
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private static func locationStatusText(_ authorization: CLAuthorizationStatus) -> String {
        switch authorization {
        case .authorizedAlways:
            return "Always — background nudges on"
        case .authorizedWhenInUse:
            return "While using — background nudges off"
        case .notDetermined:
            return "Not asked yet"
        case .denied, .restricted:
            return "Off"
        @unknown default:
            // The Swift overlay omits the provisional status (ObjC raw
            // value 5); it would limit background delivery.
            return authorization.rawValue == 5 ? "Provisional — nudges may be limited" : "Unknown"
        }
    }

    private static func locationStatusColor(_ authorization: CLAuthorizationStatus) -> Color {
        switch authorization {
        case .authorizedAlways:
            return .green
        case .denied, .restricted:
            return .red
        default:
            return .orange
        }
    }

    private var notificationsRow: some View {
        HStack {
            Text("Notifications")
            Spacer()
            Text(notificationsGranted ? "On" : "Not allowed")
                .foregroundStyle(notificationsGranted ? Color.green : Color.red)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private var monitoredRow: some View {
        let monitor = appState.placeMonitor
        return HStack {
            Text("Monitored places")
            Spacer()
            if monitor.isRunning {
                Text("\(monitor.monitoredCount) of 20")
                    .foregroundStyle(monitor.monitoredCount == 0 ? Color.orange : Color.green)
            } else {
                Text("monitor not running")
                    .foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private var alertsTodayRow: some View {
        let scheduler = appState.alertScheduler
        return HStack {
            Text("Alerts today")
            Spacer()
            if let last = scheduler.lastAlertAt {
                Text("\(scheduler.alertsToday) of \(appState.settings.alertsPerDay) — last \(last, format: .relative(presentation: .named))")
            } else {
                Text("\(scheduler.alertsToday) of \(appState.settings.alertsPerDay)")
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private var lastSyncRow: some View {
        HStack {
            Text("Last sync")
            Spacer()
            if let last = appState.syncStatus.lastSync {
                Text(last, format: .relative(presentation: .named))
            } else if let error = appState.syncStatus.lastError {
                Text(error)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else {
                Text("never")
                    .foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private func refreshNotifications() async {
        notificationsGranted = await appState.notificationRouter.isNotificationAuthorizationGranted()
    }

    // MARK: Sync + outbox

    private var syncSection: some View {
        Section("Sync") {
            Button {
                Task {
                    await appState.sync(auto: false) // 15 s manual timeout
                }
            } label: {
                HStack {
                    if appState.isSyncing {
                        ProgressView()
                    }
                    Text("Sync now")
                    Spacer()
                    if let last = appState.syncStatus.lastSync {
                        Text(last, format: .relative(presentation: .named))
                            .foregroundStyle(.secondary)
                    } else if !appState.isSyncing {
                        Text("never")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(appState.isSyncing)

            if let error = appState.syncStatus.lastError {
                Label(error, systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
            }

            if !appState.outbox.isEmpty {
                outboxList
            }
        }
    }

    @ViewBuilder
    private var outboxList: some View {
        ForEach(appState.outbox) { item in
            OutboxRow(
                building: appState.question(item.questionID)?.building ?? item.questionID,
                item: item
            ) {
                appState.deleteOutboxItem(item)
            }
        }
        if appState.outbox.contains(where: { $0.state == .pending }) {
            Text("Pending answers go up on the next sync. Rejected ones are kept here until you delete them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Photos (photo PRD 4.5)

    /// The photo outbox: count + size, the upload/storage nudges toggles,
    /// and the photo rows with thumbnails and swipe-to-delete.
    private var photoSection: some View {
        @Bindable var settings = appState.settings
        let items = appState.photoOutbox.sorted { $0.createdAt > $1.createdAt }
        return Section("Photos") {
            LabeledContent("Photo outbox") {
                Text(Self.photoOutboxSummary(
                    count: items.count,
                    bytes: appState.photoStore.totalSizeBytes()
                ))
                .foregroundStyle(.secondary)
            }
            Toggle("Upload over Wi-Fi only", isOn: $settings.photosWiFiOnly)
            Toggle("Also save to Photos", isOn: $settings.saveToPhotos)
            Toggle("Night photo nudges", isOn: $settings.nightAlertsEnabled)
            Toggle("Show “photo wanted” badge", isOn: $settings.showPhotoWanted)

            ForEach(items) { item in
                PhotoOutboxRow(item: item) {
                    appState.deletePhoto(item)
                }
            }

            if items.isEmpty {
                Text("Photos you take appear here, upload over Wi-Fi, and are kept for 7 days after uploading.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func photoOutboxSummary(count: Int, bytes: Int64) -> String {
        guard count > 0 else { return "empty" }
        return "\(count) · \(bytes.formatted(.byteCount(style: .file)))"
    }

    // MARK: URL

    private func saveURL() {
        @Bindable var settings = appState.settings
        guard let text = urlText, let usable = OnboardingView.usableServerURL(text) else { return }
        settings.serverURL = usable
        // A real URL takes over from the demo data; the next sync uses it.
        settings.demoMode = false
        urlText = nil
    }
}

/// One outbox row: where the answer was meant for, what was sent, and its
/// state (pending or rejected + reason). Deletable (PRD 4.5).
struct OutboxRow: View {
    let building: String
    let item: OutboxItem
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: item.state == .pending ? "clock" : "xmark.octagon")
                    .foregroundStyle(item.state == .pending ? Color.secondary : Color.red)
                Text(building)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(item.state == .pending ? "pending" : "rejected")
                    .font(.caption.bold())
                    .foregroundStyle(item.state == .pending ? Color.secondary : Color.red)
            }
            Text(item.answer)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let reason = item.rejectReason, !reason.isEmpty {
                Text("Reason: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One photo outbox row (photo PRD 4.5): thumbnail, where it was, kind +
/// light, and its state. Rejected photos show the server's reason and stay
/// until the user swipes them away; uploaded ones after 7 days.
struct PhotoOutboxRow: View {
    let item: PhotoOutboxItem
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            LocalPhotoThumbnail(item: item)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.building.isEmpty ? (item.placeKey ?? "No place") : item.building)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(item.kindRaw) · \(item.lightRaw) · \(item.taken, format: .dateTime.day().month())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let reason = item.rejectReason, !reason.isEmpty {
                    Text("Reason: \(reason)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(stateLabel)
                .font(.caption.bold())
                .foregroundStyle(stateColor)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var stateLabel: String {
        switch item.state {
        case .pending: return "pending"
        case .sent: return "uploaded"
        case .rejected: return "rejected"
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .pending: return .secondary
        case .sent: return .green
        case .rejected: return .red
        }
    }
}
