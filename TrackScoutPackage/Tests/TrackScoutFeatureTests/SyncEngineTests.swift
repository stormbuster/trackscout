import Foundation
import SwiftData
import Testing
@testable import TrackScoutFeature

/// A stand-in for the review server. Mutable so tests can script what each
/// endpoint returns. Everything that touches it (`SyncEngine`, the test
/// methods) is `@MainActor`, so `@unchecked Sendable` is safe: the mutable
/// state is in practice confined to the main actor.
final class FakeReviewServer: ReviewServerClient, @unchecked Sendable {
    struct FetchFailure: Error {}

    let baseURL = URL(string: "http://fake.invalid")!
    var questions: [QuestionDTO]
    var answers: [String: ServerAnswer]
    /// Errors thrown by `postAnswer`, consumed oldest-first (one per call).
    var postFailures: [any Error] = []
    /// Errors thrown by `fetchQuestions` / `fetchAnswers`, consumed one per
    /// call (script a timed-out questions file, a dead answers file, …).
    var questionsFailures: [any Error] = []
    var answersFailures: [any Error] = []
    /// Errors thrown by `postPhoto`, consumed oldest-first (a 400/413
    /// surfaces as `PhotoRejected` in the engine).
    var photoFailures: [any Error] = []
    /// Every photo POST that reached the "server", in call order.
    private(set) var postedPhotos: [PhotoUpload] = []
    /// What `fetchPhotos` returns (the `GET /data/owner_photos.json` doc).
    var ownerPhotos: [String: PhotoRecord] = [:]
    /// What `fetchTrackScoutSettings` returns; `nil` stands in for a 404.
    var trackScoutSettings: TrackScoutSettingsDTO? = nil
    /// Errors thrown by `fetchTrackScoutSettings`, consumed one per call.
    var settingsFailures: [any Error] = []
    /// The `groups` array of the questions doc (display order of labels).
    var groups: [String]? = nil
    /// Every POST that reached the "server", in call order.
    private(set) var posted: [AnswerPost] = []

    init(questions: [QuestionDTO] = [], answers: [String: ServerAnswer] = [:]) {
        self.questions = questions
        self.answers = answers
    }

    func fetchQuestions(timeout: TimeInterval) async throws -> QuestionsDoc {
        if !questionsFailures.isEmpty {
            throw questionsFailures.removeFirst()
        }
        return QuestionsDoc(generated: nil, questions: questions, groups: groups)
    }

    func fetchAnswers(timeout: TimeInterval) async throws -> [String: ServerAnswer] {
        if !answersFailures.isEmpty {
            throw answersFailures.removeFirst()
        }
        return answers
    }

    func fetchTrackScoutSettings(timeout: TimeInterval) async throws -> TrackScoutSettingsDTO? {
        if !settingsFailures.isEmpty {
            throw settingsFailures.removeFirst()
        }
        return trackScoutSettings
    }

    func postAnswer(_ post: AnswerPost, timeout: TimeInterval) async throws -> ServerAnswer {
        if !postFailures.isEmpty {
            throw postFailures.removeFirst()
        }
        posted.append(post)
        return ServerAnswer(id: post.id, answer: post.answer, comment: post.comment, time: "t")
    }

    func postPhoto(_ upload: PhotoUpload, timeout: TimeInterval) async throws -> PhotoStored {
        if !photoFailures.isEmpty {
            throw photoFailures.removeFirst()
        }
        postedPhotos.append(upload)
        return PhotoStored(photo_id: upload.photoID, stored: "photos/\(upload.photoID).jpg")
    }

    func fetchPhotos(timeout: TimeInterval) async throws -> [String: PhotoRecord] {
        ownerPhotos
    }

    func photoURL(for stored: String) -> URL {
        URL(string: "http://fake.invalid/photo/\(stored)")!
    }

    func imageURL(for src: String) -> URL {
        URL(string: "http://fake.invalid/qimg/\(src)")!
    }

    func downloadImage(from url: URL, timeout: TimeInterval) async throws -> Data {
        Data()
    }
}

/// An in-memory SwiftData store with the app's schema (the `try!` is safe:
/// an in-memory container cannot fail here, and a failure means the schema
/// itself is broken — which is exactly what a test crash should flag).
@MainActor
func makeTestContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Question.self, Place.self, OutboxItem.self, CachedImage.self, PlaceAlertRecord.self,
             PhotoOutboxItem.self, OwnerPhoto.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
}

struct SyncEngineTests {
    func dto(_ id: String, lat: Double = 52.5, lon: Double = 13.4, question: String? = nil) -> QuestionDTO {
        QuestionDTO(
            id: id, page: 1, order: 1, group: "rest", building: "B",
            lat: lat, lon: lon, context: "", question: question ?? "Q \(id)", type: "text",
            options: [], images: []
        )
    }

