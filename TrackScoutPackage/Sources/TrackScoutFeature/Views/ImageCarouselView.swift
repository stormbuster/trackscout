import SwiftUI
import UIKit

/// The swipeable question-image carousel (PRD 4.4) with captions; tapping an
/// image opens it fullscreen with pinch-zoom.
public struct ImageCarouselView: View {
    let srcs: [String]
    let captions: [String]
    var height: CGFloat = 300

    @State private var index = 0
    @State private var zoomed: ZoomRequest?

    private struct ZoomRequest: Identifiable {
        let id: Int
    }

    public init(srcs: [String], captions: [String] = [], height: CGFloat = 300) {
        self.srcs = srcs
        self.captions = captions
        self.height = height
    }

    public var body: some View {
        TabView(selection: $index) {
            ForEach(Array(srcs.enumerated()), id: \.offset) { index, src in
                CarouselImageView(src: src, height: height)
                    .onTapGesture {
                        zoomed = ZoomRequest(id: index)
                    }
                    .accessibilityLabel("Image \(index + 1) of \(srcs.count); double-tap to enlarge")
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: srcs.count > 1 ? .automatic : .never))
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottom) {
            if captions.indices.contains(index), !captions[index].isEmpty {
                Text(captions[index])
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    .padding(10)
            }
        }
        .fullScreenCover(item: $zoomed) { request in
            ZoomImageView(imageSrc: srcs[request.id], caption: captions.indices.contains(request.id) ? captions[request.id] : "")
        }
    }
}

/// One carousel page: the cached bytes, or a placeholder that downloads on
/// demand. Re-loads whenever the src changes.
struct CarouselImageView: View {
    @Environment(AppState.self) private var appState
    let src: String
    let height: CGFloat

    @State private var data: Data?

    var body: some View {
        ZStack {
            if let data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        ProgressView()
                    }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .task(id: src) {
            data = appState.imageStore.data(for: src)
            if data == nil {
                data = try? await appState.imageStore.download(src)
            }
        }
    }
}

/// Fullscreen image with pinch-zoom, pan, double-tap to zoom, tap to close.
struct ZoomImageView: View {
    @Environment(AppState.self) private var appState
    let imageSrc: String
    let caption: String

    @Environment(\.dismiss) private var dismiss
    @State private var data: Data?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnifyGesture)
                    .simultaneousGesture(panGesture)
                    .onTapGesture(count: 2) {
                        withAnimation(.spring()) {
                            if scale > 1 {
                                scale = 1
                                lastScale = 1
                                offset = .zero
                                lastOffset = .zero
                            } else {
                                scale = 2.5
                                lastScale = 2.5
                            }
                        }
                    }
                    .onTapGesture {
                        if scale == 1 {
                            dismiss()
                        }
                    }
            } else {
                ProgressView()
                    .tint(.white)
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .accessibilityLabel("Close")
                    .padding()
                }
                Spacer()
                if !caption.isEmpty {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 12)
                        .lineLimit(2)
                }
            }
        }
        .task(id: imageSrc) {
            data = appState.imageStore.data(for: imageSrc)
            if data == nil {
                data = try? await appState.imageStore.download(imageSrc)
            }
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = max(1, lastScale * value.magnification)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 {
                    scale = 1
                    offset = .zero
                    lastOffset = .zero
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }
}
