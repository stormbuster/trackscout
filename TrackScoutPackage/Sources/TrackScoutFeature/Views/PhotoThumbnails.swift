import SwiftUI
import UIKit

/// The payload of a fullscreen photo (tap on a thumbnail, photo PRD 4.1).
/// The data is fetched once by the caller; the view decodes it in `task`.
struct FullscreenPhoto: Identifiable {
    let id = UUID()
    var data: Data?
    var caption: String?
}

/// A 52 pt square thumbnail of a local outbox photo (file read, no network).
struct LocalPhotoThumbnail: View {
    @Environment(AppState.self) private var appState
    let item: PhotoOutboxItem

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            guard image == nil else { return }
            if let data = try? appState.photoStore.data(for: item) {
                image = UIImage(data: data)
            }
        }
    }
}

/// A 52 pt square thumbnail of a server-side photo (`owner_photos.json`,
/// fetched via `GET /photo/<stored>` once per session through `AppState`).
struct ServerPhotoThumbnail: View {
    @Environment(AppState.self) private var appState
    let photo: OwnerPhoto

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            guard image == nil else { return }
            guard let data = await appState.ownerPhotoData(for: photo) else { return }
            image = UIImage(data: data)
        }
    }
}
