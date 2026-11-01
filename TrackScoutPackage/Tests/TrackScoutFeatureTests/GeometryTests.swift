import CoreLocation
import Foundation
import Testing
@testable import TrackScoutFeature

struct GeometryTests {
    @Test func round5() {
        #expect(Geo.round5(52.52353999) == 52.52354)
        #expect(Geo.round5(13.413463) == 13.41346)
        #expect(Geo.round5(1.0) == 1.0)
    }

    @Test func key() {
        #expect(Geo.key(lat: 52.523539, lon: 13.413463) == "52.52354,13.41346")
        #expect(Geo.key(lat: 52.5, lon: 13.4) == "52.50000,13.40000")
    }

    @Test func coordinateForKey() {
        let c = Geo.coordinate(forKey: "52.52354,13.41346")
        #expect(c?.latitude == 52.52354)
        #expect(c?.longitude == 13.41346)
        #expect(Geo.coordinate(forKey: "garbage") == nil)
        #expect(Geo.coordinate(forKey: "1,2,3") == nil)
        #expect(Geo.coordinate(forKey: "52.5") == nil)
    }

    @Test func distance() {
        let a = CLLocationCoordinate2D(latitude: 52.0, longitude: 13.0)
        let b = CLLocationCoordinate2D(latitude: 53.0, longitude: 13.0)
        let d = Geo.distance(from: a, to: b)
        // 1 degree of latitude is ~111.195 km.
        #expect((111_000...111_400).contains(d))
        #expect(Geo.distance(from: a, to: a) == 0)
        #expect(Geo.distance(from: b, to: a) == d) // symmetric
    }

    @Test func bearing() {
        func c(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        #expect(Geo.bearing(from: c(0, 0), to: c(1, 0)) == 0)   // north
        #expect(Geo.bearing(from: c(0, 0), to: c(0, 1)) == 90)  // east
        #expect(Geo.bearing(from: c(0, 0), to: c(-1, 0)) == 180) // south
        #expect(abs(Geo.bearing(from: c(0, 0), to: c(0, -1)) - 270) < 1e-9) // west
    }
}
