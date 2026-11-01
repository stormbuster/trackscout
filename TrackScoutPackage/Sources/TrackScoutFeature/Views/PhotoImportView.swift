import CoreLocation
import PhotosUI
import SwiftUI
import UIKit

/// Import from the photo library (photo PRD 5.3): a `PhotosPicker`, the
/// photo's EXIF date and location, the "Taken here?" gate when the EXIF
/// point is more than 150 m from the chosen place, and the JPEG conversion
/// into the outbox.
///
/// The picker runs out of process, so no library-read permission is asked;
/// the user's selection *is* the consent.
struct PhotoImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let questionID: String?
    let placeKey: String?
    let building: String
    var kind: PhotoKind
    /// `nil` = the light is computed from the sun; else the user's override.
    var lightOverride: LightKind?

    @State private var selection: PhotosPickerItem?
    @State private var importedData: Data?
    @State private var exifCoordinate: CLLocationCoordinate2D?
    @State private var takenDate: Date?
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showingTakenHere = false

    init(
        questionID: String? = nil,
        placeKey: String? = nil,
        building: String,
        kind: PhotoKind = .other,
        lightOverride: LightKind? = nil
    ) {
        self.questionID = questionID
        self.placeKey = placeKey
        self.building = building
        self.kind = kind
        self.lightOverride = lightOverride
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    PhotosPicker(
                        selection: $selection,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label("Choose a photo", systemImage: "photo.on.rectangle.angled")
                    }
                    if let importedData, let image = UIImage(data: importedData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if let takenDate {
                        LabeledContent("Taken", value: takenDate, format: .dateTime.day().month().year().hour().minute())
                    }
                    LabeledContent("Location") {
                        Text(locationDescription)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        if appState.needsTakenHereConfirmation(
                            exifCoordinate: exifCoordinate,
                            placeKey: placeKey
                        ) {
                            showingTakenHere = true
                        } else {
                            attach(takenHere: false)
                        }
                    } label: {
                        if isImporting {
                            ProgressView()
                        } else {
                            Text("Attach photo")
                        }
                    }
                    .disabled(importedData == nil || isImporting)

                    if let importError {
                        Text(importError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Choose from Photos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog(
                "Taken here?",
                isPresented: $showingTakenHere,
                titleVisibility: .visible
            ) {
                Button("Yes, it was taken at \(building)") { attach(takenHere: true) }
                Button("No, use the photo's location") { attach(takenHere: false) }
            } message: {
                Text("The photo's position is more than 150 m from the chosen place.")
            }
            .task(id: selection) {
                await loadSelection()
            }
        }
    }

    private var locationDescription: String {
        if let exifCoordinate {
            return exifCoordinate.latitude.formatted(.number.precision(.fractionLength(5)))
                + ", "
                + exifCoordinate.longitude.formatted(.number.precision(.fractionLength(5)))
        }
        if let placeKey {
            return "From the chosen place (no EXIF location)"
        }
        return "Unknown"
    }

    /// Loads the chosen item and reads its EXIF (photo PRD 5.3).
    private func loadSelection() async {
        guard let selection else { return }
        do {
            guard let data = try await selection.loadTransferable(type: Data.self) else {
                importError = "The photo could not be read."
                return
            }
            // The original bytes are kept: `importPhoto` does the one JPEG
            // re-encode (photo PRD 5.3), so the preview and the gate read
            // the same metadata without a double compression.
            importedData = data
            exifCoordinate = PhotoEncoder.exifCoordinate(from: data)
            takenDate = PhotoEncoder.exifDate(from: data)
            importError = nil
        } catch {
            importedData = nil
            exifCoordinate = nil
            takenDate = nil
            importError = error.localizedDescription
        }
    }

    /// Attaches the photo to the outbox. `takenHere` is the answer to the
    /// "Taken here?" prompt (only asked when the EXIF point is more than
    /// 150 m from the place).
    private func attach(takenHere: Bool) {
        guard let importedData else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                try await appState.importPhoto(
                    data: importedData,
                    questionID: questionID,
                    placeKey: placeKey,
                    building: building,
                    kind: kind,
                    lightOverride: lightOverride,
                    takenHereConfirmed: takenHere
                )
                dismiss()
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}
