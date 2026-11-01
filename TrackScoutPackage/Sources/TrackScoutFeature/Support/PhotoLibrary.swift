import Foundation
import Photos
import UIKit

/// Saving captured photos into the system photo library (photo PRD 4.1:
/// optional, "Save captured photos to Photos" in Settings, default off).
///
/// The app never edits or deletes library content — it is strictly an
/// add-only convenience, so it asks for
/// `PHAccessLevel.addOnly` and skips the save entirely when the user has
/// not granted that (the capture itself always succeeds).
public enum PhotoLibrary {
    /// Whether the app may add to the library *right now*.
    public static var isAuthorized: Bool {
        PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
    }

    /// Adds `jpeg` (captured at `taken`) as a new asset. Returns `false`
    /// when the library is unavailable or the add fails; the caller treats
    /// the failure as non-fatal — the survey photo is already stored locally.
    @MainActor
    public static func save(jpeg: Data, taken: Date) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized else { return false }
        guard let image = UIImage(data: jpeg) else { return false }
        do {
            let library = PHPhotoLibrary()
            try await library.performChanges {
                let request = PHAssetChangeRequest.creationRequestForAsset(from: image)
                request.creationDate = taken
            }
            return true
        } catch {
            return false
        }
    }
}
