import CoreLocation
import SwiftUI
import UIKit

/// The Capture tab (photo PRD 4.2): the subject place (the nearest within
/// 60 m, prefilled; a picker of the others within 150 m, plus "Other
/// building"), the light chip (auto from the sun, tappable to override),
/// the kind picker, and the three big buttons — Storefront set, Single
/// photo, Choose from Photos.
public struct CaptureView: View {
    @Environment(AppState.self) private var appState

    /// `nil` = "Other building" (the free-text name below).
    @State private var selectedPlaceKey: String?
    @State private var otherBuilding = ""
    /// `nil` = auto from the sun; a value = the user's override.
    @State private var lightOverride: LightKind?
    @State private var kind: PhotoKind = .storefront
    @State private var hasPrefilled = false

    @State private var showingStorefrontSet = false
    @State private var showingCamera = false
    @State private var showingImporter = false

    public init() {}

    // MARK: Subject place

    /// The places the picker lists: within 150 m, nearest first (photo
    /// PRD 4.2). Empty until the first fix.
    private var pickerPlaces: [Place] {
        guard let center = appState.location.lastLocation?.coordinate else { return [] }
        return appState.places
            .compactMap { place -> (Place, Double)? in
                guard let placeCoordinate = Geo.coordinate(forKey: place.key) else { return nil }
                return (place, Geo.distance(from: center, to: placeCoordinate))
            }
            .filter { $0.1 <= 150 }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private var selectedPlace: Place? {
        guard let key = selectedPlaceKey else { return nil }
        return appState.places.first { $0.key == key }
    }

    /// The building name the meta records: the chosen place's, else the
    /// free text, else empty.
    private var building: String {
        selectedPlace?.building ?? otherBuilding
    }

    /// Prefills the subject with the nearest place within 60 m (photo PRD
    /// 4.2) — once, and only if the user has not chosen anything yet.
    private func prefillIfNeeded() {
        guard !hasPrefilled, selectedPlaceKey == nil else {
            hasPrefilled = true
            return
        }
        hasPrefilled = true
        guard let center = appState.location.lastLocation?.coordinate else { return }
        let nearest = pickerPlaces.first { place in
            guard let placeCoordinate = Geo.coordinate(forKey: place.key) else { return false }
            return Geo.distance(from: center, to: placeCoordinate) <= 60
        }
        selectedPlaceKey = nearest?.key // `nil` = no place within 60 m → blank subject
    }

    // MARK: Body

    public var body: some View {
        NavigationStack {
            Form {
                subjectSection
                actionsSection
                outboxSection
            }
            .navigationTitle("Capture")
            .task { prefillIfNeeded() }
            .fullScreenCover(isPresented: $showingStorefrontSet) {
                StorefrontSetView(
                    placeKey: selectedPlaceKey,
                    building: building,
                    lightOverride: lightOverride
                )
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraView(
                    title: "Single photo",
                    initialKind: kind,
                    onPhoto: { data, chosenKind, chosenLight in
                        try await appState.capturePhoto(
                            placeKey: selectedPlaceKey,
                            building: building,
                            kind: chosenKind,
                            lightOverride: chosenLight
                        )
                    }
                )
            }
            .fullScreenCover(isPresented: $showingImporter) {
                PhotoImportView(
                    questionID: nil,
                    placeKey: selectedPlaceKey,
                    building: building,
                    kind: kind,
                    lightOverride: lightOverride
                )
            }
        }
    }

    // MARK: Sections

    private var subjectSection: some View {
        Section("Subject") {
            Picker("Place", selection: Binding(
                get: { selectedPlaceKey ?? Self.otherBuildingKey },
                set: { selectedPlaceKey = ($0 == Self.otherBuildingKey) ? nil : $0 }
            )) {
                ForEach(pickerPlaces) { place in
                    Text(place.building).tag(place.key)
                }
                Text("Other building").tag(Self.otherBuildingKey)
            }
            if selectedPlaceKey == nil {
                TextField("Building name", text: $otherBuilding)
            }
        }
    }

    /// The sentinel picker tag for "Other building" (a place key is
    /// `"lat,lon"`, so this can never collide).
    private static let otherBuildingKey = "other-building"

    private var actionsSection: some View {
        Section {
            bigButton(
                title: "Storefront set",
                systemImage: "building.2",
                action: { showingStorefrontSet = true }
            )
            bigButton(
                title: "Single photo",
                systemImage: "camera",
                action: { showingCamera = true }
            )
            bigButton(
                title: "Choose from Photos",
                systemImage: "photo.on.rectangle.angled",
                action: { showingImporter = true }
            )

            lightRow
            kindRow
        }
    }

    private func bigButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the \(title.lowercased())")
    }

    /// The light chip (photo PRD 4.2): auto from the sun, tappable to
    /// override. The camera re-evaluates the auto light itself; this is the
    /// pre-shot choice.
    private var lightRow: some View {
        let auto = autoLight
        return LabeledContent("Light") {
            Menu {
                Button("Auto") { lightOverride = nil }
                Button("Day") { lightOverride = .day }
                Button("Dusk") { lightOverride = .dusk }
                Button("Night") { lightOverride = .night }
            } label: {
                let effective = lightOverride ?? auto
                return Label(
                    lightOverride == nil ? effective.label : "\(effective.label) (set)",
                    systemImage: effective.symbol
                )
            }
        }
    }

    private var kindRow: some View {
        Picker("Kind", selection: $kind) {
            ForEach(PhotoKind.allCases) { candidate in
                Text(candidate.label).tag(candidate)
            }
        }
    }

    /// The current sun at the last fix (photo PRD 5.1); `.day` before the
    /// first fix so the chip always shows something.
    private var autoLight: LightKind {
        guard let coordinate = appState.location.lastLocation?.coordinate else { return .day }
        return Sun.kind(time: .now, lat: coordinate.latitude, lon: coordinate.longitude)
    }

    /// The photo outbox state (photo PRD 4.5): while uploads are Wi-Fi-only
    /// and photos are pending, say so.
    @ViewBuilder
    private var outboxSection: some View {
        let pendingCount = appState.photoOutbox.filter { $0.state == .pending }.count
        if appState.settings.photosWiFiOnly, pendingCount > 0 {
            Section {
                Label(
                    pendingCount == 1
                        ? "1 photo waiting for Wi-Fi"
                        : "\(pendingCount) photos waiting for Wi-Fi",
                    systemImage: "wifi.exclamationmark"
                )
                .foregroundStyle(.orange)
            }
        }
    }
}
