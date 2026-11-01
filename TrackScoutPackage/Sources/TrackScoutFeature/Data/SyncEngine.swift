import Foundation
import Network
import SwiftData

/// Outcome of one sync attempt.
public struct SyncOutcome: Equatable, Sendable {
    public var questionCount: Int = 0
    public var answersCount: Int = 0
    public var outboxSent: Int = 0
    public var outboxRejected: Int = 0
    /// Photos uploaded in the photo-outbox step (photo PRD 4.5).
    public var photosSent: Int = 0
    /// Photos rejected by the server (or unreadable locally) in that step.
    public var photosRejected: Int = 0
    /// The server's total photo count (from `owner_photos.json`).
    public var photosCount: Int = 0
    /// The project's intended display order of the free-form `group` labels
    /// (the questions file's optional `groups` array); `nil` when the file
    /// has none — the app falls back to alphabetical.
    public var groupOrder: [String]? = nil
    /// Project display settings from `GET /data/trackscout.json` (README,
    /// §project files); `nil` when the server has no such file — the app
    /// keeps the values it already has.
    public var projectSettings: TrackScoutSettingsDTO? = nil
    public var error: String? = nil

    public var succeeded: Bool { error == nil }
}

/// Executes a sync in the order of PRD 4.1, extended by the photo PRD 4.5:
///   1. POST the answer outbox, oldest first. A 400 marks the item *rejected*
///      (never retried); a success deletes it and denormalises the confirmed
///      answer onto the question, so "answered" holds even if step 2 fails. A
///      network failure stops the sync with the remaining items still pending.
///   2. POST the photo outbox, oldest first, one at a time (photo PRD 4.5).
///      200 → sent (the file is kept 7 days for thumbnails); 400/413 →
///      rejected; a network failure stops the step (the rest stays pending)
///      but does *not* fail the sync. Gated by `shouldUploadPhotos` — the
///      Wi-Fi-only setting makes this a no-op on cellular.
///   3. GET the questions → upsert the stored questions (matched by id), remove
///      ones the server no longer has, rebuild all places. A failure here does
///      *not* stop the following GETs (the questions file is large and times
///      out first on slow networks); the first error is reported.
///   4. GET the answers → denormalise the latest server answer onto each
///      question (404 = no answers → clear them).
///   5. GET `owner_photos.json` → rebuild the stored server photos wholesale
///      (404 = none yet).
///   6. Prefetch missing images, Wi-Fi only, best-effort — run as a separate
///      task (`prefetchImages`) so it never blocks the core sync.
@MainActor
public final class SyncEngine {
    public let context: ModelContext
    private let makeClient: () throws -> ReviewServerClient
    public let imageStore: ImageStore
    public let photoStore: PhotoStore
    private let pathMonitor: NWPathMonitor

    /// Whether the current network path is Wi-Fi (image prefetch gate).
    public private(set) var isWiFi = false

    /// Whether photo uploads may go out now (photo PRD 4.5: Wi-Fi only by
    /// default). `nil` means "always allow"; the app injects the Wi-Fi gate.
    public var shouldUploadPhotos: (() -> Bool)? = nil

