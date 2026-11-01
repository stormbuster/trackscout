import SwiftUI

/// The "All" tab (PRD 4.3): every place, grouped by the project's free-form
/// `group` labels (in the order the last questions file gave them —
/// alphabetical before the first sync), then building name; searchable over
/// building names and question text. The "show answered" toggle is shared
/// with the Nearby tab.
public struct AllPlacesView: View {
    @Environment(AppState.self) private var appState

    /// Plain row snapshots, like Nearby: stable list diffs across syncs.
    struct Row: Identifiable, Equatable {
        let key: String
        let building: String
        let groupName: String
        let openCount: Int
        let total: Int
        let firstImageSrc: String?

        var id: String { key }
    }

    struct Group: Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    @State private var searchText = ""
    @State private var rows: [Row] = []

    public init() {}

    public var body: some View {
        List {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.rows) { row in
                        Button {
                            appState.openPlace(row.key)
                        } label: {
                            AllRow(row: row)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if rows.isEmpty {
                emptyState
            }
        }
        .searchable(text: $searchText, prompt: "Building or question")
        .navigationTitle("All")
        .onChange(of: searchText) { recompute() }
        .onChange(of: contentStamp) { recompute() }
        .onAppear { recompute() }
    }

    // MARK: Derived content

    private var contentStamp: String {
        let keys = appState.places.map(\.key)
        let pending = appState.pendingOutboxQuestionIDs.sorted()
        // The group order is in-memory state of the app (not observed); fold
        // it in so a sync that changes only the label order re-renders.
        let groupOrder = appState.groupOrder?.joined(separator: "|") ?? ""
        return keys.joined(separator: " ") + " | "
            + pending.joined(separator: ",") + " | "
            + (appState.settings.showAnswered ? "1" : "0") + " | "
            + groupOrder
    }

    @ViewBuilder
    private var emptyState: some View {
        if appState.places.isEmpty {
            ContentUnavailableView(
                "No places yet",
                systemImage: "building.2",
                description: Text("Sync when the review server is reachable to load them.")
            )
        } else if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if appState.settings.showAnswered == false {
            ContentUnavailableView(
                "Nothing open",
                systemImage: "checkmark.circle",
                description: Text("Every place is answered. Enable “Show answered” to see them all.")
            )
        }
    }

    /// Sections in the project's group-label order (the questions file's
    /// `groups` array; alphabetical before the first sync or when it is
    /// absent), alphabetical within a label.
    private var groups: [Group] {
        var sections: [String: [Row]] = [:]
        for row in rows {
            sections[row.groupName, default: []].append(row)
        }
        let order = PlaceBuilder.groupOrder(appState.groupOrder)
        return sections
            .sorted { order($0.key, $1.key) }
            .map { Group(title: $0.key, rows: $0.value) }
    }

    private func recompute() {
        let showAnswered = appState.settings.showAnswered
        let pending = appState.pendingOutboxQuestionIDs
        let search = searchText.trimmingCharacters(in: .whitespaces).lowercased()

        var newRows: [Row] = []
        for place in appState.places {
            let questions = place.questionIDs.compactMap { appState.question($0) }
            let open = questions.filter { !$0.isAnswered(outboxQuestionIDs: pending) }
            guard open.count > 0 || showAnswered else { continue }
            if !search.isEmpty {
                let matches = place.building.lowercased().contains(search)
                    || questions.contains { $0.text.lowercased().contains(search) }
                guard matches else { continue }
            }
            let first = questions.first
            newRows.append(
                Row(
                    key: place.key,
                    building: place.building,
                    groupName: first?.group ?? "other",
                    openCount: open.count,
                    total: questions.count,
                    firstImageSrc: first?.imageSrcs.first
                )
            )
        }
        let order = PlaceBuilder.groupOrder(appState.groupOrder)
        newRows.sort { lhs, rhs in
            let left = order(lhs.groupName, rhs.groupName)
            let right = order(rhs.groupName, lhs.groupName)
            if left && !right { return true }
            if right && !left { return false }
            return lhs.building.localizedCaseInsensitiveCompare(rhs.building) == .orderedAscending
        }
        withAnimation(.default) {
            rows = newRows
        }
    }
}

/// One "All" row: building, open/answered state, badge or checkmark, thumbnail.
struct AllRow: View {
    let row: AllPlacesView.Row

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.building)
                    .font(.headline)
                    .lineLimit(2)
                Text(subtitle)
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
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("All answered")
            }

            ThumbnailView(src: row.firstImageSrc)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        row.openCount > 0 ? "\(row.openCount) open of \(row.total)" : "all answered"
    }
}
