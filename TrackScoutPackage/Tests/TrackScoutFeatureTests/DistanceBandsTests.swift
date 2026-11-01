import Foundation
import Testing
@testable import TrackScoutFeature

struct DistanceBandsTests {
    @Test func bandIndexBoundaries() {
        #expect(DistanceBands.index(for: 0) == 0)
        #expect(DistanceBands.index(for: 9.9) == 0)
        #expect(DistanceBands.index(for: 10) == 0) // "within 10 m" is inclusive
        #expect(DistanceBands.index(for: 10.1) == 1)
        #expect(DistanceBands.index(for: 49.9) == 1)
        #expect(DistanceBands.index(for: 50) == 1)
        #expect(DistanceBands.index(for: 50.1) == 2)
        #expect(DistanceBands.index(for: 100) == 2)
        #expect(DistanceBands.index(for: 100.1) == 3)
        #expect(DistanceBands.index(for: 500) == 3)
        #expect(DistanceBands.index(for: 500.1) == 4)
        #expect(DistanceBands.index(for: 1000) == 4)
        #expect(DistanceBands.index(for: 1000.1) == 5)
        #expect(DistanceBands.index(for: 50_000) == 5)
        #expect(DistanceBands.index(for: nil) == DistanceBands.noFixBand)
    }

    @Test func labels() {
        #expect(DistanceBands.label(for: 0) == "Within 10 m")
        #expect(DistanceBands.label(for: 1) == "10 – 50 m")
        #expect(DistanceBands.label(for: 2) == "50 – 100 m")
        #expect(DistanceBands.label(for: 3) == "100 – 500 m")
        #expect(DistanceBands.label(for: 4) == "500 m – 1 km")
        #expect(DistanceBands.label(for: 5) == "1 km and beyond")
        #expect(DistanceBands.label(for: DistanceBands.noFixBand) == "No position yet")
    }

    @Test func bucketQuantization() {
        #expect(DistanceBands.bucket(for: 9.9) == 1)
        #expect(DistanceBands.bucket(for: 10) == 2)
        #expect(DistanceBands.bucket(for: 14.9) == 2)
        #expect(DistanceBands.bucket(for: 15) == 3)
        #expect(DistanceBands.bucket(for: 1000) == 200)
        #expect(DistanceBands.bucket(for: nil) == .max)
    }

    @Test func orderedIndicesBandsFirst() {
        // 510 m, 8 m, 20 m → 8 m, 20 m, 510 m.
        let order = DistanceBands.orderedIndices(distances: [510, 8, 20], previousRanks: [0, 1, 2])
        #expect(order == [1, 2, 0])
    }

    @Test func orderedIndicesStableWithinBucket() {
        // 12 m and 12.8 m share one 5 m bucket: the previous display order
        // decides, in both directions.
        #expect(
            DistanceBands.orderedIndices(distances: [12.8, 12.0], previousRanks: [0, 1])
                == [0, 1]
        )
        #expect(
            DistanceBands.orderedIndices(distances: [12.8, 12.0], previousRanks: [1, 0])
                == [1, 0]
        )
    }

    @Test func orderedIndicesNilGoesLast() {
        let order = DistanceBands.orderedIndices(distances: [3, nil, 200], previousRanks: [0, 1, 2])
        #expect(order == [0, 2, 1])
    }

    @Test func unchangedDistancesReproduceTheOrder() {
        // The no-flapping invariant: sorting the same distances again, with
        // the previous display ranks, must yield the same display order.
        let distances: [Double?] = [23.0, 8.0, 12.0, 410.0, 23.4]
        let order = DistanceBands.orderedIndices(
            distances: distances, previousRanks: [0, 1, 2, 3, 4])
        // Rebuild the ranks from the display order and sort again.
        var newRanks = Array(repeating: 0, count: distances.count)
        for (position, index) in order.enumerated() {
            newRanks[index] = position
        }
        #expect(
            DistanceBands.orderedIndices(distances: distances, previousRanks: newRanks)
                == order
        )
    }
}
