import SwiftUI
import UIKit

/// One page of the question pager (PRD 4.4): media (image carousel, or a
/// larger map when there are no images) → 3D map → building / context /
/// question → answer controls → comment → submit, plus the "This isn't
/// here" wrong-location report.
struct QuestionPageView: View {
    @Environment(AppState.self) private var appState
    let question: Question
    /// Called once the answer has been recorded, with the id of the next
    /// open question of the place (computed before the submit) or `nil`
    /// when this was the last one.
    let onAdvance: (String?) -> Void

    @State private var selectedAnswer: String?
    @State private var answerText = ""
    @State private var comment = ""
    @State private var isSubmitting = false
    @State private var showingWrongLocation = false
    @State private var hasPreselected = false
    @State private var showingCamera = false
    @State private var showingImporter = false
    @State private var fullscreenPhoto: FullscreenPhoto?

    init(question: Question, onAdvance: @escaping (String?) -> Void) {
        self.question = question
        self.onAdvance = onAdvance
    }

    private var hasImages: Bool { !question.imageSrcs.isEmpty }

    /// The question's current effective answer (PRD 4.4: already-answered
    /// questions show the previous answer preselected; re-submitting
    /// replaces it).
    private var previousAnswer: String? {
        let pending = appState.outbox.first {
            $0.questionID == question.id && $0.state == .pending
        }
        return pending?.answer ?? question.serverAnswer
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if hasImages {
                    ImageCarouselView(srcs: question.imageSrcs, captions: question.imageCaptions)
                }
                MapCardView(
                    coordinate: question.coordinate,
                    style: appState.settings.mapStyle,
                    height: hasImages ? 220 : 380
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(question.building)
                        .font(.title3.weight(.semibold))
                    if !question.context.isEmpty {
                        Text(question.context)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(question.text)
                        .font(.headline)
                }

                if let previous = previousAnswer, !previous.isEmpty {
                    previousNote(previous)
                }

                answerControls

                photoSection

                TextField(
                    "Add a comment (optional)",
                    text: $comment,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                Button {
                    showingWrongLocation = true
                } label: {
                    Text("This isn’t here")
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity)
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            submitBar
        }
        .sheet(isPresented: $showingWrongLocation) {
            WrongLocationSheet(question: question) { next in
                onAdvance(next)
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraView(
                title: "Add photo",
                initialKind: .other,
                showsKindPicker: false,
                onPhoto: { data, kind, light in
                    try await appState.capturePhoto(
                        questionID: question.id,
                        placeKey: question.placeKey,
                        building: question.building,
                        kind: kind,
                        lightOverride: light
                    )
                }
            )
        }
        .fullScreenCover(isPresented: $showingImporter) {
            PhotoImportView(
                questionID: question.id,
                placeKey: question.placeKey,
                building: question.building,
                kind: .other
            )
        }
        .fullScreenCover(item: $fullscreenPhoto) { photo in
            FullscreenImageView(data: photo.data, caption: photo.caption)
        }
        .task {
            guard !hasPreselected else { return }
            hasPreselected = true
            guard let previous = previousAnswer, !previous.isEmpty else { return }
            switch question.type {
            case .yesno where [AnswerValues.yes, AnswerValues.no, AnswerValues.dontKnow].contains(previous):
                selectedAnswer = previous
            case .choice where question.options.contains(previous) || previous == AnswerValues.dontKnow:
                selectedAnswer = previous
            case .text:
                answerText = previous
            default:
                break
            }
        }
    }

    // MARK: Answer controls (PRD 4.4)

    @ViewBuilder
    private var answerControls: some View {
        switch question.type {
        case .yesno:
            ForEach([AnswerValues.yes, AnswerValues.no, AnswerValues.dontKnow], id: \.self) { option in
                AnswerButton(title: option, isSelected: selectedAnswer == option) {
                    selectedAnswer = option
                }
            }
        case .choice:
            ForEach(question.options, id: \.self) { option in
                AnswerButton(title: option, isSelected: selectedAnswer == option) {
                    selectedAnswer = option
                }
            }
            AnswerButton(title: AnswerValues.dontKnow, isSelected: selectedAnswer == AnswerValues.dontKnow) {
                selectedAnswer = AnswerValues.dontKnow
            }
        case .text:
            TextField("Your answer", text: $answerText, axis: .vertical)
                .lineLimit(1...5)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            AnswerButton(title: AnswerValues.dontKnow, isSelected: selectedAnswer == AnswerValues.dontKnow) {
                selectedAnswer = AnswerValues.dontKnow
            }
        }
    }

    private func previousNote(_ previous: String) -> some View {
        Label {
            Text("You already answered: “\(previous)”. Submitting again replaces it.")
                .font(.footnote)
        } icon: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.footnote)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Photos (photo PRD 4.1)

    /// The "photo wanted" chip, the Add-photo button, and the thumbnail
    /// strip (local outbox photos + the server's). Photos are independent
    /// of the answer: the button is always present.
    @ViewBuilder
    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let wanted = question.photoWanted {
                Label(wanted.label, systemImage: "camera.viewfinder")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.15), in: Capsule())
            }

