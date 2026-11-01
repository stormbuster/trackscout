import Foundation
import Testing
@testable import TrackScoutFeature

/// The `multipart/form-data` body builder (photo PRD 3, acceptance 8): the
/// `meta` and `photo` parts, CRLF layout, boundary framing, and the PRD's
/// "never send location" rule — the location lives in the `meta` part, never
/// in the URL.
struct PhotoMultipartTests {
    /// 2026-10-30 21:14:05 in Berlin — the instant from the PRD's example
    /// (CET; the test only pins the instant, the formatter renders it in the
    /// host's zone).
    var taken: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 21, minute: 14, second: 5))!
    }

    /// Deterministic fake JPEG. Plain ASCII, so it can never contain the
    /// 32-hex-char boundary by accident and byte-exact comparison is safe.
    var jpeg: Data {
        Data(("FAKE-JPEG-" + String(repeating: "x", count: 64)).utf8)
    }

    /// A capture-mode photo (no question) of a place, as a straight-on shot
    /// of a guided set — every optional meta field populated.
    func captureMeta() -> PhotoMeta {
        PhotoMeta(
            photoID: "cap-1",
            questionID: nil,
            placeKey: "52.5235,13.4135",
            building: "Park Inn tower",
            kind: .storefront,
            light: .night,
            taken: taken,
            lat: 52.528771,
            lon: 13.403102,
            accuracyMeters: 6.5,
            headingDegrees: 182,
            pitchDegrees: 8,
            source: .camera,
            note: "neon only on after 18:00",
            setID: "A71C0000-1111-2222-3333-444455556666",
            setStep: "straight_on"
        )
    }

    func upload(baseURL: URL = URL(string: "http://fake.invalid")!) throws -> PhotoUpload {
        try PhotoUpload.make(baseURL: baseURL, meta: captureMeta(), photo: jpeg, fileName: "cap-1.jpg")
    }

    // MARK: The URL

    @Test func urlIsBasePlusApiPhotoWithNoLocation() throws {
        let upload = try upload()
        #expect(upload.url.absoluteString == "http://fake.invalid/api/photo")
        #expect(!upload.url.absoluteString.contains("lat"))
        #expect(!upload.url.absoluteString.contains("lon"))
        #expect(!upload.url.absoluteString.contains("52."))
        #expect(upload.photoID == "cap-1")
    }

    @Test func urlToleratesTrailingSlashBase() throws {
        let upload = try upload(baseURL: URL(string: "http://fake.invalid/")!)
        #expect(upload.url.absoluteString == "http://fake.invalid/api/photo")
    }

    // MARK: The framing

    @Test func contentTypeMatchesTheBoundaryOnTheFirstLine() throws {
        let upload = try upload()
        let prefix = "multipart/form-data; boundary="
        #expect(upload.contentType.hasPrefix(prefix))
        let boundary = String(upload.contentType.dropFirst(prefix.count))
        let needle = Data(("--" + boundary + "\r\n").utf8)
        #expect(upload.body.prefix(needle.count) == needle)
    }

    @Test func bodyEndsWithTheClosingBoundary() throws {
        let upload = try upload()
        let boundary = String(upload.contentType.dropFirst("multipart/form-data; boundary=".count))
        let terminator = Data(("--" + boundary + "--\r\n").utf8)
        #expect(upload.body.suffix(terminator.count) == terminator)
    }

    // MARK: The meta part

    @Test func metaPartRoundTripsThroughPhotoJSON() throws {
        let upload = try upload()
        let parts = try Self.extractParts(upload.body, contentType: upload.contentType)
        let decoded = try PhotoJSON.decodeMeta(from: parts.meta)
        let original = captureMeta()
        #expect(decoded.photoID == original.photoID)
        #expect(decoded.questionID == original.questionID)
        #expect(decoded.placeKey == original.placeKey)
        #expect(decoded.building == original.building)
        #expect(decoded.kind == original.kind)
        #expect(decoded.light == original.light)
        #expect(decoded.taken == original.taken)
        #expect(decoded.lat == original.lat)
        #expect(decoded.lon == original.lon)
        #expect(decoded.accuracyMeters == original.accuracyMeters)
        #expect(decoded.headingDegrees == original.headingDegrees)
        #expect(decoded.pitchDegrees == original.pitchDegrees)
        #expect(decoded.source == original.source)
        #expect(decoded.note == original.note)
        #expect(decoded.setID == original.setID)
        #expect(decoded.setStep == original.setStep)
    }

    @Test func metaPartShowsThePrdWireShape() throws {
        let upload = try upload()
        let parts = try Self.extractParts(upload.body, contentType: upload.contentType)
        let metaText = String(decoding: parts.meta, as: UTF8.self)
        #expect(metaText.contains(#""photo_id":"cap-1""#))
        // Capture mode: the question is explicitly null, the place is set.
        #expect(metaText.contains(#""question_id":null"#))
        #expect(metaText.contains(#""place_key":"52.5235,13.4135""#))
        #expect(metaText.contains(#""kind":"storefront""#))
        #expect(metaText.contains(#""light":"night""#))
        #expect(metaText.contains(#""source":"camera""#))
        #expect(metaText.contains(#""set_step":"straight_on""#))
        // The PRD's `taken`: ISO 8601 with a UTC offset ("...+01:00").
        #expect(metaText.range(of: #""taken":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}""#, options: .regularExpression) != nil)
        // And the location *does* ride in the meta — the one PRD exception.
        #expect(metaText.range(of: #""lat":"#, options: .regularExpression) != nil)
        #expect(metaText.range(of: #""lon":"#, options: .regularExpression) != nil)
    }

    // MARK: The photo part

    @Test func photoPartIsByteExact() throws {
        let upload = try upload()
        let parts = try Self.extractParts(upload.body, contentType: upload.contentType)
        #expect(parts.photo == jpeg)
    }

    // MARK: Part extraction

    private enum TestError: Error { case malformedBody }

    /// Splits the body into its two payloads. The layout is
    /// `--b CRLF`, headers `CRLF`, `CRLF`, payload, `CRLF --b CRLF`, …,
    /// `--b-- CRLF`, so each payload sits between a blank line and the next
    /// boundary line. (Byte-level: the JPEG part may contain non-UTF-8.)
    static func extractParts(_ body: Data, contentType: String) throws -> (meta: Data, photo: Data) {
        guard contentType.hasPrefix("multipart/form-data; boundary=") else {
            throw TestError.malformedBody
        }
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let blank = Data([0x0D, 0x0A, 0x0D, 0x0A])
        let secondBoundary = Data(("\r\n--\(boundary)\r\n").utf8)
        let terminator = Data(("\r\n--\(boundary)--\r\n").utf8)

        func indexOf(_ needle: Data, from start: Int) -> Int? {
            guard start >= 0, start + needle.count <= body.count else { return nil }
            var index = start
            while index + needle.count <= body.count {
                if body.subdata(in: index..<(index + needle.count)) == needle {
                    return index
                }
                index += 1
            }
            return nil
        }

        guard let metaStart = indexOf(blank, from: 0).map({ $0 + blank.count }) else {
            throw TestError.malformedBody
        }
        guard let metaEnd = indexOf(secondBoundary, from: metaStart) else {
            throw TestError.malformedBody
        }
        let meta = body.subdata(in: metaStart..<metaEnd)

        guard let photoStart = indexOf(blank, from: metaEnd + secondBoundary.count).map({ $0 + blank.count }) else {
            throw TestError.malformedBody
        }
        guard let photoEnd = indexOf(terminator, from: photoStart) else {
            throw TestError.malformedBody
        }
        return (meta, body.subdata(in: photoStart..<photoEnd))
    }
}
