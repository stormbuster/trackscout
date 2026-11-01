// SPDX-License-Identifier: MIT
import Foundation

/// The bundled demo questions file (§8.2 "Use demo data"): a fully synthetic
/// sample on a public landmark street, shipped inside `TrackScoutFeature.bundle`
/// and decoded on demand. It lets the app run without any server at all —
/// answers and photos behave offline exactly as `SyncEngine.demoSync()`
/// describes. Returns `nil` only if the resource is missing from the bundle,
/// which would be a packaging bug, not a user-facing failure.
public enum DemoData {
    public static func questionsDoc() -> QuestionsDoc? {
        guard
            let url = Bundle.module.url(forResource: "demo_questions", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? JSONDecoder().decode(QuestionsDoc.self, from: data)
    }
}
