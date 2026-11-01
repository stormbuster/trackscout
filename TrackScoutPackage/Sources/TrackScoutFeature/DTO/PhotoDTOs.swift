import Foundation

/// Where the photo was taken with respect to the sun (photo PRD 5.1).
/// `LightKind` lives in `Sun.swift`; this file is the wire shapes.

/// What the photo shows (photo PRD 3: the `kind` field of the meta).
public enum PhotoKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case storefront = "storefront"
    case sign = "sign"
    case facade = "facade"
    case detail = "detail"
    case nightLighting = "night_lighting"
    case other = "other"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .storefront: return "Storefront"
        case .sign: return "Sign"
        case .facade: return "Facade"
        case .detail: return "Detail"
        case .nightLighting: return "Night lighting"
        case .other: return "Other"
        }
    }
}

/// How the photo got here (photo PRD 3: `source`).
public enum PhotoSource: String, Codable, Sendable {
    case camera = "camera"
    case photoImport = "import"
}

/// The `meta` JSON part of `POST /api/photo` (photo PRD 3). All fields are
/// required unless marked optional; `CodingKeys` match the wire names.
public struct PhotoMeta: Codable, Sendable {
    public let photoID: String // client-generated UUID, the idempotency key
    public let questionID: String? // null for capture-mode photos
    public let placeKey: String? // the "lat,lon" place key, or null
    public var building: String // free text, prefilled from the place
    public var kind: PhotoKind
    public var light: LightKind // auto from the sun, user can override
    public let taken: Date // capture time (EXIF time for imports)
    public var lat: Double? // device position at capture; optional for imports
    public var lon: Double?
    public var accuracyMeters: Double?
    public var headingDegrees: Double? // compass heading the camera faced
    public var pitchDegrees: Double? // camera tilt, up + / down −
    public let source: PhotoSource
    public var note: String?
    public var setID: String? // guided storefront set (photo PRD 5.3)
    public var setStep: String?

    public init(
        photoID: String,
        questionID: String?,
        placeKey: String?,
        building: String,
        kind: PhotoKind,
        light: LightKind,
        taken: Date,
        lat: Double? = nil,
        lon: Double? = nil,
        accuracyMeters: Double? = nil,
        headingDegrees: Double? = nil,
        pitchDegrees: Double? = nil,
        source: PhotoSource,
        note: String? = nil,
        setID: String? = nil,
        setStep: String? = nil
    ) {
        self.photoID = photoID
        self.questionID = questionID
        self.placeKey = placeKey
        self.building = building
        self.kind = kind
        self.light = light
        self.taken = taken
        self.lat = lat
        self.lon = lon
        self.accuracyMeters = accuracyMeters
        self.headingDegrees = headingDegrees
        self.pitchDegrees = pitchDegrees
        self.source = source
        self.note = note
        self.setID = setID
        self.setStep = setStep
    }
}

extension PhotoMeta {
    private enum CodingKeys: String, CodingKey {
        case photoID = "photo_id"
        case questionID = "question_id"
        case placeKey = "place_key"
        case building, kind, light, taken, lat, lon
        case accuracyMeters = "acc_m"
        case headingDegrees = "heading_deg"
        case pitchDegrees = "pitch_deg"
        case source, note
        case setID = "set_id"
        case setStep = "set_step"
    }
}

extension PhotoMeta {
    /// The synthesized encoder would omit `nil` optionals entirely, but the
    /// PRD's wire shape keeps `question_id` and `place_key` *present* and
    /// writes `null` (capture mode has no question; "Other building" has no
    /// place key) — the server stores what it receives verbatim. Those two
    /// are therefore always encoded; only the genuinely optional fields
    /// (position, orientation, note, set) are dropped when absent. Decoding
    /// stays lenient: `null` and missing both read as `nil`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(photoID, forKey: .photoID)
        try container.encode(questionID, forKey: .questionID)
        try container.encode(placeKey, forKey: .placeKey)
        try container.encode(building, forKey: .building)
        try container.encode(kind, forKey: .kind)
        try container.encode(light, forKey: .light)
        try container.encode(taken, forKey: .taken)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(lat, forKey: .lat)
        try container.encodeIfPresent(lon, forKey: .lon)
        try container.encodeIfPresent(accuracyMeters, forKey: .accuracyMeters)
        try container.encodeIfPresent(headingDegrees, forKey: .headingDegrees)
        try container.encodeIfPresent(pitchDegrees, forKey: .pitchDegrees)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(setID, forKey: .setID)
        try container.encodeIfPresent(setStep, forKey: .setStep)
    }
}

