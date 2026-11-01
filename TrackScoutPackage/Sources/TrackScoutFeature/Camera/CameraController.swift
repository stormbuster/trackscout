import AVFoundation
import Foundation
import Observation

/// Errors surfaced by the camera (photo PRD 5.2).
public enum CameraError: LocalizedError, Sendable {
    case permissionDenied
    case notRunning
    case captureFailed

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "Camera access is off (Settings → Privacy → Camera)."
        case .notRunning: "The camera is not open."
        case .captureFailed: "The shot could not be processed."
        }
    }
}

/// The camera behind the Capture tab and the guided storefront set (photo
/// PRD 5.2): one `AVCaptureSession` + `AVCapturePhotoOutput`, owned by the
/// app, so the preview and the overlays the app draws on top of it (level
/// indicator, ghost overlay, step hint) all come from the same live feed —
/// the system Camera app would not let us.
///
/// `photoQualityPrioritization = .quality` per the PRD: a storefront shot
/// is a survey record, not a video frame.
@MainActor
@Observable
public final class CameraController {
    public private(set) var isRunning = false

    /// The live session. The preview layer (`CameraView`) attaches to it and
    /// sets the video orientation.
    public let session: AVCaptureSession

    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "trackscout.camera")
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private var isConfigured = false
    /// The configured input device — `capturePhoto()` derives its
    /// `maxPhotoDimensions` from the same active format.
    @ObservationIgnored private var device: AVCaptureDevice?
    /// The output's delegate is a non-retained reference, so keep the
    /// one-shot delegate alive for the duration of a capture.
    @ObservationIgnored private var captureDelegate: PhotoCaptureDelegate?

    public init() {
        self.session = AVCaptureSession()
    }

    /// Requests camera access, configures the session, and starts it.
    public func start() async throws {
        guard !isRunning else { return }
        let authorized = await AVCaptureDevice.requestAccess(for: .video)
        guard authorized else { throw CameraError.permissionDenied }
        configure()
        sessionQueue.async { [session] in
            session.startRunning()
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        sessionQueue.async { [session] in
            session.stopRunning()
        }
        isRunning = false
    }

    /// Takes one still and returns the captured image data (`PhotoEncoder`
    /// re-encodes it as JPEG 0.85 with the EXIF time/location, photo PRD
    /// 5.1). The capture itself comes back in the device's native photo
    /// format (HEIF on modern iPhones); the encoder normalises it, so the
    /// format is not pinned here.
    public func capturePhoto() async throws -> Data {
        guard isRunning else { throw CameraError.notRunning }
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        // Full resolution for measuring. This property defaults to the
        // *smallest* supported dimension, so set the same largest value as
        // the output (it must match the format's
        // `supportedMaxPhotoDimensions` and not exceed the output's
        // `maxPhotoDimensions`); a hand-rolled "(0, 0) = largest" throws on
        // real hardware.
        if let dims = Self.largestPhotoDimensions(for: device) {
            settings.maxPhotoDimensions = dims
        }

        let delegate = PhotoCaptureDelegate()
        captureDelegate = delegate
        defer { captureDelegate = nil }
        // The delegate is passed per capture — the documented mechanism
        // (`capturePhotoWithSettings:delegate:`); the output's own
        // `delegate` property is not in this SDK's Swift surface.
        return try await delegate.run {
            self.sessionQueue.async { [photoOutput] in
                // If the session has stopped (or, in the simulator, the
                // fake camera never actually started), the output's video
                // connection is inactive and `capturePhoto` would throw an
                // uncatchable ObjC exception ("No active and enabled video
                // connection"). Surface a catchable error instead.
                guard photoOutput.connection(with: .video)?.isActive == true else {
                    delegate.finish(with: .failure(CameraError.notRunning))
                    return
                }
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    private func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        self.device = device
        sessionQueue.async { [session, photoOutput, device] in
            session.beginConfiguration()
            session.sessionPreset = .hd1920x1080
            if let device, let input = try? AVCaptureDeviceInput(device: device) {
                if session.canAddInput(input) {
                    session.addInput(input)
                }
            }
            if session.canAddOutput(photoOutput) {
                // Must be set before `startRunning` (SDK header note on
                // AVCapturePhotoOutput). Full resolution for measuring: the
                // property must match one of the dimensions in
                // `activeFormat.supportedMaxPhotoDimensions` — any other
                // value (including the old "(0, 0) = largest" convention)
                // throws an uncatchable ObjC exception on real hardware.
                if let dims = Self.largestPhotoDimensions(for: device) {
                    photoOutput.maxPhotoDimensions = dims
                }
                session.addOutput(photoOutput)
            }
            session.commitConfiguration()
        }
    }

    /// The largest dimension in the device's active format
    /// `supportedMaxPhotoDimensions` — the "full resolution" value both
    /// `maxPhotoDimensions` properties must use. `nil` when the format
    /// reports none (leaves the framework defaults in place).
    private static func largestPhotoDimensions(for device: AVCaptureDevice?) -> CMVideoDimensions? {
        guard let device else { return nil }
        return device.activeFormat.supportedMaxPhotoDimensions
            .max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
    }
}

/// One-shot `AVCapturePhotoCaptureDelegate`. The photo output calls back on
/// the session queue; the continuation is resumed from there.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private var isResumed = false
    private var continuation: CheckedContinuation<Data, Error>?

    func run(_ kickOff: () -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            self.continuation = continuation
            kickOff()
        }
    }

    fileprivate func finish(with result: Result<Data, Error>) {
        guard !isResumed else { return }
        isResumed = true
        let continuation = self.continuation
        self.continuation = nil
        switch result {
        case .success(let data): continuation?.resume(returning: data)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: (any Error)?) {
        if let error {
            finish(with: .failure(error))
        } else if let data = photo.fileDataRepresentation() {
            finish(with: .success(data))
        } else {
            finish(with: .failure(CameraError.captureFailed))
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: (any Error)?) {
        finish(with: .failure(error ?? CameraError.captureFailed))
    }
}
