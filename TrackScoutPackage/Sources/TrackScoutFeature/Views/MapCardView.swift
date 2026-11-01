import CoreLocation
import MapKit
import SwiftUI

/// The question's 3D map card (PRD 4.4): realistic-elevation imagery (or
/// hybrid, toggle in Settings), centred on the question point at ~60° pitch
/// and ~250 m, with a marker and the user's position. No Look Around.
public struct MapCardView: View {
    let coordinate: CLLocationCoordinate2D
    let style: AppSettings.MapStyle
    let height: CGFloat

    @State private var camera: MapCameraPosition

    public init(
        coordinate: CLLocationCoordinate2D,
        style: AppSettings.MapStyle = .imagery,
        height: CGFloat = 260
    ) {
        self.coordinate = coordinate
        self.style = style
        self.height = height
        let camera = MapCamera(centerCoordinate: coordinate, distance: 250, heading: 0, pitch: 60)
        _camera = State(initialValue: .camera(camera))
    }

    public var body: some View {
        styledMap
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var baseMap: some View {
        Map(position: $camera) {
            Annotation("Question location", coordinate: coordinate) {
                Image(systemName: "mappin.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
            }
            UserAnnotation()
        }
    }

    /// `.imagery` and `.hybrid` are different types, so the style toggle
    /// branches the view rather than picking one of a shared type.
    @ViewBuilder
    private var styledMap: some View {
        switch style {
        case .imagery:
            baseMap.mapStyle(.imagery(elevation: .realistic))
        case .hybrid:
            baseMap.mapStyle(.hybrid(elevation: .realistic))
        }
    }
}
