import Foundation

/// A place computed from the questions, ready to be stored.
public struct BuiltPlace: Hashable, Sendable {
    public let key: String
    public let lat: Double
    public let lon: Double
    public let building: String
    public let questionIDs: [String] // in display order
}

/// Groups questions into places (PRD 4.2: round lat/lon to 5 decimals) and
/// orders the questions the way the UI shows them: by the project's order of
/// free-form `group` labels (the questions file's optional `groups` array;
/// alphabetical when it is absent), then `page`, then `order`.
public enum PlaceBuilder {
    /// A strict-weak-ordering comparator for free-form group labels. A label
    /// sorts by its index in `groups` (the display order the project intends);
    /// labels missing from the array sort last; ties — and a `nil` array —
    /// fall back to a case-insensitive alphabetical order.
    public static func groupOrder(_ groups: [String]? = nil) -> (String, String) -> Bool {
        let rank = { (label: String) -> Int in groups?.firstIndex(of: label) ?? .max }
        return { lhs, rhs in
            let left = rank(lhs), right = rank(rhs)
            if left != right { return left < right }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    public static func build(
        questions: [QuestionDTO],
        groupOrder: (String, String) -> Bool = groupOrder()
    ) -> [BuiltPlace] {
        var byPlace: [String: [QuestionDTO]] = [:]
        for question in questions {
            let key = Geo.key(lat: question.lat, lon: question.lon)
            byPlace[key, default: []].append(question)
        }
        let places = byPlace.map { key, questions in
            let sorted = questions.sorted { lhs, rhs in
                let left = groupOrder(lhs.group, rhs.group)
                let right = groupOrder(rhs.group, lhs.group)
                if left && !right { return true }
                if right && !left { return false }
                if lhs.page != rhs.page { return lhs.page < rhs.page }
                return lhs.order < rhs.order
            }
            guard let first = sorted.first else { return BuiltPlace(key: key, lat: 0, lon: 0, building: "", questionIDs: []) }
            return BuiltPlace(
                key: key,
                lat: first.lat,
                lon: first.lon,
                building: first.building,
                questionIDs: sorted.map(\.id)
            )
        }
        return places.sorted { $0.key < $1.key } // deterministic
    }
}
