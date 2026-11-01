import Foundation
import SwiftData

/// One entry of the server's `owner_photos.json` (photo PRD 3), keyed by
/// `photo_id` in the document. Rebuilt wholesale on every sync (like the
/// answers, photos are volatile server state the app only reads).
///
/// Drives "which places already have a day / night photo" (the question-page
/// chips and the map's photo-wanted layer) and the server-side thumbnails.
@Model
public final class OwnerPhoto {
    @Attribute(.unique) public var photoID: String
    public var questionID: String? // null for capture-mode photos
    public var placeKey: String?
    public var kindRaw: String // raw, tolerant of server-side spellings
    public var lightRaw: String // "day" | "dusk" | "night"
    public var taken: Date?
    /// Repo-relative path on the server, fetched via `GET /photo/<path>`.
    public var stored: String?

    public var light: LightKind? {
        LightKind(rawValue: lightRaw)
    }

    public init(
        photoID: String,
        questionID: String? = nil,
        placeKey: String? = nil,
        kindRaw: String,
        lightRaw: String,
        taken: Date? = nil,
        stored: String? = nil
    ) {
        self.photoID = photoID
        self.questionID = questionID
        self.placeKey = placeKey
        self.kindRaw = kindRaw
        self.lightRaw = lightRaw
        self.taken = taken
        self.stored = stored
    }
}