    /// The client is built per sync so a changed settings URL takes effect.
    /// The factory throws `NoServerURLError` when no URL resolves (§8.2: the
    /// app ships without a default URL).
    public init(context: ModelContext, makeClient: @escaping () throws -> ReviewServerClient) {
        self.context = context
        self.makeClient = makeClient
        self.imageStore = ImageStore(context: context, makeClient: makeClient)
        self.photoStore = PhotoStore(context: context)
        let monitor = NWPathMonitor()
        self.pathMonitor = monitor
        monitor.start(queue: .global(qos: .utility))
        // First fix from the current path, then keep it up to date.
        isWiFi = monitor.currentPath.usesInterfaceType(.wifi)
        monitor.pathUpdateHandler = { [weak self] path in
            let isWiFi = path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                self?.isWiFi = isWiFi
            }
        }
    }

    /// Steps 1–5. `timeout` applies to each individual request: 3 s for
    /// automatic syncs (PRD 4.1), more generous for a manual "Sync now".
    public func sync(timeout: TimeInterval = 3) async -> SyncOutcome {
        // A missing URL is a clean, reported state — the UI shows it, the
        // app never crashes on an empty setting (§8.2).
        let client: ReviewServerClient
        do {
            client = try makeClient()
        } catch {
            return SyncOutcome(error: Self.describe(error))
        }
        var outcome = SyncOutcome()
        do {
            // A network failure here stops the whole sync (PRD 4.1): the
            // remaining outbox stays pending, and the GETs would likely fail.
            try await sendOutbox(client: client, timeout: timeout, outcome: &outcome)
        } catch {
            outcome.error = Self.describe(error)
            return outcome
        }
        // Steps 2–5 are independent: each failure is recorded, the sync goes
        // on, and the first error is what the UI reports.
        var firstError: String?
        do {
            try await sendPhotoOutbox(client: client, timeout: timeout, outcome: &outcome)
        } catch {
            if firstError == nil {
                firstError = Self.describe(error)
            }
        }
        do {
            try await fetchQuestions(client: client, timeout: timeout, outcome: &outcome)
        } catch {
            if firstError == nil {
                firstError = Self.describe(error)
            }
        }
        do {
            try await fetchAnswers(client: client, timeout: timeout, outcome: &outcome)
        } catch {
            if firstError == nil {
                firstError = Self.describe(error)
            }
        }
        // Project display settings (trackscout.json): deliberately best-
        // effort — a failure (or a 404) keeps the app's own values and never
        // fails the sync.
        do {
            outcome.projectSettings = try await client.fetchTrackScoutSettings(timeout: timeout)
        } catch {
            // Intentionally silent.
        }
        do {
            try await fetchOwnerPhotos(client: client, timeout: timeout, outcome: &outcome)
        } catch {
            if firstError == nil {
                firstError = Self.describe(error)
            }
        }
        outcome.error = firstError
        return outcome
    }

    /// Step 6: download every not-yet-cached question image, Wi-Fi only.
    public func prefetchImages() async {
        guard isWiFi else { return }
        let questions = (try? context.fetch(FetchDescriptor<Question>())) ?? []
        let missing = imageStore.missingImageSrcs(in: questions)
        guard !missing.isEmpty else { return }
        await imageStore.prefetch(missing)
    }

    // MARK: Step 1

    private func sendOutbox(client: ReviewServerClient, timeout: TimeInterval, outcome: inout SyncOutcome) async throws {
        // The `#Predicate` macro cannot evaluate the enum case itself, so
        // the raw value is captured as a plain constant first.
        let pendingRaw = OutboxState.pending.rawValue
        let pending = try context.fetch(FetchDescriptor<OutboxItem>(
            predicate: #Predicate { $0.stateRaw == pendingRaw }
        )).sorted { $0.createdAt < $1.createdAt }
        let questionsByID = try context.fetch(FetchDescriptor<Question>())
            .reduce(into: [String: Question]()) { $0[$1.id] = $1 }

        for item in pending {
            let post = AnswerPost(id: item.questionID, answer: item.answer, comment: item.comment)
            do {
                let confirmed = try await client.postAnswer(post, timeout: timeout)
                context.delete(item)
                // Denormalise the confirmed answer *now* (PRD 4.1: a posted
                // answer counts as answered from the moment the server
                // confirms it). If step 3's questions GET then fails — it is
                // the large file and times out first on slow networks — the
                // answer survives instead of the question flipping back to
                // open.
                questionsByID[item.questionID]?.applyServerAnswer(confirmed)
                outcome.outboxSent += 1
            } catch let error as AnswerRejected {
                item.state = .rejected
                item.rejectReason = error.reason
                outcome.outboxRejected += 1
            } catch {
                try? context.save() // keep what was sent so far
                throw error // keep the rest pending for the next sync
            }
        }
        try context.save()
    }

    // MARK: Step 2 — photo outbox (photo PRD 4.5)

    /// Posts the photo outbox, oldest first, one at a time. Non-fatal: a
    /// network failure keeps the rest pending and the sync continues.
    private func sendPhotoOutbox(client: ReviewServerClient, timeout: TimeInterval, outcome: inout SyncOutcome) async throws {
        if let shouldUploadPhotos, !shouldUploadPhotos() {
            return // Wi-Fi-only gate (photo PRD 4.5): everything stays queued
        }
        let pending = photoStore.pending()
        outcome.photosCount = pending.count

        for item in pending {
            // Local preparation: an unreadable file or a corrupt meta must
            // not wedge the item pending forever — it is rejected.
            let upload: PhotoUpload
            do {
                let data = try photoStore.data(for: item)
                let meta = try PhotoJSON.decodeMeta(from: item.metaJSON)
                upload = try PhotoUpload.make(
                    baseURL: client.baseURL, meta: meta, photo: data, fileName: item.fileName
                )
            } catch {
                photoStore.markRejected(item, reason: "the photo file is missing")
                outcome.photosRejected += 1
                continue
            }
            do {
                // A 200 with `duplicate: true` (the server already has this
                // photo_id, e.g. a killed background upload finished) still
                // means sent.
                let stored = try await client.postPhoto(upload, timeout: timeout)
                photoStore.markSent(item, stored: stored.stored)
                outcome.photosSent += 1
            } catch let error as PhotoRejected {
                photoStore.markRejected(item, reason: error.reason)
                outcome.photosRejected += 1
            } catch {
                photoStore.save() // keep what was sent so far
                throw error // keep the rest pending for the next sync
            }
        }
        photoStore.pruneExpired()
        photoStore.save()
    }

    /// A "sync" for demo mode (§8.2 "Use demo data"): no network at all.
    /// Pending outbox items are confirmed locally — the answer is
    /// denormalised onto its question and the item deleted, exactly as if the
    /// server had confirmed it — so the UI behaves normally offline. Photos
    /// are not uploaded (the queue keeps them); questions and answers are
    /// left as-is. The run always succeeds, with the store's own counts.
    public func demoSync() -> SyncOutcome {
        var outcome = SyncOutcome()
        let pendingRaw = OutboxState.pending.rawValue
        let pending = (try? context.fetch(FetchDescriptor<OutboxItem>(
            predicate: #Predicate { $0.stateRaw == pendingRaw }
        ))) ?? []
        let questions = (try? context.fetch(FetchDescriptor<Question>())) ?? []
        let questionsByID = questions.reduce(into: [String: Question]()) { $0[$1.id] = $1 }

        for item in pending {
            guard let question = questionsByID[item.questionID] else { continue }
            question.applyServerAnswer(
                ServerAnswer(id: item.questionID, answer: item.answer, comment: item.comment)
            )
            context.delete(item)
            outcome.outboxSent += 1
        }
        try? context.save()

        outcome.questionCount = questionsByID.count
        outcome.answersCount = questionsByID.values.filter { $0.serverAnswer?.isEmpty == false }.count
        outcome.photosCount = photoStore.pending().count
        return outcome
    }

    // MARK: Step 3 — questions

    private func fetchQuestions(client: ReviewServerClient, timeout: TimeInterval, outcome: inout SyncOutcome) async throws {
        let doc = try await client.fetchQuestions(timeout: timeout)
        try applyQuestions(doc, groupOrder: doc.groups)
        outcome.questionCount = doc.questions.count
        outcome.groupOrder = doc.groups
    }

    /// Upserts the stored questions from a questions document (matched by id)
    /// and rebuilds all places. Shared by the sync's step 3 and the demo
    /// load: the stored questions are always a mirror of the last document.
    func applyQuestions(_ doc: QuestionsDoc, groupOrder: [String]? = nil) throws {
        let dtosByID = Dictionary(uniqueKeysWithValues: doc.questions.map { ($0.id, $0) })
        let existing = try context.fetch(FetchDescriptor<Question>())
            .reduce(into: [String: Question]()) { $0[$1.id] = $1 }
        let now = Date()

        for (id, dto) in dtosByID {
            let placeKey = Geo.key(lat: dto.lat, lon: dto.lon)
            if let question = existing[id] {
                question.page = dto.page
                question.order = dto.order
                question.group = dto.group
                question.building = dto.building
                question.lat = dto.lat
                question.lon = dto.lon
                question.context = dto.context
                question.text = dto.question
                question.typeRaw = dto.type
                question.options = dto.options
                question.imageSrcs = dto.images.map(\.src)
                question.imageCaptions = dto.images.map { $0.caption ?? "" }
                question.photoWantedRaw = dto.photoWanted
                question.placeKey = placeKey
                question.syncedAt = now
                // serverAnswer* fields are refreshed in step 4
            } else {
                context.insert(Question(dto: dto, syncedAt: now, placeKey: placeKey))
            }
        }
        for (id, question) in existing where dtosByID[id] == nil {
            context.delete(question)
        }

        // Places are derived: rebuild wholesale.
        let built = PlaceBuilder.build(questions: doc.questions, groupOrder: PlaceBuilder.groupOrder(groupOrder))
        for place in try context.fetch(FetchDescriptor<Place>()) {
            context.delete(place)
        }
        for entry in built {
            context.insert(Place(key: entry.key, lat: entry.lat, lon: entry.lon,
                                  building: entry.building, questionIDs: entry.questionIDs))
        }
        try context.save()
    }

    // MARK: Step 4 — answers

    private func fetchAnswers(client: ReviewServerClient, timeout: TimeInterval, outcome: inout SyncOutcome) async throws {
        let answers = try await client.fetchAnswers(timeout: timeout)
        let questions = try context.fetch(FetchDescriptor<Question>())
            .reduce(into: [String: Question]()) { $0[$1.id] = $1 }
        if answers.isEmpty {
            // The answers file is missing/empty: no answers exist.
            for question in questions.values {
                question.clearServerAnswer()
            }
        } else {
            for (id, answer) in answers where questions[id] != nil {
                questions[id]?.applyServerAnswer(answer)
            }
        }
        try context.save()
        outcome.answersCount = answers.count
    }

    // MARK: Step 5 — server photos (photo PRD 3, 4.5)

    /// GET `owner_photos.json` → rebuild the stored server photos wholesale.
    /// Photos are volatile server state the app only reads (like the answers),
    /// so the whole set is replaced on every sync. A 404 already arrives as
    /// an empty dictionary from the client.
    private func fetchOwnerPhotos(client: ReviewServerClient, timeout: TimeInterval, outcome: inout SyncOutcome) async throws {
        let photos = try await client.fetchPhotos(timeout: timeout)
        for stored in try context.fetch(FetchDescriptor<OwnerPhoto>()) {
            context.delete(stored)
        }
        for record in photos.values {
            context.insert(
                OwnerPhoto(
                    photoID: record.photoID,
                    questionID: record.questionID,
                    placeKey: record.placeKey,
                    kindRaw: record.kind,
                    lightRaw: record.light,
                    taken: record.taken.flatMap(PhotoJSON.date),
                    stored: record.stored
                )
            )
        }
        try context.save()
        outcome.photosCount = photos.count
    }

    // MARK: Errors

    public static func describe(_ error: Error) -> String {
        if error is NoServerURLError {
            return "No server URL set"
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "Server not reachable"
            case .timedOut:
                return "Server did not answer in time"
            case .badURL, .unsupportedURL:
                return "Bad server URL"
            default:
                return "Network error"
            }
        }
        return error.localizedDescription
    }
}
