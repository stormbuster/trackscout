import CoreGraphics
import CoreLocation
import Foundation
import ImageIO
import Testing

@testable import TrackScoutFeature

/// EXIF reading for imports and the metadata carry-over of the one JPEG
/// re-encode (photo PRD 3, acceptance 5). The source bytes are built in
/// memory with ImageIO — the same round trip the app performs, so what the
/// encoder reads back is exactly what a picked or captured photo carries.
struct PhotoEncoderTests {
    enum FixtureError: Error { case noImage }

    /// A tiny 8x8 JPEG, optionally stamped with an EXIF and/or GPS segment.
    func jpeg(exif: [CFString: Any]? = nil, gps: [CFString: Any]? = nil) throws -> Data {
        guard
            let context = CGContext(
                data: nil,
                width: 8,
                height: 8,
                bitsPerComponent: 8,
                bytesPerRow: 32,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw FixtureError.noImage
        }
        context.setFillColor(CGColor(red: 0.6, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let cgImage = context.makeImage() else {
            throw FixtureError.noImage
        }

        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)
        else {
            throw FixtureError.noImage
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let exif {
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if let gps {
            properties[kCGImagePropertyGPSDictionary] = gps
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.noImage
        }
        return output as Data
    }

    @Test func exifDateReadsDateTimeOriginalFromTheFile() throws {
        let data = try jpeg(exif: [kCGImagePropertyExifDateTimeOriginal: "2026:10:30 17:00:00"])
        let expected = Calendar.current.date(
            from: DateComponents(year: 2026, month: 10, day: 30, hour: 17, minute: 0, second: 0)
        )!
        let actual = PhotoEncoder.exifDate(from: data)
        #expect(actual == expected)
    }

    @Test func exifDatePrefersDateTimeOriginalOverDigitized() throws {
        let data = try jpeg(
            exif: [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:30 17:00:00",
                kCGImagePropertyExifDateTimeDigitized: "2026:10:31 08:00:00",
            ]
        )
        let expected = Calendar.current.date(
            from: DateComponents(year: 2026, month: 10, day: 30, hour: 17, minute: 0, second: 0)
        )!
        #expect(PhotoEncoder.exifDate(from: data) == expected)
    }

    @Test func exifDateIsNilWithoutAnExifSegment() throws {
        #expect(PhotoEncoder.exifDate(from: try jpeg()) == nil)
    }

    @Test func exifCoordinateReadsTheGpsPosition() throws {
        let data = try jpeg(
            gps: [
                kCGImagePropertyGPSLatitude: 52.52,
                kCGImagePropertyGPSLatitudeRef: "N" as CFString,
                kCGImagePropertyGPSLongitude: 13.405,
                kCGImagePropertyGPSLongitudeRef: "E" as CFString,
            ]
        )
        let coordinate = PhotoEncoder.exifCoordinate(from: data)
        #expect(coordinate != nil)
        #expect(abs(coordinate!.latitude - 52.52) < 0.0001)
        #expect(abs(coordinate!.longitude - 13.405) < 0.0001)
    }

    @Test func exifCoordinateAppliesTheHemisphereSign() throws {
        let data = try jpeg(
            gps: [
                kCGImagePropertyGPSLatitude: 52.52,
                kCGImagePropertyGPSLatitudeRef: "S" as CFString,
                kCGImagePropertyGPSLongitude: 13.405,
                kCGImagePropertyGPSLongitudeRef: "W" as CFString,
            ]
        )
        let coordinate = PhotoEncoder.exifCoordinate(from: data)
        #expect(coordinate != nil)
        #expect(abs(coordinate!.latitude + 52.52) < 0.0001)
        #expect(abs(coordinate!.longitude + 13.405) < 0.0001)
    }

    @Test func exifCoordinateIsNilWithoutGps() throws {
        #expect(PhotoEncoder.exifCoordinate(from: try jpeg()) == nil)
    }

    @Test func reEncodeCarriesExifDateAndGpsAcross() throws {
        let source = try jpeg(
            exif: [kCGImagePropertyExifDateTimeOriginal: "2026:10:30 17:00:00"],
            gps: [
                kCGImagePropertyGPSLatitude: 52.52,
                kCGImagePropertyGPSLatitudeRef: "N" as CFString,
                kCGImagePropertyGPSLongitude: 13.405,
                kCGImagePropertyGPSLongitudeRef: "E" as CFString,
            ]
        )
        let reencoded = try PhotoEncoder.jpeg(from: source)

        // The one re-encode the upload performs must keep the metadata the
        // review site and the "Taken here?" gate read from the file.
        let expected = Calendar.current.date(
            from: DateComponents(year: 2026, month: 10, day: 30, hour: 17, minute: 0, second: 0)
        )!
        #expect(PhotoEncoder.exifDate(from: reencoded) == expected)
        let coordinate = PhotoEncoder.exifCoordinate(from: reencoded)
        #expect(coordinate != nil)
        #expect(abs(coordinate!.latitude - 52.52) < 0.0001)
        #expect(abs(coordinate!.longitude - 13.405) < 0.0001)
    }

    @Test func jpegRejectsDataThatIsNotAnImage() {
        do {
            _ = try PhotoEncoder.jpeg(from: Data("not an image".utf8))
            #expect(false, "non-image data must throw")
        } catch let error as PhotoEncodingError {
            #expect(error == .notAnImage)
        } catch {
            #expect(false, "wrong error type: \(error)")
        }
    }
}
