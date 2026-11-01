import SwiftUI
import SwiftData
import TrackScoutFeature

/// The application shell: creates the `ModelContainer` and the single
/// `AppState`, wires scene phase to it, and hands the state to the feature's
/// `ContentView`. All behaviour lives in `TrackScoutFeature`; this file is
/// the glue (and the home of the SwiftData container, which the shell must
/// own so the scene is bound to it).
@main
@MainActor
struct TrackScoutApp: App {
    @State private var modelContainer: ModelContainer
    @State private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: Question.self, Place.self, OutboxItem.self, CachedImage.self, PlaceAlertRecord.self,
                     PhotoOutboxItem.self, OwnerPhoto.self
            )
        } catch {
            fatalError("Failed to create the SwiftData container: \(error)")
        }
        _modelContainer = State(initialValue: container)
        _appState = State(initialValue: AppState(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .modelContainer(modelContainer)
                .task {
                    await appState.appDidLaunch()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    appState.scenePhaseChanged(newPhase)
                }
        }
    }
}
