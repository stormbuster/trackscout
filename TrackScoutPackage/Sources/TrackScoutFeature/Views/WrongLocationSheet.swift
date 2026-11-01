import SwiftUI
import UIKit

/// The "This isn't here" report (PRD 4.4): submits through the same answer
/// POST with `answer` = `WRONG LOCATION` and a comment of the form
/// `"<note> | at lat,lon ±acc m"` — it feeds the location-corrections pass
/// on the Windows side.
struct WrongLocationSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let question: Question
    /// Same contract as `QuestionPageView.onAdvance` (the report *is* an
    /// answer, so the pager advances exactly as after a normal submit).
    let onAdvance: (String?) -> Void

    @State private var note = ""
    @State private var useMyPosition = true
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("The business or feature is not where this question points. Submitting records a WRONG LOCATION answer with your report, so the location can be corrected.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Report") {
                    TextField("What is actually here? (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                    Toggle("Use my current position", isOn: $useMyPosition)
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            if isSubmitting {
                                ProgressView()
                            }
                            Text("Submit report")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!canSubmit || isSubmitting)
                }
            }
            .navigationTitle("This isn't here")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedNote.isEmpty
            || (useMyPosition && appState.location.lastLocation != nil)
    }

    private func submit() {
        guard canSubmit, !isSubmitting else { return }
        // As with normal submits: the next open is resolved before the
        // answer lands, then the pager reorders and advances.
        let next = appState.nextOpenQuestionID(after: question.id)
        isSubmitting = true
        let comment = buildComment()
        Task {
            await appState.submitAnswer(
                question: question,
                answer: AnswerValues.wrongLocation,
                comment: comment
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            onAdvance(next)
        }
    }

    /// `"<note> | at lat,lon ±acc m"` (PRD 4.4); the parts are dropped when
    /// empty, so a note-only report is just the note.
    private func buildComment() -> String {
        var parts: [String] = []
        if !trimmedNote.isEmpty {
            parts.append(trimmedNote)
        }
        if useMyPosition, let location = appState.location.lastLocation {
            let coordinate = location.coordinate
            let accuracy = max(1, Int(location.horizontalAccuracy.rounded()))
            parts.append(
                String(format: "at %.5f,%.5f ±%d m", coordinate.latitude, coordinate.longitude, accuracy)
            )
        }
        return parts.joined(separator: " | ")
    }
}
