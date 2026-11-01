import Foundation

/// Client for the review server's endpoints (PRD 3, photo PRD 3).
///
/// A protocol so tests and previews can substitute a fake; the app always
/// uses `LiveReviewServer`. The "never POST to the real server" development
/// rule is honoured by pointing `AppSettings.resolvedServerURL` at the
/// reference server (`server/`).
public protocol ReviewServerClient: Sendable {
    var baseURL: URL { get }
    func fetchQuestions(timeout: TimeInterval) async throws -> QuestionsDoc
    func fetchAnswers(timeout: TimeInterval) async throws -> [String: ServerAnswer]
    /// `GET /data/trackscout.json` (optional per-project display settings).
    /// A 404 means the server has none and returns `nil`; the app then keeps
    /// its own values.
    func fetchTrackScoutSettings(timeout: TimeInterval) async throws -> TrackScoutSettingsDTO?
    func postAnswer(_ post: AnswerPost, timeout: TimeInterval) async throws -> ServerAnswer
    /// Uploads one photo (photo PRD 3). A 400 (bad meta / non-JPEG) or 413
    /// (over 25 MB) throws `PhotoRejected` — the photo is rejected, never
    /// retried.
    func postPhoto(_ upload: PhotoUpload, timeout: TimeInterval) async throws -> PhotoStored
    /// `GET /data/owner_photos.json` (photo PRD 3); a 404 means "no photos
    /// yet" and returns an empty dictionary.
    func fetchPhotos(timeout: TimeInterval) async throws -> [String: PhotoRecord]
    /// Maps a stored photo's repo-relative path to a fetchable URL:
    /// `GET /photo/<percent-encoded path>`.
    func photoURL(for stored: String) -> URL
    /// Maps a question file `images[].src` to a fetchable URL: absolute
    /// http(s) URLs load directly, everything else goes via `/qimg/<src>`.
    func imageURL(for src: String) -> URL
    func downloadImage(from url: URL, timeout: TimeInterval) async throws -> Data
}

public struct LiveReviewServer: ReviewServerClient {
    public let baseURL: URL
    private let session: URLSession
    /// Background session for photo uploads (photo PRD 4.5): a large batch
    /// keeps uploading after the app leaves the foreground. `isDiscretionary`
    /// is off because *the app* decides when to upload (the sync, with its
    /// Wi-Fi-only gate); a killed app's unfinished upload is harmless — the
    /// server dedupes on `photo_id` and the re-POST gets `duplicate: true`.
    private let uploadSession: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.uploadSession = Self.makeUploadSession()
    }

    private static func makeUploadSession() -> URLSession {
        let identifier = (Bundle.main.bundleIdentifier ?? "com.trackscout.app") + ".photoUploads"
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForRequest = 180
        return URLSession(configuration: configuration)
    }

    public func fetchQuestions(timeout: TimeInterval) async throws -> QuestionsDoc {
        let (data, code) = try await get(path: "data/owner_questions.json", timeout: timeout)
        guard code == 200 else { throw ReviewHTTPError(code: code) }
        return try JSONDecoder().decode(QuestionsDoc.self, from: data)
    }

    public func fetchAnswers(timeout: TimeInterval) async throws -> [String: ServerAnswer] {
        let (data, code) = try await get(path: "data/owner_answers.json", timeout: timeout)
        switch code {
        case 200:
            return try JSONDecoder().decode([String: ServerAnswer].self, from: data)
        case 404:
            // "It may be missing (404), which means there are no answers yet."
            return [:]
        default:
            throw ReviewHTTPError(code: code)
        }
    }

    public func fetchTrackScoutSettings(timeout: TimeInterval) async throws -> TrackScoutSettingsDTO? {
        let (data, code) = try await get(path: "data/trackscout.json", timeout: timeout)
        switch code {
        case 200:
            return try JSONDecoder().decode(TrackScoutSettingsDTO.self, from: data)
        case 404:
            // The file is optional; the app keeps its own values.
            return nil
        default:
            throw ReviewHTTPError(code: code)
        }
    }

    public func postAnswer(_ post: AnswerPost, timeout: TimeInterval) async throws -> ServerAnswer {
        var request = URLRequest(url: url(path: "api/answer"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(post)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(ServerAnswer.self, from: data)
        case 400:
            let reason = (try? JSONDecoder().decode(Rejection.self, from: data))?.error
                ?? "the server rejected the answer"
            throw AnswerRejected(id: post.id, reason: reason)
        default:
            throw ReviewHTTPError(code: http.statusCode)
        }
    }

    public func postPhoto(_ upload: PhotoUpload, timeout: TimeInterval) async throws -> PhotoStored {
        var request = URLRequest(url: upload.url)
        request.httpMethod = "POST"
        request.setValue(upload.contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = upload.body

        let (data, response) = try await uploadSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(PhotoStored.self, from: data)
        case 400, 413:
            let reason = (try? JSONDecoder().decode(Rejection.self, from: data))?.error
                ?? "the server rejected the photo (HTTP \(http.statusCode))"
            throw PhotoRejected(photoID: upload.photoID, reason: reason)
        default:
            throw ReviewHTTPError(code: http.statusCode)
        }
    }

    public func fetchPhotos(timeout: TimeInterval) async throws -> [String: PhotoRecord] {
        let (data, code) = try await get(path: "data/owner_photos.json", timeout: timeout)
        switch code {
        case 200:
            return try JSONDecoder().decode([String: PhotoRecord].self, from: data)
        case 404:
            // "It may be 404 when there are none yet."
            return [:]
        default:
            throw ReviewHTTPError(code: code)
        }
    }

    public func photoURL(for stored: String) -> URL {
        let encoded = stored.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stored
        return url(path: "photo/\(encoded)")
    }

    public func imageURL(for src: String) -> URL {
        if let direct = URL(string: src), let scheme = direct.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return direct
        }
        // Repo-relative src -> /qimg/<URL-encoded src>. The server unquotes the
        // path, so slashes inside the src stay as separators.
        let encoded = src.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? src
        let base = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        return URL(string: "\(base)/qimg/\(encoded)")!
    }

    public func downloadImage(from url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private struct Rejection: Decodable {
        let error: String
    }

    private func url(path: String) -> URL {
        let trimmed = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        return URL(string: trimmed + "/" + path)!
    }

    private func get(path: String, timeout: TimeInterval) async throws -> (Data, Int) {
        var request = URLRequest(url: url(path: path))
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http.statusCode)
    }
}

/// There is no server URL to use (§8.2: the app ships without a default and
/// asks for one on first launch). Thrown by the app's client factories when
/// the resolved URL is empty or unparseable; callers surface it as a sync
/// status message, not a crash.
public struct NoServerURLError: Error, CustomStringConvertible, Sendable {
    public init() {}
    public var description: String { "No server URL is set." }
}
