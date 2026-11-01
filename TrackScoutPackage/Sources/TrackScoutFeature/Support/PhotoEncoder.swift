import CoreGraphics
import CoreLocation
import Foundation
import ImageIO
import UIKit

public enum PhotoEncodingError: Error, Equatable, Sendable {
    case notAnImage
    case encodingFailed

    public var description: String {
        switch self {
        case .notAnImage: return "the data is not a decodable image"
        case .encodingFailed: return "the JPEG encoding failed"
        }
    }
}

/// JPEG encoding for uploads and thumbnails (photo PRD 3, 5.1, 5.3).
///
/// Everything goes through ImageIO so the source's metadata (EXIF exposure —
/// ISO, shutter, focal length — and the orientation tag) is carried over into
/// the re-encoded JPEG; the PRD asks to keep it for judging sign brightness
/// at night. Because the tag travels with the file, the image displays upright
/// in any viewer without double-rotating it.
public enum PhotoEncoder {
    /// Upload quality (photo PRD 3: JPEG 0.85, full resolution kept for
    /// measuring).
    public static let uploadQuality: CGFloat = 0.85

    /// Re-encodes image bytes (HEIC, PNG, JPEG, …) as JPEG. Throws
    /// `PhotoEncodingError.notAnImage` for data that is not an image.
    public static func jpeg(from source: Data, quality: CGFloat = uploadQuality) throws -> Data {
        guard
            let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
            CGImageSourceGetCount(imageSource) > 0,
            let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw PhotoEncodingError.notAnImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            throw PhotoEncodingError.encodingFailed
        }

        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
            // Carry the EXIF (exposure), TIFF, and GPS segments across. The
            // orientation tag travels with the EXIF, so the upright display
            // survives the re-encode.
            if let exif = imageProperties[kCGImagePropertyExifDictionary] {
                properties[kCGImagePropertyExifDictionary] = exif
            }
            if let tiff = imageProperties[kCGImagePropertyTIFFDictionary] {
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
            if let gps = imageProperties[kCGImagePropertyGPSDictionary] {
                properties[kCGImagePropertyGPSDictionary] = gps
            }
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoEncodingError.encodingFailed
        }
        return output as Data
    }

    /// The capture time recorded in EXIF (photo PRD 5.3: imports use their
    /// EXIF time). Prefers `DateTimeOriginal`, then `DateTimeDigitized`, then
    /// `DateTime`. The EXIF string has no time zone; it is parsed in the
    /// local zone.
    public static func exifDate(from source: Data) -> Date? {
        guard
            let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
            let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
            let exif = imageProperties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else {
            return nil
        }
        let raw =
            exif[kCGImagePropertyExifDateTimeOriginal as CFString] as? String
            ?? exif[kCGImagePropertyExifDateTimeDigitized as CFString] as? String
            ?? exif["DateTime" as CFString] as? String // older EXIF "DateTime" tag
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)
    }

    /// The GPS coordinate recorded in EXIF (photo PRD 5.1/5.3: imports use
    /// their EXIF location, and without one, the chosen place's coordinates).
    public static func exifCoordinate(from source: Data) -> CLLocationCoordinate2D? {
        guard
            let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
            let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
            let gps = imageProperties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
            let lat = gps[kCGImagePropertyGPSLatitude as CFString] as? Double,
            let lon = gps[kCGImagePropertyGPSLongitude as CFString] as? Double
        else {
            return nil
        }
        // EXIF stores a magnitude plus a hemisphere reference (N/S, E/W);
        // ImageIO reads both back separately, so apply the sign. The `> 0`
        // guards keep already-signed producers from being double-negated.
        let latRef = ((gps[kCGImagePropertyGPSLatitudeRef as CFString] as? String) ?? "N").uppercased()
        let lonRef = ((gps[kCGImagePropertyGPSLongitudeRef as CFString] as? String) ?? "E").uppercased()
        var latitude = lat
        var longitude = lon
        if latRef == "S", latitude > 0 { latitude = -latitude }
        if lonRef == "W", longitude > 0 { longitude = -longitude }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// A small `UIImage` for thumbnails (outbox rows, question-page strips).
    /// The transform flag applies the EXIF orientation, so portrait shots
    /// display upright.
    public static func thumbnail(from source: Data, maximumPixels: CGFloat = 300) -> UIImage? {
        guard
            let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                ] as CFDictionary
            )
        else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
