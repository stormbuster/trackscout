import SwiftUI

/// The question pager for one place (PRD 4.4): the place's questions as a
/// horizontal page, open ones first, answered ones after. The selection is
/// tracked by question id so the pages can reorder (after a submit or a
/// sync) without moving the reader.
public struct QuestionPagerView: View {
    @Environment(AppState.self) private var appState
    let placeKey: String

    @State private var pages: [Question] = []
    @State private var selectedIndex = 0

    public init(placeKey: String) {
        self.placeKey = placeKey
    }

    public var body: some View {
        Group {
            if pages.isEmpty {
                ContentUnavailableView(
                    "No questions here",
                    systemImage: "questionmark.circle",
                    description: Text("This place no longer has open questions.")
                )
            } else {
                TabView(selection: $selectedIndex) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, question in
                        QuestionPageView(question: question) { nextID in
                            advance(after: question.id, suggestedNext: nextID)
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .automatic : .never))
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: contentStamp) { recomputePages() }
        .onAppear { recomputePages() }
    }

    // MARK: Derived

    private var place: Place? {
        appState.places.first { $0.key == placeKey }
    }

    private var title: String {
        place?.building ?? "Questions"
    }

    /// Everything that can change the page list: the question set (syncs)
    /// and the pending outbox (answers).
    private var contentStamp: String {
        let ids = appState.questions.map(\.id)
        let pending = appState.pendingOutboxQuestionIDs.sorted()
        return ids.joined(separator: ",") + " | " + pending.joined(separator: ",")
    }

    /// The place's questions in display order, open first. Keeps the current
    /// selection (by id) when the list changes shape.
    private func recomputePages() {
        let all: [Question]
        if let place {
            let displayOrder = Dictionary(
                uniqueKeysWithValues: appState.questions.enumerated().map { ($0.element.id, $0.offset) }
            )
            all = place.questionIDs
                .compactMap { appState.question($0) }
                .sorted { displayOrder[$0.id, default: .max] < displayOrder[$1.id, default: .max] }
        } else {
            // The place was rebuilt away by a sync (its point moved) — fall
            // back to the questions that still point here.
            all = appState.questions.filter { $0.placeKey == placeKey }
        }

        let pending = appState.pendingOutboxQuestionIDs
        let open = all.filter { !$0.isAnswered(outboxQuestionIDs: pending) }
        let answered = all.filter { $0.isAnswered(outboxQuestionIDs: pending) }
        let newPages = open + answered

        let previousID = pages.indices.contains(selectedIndex) ? pages[selectedIndex].id : nil
        withAnimation(.default) {
            pages = newPages
        }
        if let previousID, let index = newPages.firstIndex(where: { $0.id == previousID }) {
            selectedIndex = index
        } else if newPages.isEmpty {
            selectedIndex = 0
        }
    }

    /// After a submit: reorder, then move to the next open question — or
    /// back to Nearby when the place ran dry (PRD 4.4).
    private func advance(after answeredID: String, suggestedNext: String?) {
        recomputePages()
        if let next = suggestedNext, let index = pages.firstIndex(where: { $0.id == next }) {
            withAnimation(.default) {
                selectedIndex = index
            }
        } else {
            appState.popToMain()
        }
    }
}
