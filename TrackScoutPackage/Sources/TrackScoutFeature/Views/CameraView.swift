import AVFoundation
import SwiftUI
import UIKit

/// The live camera with the survey overlays (photo PRD 5.2).
///
/// A preview over the shared `CameraController` session, plus:
/// - a level indicator (the bubble follows the roll; green when square),
/// - the light chip — auto from the sun at the device position, re-evaluated
///   every 30 s, tappable to override,
/// - the ghost overlay of the day step-1 shot when shooting at night
///   (the guided set's last step), with an opacity slider,
/// - the step hint of the guided set, or nothing for a free shot,
/// - the kind chips, the night-mode hint, and the shutter.
///
/// The view only produces the JPEG and the user's choices; the caller turns
/// them into an outbox item (through `AppState`).
struct CameraView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var title: String
    /// The guided set's step hint; `nil` for a free shot (no hint shown).
    var stepHint: String? = nil
    /// A previous day shot to ghost behind the live feed at night.
    var ghostImage: UIImage? = nil
    var initialKind: PhotoKind = .storefront
    /// Whether the kind chips show at all (the question page pins `.other`).
    var showsKindPicker = true
    /// Called with the JPEG and the user's choices once the shot is taken.
    var onPhoto: ((Data, PhotoKind, LightKind?) async throws -> Void)

    @State private var kind: PhotoKind
    /// `nil` = auto (the sun); a value = the user's override.
    @State private var lightOverride: LightKind?
    @State private var ghostOpacity = 0.5
    @State private var isCapturing = false
    @State private var errorMessage: String?
    @State private var now = Date()

    init(
        title: String,
        stepHint: String? = nil,
        ghostImage: UIImage? = nil,
        initialKind: PhotoKind = .storefront,
        showsKindPicker: Bool = true,
        onPhoto: @escaping ((Data, PhotoKind, LightKind?) async throws -> Void)
    ) {
        self.title = title
        self.stepHint = stepHint
        self.ghostImage = ghostImage
        self.initialKind = initialKind
        self.showsKindPicker = showsKindPicker
        self.onPhoto = onPhoto
        _kind = State(initialValue: initialKind)
    }

    /// The light the meta will record: the override, else the sun.
    private var effectiveLight: LightKind {
        lightOverride ?? autoLight
    }

    /// The sun at the last fix (photo PRD 5.1); `.day` before the first fix
    /// so the chip always shows something.
    private var autoLight: LightKind {
        guard let coordinate = appState.location.lastLocation?.coordinate else { return .day }
        return Sun.kind(time: now, lat: coordinate.latitude, lon: coordinate.longitude)
    }

    var body: some View {
        VStack(spacing: 0) {
            preview
                .overlay(alignment: .top) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding()
                }
            controls
        }
        .background(Color.black.ignoresSafeArea())
        .task {
            appState.attitude.start()
            do {
                try await appState.camera.start()
            } catch {
                errorMessage = error.localizedDescription
            }
            // Re-evaluate the auto light every 30 s (dusk is a moving
            // target; the sun does not wait for a redraw).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = .now
            }
        }
        .onDisappear {
            appState.camera.stop()
            appState.attitude.stop()
        }
        .overlay {
            if let errorMessage {
                permissionOrErrorOverlay(errorMessage)
            }
        }
    }

    // MARK: Preview + overlays

    private var preview: some View {
        CameraPreview(session: appState.camera.session)
            .overlay {
                VStack {
                    levelIndicator
                    if effectiveLight == .night, let ghostImage {
                        Image(uiImage: ghostImage)
                            .resizable()
                            .scaledToFit()
                            .opacity(ghostOpacity)
                            .allowsHitTesting(false)
                    }
                    Spacer()
                    if let stepHint {
                        Text(stepHint)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 8)
                    }
                }
                .padding()
            }
    }

    /// The roll bubble from the shared attitude. Reads `DeviceAttitude`
    /// through the environment (injected below) so its 30 Hz updates re-render
    /// only this small subview, never the whole screen.
    private var levelIndicator: some View {
        LevelIndicator()
            .environment(appState.attitude)
            .frame(height: 32)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                lightChip
                if showsKindPicker {
                    kindChips
                }
                Spacer()
            }
            .padding(.horizontal)

            // Photo PRD 5.2: the system's Night mode is not available to
            // third-party apps, so at night we say so and point to it.
            if effectiveLight == .night {
                Text("For the best night shot use the Camera app in Night mode, then Choose from Photos")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if ghostImage != nil, effectiveLight == .night {
                HStack {
                    Text("Ghost")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Slider(value: $ghostOpacity, in: 0...1)
                        .tint(.white)
                }
                .padding(.horizontal)
            }

            Button {
                capture()
            } label: {
                Image(systemName: isCapturing ? "circle.fill" : "circle.dashed")
                    .font(.system(size: 72))
                    .foregroundStyle(.white)
            }
            .disabled(isCapturing)
            .accessibilityLabel(isCapturing ? "Taking photo" : "Take photo")

            Button("Cancel") { dismiss() }
                .foregroundStyle(.white)
        }
        .padding(.vertical)
    }

    private var lightChip: some View {
        let light = effectiveLight
        return Menu {
            Button("Auto (\(autoLight.label))") { lightOverride = nil }
            Button("Day") { lightOverride = .day }
            Button("Dusk") { lightOverride = .dusk }
            Button("Night") { lightOverride = .night }
        } label: {
            Label(
                lightOverride == nil ? light.label : "\(light.label) (set)",
                systemImage: light.symbol
            )
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var kindChips: some View {
        HStack(spacing: 6) {
            ForEach(PhotoKind.allCases) { candidate in
                Button(candidate.label) { kind = candidate }
                    .font(.footnote.weight(kind == candidate ? .semibold : .regular))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        kind == candidate ? Color.accentColor : Color.white.opacity(0.12),
                        in: Capsule()
                    )
                    .foregroundStyle(.white)
            }
        }
    }

    private func capture() {
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                let data = try await appState.camera.capturePhoto()
                try await onPhoto(data, kind, lightOverride)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func permissionOrErrorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding()
            if message.contains("Settings") {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Close") { dismiss() }
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
    }
}

/// The `AVCaptureVideoPreviewLayer` host. The session comes from the shared
/// `CameraController`; the layer just mirrors it.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.previewLayer.videoGravity = .resizeAspectFill
    }
}

