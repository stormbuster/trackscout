import Foundation

/// A ready-to-send `POST /api/photo` request, assembled by `PhotoMultipart`.
///
/// Kept as a plain value so the sync engine (and its tests) can build and
/// inspect uploads without a server. The photo's *location* lives inside the
/// body's `meta` part — the PRD's one exception to "never send location" —
/// and never in the URL.
public struct PhotoUpload: Sendable {
    public let url: URL
    public let contentType: String
    public let body: Data
    /// The idempotency key; a 400/413 rejects the photo under this id.
    public let photoID: String

    /// Assembles an upload for `<baseURL>/api/photo`.
    public static func make(baseURL: URL, meta: PhotoMeta, photo: Data, fileName: String) throws -> PhotoUpload {
        let boundary = PhotoMultipart.makeBoundary()
        let body = try PhotoMultipart.body(boundary: boundary, meta: meta, photo: photo, fileName: fileName)
        var base = baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        return PhotoUpload(
            url: URL(string: base + "/api/photo")!,
            contentType: "multipart/form-data; boundary=\(boundary)",
            body: body,
            photoID: meta.photoID
        )
    }
}

/// Pure `multipart/form-data` assembly (photo PRD 3): a `meta` part
/// (`application/json`), then the `photo` part (`image/jpeg`), CRLF line
/// endings, terminated with `--boundary--`.
public enum PhotoMultipart {
    /// A unique boundary: fixed prefix + 16 hex chars of a UUID.
    public static func makeBoundary() -> String {
        "----TrackScout" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Builds the request body. `meta` is encoded with `PhotoJSON` (ISO 8601
    /// with offset for `taken`), then the raw JPEG bytes follow.
    public static func body(boundary: String, meta: PhotoMeta, photo: Data, fileName: String) throws -> Data {
        let crlf = Data([0x0D, 0x0A])
        var data = Data()
        func line(_ text: String) {
            data.append(Data(text.utf8))
            data.append(crlf)
        }

        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"meta\"")
        line("Content-Type: application/json")
        line("")
        data.append(try PhotoJSON.encodeMeta(meta))
        data.append(crlf)

        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"photo\"; filename=\"\(fileName)\"")
        line("Content-Type: image/jpeg")
        line("")
        data.append(photo)
        data.append(crlf)
        line("--\(boundary)--")
        return data
    }
}
