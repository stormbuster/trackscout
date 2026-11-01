import Foundation
import SwiftData
import Testing
@testable import TrackScoutFeature

/// The photo outbox state machine (photo PRD 4.5, acceptance 8): pending →
/// sent / rejected, 7-day sent retention, prune, delete, replace on re-add,
/// and the ghost-overlay lookup. `makeTestContainer` (SyncEngineTests)
/// provides the in-memory store; the files themselves land in the test
/// host's Application Support under unique names and are cleaned up.
struct PhotoOutboxTests {
    var id: String { UUID().uuidString }

    func jpeg(_ tag: String) -> Data {
        Data(("JPEG:" + tag + String(repeating: "y", count: 48)).utf8)
    }

    func meta(
        _ photoID: String,
        questionID: String? = nil,
        placeKey: String? = nil,
        kind: PhotoKind = .facade,
        light: LightKind = .day,
        taken: Date = .now,
        setStep: String? = nil
    ) -> PhotoMeta {
        var meta = PhotoMeta(
            photoID: photoID,
            questionID: questionID,
            placeKey: placeKey,
            building: "Test building",
            kind: kind,
            light: light,
            taken: taken,
            source: .camera
        )
        meta.setStep = setStep
        return meta
    }

    @MainActor
    func makeStore() throws -> (ModelContainer, PhotoStore) {
        let container = try makeTestContainer()
        return (container, PhotoStore(context: container.mainContext))
    }

    /// Removes the records (and files) a test created, so repeated runs do
    /// not litter the test host's Application Support.
    @MainActor
    func cleanup(_ store: PhotoStore) {
        for item in store.outboxItems() {
            store.delete(item)
        }
    }

    // MARK: add

    @MainActor
    @Test func addCreatesPendingRecordAndFile() throws {
        let (container, store) = try makeStore()
        let photoID = id
        let taken = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let file = jpeg("a")

        let item = try store.add(meta: meta(photoID, placeKey: "52.5,13.4", taken: taken), jpeg: file)

        #expect(item.state == .pending)
        #expect(item.photoID == photoID)
        #expect(item.fileName == photoID + ".jpg")
        // Denormalised fields (the UI filters on these without decoding).
        #expect(item.placeKey == "52.5,13.4")
        #expect(item.questionID == nil)
        #expect(item.building == "Test building")
        #expect(item.kindRaw == "facade")
        #expect(item.lightRaw == "day")
        #expect(item.taken == taken)
        #expect(item.sizeBytes == file.count)
        // The file is on disk and is exactly the bytes we handed over.
        let fileURL = store.photoDirectory.appendingPathComponent(item.fileName)
        #expect(try Data(contentsOf: fileURL) == file)
        // The encoded meta round-trips.
        #expect(store.meta(for: item)?.placeKey == "52.5,13.4")
        #expect(store.pending().map(\.photoID) == [photoID])
        cleanup(store)
    }

    // MARK: sent → 7-day retention

    @MainActor
    @Test func markSentStartsTheSevenDayRetentionClock() throws {
        let (container, store) = try makeStore()
        let item = try store.add(meta: meta(id), jpeg: jpeg("b"))
        let sentAt = Date(timeIntervalSinceReferenceDate: 2_000_000)

        store.markSent(item, stored: "photos/2026-10-30/\(item.photoID).jpg", at: sentAt)

        #expect(PhotoStore.sentRetention == 7 * 24 * 3600)
        #expect(item.state == .sent)
        #expect(item.sentAt == sentAt)
        #expect(item.keepUntil == sentAt.addingTimeInterval(PhotoStore.sentRetention))
        #expect(item.serverStored == "photos/2026-10-30/\(item.photoID).jpg")
        #expect(store.pending().isEmpty)
        // The file survives for the thumbnails until the retention elapses.
        #expect(FileManager.default.fileExists(atPath: store.photoDirectory.appendingPathComponent(item.fileName).path))
        cleanup(store)
    }

    // MARK: rejected

    @MainActor
    @Test func rejectedSurvivesPrune() throws {
        let (container, store) = try makeStore()
        let item = try store.add(meta: meta(id), jpeg: jpeg("c"))

        store.markRejected(item, reason: "photo is not a JPEG")

        #expect(item.state == .rejected)
        #expect(item.rejectReason == "photo is not a JPEG")

        // Rejected photos are never auto-deleted: the PRD keeps them visible
        // until the user deletes them.
        store.pruneExpired(now: .distantFuture)

        let fileURL = store.photoDirectory.appendingPathComponent(item.fileName)
        #expect(try Data(contentsOf: fileURL) == jpeg("c"))
        #expect(store.outboxItems().map(\.photoID) == [item.photoID])
        cleanup(store)
    }

