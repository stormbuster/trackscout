import CoreMotion
import Foundation
import Observation

/// Device-frame gravity, for the Capture screen's level indicator.
///
/// Derived from `CMDeviceMotion.gravity` (device frame, unit vector, pointing
/// down) rather than `attitude` — the SDK documents the reference frames but
/// not their sign conventions, while the gravity vector needs no frame at
/// all, so every value below is sign-independent:
///
/// - `tiltFromPlumbDegrees`: how far the phone's top edge is from vertical.
///   0 = held upright/plumb (the stable "phone level" hold the storefront
///   hints ask for), 90 = flat. The same number whether the top edge tips
///   forward or back.
/// - `pitchDegrees`: how far the rear camera aims from horizontal —
///   negative = looking down (fit the door and pavement), positive = looking
///   up (fit the sign). 0 = a plumb phone aims straight ahead.
/// - `bankDegrees`: how far the top edge rolls left or right of vertical;
///   the indicator's bubble moves by this. The bubble is symmetric, so a
///   sign that appears mirrored in the field is a one-line flip.
///
/// No permission is needed for device motion (photo PRD 5.4).
@MainActor
@Observable
public final class DeviceAttitude {
    public private(set) var tiltFromPlumbDegrees: Double = 0
    public private(set) var pitchDegrees: Double = 0
    public private(set) var bankDegrees: Double = 0

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private let queue = OperationQueue()
    @ObservationIgnored private var isRunning = false

    /// Starts the gravity feed (~30 Hz, enough for a level bubble, cheap
    /// enough to leave on for the whole capture).
    public func start() {
        guard !isRunning, manager.isDeviceMotionAvailable else { return }
        isRunning = true
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let motion else { return }
            let g = motion.gravity
            let x = Double(g.x), y = Double(g.y), z = Double(g.z)
            Task { @MainActor [weak self] in
                self?.update(x: x, y: y, z: z)
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopDeviceMotionUpdates()
    }

    private func update(x: Double, y: Double, z: Double) {
        // `gravity` is normalized to a unit vector; a near-zero magnitude
        // means the sensor is still settling (boot, free fall) — keep the
        // last good value.
        let magnitude = (x * x + y * y + z * z).squareRoot()
        guard magnitude > 0.5 else { return }
        let gx = x / magnitude, gy = y / magnitude, gz = z / magnitude

        // Device axes: +x toward the right edge, +y toward the top edge,
        // +z out of the screen; the rear camera looks out of the back (-z).
        //
        // Top edge vs. world "up" (-g): 0° when plumb in portrait.
        tiltFromPlumbDegrees = acos(min(1, max(-1, -gy))) * 180 / .pi
        // The camera looks out of the back (-z). Its elevation above the
        // horizon is the screen normal's component along "down": 0 when the
        // phone is plumb (aim horizontal), negative when the top edge tips
        // forward over the hand (the normal gesture for the base of a
        // building), positive when aimed at the sky.
        pitchDegrees = asin(min(1, max(-1, gz))) * 180 / .pi
        // Wrist roll about the screen normal.
        bankDegrees = atan2(gx, -gy) * 180 / .pi
    }
}
