import Foundation
import SwiftData

/// Lifecycle of a photo in the outbox (photo PRD 4.5).
public enum PhotoOutboxState: String, Codable, Sendable {
    case pending
    /// The server accepted it (200). The file is kept for the thumbnails for
    /// `PhotoStore.sentRetention`, then pruned.
    case sent
    /// The server rejected it (400 bad meta / non-JPEG, or 413 too large).
    /// Never retried; shown in Settings until the user deletes it.
    case rejected
}

/// A photo waiting to be (or already) uploaded to `POST /api/photo`.
/// The JPEG file lives in `PhotoStore`'s Application Support folder; this
/// record is what the sync posts and what the UI lists. The `PhotoMeta` is
/// stored encoded (`metaJSON`) so the upload body is byte-for-byte what was
/// captured — only `note` and the light override are editable, and they go
/// through re-encoding.
@Model
public final class PhotoOutboxItem {
    @Attribute(.unique) public var photoID: String
    /// File name in the PhotoStore folder: `"<photoID>.jpg"`.
    public var fileName: String
    /// `PhotoMeta` encoded with `PhotoJSON` — the `meta` part of the upload.
    public var metaJSON: Data
    public var stateRaw: String
    public var createdAt: Date
    public var sentAt: Date?
    /// Sent files are kept until this date for the thumbnails, then pruned.
    public var keepUntil: Date?
    public var rejectReason: String?
    /// The server's repo-relative path (from the 200).
    public var serverStored: String?
    // Denormalised from the meta so the UI can filter by question / place /
    // light without decoding the JSON on every render:
    public var questionID: String?
    public var placeKey: String?
    public var building: String
    public var kindRaw: String
    public var lightRaw: String
    public var taken: Date
    public var sizeBytes: Int

    public var state: PhotoOutboxState {
        get { PhotoOutboxState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }

    init(
        meta: PhotoMeta,
        fileName: String,
        sizeBytes: Int,
        createdAt: Date = .now
    ) {
        photoID = meta.photoID
        self.fileName = fileName
        metaJSON = PhotoJSON.encodeMetaData(meta)
        stateRaw = PhotoOutboxState.pending.rawValue
        self.createdAt = createdAt
        questionID = meta.questionID
        placeKey = meta.placeKey
        building = meta.building
        kindRaw = meta.kind.rawValue
        lightRaw = meta.light.rawValue
        taken = meta.taken
        self.sizeBytes = sizeBytes
    }

    /// Re-applies an edited meta (light override, note) to the record.
    func applyMeta(_ meta: PhotoMeta) {
        metaJSON = PhotoJSON.encodeMetaData(meta)
        questionID = meta.questionID
        placeKey = meta.placeKey
        building = meta.building
        kindRaw = meta.kind.rawValue
        lightRaw = meta.light.rawValue
        taken = meta.taken
    }
}
