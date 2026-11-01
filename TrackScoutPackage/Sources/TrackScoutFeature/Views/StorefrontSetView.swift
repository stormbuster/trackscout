import SwiftUI
import UIKit

/// The guided storefront set (photo PRD 4.3): up to 5 shots, each with its
/// one-line on-screen hint, each skippable, all sharing one `set_id`.
///
/// At night the set reuses the day `straight_on` photo of the place as a
/// semi-transparent ghost behind the live feed (opacity slider in
/// `CameraView`) so the night shot lines up with the day one.
struct StorefrontSetView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let placeKey: String?
    let building: String
    /// The light override chosen on the Capture tab; `nil` = auto.
    var lightOverride: LightKind? = nil

    /// The five steps of the set, in order (photo PRD 4.3). The `id` is
    /// recorded in the meta's `set_step`; the `kind` is what the step
    /// measures.
    struct Step: Identifiable {
        let id: String
        let hint: String
        let kind: PhotoKind
    }

    static let steps: [Step] = [
        Step(
            id: "straight_on",
            hint: "Stand opposite the shop, phone level and upright. Fit the whole shopfront, from pavement to the fascia above the awning, and both neighbouring piers.",
            kind: .storefront
        ),
        Step(
            id: "oblique_left",
            hint: "Walk about 5 m left and aim back at the shopfront (door depths, recesses, steps).",
            kind: .facade
        ),
        Step(
            id: "oblique_right",
            hint: "The same from the right.",
            kind: .facade
        ),
        Step(
            id: "sign_close",
            hint: "Fill the frame with the sign or lettering.",
            kind: .sign
        ),
        Step(
            id: "door_close",
            hint: "The door, its steps and the house number.",
            kind: .detail
        ),
    ]

    /// The set id: continues the day set when one exists (so the night
    /// shots join it); a new UUID for a first set.
    @State private var setID = UUID().uuidString
    /// The day `straight_on` image, ghosted behind the live feed at night.
    @State private var ghostImage: UIImage?
    @State private var stepIndex = 0
    /// True once the last step is done (or the set was ended early).
    @State private var isFinished = false

    var body: some View {
        Group {
            if isFinished {
                doneScreen
            } else {
                stepScreen
            }
        }
        .task {
            // Continue the day set and load the night ghost, if there is
            // one (photo PRD 4.3).
            if let existing = appState.photoStore.existingStraightOnDay(forPlaceKey: placeKey),
               let meta = appState.photoStore.meta(for: existing) {
                setID = meta.setID ?? setID
                if let data = try? appState.photoStore.data(for: existing) {
                    ghostImage = UIImage(data: data)
                }
            }
        }
    }

    // MARK: Steps

    private var currentStep: Step { Self.steps[stepIndex] }

    private var stepScreen: some View {
        CameraView(
            title: "Step \(stepIndex + 1) of \(Self.steps.count)",
            stepHint: currentStep.hint,
            ghostImage: ghostImage,
            initialKind: currentStep.kind,
            showsKindPicker: false,
            onPhoto: { _, _, light in
                try await appState.capturePhoto(
                    placeKey: placeKey,
                    building: building,
                    kind: currentStep.kind,
                    lightOverride: light,
                    setID: setID,
                    setStep: currentStep.id
                )
                advance()
            }
        )
        .overlay(alignment: .top) {
            // Photo PRD 4.3: every step can be skipped.
            HStack {
                Button("Skip step") { advance() }
                Spacer()
                if stepIndex < Self.steps.count - 1 {
                    Button("End set") { isFinished = true }
                        .opacity(0.7)
                }
            }
            .font(.footnote)
            .foregroundStyle(.white)
            .padding(.horizontal)
            .padding(.top, 34) // under the title
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal)
        }
    }

    private func advance() {
        if stepIndex < Self.steps.count - 1 {
            stepIndex += 1
        } else {
            isFinished = true
        }
    }

    // MARK: Finish

    private var doneScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Set complete")
                .font(.title2.weight(.semibold))
            Text("The photos are in the outbox and will upload over Wi-Fi.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}
