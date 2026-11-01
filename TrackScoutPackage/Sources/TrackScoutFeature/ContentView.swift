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
