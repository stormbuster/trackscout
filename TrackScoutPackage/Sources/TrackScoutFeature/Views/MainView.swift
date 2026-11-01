import SwiftUI

/// The main screen: the Nearby / Capture / All tabs (PRD 4.3). Always the
/// root of the navigation stack.
public struct MainView: View {
    enum Tab: Hashable {
        case nearby
        case capture
        case all
    }

    @Environment(AppState.self) private var appState
    @State private var tab: Tab = .nearby

    public init() {}

    public var body: some View {
        TabView(selection: $tab) {
            NearbyView()
                .tabItem {
                    Label("Nearby", systemImage: "location.viewfinder")
                }
                .tag(Tab.nearby)

            CaptureView()
                .tabItem {
                    Label("Capture", systemImage: "camera")
                }
                .tag(Tab.capture)

            AllPlacesView()
                .tabItem {
                    Label("All", systemImage: "list.bullet")
                }
                .tag(Tab.all)
        }
        // The "demo data / last sync / pending answers" status is a plain
        // strip above the tab content, not a nav-bar item: when a TabView
        // sits at the root of a NavigationStack, the root tabs render no
        // toolbar at all (title or principal), so a toolbar here would
        // never show. The strip disappears with the root when a pager is
        // pushed, which is where it is not needed.
        .safeAreaInset(edge: .top) {
            if hasStatus {
                syncStatus
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }

    private var hasStatus: Bool {
        appState.settings.demoMode
            || appState.isSyncing
            || appState.syncStatus.lastSync != nil
            || appState.syncStatus.lastError != nil
            || appState.syncStatus.outboxCount > 0
    }

    private var syncStatus: some View {
        HStack(spacing: 6) {
            if appState.settings.demoMode {
                Text("demo data")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            if appState.isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else if let last = appState.syncStatus.lastSync {
                Image(systemName: "checkmark.icloud")
                    .foregroundStyle(.secondary)
                Text(last, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let error = appState.syncStatus.lastError {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if appState.syncStatus.outboxCount > 0 {
                Text("\(appState.syncStatus.outboxCount)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal)
        .frame(height: 28)
        .accessibilityElement(children: .combine)
    }
}
