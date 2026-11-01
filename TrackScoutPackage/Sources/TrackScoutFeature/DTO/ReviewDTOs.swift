import Foundation

/// Wire shape of `GET /data/owner_questions.json`.
public struct QuestionsDoc: Decodable, Sendable {
    public let generated: String?
    public let questions: [QuestionDTO]
    /// Optional (README, §project files): the order of the free-form
    /// `group` labels as the project intends them to be displayed. Absent =
    /// the app orders the places alphabetically.
    public let groups: [String]?
}

/// Wire shape of the optional `GET /data/trackscout.json` (README,
/// §project files): per-project display settings. Every field is optional
/// and the file itself is optional (a 404 means "keep the app defaults").
public struct TrackScoutSettingsDTO: Decodable, Equatable, Sendable {
    public let name: String?
    public let alertRadiusMeters: Double?
    public let nightWindow: NightWindow?

    public struct NightWindow: Decodable, Equatable, Sendable {
        /// Minutes after sunset until the night-photo window opens.
        public let startOffsetMinutes: Double?
        /// Fractional local hour (23.5 = 23:30) at which the window closes.
        public let endHour: Double?

        private enum CodingKeys: String, CodingKey {
            case startOffsetMinutes = "start_offset_minutes"
            case endHour = "end_hour"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case alertRadiusMeters = "alert_radius_meters"
        case nightWindow = "night_window"
    }
}

/// Wire shape of one question. Underscored internal ids that a project may
/// carry in its questions file are deliberately not decoded — they must
/// never reach the UI.
public struct QuestionDTO: Decodable, Sendable, Hashable {
    public let id: String
    public let page: Int
    public let order: Int
    public let group: String
    public let building: String
    public let lat: Double
    public let lon: Double
    public let context: String
    public let question: String
    public let type: String // "yesno" | "choice" | "text"
    public let options: [String]
    public let images: [ImageDTO]
    /// Optional (photo PRD 3): "day" | "night" | "both". Missing = no photo
    /// is requested; old questions files without it keep working.
    public let photoWanted: String?

    public init(
        id: String,
        page: Int,
        order: Int,
        group: String,
        building: String,
        lat: Double,
        lon: Double,
        context: String,
        question: String,
        type: String,
        options: [String],
        images: [ImageDTO],
        photoWanted: String? = nil
    ) {
        self.id = id
        self.page = page
        self.order = order
        self.group = group
        self.building = building
        self.lat = lat
        self.lon = lon
        self.context = context
        self.question = question
        self.type = type
        self.options = options
        self.images = images
        self.photoWanted = photoWanted
    }

    private enum CodingKeys: String, CodingKey {
        case id, page, order, group, building, lat, lon, context, question, type, options, images
        case photoWanted = "photo_wanted"
    }
}

public struct ImageDTO: Decodable, Sendable, Hashable {
    public let src: String
    public let caption: String?

    public init(src: String, caption: String? = nil) {
        self.src = src
        self.caption = caption
    }
}

/// One entry of `GET /data/owner_answers.json` (keyed by question id).
public struct ServerAnswer: Decodable, Encodable, Hashable, Sendable {
    public let id: String
    public let answer: String
    public var comment: String?
    public let time: String?

    public init(id: String, answer: String, comment: String? = nil, time: String? = nil) {
        self.id = id
        self.answer = answer
        self.comment = comment
        self.time = time
    }
}

/// Body of `POST /api/answer`.
public struct AnswerPost: Encodable, Sendable {
    public let id: String
    public let answer: String
    public var comment: String?

    public init(id: String, answer: String, comment: String? = nil) {
        self.id = id
        self.answer = answer
        self.comment = comment
    }
}

/// The server answered 400 to a POST — the id is unknown or the answer empty.
/// Such answers are marked rejected and never retried.
public struct AnswerRejected: Error, CustomStringConvertible, Sendable {
    public let id: String
    public let reason: String

    public init(id: String, reason: String) {
        self.id = id
        self.reason = reason
    }

    public var description: String { "\(id): \(reason)" }
}

/// `GET /data/owner_answers.json` answered 404 — there are no answers yet.
public struct AnswersNotFound: Error, Sendable {}

/// Any other unexpected HTTP status from the review server.
public struct ReviewHTTPError: Error, CustomStringConvertible, Sendable {
    public let code: Int

    public init(code: Int) {
        self.code = code
    }

    public var description: String { "review server HTTP \(code)" }
}
