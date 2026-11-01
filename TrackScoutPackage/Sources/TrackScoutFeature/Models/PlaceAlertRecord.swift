import Foundation
import SwiftData

/// When a place was last alerted, for the 7-day per-place repeat gate.
@Model
public final class PlaceAlertRecord {
    @Attribute(.unique) public var placeKey: String
    public var lastAlertedAt: Date

    public init(placeKey: String, lastAlertedAt: Date = .now) {
        self.placeKey = placeKey
        self.lastAlertedAt = lastAlertedAt
    }
}
