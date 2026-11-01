import Foundation
import SwiftData

/// Records that an image is cached on disk. The bytes live in the Caches
/// directory (not in the store) so the database stays small (PRD 4.1).
@Model
public final class CachedImage {
    @Attribute(.unique) public var src: String // the question file's images[].src value
    public var fileName: String
    public var byteCount: Int
    public var cachedAt: Date

    public init(src: String, fileName: String, byteCount: Int, cachedAt: Date = .now) {
        self.src = src
        self.fileName = fileName
        self.byteCount = byteCount
        self.cachedAt = cachedAt
    }
}
