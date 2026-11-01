import CoreLocation
import Foundation
import SwiftData

/// The three answer types, as spelled in the questions file.
public enum QuestionType: String, Codable, CaseIterable, Sendable {
    case yesno = "yesno"
    case choice = "choice"
    case text = "text"
}

/// A question, matched across syncs by `id` (PRD 3: questions are volatile).
///
/// The latest *server* answer is denormalised here so "answered" can be
/// decided offline; the outbox is checked separately.
@Model
public final class Question {
    @Attribute(.unique) public var id: String
    public var page: Int
    public var order: Int
    public var group: String // a free-form label from the project's questions file
    public var building: String
    public var lat: Double
    public var lon: Double
    public var context: String
    public var text: String // the question itself
    public var typeRaw: String
    public var options: [String]
    public var imageSrcs: [String]
    public var imageCaptions: [String]
    public var serverAnswer: String?
    public var serverComment: String?
    public var serverAnswerTime: String?
    public var syncedAt: Date
    /// Key of the place this question belongs to (see Place).
    public var placeKey: String?
    /// Raw value of the questions file's `photo_wanted` (photo PRD 3):
    /// "day" | "night" | "both", or nil when no photo is requested.
    public var photoWantedRaw: String?
    /// Light kinds of the photos attached to this question, denormalised from
    /// the photo outbox and `owner_photos.json` (photo PRD 4.1). Refreshed in
    /// `AppState.refreshDerived`.
    public var photoLights: [String] = []

    public var type: QuestionType {
        get { QuestionType(rawValue: typeRaw) ?? .text }
        set { typeRaw = newValue.rawValue }
    }

    /// What photo the question asks for (photo PRD 3), if anything.
    public var photoWanted: PhotoWanted? {
        photoWantedRaw.flatMap(PhotoWanted.init(rawValue:))
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// A question counts as answered if the server has an answer for it or the
    /// outbox holds a non-rejected one for it (PRD 4.1).
    ///
    /// A question that wants a photo additionally counts as answered once a
    /// photo of the wanted light exists — an answer or a photo of the wanted
    /// light both close it (photo PRD 4.1).
    public func isAnswered(outboxQuestionIDs outbox: Set<String>) -> Bool {
        if (serverAnswer?.isEmpty == false) || outbox.contains(id) {
            return true
        }
        guard let wanted = photoWanted else { return false }
        let lights = Set(photoLights)
        switch wanted {
        case .day:
            return lights.contains(LightKind.day.rawValue)
        case .night:
            return lights.contains(LightKind.night.rawValue)
        case .both:
            return lights.contains(LightKind.day.rawValue)
                && lights.contains(LightKind.night.rawValue)
        }
    }

    public init(dto: QuestionDTO, syncedAt: Date, placeKey: String) {
        id = dto.id
        page = dto.page
        order = dto.order
        group = dto.group
        building = dto.building
        lat = dto.lat
        lon = dto.lon
        context = dto.context
        text = dto.question
        typeRaw = dto.type
        options = dto.options
        imageSrcs = dto.images.map(\.src)
        imageCaptions = dto.images.map { $0.caption ?? "" }
        self.syncedAt = syncedAt
        self.placeKey = placeKey
        photoWantedRaw = dto.photoWanted
    }

    /// Apply a server answer to this question (replaces any previous one).
    public func applyServerAnswer(_ answer: ServerAnswer) {
        serverAnswer = answer.answer
        serverComment = answer.comment
        serverAnswerTime = answer.time
    }

    /// Drop a stale server answer (the answers file 404s = none exist).
    public func clearServerAnswer() {
        serverAnswer = nil
        serverComment = nil
        serverAnswerTime = nil
    }
}
