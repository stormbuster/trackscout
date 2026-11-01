import CoreLocation
import SwiftUI

/// The "Nearby" tab (PRD 4.3): open places grouped into distance bands
/// (≤10 m, 10–50 m, 50–100 m, 100–500 m, 0.5–1 km, 1 km+), the closest band
/// always on top, re-sorted on every location update as the user walks.
/// Within a band the order is quantized to 5 m so the list does not flap
/// with GPS jitter. Each row has a compass arrow, distance, open count, and
/// thumbnail. A "show answered" toggle brings back fully-answered places.
public struct NearbyView: View {
    @Environment(AppState.self) private var appState

    /// A plain snapshot of one row, so list diffs and animations are stable
    /// even when the underlying `@Model` objects are replaced on sync.
    struct Row: Identifiable, Equatable {
        let key: String
        let building: String
        let lat: Double
        let lon: Double
        let distance: Double? // nil until the first fix
        let bearing: Double?
        let openCount: Int
        let total: Int
        let firstImageSrc: String?
        /// "photo wanted" (photo PRD 4.2): a photo is still wanted and the
        /// Settings toggle is on.
        let photoWanted: Bool

        var id: String { key }
    }

    @State private var rows: [Row] = []

    /// One distance band's worth of rows, in display order.
    struct BandSection: Identifiable {
        let band: Int
        let title: String
        var rows: [Row]

        var id: Int { band }
    }

    public init() {}

    public var body: some View {
        let sections = bandSections
        List {
            progressSection

            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        Button {
                            appState.openPlace(row.key)
                        } label: {
                            NearbyRow(row: row, heading: appState.location.heading)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    // The first band keeps the classic "Places" header with
                    // the toggle; the rest are labelled by their radius.
                    if section.id == sections.first?.id {
                        HStack {
                            Text("Places")
                            Spacer()
                            ShowAnsweredToggle()
                        }
                    } else {
                        Text(section.title)
                    }
                }
            }

            if rows.isEmpty {
                emptyState
            }
        }
        .listStyle(.plain)
        .onChange(of: appState.location.lastLocation) {
            recompute() // every fix: the list must follow the user in realtime
        }
        .onChange(of: contentStamp) {
            recompute()
        }
        .onAppear {
            recompute()
        }
    }

    // MARK: Derived content

    /// A cheap Equatable stamp of everything that can change the rows:
    /// the places, the open/answered state, and the show-answered toggle.
    private var contentStamp: String {
        let keys = appState.places.map(\.key)
        let pending = appState.pendingOutboxQuestionIDs.sorted()
        return keys.joined(separator: " ") + " | "
            + pending.joined(separator: ",") + " | "
            + (appState.settings.showAnswered ? "1" : "0") + " | "
            + (appState.settings.showPhotoWanted ? "1" : "0")
    }

    private var progressSection: some View {
        let openSet = appState.pendingOutboxQuestionIDs
        let all = appState.questions
        let answered = all.filter { $0.isAnswered(outboxQuestionIDs: openSet) }.count
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(answered) of \(all.count) answered")
                    .font(.subheadline.weight(.medium))
                ProgressView(value: all.isEmpty ? 0 : Double(answered) / Double(all.count))
                    .tint(.green)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if appState.places.isEmpty {
            ContentUnavailableView(
                "No places yet",
                systemImage: "building.2",
                description: Text("Sync when the review server is reachable to load them.")
            )
        } else if appState.location.lastLocation == nil {
            ContentUnavailableView(
                "Waiting for a position",
                systemImage: "location.viewfinder",
                description: Text("Nearby places appear once the phone has a fix.")
            )
        } else if appState.settings.showAnswered == false {
            ContentUnavailableView(
                "Nothing open nearby",
                systemImage: "checkmark.circle",
                description: Text("Enable “Show answered” to see every place.")
            )
        }
    }

    // MARK: Recomputation

    /// The rows' display order grouped into distance bands (the rows are
    /// already band-sorted, so consecutive runs form the sections).
    private var bandSections: [BandSection] {
        var sections: [BandSection] = []
        for row in rows {
            let band = DistanceBands.index(for: row.distance)
            if var last = sections.last, last.band == band {
                last.rows.append(row)
                sections[sections.count - 1] = last
            } else {
                sections.append(BandSection(band: band, title: DistanceBands.label(for: band), rows: [row]))
            }
        }
        return sections
    }

    /// Rebuilds the rows from the current places and position. Every call
    /// re-sorts against the latest fix — the list must track the user in
    /// realtime (foreground fixes arrive at roughly 1 Hz).
    private func recompute() {
        let center = appState.location.lastLocation?.coordinate
        let showAnswered = appState.settings.showAnswered
        let openSet = appState.pendingOutboxQuestionIDs

        let newRows: [Row] = appState.places.compactMap { place in
            let questions = place.questionIDs.compactMap { appState.question($0) }
            let open = questions.filter { !$0.isAnswered(outboxQuestionIDs: openSet) }.count
            guard open > 0 || showAnswered else { return nil }
            let placeCoordinate = CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)
            return Row(
                key: place.key,
                building: place.building,
                lat: place.lat,
                lon: place.lon,
                distance: center.map { Geo.distance(from: $0, to: placeCoordinate) },
                bearing: center.map { Geo.bearing(from: $0, to: placeCoordinate) },
                openCount: open,
                total: questions.count,
                firstImageSrc: questions.first?.imageSrcs.first,
                photoWanted: appState.settings.showPhotoWanted
                    && appState.hasPhotoWanted(place: place)
            )
        }

        // Distance bands first, then 5 m buckets; ties keep the previous
        // display order so the list only moves when it really should.
        let previousRank = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.key, $0) })
        let ranks = newRows.indices.map {
            previousRank[newRows[$0].key] ?? 1_000_000 + $0
        }
        let order = DistanceBands.orderedIndices(
            distances: newRows.map(\.distance), previousRanks: ranks)

        let sorted = order.map { newRows[$0] }
        guard sorted != rows else { return }
        withAnimation(.default) {
            rows = sorted
        }
    }
}

/// One Nearby row: compass arrow, building, distance + open count, thumbnail.
struct NearbyRow: View {
    let row: NearbyView.Row
    let heading: Double?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "location.north.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .rotationEffect(.degrees((row.bearing ?? 0) - (heading ?? 0)))
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.building)
                    .font(.headline)
                    .lineLimit(2)
                Text(secondaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if row.openCount > 0 {
                Text("\(row.openCount)")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.white)
                    .accessibilityLabel("\(row.openCount) open questions")
            }

            if row.photoWanted {
                Image(systemName: "camera.viewfinder")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Photo wanted")
            }

            ThumbnailView(src: row.firstImageSrc)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var secondaryText: String {
        var parts: [String] = []
        if let distance = row.distance {
            parts.append(distance < 1000
                ? "\(Int(distance.rounded())) m"
                : String(format: "%.1f km", distance / 1000))
        } else {
            parts.append("no position yet")
        }
        parts.append(row.openCount > 0 ? "\(row.openCount) open" : "all answered")
        return parts.joined(separator: " · ")
    }
}

/// The "show answered" toggle, shared by both tabs (one user setting).
struct ShowAnsweredToggle: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        Toggle("Show answered", isOn: $settings.showAnswered)
            .font(.subheadline)
            .fixedSize()
    }
}
