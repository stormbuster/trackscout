import CoreLocation
import Foundation
import Testing
@testable import TrackScoutFeature

struct MonitoredPlaceSelectorTests {
    private let center = CLLocationCoordinate2D(latitude: 52.5, longitude: 13.4)

    /// Places on an east-west line ~65 m apart (0.001° longitude at this latitude).
    func place(_ i: Int, isOpen: Bool = true) -> MonitoredPlace {
        MonitoredPlace(key: "p\(i)", lat: 52.5, lon: 13.4 + Double(i) * 0.001, isOpen: isOpen)
    }

    @Test func selectsAtMostTwenty() {
        let picked = MonitoredPlaceSelector.select((0..<25).map { place($0) }, center: center)
        #expect(picked.count == 20)
    }

    @Test func nearestFirst() {
        let picked = MonitoredPlaceSelector.select((0..<25).map { place($0) }, center: center)
        #expect(picked.first?.key == "p0")
        #expect(picked.last?.key == "p19")
    }

    @Test func closedPlacesAreNeverMonitored() {
        // p0 is closest but closed; it must not take a slot.
        let places = [place(0, isOpen: false), place(1), place(2, isOpen: false), place(3)]
        let picked = MonitoredPlaceSelector.select(places, center: center)
        #expect(picked.map(\.key) == ["p1", "p3"])
    }

    @Test func allIfFewerThanMaxAreOpen() {
        let places = (0..<5).map { place($0) } + [place(5, isOpen: false), place(6, isOpen: false)]
        let picked = MonitoredPlaceSelector.select(places, center: center)
        #expect(picked.count == 5)
    }

    @Test func customMaximum() {
        let picked = MonitoredPlaceSelector.select((0..<25).map { place($0) }, center: center, max: 5)
        #expect(picked.map(\.key) == ["p0", "p1", "p2", "p3", "p4"])
    }
}