    @MainActor
    @Test func outboxPostsOldestFirstAndDeletesOnSuccess() async throws {
        let container = try makeTestContainer()
        let fake = FakeReviewServer()
        let engine = SyncEngine(context: container.mainContext) { fake }

        let older = OutboxItem(questionID: "q1", answer: "Yes", comment: nil,
                               createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = OutboxItem(questionID: "q1", answer: "No", comment: "changed my mind",
                               createdAt: Date(timeIntervalSince1970: 2_000))
        container.mainContext.insert(older)
        container.mainContext.insert(newer)
        try container.mainContext.save()

        let outcome = await engine.sync()

        #expect(outcome.succeeded)
        #expect(outcome.outboxSent == 2)
        #expect(fake.posted.count == 2)
        // Oldest first, even for the same question.
        #expect(fake.posted[0].answer == "Yes")
        #expect(fake.posted[1].answer == "No")
        #expect(fake.posted[1].comment == "changed my mind")
        #expect(try container.mainContext.fetch(FetchDescriptor<OutboxItem>()).isEmpty)
    }

    @MainActor
    @Test func rejectedAnswersAreKeptWithReasonAndNeverRetried() async throws {
        let container = try makeTestContainer()
        let fake = FakeReviewServer()
        fake.postFailures = [AnswerRejected(id: "q1", reason: "unknown id")]
        let engine = SyncEngine(context: container.mainContext) { fake }
        container.mainContext.insert(OutboxItem(questionID: "q1", answer: "Yes", comment: nil))
        try container.mainContext.save()

        let outcome = await engine.sync()

        // A rejection is handled, not fatal: the rest of the sync runs.
        #expect(outcome.succeeded)
        #expect(outcome.outboxRejected == 1)
        let items = try container.mainContext.fetch(FetchDescriptor<OutboxItem>())
        #expect(items.count == 1)
        #expect(items[0].state == .rejected)
        #expect(items[0].rejectReason == "unknown id")

        // The next sync must not POST it again.
        let _ = await engine.sync()
        #expect(fake.posted.isEmpty)
    }

    @MainActor
    @Test func networkFailureStopsSyncButKeepsRemainingPending() async throws {
        let container = try makeTestContainer()
        let fake = FakeReviewServer()
        fake.postFailures = [URLError(.notConnectedToInternet)]
        let engine = SyncEngine(context: container.mainContext) { fake }
        container.mainContext.insert(OutboxItem(questionID: "q1", answer: "Yes", comment: nil))
        container.mainContext.insert(OutboxItem(questionID: "q2", answer: "No", comment: nil))
        try container.mainContext.save()

        let outcome = await engine.sync()

        #expect(!outcome.succeeded)
        #expect(outcome.error == "Server not reachable")
        let items = try container.mainContext.fetch(FetchDescriptor<OutboxItem>())
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.state == .pending })
    }

    @MainActor
    @Test func questionsAreUpsertedInPlaceAndStaleOnesRemoved() async throws {
        let container = try makeTestContainer()
        let fake = FakeReviewServer(questions: [
            dto("q1", question: "new wording"),
            dto("q2", lat: 52.6, lon: 13.5),
        ])
        let engine = SyncEngine(context: container.mainContext) { fake }
        // Seed a store with an older version of q1 and a q3 the server dropped.
        let seeded = Question(dto: dto("q1", question: "old wording"), syncedAt: .now, placeKey: Geo.key(lat: 52.5, lon: 13.4))
        container.mainContext.insert(seeded)
        container.mainContext.insert(Question(dto: dto("q3"), syncedAt: .now, placeKey: Geo.key(lat: 52.5, lon: 13.4)))
        try container.mainContext.save()

        let outcome = await engine.sync()

        #expect(outcome.succeeded)
        #expect(outcome.questionCount == 2)
        let questions = try container.mainContext.fetch(FetchDescriptor<Question>()).sorted { $0.id < $1.id }
        #expect(questions.map(\.id) == ["q1", "q2"])
        // q1 was mutated in place, not replaced — object identity survives.
        #expect(try container.mainContext.fetch(FetchDescriptor<Question>()).first { $0.id == "q1" } === seeded)
        #expect(seeded.text == "new wording")
        // Places rebuilt wholesale: one per rounded point.
        let places = try container.mainContext.fetch(FetchDescriptor<Place>()).sorted { $0.key < $1.key }
        #expect(places.map(\.key) == ["52.50000,13.40000", "52.60000,13.50000"])
    }

    @MainActor
    @Test func serverAnswersDenormaliseAndEmptyClears() async throws {
        let container = try makeTestContainer()
        let fake = FakeReviewServer(
            questions: [dto("q1"), dto("q2")],
            answers: ["q1": ServerAnswer(id: "q1", answer: "Yes", comment: "sure", time: "2026-10-30 11:30"),
                      "qGONE": ServerAnswer(id: "qGONE", answer: "No", comment: nil, time: nil)]
        )
        let engine = SyncEngine(context: container.mainContext) { fake }

        let outcome = await engine.sync()
        #expect(outcome.succeeded)
        #expect(outcome.answersCount == 2)
        let q1 = try container.mainContext.fetch(FetchDescriptor<Question>()).first { $0.id == "q1" }
        let q2 = try container.mainContext.fetch(FetchDescriptor<Question>()).first { $0.id == "q2" }
        #expect(q1?.serverAnswer == "Yes")
        #expect(q1?.serverComment == "sure")
        // An answer whose question no longer exists is ignored.
        #expect(q2?.serverAnswer == nil)

        // The answers file 404s (empty) → everything clears.
        fake.answers = [:]
        let _ = await engine.sync()
        #expect((try container.mainContext.fetch(FetchDescriptor<Question>())).allSatisfy { $0.serverAnswer == nil })
    }

    @MainActor
    @Test func aSubmittedAnswerSurvivesWhenBothFileFetchesFail() async throws {
        // The reported bug: submit an answer (POST confirms), then both GETs
        // fail. The old sync aborted at the questions GET, so the answers GET
        // never ran, the answer was never applied locally, and the question
        // flipped back to open. The POST confirmation must keep it answered.
        let container = try makeTestContainer()
        let fake = FakeReviewServer(questions: [dto("q1")])
        let engine = SyncEngine(context: container.mainContext) { fake }
        let seeded = Question(dto: dto("q1"), syncedAt: .now, placeKey: Geo.key(lat: 52.5, lon: 13.4))
        container.mainContext.insert(seeded)
        try container.mainContext.save()
        container.mainContext.insert(OutboxItem(questionID: "q1", answer: "Yes", comment: "my answer"))
        try container.mainContext.save()
        fake.questionsFailures = [URLError(.timedOut)]
        fake.answersFailures = [URLError(.timedOut)]

        let outcome = await engine.sync()

        #expect(!outcome.succeeded)
        #expect(outcome.outboxSent == 1)
        // The outbox item is gone (confirmed) …
        #expect(try container.mainContext.fetch(FetchDescriptor<OutboxItem>()).isEmpty)
        // … and the answer denormalised from the confirmation, so the
        // question no longer counts as open.
        #expect(seeded.serverAnswer == "Yes")
        #expect(seeded.serverComment == "my answer")
        #expect(seeded.isAnswered(outboxQuestionIDs: []) == true)
    }

    @MainActor
    @Test func aFailedQuestionsFetchStillFetchesAndAppliesAnswers() async throws {
        // Steps 2 and 3 are independent: the questions file (273 KB in the
        // field) can time out without dragging the small answers file down —
        // the answers must still denormalise, and the failure must be
        // reported.
        let container = try makeTestContainer()
        let fake = FakeReviewServer(
            questions: [dto("q1"), dto("q2")],
            answers: ["q2": ServerAnswer(id: "q2", answer: "No", comment: "nope", time: "t")]
        )
        let engine = SyncEngine(context: container.mainContext) { fake }
        container.mainContext.insert(Question(dto: dto("q1"), syncedAt: .now, placeKey: Geo.key(lat: 52.5, lon: 13.4)))
        container.mainContext.insert(Question(dto: dto("q2"), syncedAt: .now, placeKey: Geo.key(lat: 52.5, lon: 13.4)))
        try container.mainContext.save()
        fake.questionsFailures = [URLError(.timedOut)]

        let outcome = await engine.sync()

        #expect(!outcome.succeeded)
        #expect(outcome.error == "Server did not answer in time")
        #expect(outcome.answersCount == 1)
        let q2 = try container.mainContext.fetch(FetchDescriptor<Question>()).first { $0.id == "q2" }
        #expect(q2?.serverAnswer == "No")
        #expect(q2?.isAnswered(outboxQuestionIDs: []) == true)
    }

    @MainActor
    @Test func bothFileFetchFailuresReportTheFirstError() async throws {
        let container = try makeTestContainer()
        let fake = FakeReviewServer(questions: [dto("q1")])
        let engine = SyncEngine(context: container.mainContext) { fake }
        fake.questionsFailures = [URLError(.timedOut)]
        fake.answersFailures = [URLError(.notConnectedToInternet)]

        let outcome = await engine.sync()

        #expect(!outcome.succeeded)
        #expect(outcome.error == "Server did not answer in time")
    }
}
