import SwiftUI
import UIKit

/// A small square thumbnail for a question image: the cached bytes if
/// present, otherwise a placeholder that starts an on-demand download.
struct ThumbnailView: View {
    @Environment(AppState.self) private var appState
    let src: String?

    @State private var data: Data?

    var body: some View {
        Group {
            if let data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
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
        .task(id: src) {
            guard let src else {
                data = nil
                return
            }
            data = appState.imageStore.data(for: src)
            if data == nil {
                data = try? await appState.imageStore.download(src)
            }
        }
    }
}