/// The level bubble (photo PRD 5.2): a hairline with a dot that follows the
/// device roll — square on the building keeps it centred and green.
private struct LevelIndicator: View {
    @Environment(DeviceAttitude.self) private var attitude

    var body: some View {
        GeometryReader { geo in
            let halfWidth = geo.size.width / 2
            let scale = halfWidth / 30 // 30° of roll pushes the bubble to the edge
            let offset = min(max(attitude.bankDegrees * scale, -halfWidth), halfWidth)
            let level = abs(attitude.bankDegrees) < 3
            ZStack {
                Capsule()
                    .stroke(.white.opacity(0.5), lineWidth: 1)
                    .frame(height: 2)
                Circle()
                    .fill(level ? Color.green : Color.white)
                    .frame(width: 14, height: 14)
                    .offset(x: offset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A fullscreen image on a black background, tap to dismiss (photo PRD 4.1:
/// tapping a thumbnail opens it fullscreen). `data` is the raw JPEG; the
/// decode happens once in `task` so re-renders do not re-decode.
struct FullscreenImageView: View {
    var data: Data?
    var caption: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    init(data: Data?, caption: String? = nil) {
        self.data = data
        self.caption = caption
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(caption ?? "Photo")
            } else if data != nil {
                ProgressView()
                    .tint(.white)
            }
        }
        .overlay(alignment: .bottom) {
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .task { image = UIImage(data: data ?? Data()) }
    }
}
