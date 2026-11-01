import SwiftUI
import SwiftData

/// The app's single navigation entry point.
///
/// The `NavigationStack` is driven by `AppState.path`, so user navigation,
/// notification deep links, and onboarding all share one stack:
///
/// - the root is always `MainView` (the Nearby / All tabs);
/// - `.place` pushes the question pager for one place;
/// - `.settings` and `.onboarding` push their full screens.
public struct ContentView: View {
    @Bindable var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        NavigationStack(path: $appState.path) {
            MainView()
                .navigationDestination(for: AppState.Route.self) { route in
                    destination(for: route)
                }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                syncStatusHeader
            }
        }
        .environment(appState)
    }

    @ViewBuilder
    private func destination(for route: AppState.Route) -> some View {
        switch route {
        case .main:
            MainView() // never pushed; the root already is
        case .place(let key):
            QuestionPagerView(placeKey: key)
        case .settings:
            SettingsView()
        case .onboarding:
            OnboardingView()
        }
    }

    /// Small "last sync / pending answers" status in the nav bar.
    private var syncStatusHeader: some View {
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
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ContentView(
        appState: AppState(
            context: try! ModelContainer(
                for: Question.self, Place.self, OutboxItem.self, CachedImage.self, PlaceAlertRecord.self,
                     PhotoOutboxItem.self, OwnerPhoto.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            ).mainContext
        )
    )
}
