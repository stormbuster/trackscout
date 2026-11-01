import Foundation
import SwiftData

/// Reads and downloads question images. `CachedImage` records live in the
/// store; the byte files live in Caches so the database stays small.
@MainActor
public final class ImageStore {
    private let context: ModelContext
    private let makeClient: () throws -> ReviewServerClient
    private let folder: URL

    public init(context: ModelContext, makeClient: @escaping () throws -> ReviewServerClient) {
        self.context = context
        self.makeClient = makeClient
        // The new Foundation has no directoryHint overload; we always treat
        // this as a directory, so the plain form is right.
        let folder = URL.cachesDirectory.appendingPathComponent("TrackScoutImages")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
    }

    public var imageDirectory: URL { folder }

    private func record(for src: String) -> CachedImage? {
        let descriptor = FetchDescriptor<CachedImage>(predicate: #Predicate { $0.src == src })
        return try? context.fetch(descriptor).first
    }

    /// Cached bytes for a src, if present on disk.
    public func data(for src: String) -> Data? {
        guard let record = record(for: src) else { return nil }
        return try? Data(contentsOf: folder.appendingPathComponent(record.fileName))
    }

    public func isCached(_ src: String) -> Bool {
        guard let record = record(for: src) else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(record.fileName).path)
    }

    /// Download an image into the cache. Throws on network or disk failure
    /// (including a missing server URL, which the factory reports).
    @discardableResult
    public func download(_ src: String) async throws -> Data {
        let client = try makeClient()
        let url = client.imageURL(for: src)
        let data = try await client.downloadImage(from: url, timeout: 30)
        let fileName = Self.fileName(for: src)
        let fileURL = folder.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)

        if let existing = record(for: src) {
            existing.fileName = fileName
            existing.byteCount = data.count
            existing.cachedAt = .now
        } else {
            context.insert(CachedImage(src: src, fileName: fileName, byteCount: data.count))
        }
        try? context.save()
        return data
    }

    /// src values of all questions that are not cached yet.
    public func missingImageSrcs(in questions: [Question]) -> [String] {
        questions
            .flatMap(\.imageSrcs)
            .filter { !$0.isEmpty && !isCached($0) }
            .uniqued()
    }

    /// Prefetch a list of missing images. Failures are swallowed: prefetch is
    /// best-effort and a failed image simply loads on demand later.
    public func prefetch(_ srcs: [String]) async {
        for src in srcs {
            _ = try? await download(src)
        }
    }

    /// Deterministic file name for a src (djb2 hash, 16 hex chars).
    /// `nonisolated`: pure function, safe to call off the main actor.
    public nonisolated static func fileName(for src: String) -> String {
        var hash: UInt64 = 5381
        for byte in src.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        let suffix = src.lowercased().hasSuffix(".png") ? "png"
            : src.lowercased().hasSuffix(".jpg") || src.lowercased().hasSuffix(".jpeg") ? "jpg"
            : "img"
        return String(format: "%016x.%@", hash, suffix)
    }
}

extension Sequence where Element: Hashable {
    /// Order-preserving de-duplication.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return compactMap { seen.insert($0).inserted ? $0 : nil }
    }
}
