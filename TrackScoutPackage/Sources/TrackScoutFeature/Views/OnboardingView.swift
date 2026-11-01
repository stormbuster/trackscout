import SwiftUI
import UserNotifications

/// The first-run screen (PRD 4.2): asks for the server URL (or the bundled
/// demo data instead), explains why TrackScout wants Always location
/// (background region alerts) and lets the user choose, plus the notification
/// permission. Without Always, alerts simply stay off — everything else keeps
/// working.
public struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL

    @State private var notificationsGranted = false
    /// The URL field edits locally and applies on finish, so a half-typed URL
    /// never becomes the live setting.
    @State private var serverURL = ""

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                serverCard
                locationCard
                notificationCard
            }
            .padding()
        }
        .navigationTitle("Welcome")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Skip") {
                    finish()
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                finish()
            } label: {
                Text("Get started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canGetStarted)
            .padding()
            .background(.bar)
        }
        .task {
            serverURL = appState.settings.serverURL
            notificationsGranted = await appState.notificationRouter.isNotificationAuthorizationGranted()
        }
        .onChange(of: appState.location.authorization) {
            Task {
                notificationsGranted = await appState.notificationRouter.isNotificationAuthorizationGranted()
            }
        }
    }

    /// "Get started" needs somewhere to sync: a usable server URL, or the
    /// bundled demo data. Skipping without either falls back to demo data.
    private var canGetStarted: Bool {
        appState.settings.demoMode || Self.usableServerURL(serverURL) != nil
    }

    // MARK: Cards

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Server", systemImage: "network")
                .font(.headline)
            Text("Enter the address of your project’s server — for example the reference server on your home Wi-Fi — or use the built-in sample data instead.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("http://your-server:8765", text: $serverURL)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
            if appState.settings.demoMode {
                Label("Demo data selected — no server needed.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            } else {
                Button {
                    appState.settings.demoMode = true
                } label: {
                    Label("Use demo data", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "building.2.crop.circle")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
            Text("TrackScout")
                .font(.largeTitle.bold())
            Text("You get a nudge when you’re near a building with open questions — browse the nearby ones, and answer them while you’re standing there.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var locationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Location", systemImage: "location.viewfinder")
                .font(.headline)
            statusText
            buttons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var statusText: some View {
        switch appState.location.authorization {
        case .notDetermined:
            Text("TrackScout needs location to know which places are nearby. “Allow Always” lets it nudge you when you enter a place even if the app is closed; “While using” limits nudges to the open app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .denied, .restricted:
            Text("Location is disabled for TrackScout. Re-enable it in Settings to use the app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .authorizedWhenInUse:
            Text("Nudges only work while the app is open. Choose “Allow Always” for background nudges.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .authorizedAlways:
            Label("Location: always. Background nudges are on.", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
        @unknown default:
            Text("")
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch appState.location.authorization {
        case .notDetermined:
            HStack(spacing: 10) {
                Button {
                    appState.location.requestAuthorization(always: true)
                } label: {
                    Text("Allow always")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    appState.location.requestAuthorization(always: false)
                } label: {
                    Text("While using")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        case .denied, .restricted:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Label("Open Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        case .authorizedWhenInUse:
            Button {
                appState.location.requestAuthorization(always: true)
            } label: {
                Label("Allow always for background nudges", systemImage: "bell")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        case .authorizedAlways:
            EmptyView()
        @unknown default:
            EmptyView()
        }
    }

    private var notificationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Place nudges", systemImage: "bell.badge")
                .font(.headline)
            Text("Notifications are the nudge. Time-sensitive, so they break through Focus while you walk.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if notificationsGranted {
                Label("Notifications on.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 10) {
                    Button {
                        Task {
                            notificationsGranted = await appState.notificationRouter.requestNotificationAuthorization()
                        }
                    } label: {
                        Text("Allow notifications")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Button {
                            openURL(url)
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Open notification settings")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK:

    /// A server URL the app can actually use: non-empty, http(s), with a host.
    static func usableServerURL(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            ["http", "https"].contains(url.scheme?.lowercased()),
            url.host() != nil
        else {
            return nil
        }
        return trimmed
    }

    private func finish() {
        let settings = appState.settings
        if let url = Self.usableServerURL(serverURL) {
            settings.serverURL = url
            settings.demoMode = false
        } else {
            // No usable URL: run on the bundled sample so the app works.
            settings.demoMode = true
        }
        settings.onboarded = true
        appState.popToMain()
        // First real content: the demo load is offline, a URL triggers a sync.
        if settings.demoMode {
            Task { await appState.loadDemoData() }
        } else {
            Task { await appState.sync(auto: true) }
        }
    }
}