    // MARK: prune

    @MainActor
    @Test func pruneExpiredRemovesOnlyExpiredSent() throws {
        let (container, store) = try makeStore()
        let now = Date()
        let expired = try store.add(meta: meta(id), jpeg: jpeg("d"))
        let fresh = try store.add(meta: meta(UUID().uuidString), jpeg: jpeg("e"))
        let rejected = try store.add(meta: meta(UUID().uuidString), jpeg: jpeg("f"))
        // Sent 8 days ago → retention (7 days) elapsed a day ago.
        store.markSent(expired, stored: nil, at: now.addingTimeInterval(-8 * 86_400))
        // Sent yesterday → kept for 6 more days.
        store.markSent(fresh, stored: nil, at: now.addingTimeInterval(-86_400))
        store.markRejected(rejected, reason: "photo body over 25 MB")

        store.pruneExpired(now: now)

        let remaining = Set(store.outboxItems().map(\.photoID))
        #expect(remaining == Set([fresh.photoID, rejected.photoID]))
        #expect(!FileManager.default.fileExists(atPath: store.photoDirectory.appendingPathComponent(expired.fileName).path))
        #expect(try Data(contentsOf: store.photoDirectory.appendingPathComponent(fresh.fileName)) != nil)
        cleanup(store)
    }

    // MARK: delete

    @MainActor
    @Test func deleteRemovesRecordAndFile() throws {
        let (container, store) = try makeStore()
        let item = try store.add(meta: meta(id), jpeg: jpeg("g"))
        let fileURL = store.photoDirectory.appendingPathComponent(item.fileName)
        #expect(try Data(contentsOf: fileURL) != nil)

        store.delete(item)

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(store.outboxItems().isEmpty)
        cleanup(store)
    }

    // MARK: re-add

    @MainActor
    @Test func reAddingTheSameIDReplacesInsteadOfDuplicating() throws {
        let (container, store) = try makeStore()
        let photoID = id
        let first = try store.add(meta: meta(photoID, light: .day), jpeg: jpeg("h1"))

        // Re-saving the same capture: one record, the new bytes and meta.
        let secondJPEG = jpeg("h2")
        var edited = meta(photoID, light: .night)
        edited.note = "retake"
        let second = try store.add(meta: edited, jpeg: secondJPEG)

        #expect(second.photoID == first.photoID)
        #expect(store.outboxItems().map(\.photoID) == [photoID])
        let fileURL = store.photoDirectory.appendingPathComponent(second.fileName)
        #expect(try Data(contentsOf: fileURL) == secondJPEG)
        #expect(second.lightRaw == "night")
        #expect(store.meta(for: second)?.note == "retake")
        #expect(second.sizeBytes == secondJPEG.count)
        cleanup(store)
    }

    // MARK: the ghost-overlay lookup (photo PRD 4.3)

    @MainActor
    @Test func existingStraightOnDayPicksTheNewestUsableShot() throws {
        let (container, store) = try makeStore()
        let key = "52.5,13.4"
        let base = Date(timeIntervalSinceReferenceDate: 3_000_000)
        let otherPlaceKey = "53.0,13.0"

        func add(
            _ dayOffset: Int,
            light: LightKind = .day,
            placeKey: String = key,
            rejected: Bool = false
        ) -> PhotoOutboxItem {
            var meta = PhotoMeta(
                photoID: UUID().uuidString,
                questionID: nil,
                placeKey: placeKey,
                building: "Test building",
                kind: .storefront,
                light: light,
                taken: base.addingTimeInterval(TimeInterval(dayOffset) * 86_400),
                source: .camera
            )
            meta.setStep = "straight_on"
            let item = try! store.add(meta: meta, jpeg: jpeg(UUID().uuidString))
            if rejected {
                store.markRejected(item, reason: "test")
            }
            return item
        }

        _ = add(0) // day straight_on
        let winner = add(1) // day straight_on, newer → the ghost
        _ = add(2, light: .night) // wrong light
        _ = add(3, rejected: true) // never happened
        let other = add(4, placeKey: otherPlaceKey) // different place

        #expect(store.existingStraightOnDay(forPlaceKey: key) == winner)
        #expect(store.existingStraightOnDay(forPlaceKey: key)?.taken == base.addingTimeInterval(86_400))
        #expect(store.existingStraightOnDay(forPlaceKey: otherPlaceKey) == other)
        #expect(store.existingStraightOnDay(forPlaceKey: "no.such.place") == nil)
        #expect(store.existingStraightOnDay(forPlaceKey: nil) == nil)
        cleanup(store)
    }
}
