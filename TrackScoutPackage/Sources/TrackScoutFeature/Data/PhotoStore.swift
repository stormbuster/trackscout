import Foundation
import SwiftData

/// Owns the local photo files and the `PhotoOutboxItem` records (photo PRD
/// 4.5). Mirrors `ImageStore` — records in the SwiftData store, byte files on
/// disk — but the files live in Application Support (photos must survive
/// cache purges; the question images in Caches may not) with file protection
/// `completeUntilFirstUserAuthentication`.
///
/// The outbox state machine (pending → sent / rejected) lives here so the
/// sync engine and the settings UI both go through one place.
@MainActor
public final class PhotoStore {
    /// How long a *sent* photo's file is kept locally for the thumbnails
    /// (photo PRD 4.5: 7 days), after which `pruneExpired` removes it.
    public static let sentRetention: TimeInterval = 7 * 24 * 3600

    private let context: ModelContext
    private let folder: URL

    public init(context: ModelContext) {
        self.context = context
        let folder = URL.applicationSupportDirectory.appendingPathComponent("TrackScoutPhotos")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Self.protect(folder)
        self.folder = folder
    }

    public var photoDirectory: URL { folder }

    /// Applies the PRD 4.5 file protection to a directory or file. (On iOS
    /// the attribute is the `com.apple.file-protection` key; the
    /// `.protectedDataKey` shorthand is macOS-only.)
    private static func protect(_ url: URL) {
        let key = FileAttributeKey("com.apple.file-protection")
        try? FileManager.default.setAttributes(
            [key: FileProtectionType.completeUntilFirstUserAuthentication.rawValue],
            ofItemAtPath: url.path
        )
    }

    public static func fileName(for photoID: String) -> String {
        photoID + ".jpg"
    }

    private func fileURL(for item: PhotoOutboxItem) -> URL {
        folder.appendingPathComponent(item.fileName)
    }

    private func record(for photoID: String) -> PhotoOutboxItem? {
        let descriptor = FetchDescriptor<PhotoOutboxItem>(
            predicate: #Predicate { $0.photoID == photoID }
        )
        return try? context.fetch(descriptor).first
    }

    // MARK: Adding photos

    /// Writes the JPEG and creates (or replaces) the pending outbox record.
    /// Throws on disk failure, which the capture UI reports.
    @discardableResult
    public func add(meta: PhotoMeta, jpeg: Data) throws -> PhotoOutboxItem {
        let fileName = Self.fileName(for: meta.photoID)
        let fileURL = folder.appendingPathComponent(fileName)
        try jpeg.write(to: fileURL, options: .atomic)
        Self.protect(fileURL)

        let item: PhotoOutboxItem
        if let existing = record(for: meta.photoID) {
            item = existing
            item.fileName = fileName
            item.applyMeta(meta)
            item.sizeBytes = jpeg.count
        } else {
            item = PhotoOutboxItem(meta: meta, fileName: fileName, sizeBytes: jpeg.count)
            context.insert(item)
        }
        try context.save()
        return item
    }

    // MARK: Outbox state machine

    /// Pending photos, oldest first — the order the sync posts them (photo
    /// PRD 4.5: "oldest first, one at a time").
    public func pending() -> [PhotoOutboxItem] {
        let pendingRaw = PhotoOutboxState.pending.rawValue
        let descriptor = FetchDescriptor<PhotoOutboxItem>(
            predicate: #Predicate { $0.stateRaw == pendingRaw },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Every outbox record (all states), oldest first — the Settings list.
    public func outboxItems() -> [PhotoOutboxItem] {
        let descriptor = FetchDescriptor<PhotoOutboxItem>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// All local records for one question (pending, sent, rejected) in
    /// capture order — the question page's thumbnail strip.
    public func localPhotos(forQuestion questionID: String) -> [PhotoOutboxItem] {
        let descriptor = FetchDescriptor<PhotoOutboxItem>(
            predicate: #Predicate { $0.questionID == questionID },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The newest local step-1 (`straight_on`) *day* photo for a place —
    /// the image the night set ghosts behind the live feed so the night shot
    /// matches (photo PRD 4.3). `nil` for an unknown place or when no such
    /// photo exists; rejected photos do not count (they never happened).
    public func existingStraightOnDay(forPlaceKey placeKey: String?) -> PhotoOutboxItem? {
        guard let placeKey else { return nil }
        return outboxItems()
            .filter { item in
                guard
                    item.placeKey == placeKey,
                    item.state != .rejected,
                    let meta = meta(for: item)
                else {
                    return false
                }
                return meta.setStep == "straight_on" && meta.light == .day
            }
            .max { $0.taken < $1.taken }
    }

    /// The JPEG for a record. Throws if the file is missing or unreadable —
    /// the sync then marks the item rejected ("photo file is missing")
    /// rather than leaving it stuck pending.
    public func data(for item: PhotoOutboxItem) throws -> Data {
        try Data(contentsOf: fileURL(for: item))
    }

    /// The decoded meta of a record (the light override / note editing flow).
    public func meta(for item: PhotoOutboxItem) -> PhotoMeta? {
        try? PhotoJSON.decodeMeta(from: item.metaJSON)
    }

    /// 200 from the server: the photo is sent. The file stays for
    /// `sentRetention` (the thumbnails) and is pruned afterwards.
    public func markSent(_ item: PhotoOutboxItem, stored: String?, at date: Date = .now) {
        item.state = .sent
        item.sentAt = date
        item.keepUntil = date.addingTimeInterval(Self.sentRetention)
        if let stored { item.serverStored = stored }
        save()
    }

    /// 400 / 413 from the server, or an unreadable local file: rejected,
    /// never retried, kept for the user to inspect in Settings.
    public func markRejected(_ item: PhotoOutboxItem, reason: String) {
        item.state = .rejected
        item.rejectReason = reason
        save()
    }

    /// Deletes the record and its file (the Settings swipe-to-delete).
    public func delete(_ item: PhotoOutboxItem) {
        try? FileManager.default.removeItem(at: fileURL(for: item))
        context.delete(item)
        save()
    }

    /// Removes sent photos whose retention has elapsed (photo PRD 4.5: keep
    /// 7 days, then delete). Rejected photos are never auto-deleted — the
    /// PRD keeps them visible until the user deletes them.
    public func pruneExpired(now: Date = .now) {
        let sentRaw = PhotoOutboxState.sent.rawValue
        let past = Date.distantPast
        let cutoff = now
        let descriptor = FetchDescriptor<PhotoOutboxItem>(
            predicate: #Predicate { $0.stateRaw == sentRaw && ($0.keepUntil ?? past) <= cutoff }
        )
        let expired = (try? context.fetch(descriptor)) ?? []
        guard !expired.isEmpty else { return }
        for item in expired {
            try? FileManager.default.removeItem(at: fileURL(for: item))
            context.delete(item)
        }
        save()
    }

    // MARK: Totals

    /// The total on-disk size of the outbox, for the Settings "size in MB"
    /// row (sum of the denormalised byte counts).
    public func totalSizeBytes() -> Int64 {
        let all = (try? context.fetch(FetchDescriptor<PhotoOutboxItem>())) ?? []
        return all.reduce(0) { $0 + Int64($1.sizeBytes) }
    }

    /// Checkpoints the context mid-batch so a sync crash loses at most the
    /// current item's state change, not the whole batch.
    public func save() {
        try? context.save()
    }
}
