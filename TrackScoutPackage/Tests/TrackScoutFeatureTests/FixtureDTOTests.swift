import Foundation
import Testing
@testable import TrackScoutFeature

/// Decodes the bundled demo questions file (the same data the app ships for
/// "Use demo data") and the synthetic answers file, to guard the DTO shapes
/// against the app's real data.
struct FixtureDTOTests {
    func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            struct MissingFixture: Error { let name: String }
            throw MissingFixture(name: name)
        }
        return try Data(contentsOf: url)
    }

    @Test func questionsFixtureDecodes() throws {
        let doc = try JSONDecoder().decode(QuestionsDoc.self, from: fixture("owner_questions"))
        #expect(doc.generated == "2026-11-01")
        #expect(doc.questions.count == 12)
        // Every id unique (they are the sync's match key).
        let ids = Set(doc.questions.map(\.id))
        #expect(ids.count == 12)
        // The three answer types, as the UI renders them.
        let types = Dictionary(grouping: doc.questions, by: \.type).mapValues(\.count)
        #expect(types["yesno"] == 6)
        #expect(types["text"] == 2)
        #expect(types["choice"] == 4)
        // Yes/no questions carry no options (the UI supplies Yes/No); choice
        // questions carry their options explicitly.
        #expect(doc.questions.filter { $0.type == "yesno" }.allSatisfy { $0.options.isEmpty })
        #expect(doc.questions.filter { $0.type == "choice" }.allSatisfy { !$0.options.isEmpty })
        // The demo carries a display order for its free-form group labels.
        #expect(doc.groups == ["main", "secondary", "background"])
        // Grouping: 5 places on the avenue.
        let places = PlaceBuilder.build(questions: doc.questions, groupOrder: PlaceBuilder.groupOrder(doc.groups))
        #expect(places.count == 5)
        #expect(places.allSatisfy { (1...3).contains($0.questionIDs.count) })
        // The demo data is fully synthetic: no images, so the app never
        // needs a server for it.
        #expect(doc.questions.allSatisfy { $0.images.isEmpty })
        // Spot-check the first question of the file.
        let q = doc.questions.first { $0.id == "champ1a" }
        #expect(q?.type == "choice")
        #expect(q?.group == "main")
        #expect(q?.options == [
            "Three arches and a central balcony",
            "A flat façade with tall windows",
            "Two wings around a round hall",
        ])
    }

    @Test func answersFixtureDecodes() throws {
        let answers = try JSONDecoder().decode([String: ServerAnswer].self, from: fixture("owner_answers"))
        #expect(answers.count == 3)
        // Every answer refers to a question in the demo file.
        let questionIDs = Set(
            try JSONDecoder().decode(QuestionsDoc.self, from: fixture("owner_questions")).questions.map(\.id)
        )
        #expect(answers.keys.filter(questionIDs.contains).count == 3)
        // The protocol answer spellings the UI must reproduce exactly.
        #expect(answers["champ1a"]?.answer == "Three arches and a central balcony")
        #expect(answers["champ2a"]?.answer == "Don't know")
        #expect(answers["champ5b"]?.answer == "Yes")
    }
}
