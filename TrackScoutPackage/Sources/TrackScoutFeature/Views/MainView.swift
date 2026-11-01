import SwiftUI

/// The main screen: the Nearby / All tabs (PRD 4.3). Always the root of the
/// navigation stack.
public struct MainView: View {
    enum Tab: Hashable {
        case nearby
        case capture
        case all
    }

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
    }
}