            Menu {
                Button("Take photo", systemImage: "camera") { showingCamera = true }
                Button("Choose from Photos", systemImage: "photo.on.rectangle.angled") {
                    showingImporter = true
                }
            } label: {
                Label("Add photo", systemImage: "camera")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }

            let local = localPhotos
            let server = appState.serverPhotos(forQuestion: question.id)
            if !local.isEmpty || !server.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(local) { item in
                            LocalPhotoThumbnail(item: item)
                                .onTapGesture {
                                    if let data = try? appState.photoStore.data(for: item) {
                                        fullscreenPhoto = FullscreenPhoto(
                                            data: data,
                                            caption: "Local · \(item.kindRaw) · \(item.stateRaw)"
                                        )
                                    }
                                }
                        }
                        ForEach(server) { photo in
                            ServerPhotoThumbnail(photo: photo)
                                .onTapGesture {
                                    Task {
                                        if let data = await appState.ownerPhotoData(for: photo) {
                                            fullscreenPhoto = FullscreenPhoto(
                                                data: data,
                                                caption: "Uploaded · \(photo.kindRaw) · \(photo.lightRaw)"
                                            )
                                        }
                                    }
                                }
                        }
                    }
                }
            }
        }
    }

    /// The question's local photos for the strip (photo PRD 4.1): the
    /// pending and the sent ones; rejected ones are reviewed in Settings.
    private var localPhotos: [PhotoOutboxItem] {
        appState.localPhotos(forQuestion: question.id).filter { $0.state != .rejected }
    }

    // MARK: Submit

    /// The answer the submit would record, or `nil` when nothing is picked.
    private var resolvedAnswer: String? {
        if let selectedAnswer {
            return selectedAnswer
        }
        let trimmed = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var isReAnswer: Bool {
        previousAnswer?.isEmpty == false
    }

    private var submitBar: some View {
        Button {
            submit()
        } label: {
            HStack {
                if isSubmitting {
                    ProgressView()
                }
                Text(isReAnswer ? "Replace answer" : "Submit")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .disabled(resolvedAnswer == nil || isSubmitting)
        .padding(.horizontal)
        .padding(.bottom, 4)
        .background(.bar)
    }

    private func submit() {
        guard let answer = resolvedAnswer, !isSubmitting else { return }
        // Compute the next open *before* the answer is recorded: the pager
        // reorders its pages once it is in, so the id is the stable handle.
        let next = appState.nextOpenQuestionID(after: question.id)
        isSubmitting = true
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await appState.submitAnswer(
                question: question,
                answer: answer,
                comment: trimmedComment.isEmpty ? nil : trimmedComment
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            isSubmitting = false
            onAdvance(next)
        }
    }
}

/// One big tappable answer option (PRD 4.4: big Yes/No/Don't know, one per
/// choice option).
struct AnswerButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(title)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .font(.headline)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