extension PhotoMeta: CustomStringConvertible {
    public var description: String {
        "\(building) [\(kind.label), \(light.label), \(source)]"
    }
}

/// ISO 8601 with the UTC offset, seconds precision — the `taken` wire
/// format ("2026-10-30T21:14:05+01:00"). The built-in `.iso8601` strategy
/// emits UTC with a trailing `Z`, which the server does not want, so the
/// formatter writes the capture time in the *local* zone.
public enum PhotoJSON {
    /// The `taken` wire format: `yyyy-MM-dd'T'HH:mm:ss` + the UTC offset
    /// (`xxx`; a fourth `x` would emit the colon-less `+0100` form),
    /// e.g. "2026-10-30T21:14:05+01:00". The built-in `.iso8601`
    /// strategy emits UTC with a trailing `Z`, which the server does not
    /// want, so the formatter writes the time in the *local* zone. The parser
    /// accepts both offsets and a trailing `Z`, so it stays tolerant of the
    /// server's own output.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        formatter.timeZone = .current
        return formatter
    }()

    public static var metaEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(formatter)
        return encoder
    }

    public static var metaDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }

    public static func encodeMeta(_ meta: PhotoMeta) throws -> Data {
        try metaEncoder.encode(meta)
    }

    /// Non-throwing variant for flows where a failure just means "keep the
    /// previous value": every `PhotoMeta` field is encodable, and the
    /// formatter only fails on invalid dates, which the meta never holds.
    public static func encodeMetaData(_ meta: PhotoMeta) -> Data {
        (try? metaEncoder.encode(meta)) ?? Data()
    }

    public static func decodeMeta(from data: Data) throws -> PhotoMeta {
        try metaDecoder.decode(PhotoMeta.self, from: data)
    }

    public static func decodeMetaIfPresent(_ data: Data) -> PhotoMeta? {
        try? metaDecoder.decode(PhotoMeta.self, from: data)
    }

    /// Parses a `taken` string from `owner_photos.json` (ISO 8601 with
    /// offset; the document keeps it as a plain string).
    public static func date(_ string: String) -> Date? {
        formatter.date(from: string)
    }
}

/// One entry of `GET /data/owner_photos.json` (photo PRD 3), keyed by
/// `photo_id` in the document.
public struct PhotoRecord: Codable, Hashable, Sendable {
    public let photoID: String
    public let questionID: String?
    public let placeKey: String?
    public let kind: String // raw, tolerant of server-side spellings
    public let light: String // "day" | "dusk" | "night"
    public let taken: String?
    public let stored: String? // repo-relative path on the server

    public init(
        photo_id: String,
        question_id: String? = nil,
        place_key: String? = nil,
        kind: String,
        light: String,
        taken: String? = nil,
        stored: String? = nil
    ) {
        photoID = photo_id
        questionID = question_id
        placeKey = place_key
        self.kind = kind
        self.light = light
        self.taken = taken
        self.stored = stored
    }

    public var lightKind: LightKind? {
        LightKind(rawValue: light)
    }
}

/// `PhotoRecord` with the wire names restored, for the encoded outbox meta.
extension PhotoRecord {
    private enum CodingKeys: String, CodingKey {
        case photoID = "photo_id"
        case questionID = "question_id"
        case placeKey = "place_key"
        case kind, light, taken, stored
    }
}

/// The 200 body of `POST /api/photo` (photo PRD 3).
public struct PhotoStored: Decodable, Sendable {
    public let photoID: String
    public let stored: String?
    public let duplicate: Bool

    private enum CodingKeys: String, CodingKey {
        case photoID = "photo_id"
        case stored, duplicate
    }

    public init(photo_id: String, stored: String? = nil, duplicate: Bool = false) {
        photoID = photo_id
        self.stored = stored
        self.duplicate = duplicate
    }
}

/// The server answered 400 (bad meta / non-JPEG) or 413 (over 25 MB): the
/// photo is *rejected*, never retried, shown in Settings until deleted.
public struct PhotoRejected: Error, CustomStringConvertible, Sendable {
    public let photoID: String
    public let reason: String

    public init(photoID: String, reason: String) {
        self.photoID = photoID
        self.reason = reason
    }

    public var description: String { "\(photoID): \(reason)" }
}
