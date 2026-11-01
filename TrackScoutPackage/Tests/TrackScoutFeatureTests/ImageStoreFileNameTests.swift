import Foundation
import Testing
@testable import TrackScoutFeature

struct ImageStoreFileNameTests {
    @Test func deterministic() {
        #expect(ImageStore.fileName(for: "/img/park-inn.png") == ImageStore.fileName(for: "/img/park-inn.png"))
    }

    @Test func suffixFromSourceExtension() {
        #expect(ImageStore.fileName(for: "a.png").hasSuffix(".png"))
        #expect(ImageStore.fileName(for: "a.jpg").hasSuffix(".jpg"))
        #expect(ImageStore.fileName(for: "a.jpeg").hasSuffix(".jpg"))
        #expect(ImageStore.fileName(for: "a.webp").hasSuffix(".img"))
        #expect(ImageStore.fileName(for: "A.PNG").hasSuffix(".png")) // case-insensitive
    }

    @Test func shapeIsSixteenHexDigits() {
        let name = ImageStore.fileName(for: "some image.png")
        let dot = name.lastIndex(of: ".")!
        let stem = name[..<dot]
        #expect(stem.count == 16)
        #expect(stem.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func distinctSourcesDoNotCollide() {
        let names = ["a.png", "b.png", "a.jpg", "x/y.png"].map { ImageStore.fileName(for: $0) }
        #expect(Set(names).count == names.count)
    }
}
