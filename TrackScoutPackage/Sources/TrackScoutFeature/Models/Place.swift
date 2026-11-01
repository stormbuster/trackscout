import Foundation
import SwiftData

/// A "place": all questions sharing the same point, rounded to 5 decimal
/// places (PRD 4.2). Places are derived data — rebuilt wholesale from the
/// questions on every sync, never edited by hand.
@Model
public final class Place {
    @Attribute(.unique) public var key: String // "lat,lon" rounded to 5 dp
    public var lat: Double
    public var lon: Double
    /// Display name; several questions at one place share one facade.
    public var building: String
    /// Question ids in display order (group importance, then page, then order).
    public var questionIDs: [String]

    public init(key: String, lat: Double, lon: Double, building: String, questionIDs: [String]) {
        self.key = key
        self.lat = lat
        self.lon = lon
        self.building = building
        self.questionIDs = questionIDs
    }
}
