import Foundation

/// Distance bands driving the Nearby list's ordering (PRD 4.3): fixed,
/// cumulative radii with the closest places first, re-sorted live on every
/// location update as the user walks.
///
/// To keep rows from flapping while the phone jitters, the sort key
/// quantizes each distance into a 5 m bucket; two places sharing a bucket
/// keep their previous display order (the caller supplies unique
/// `previousRanks`), which is a valid strict-weak ordering.
public enum DistanceBands {
    /// Cumulative upper bounds in meters: ≤10, 10–50, 50–100, 100–500, ≤1 km,
    /// then everything beyond 1 km.
    public static let upperBounds: [Double] = [10, 50, 100, 500, 1000]

    /// Width of one quantized-distance sort bucket, in meters.
    public static let bucketSize: Double = 5

    /// Pseudo-band for rows without a fix; sorts after every real band.
    public static var noFixBand: Int { upperBounds.count + 1 }

    /// The band containing `distance` (meters); `nil` (no fix) sorts last.
    public static func index(for distance: Double?) -> Int {
        guard let distance else { return noFixBand }
        for (index, bound) in upperBounds.enumerated() where distance <= bound {
            return index
        }
        return upperBounds.count
    }

    /// The 5 m bucket of `distance`; the quantized key that damps jitter.
    public static func bucket(for distance: Double?) -> Int {
        guard let distance else { return .max }
        return Int(distance / bucketSize)
    }

    /// A short header for a band, e.g. "Within 10 m" or "1 km and beyond".
    public static func label(for band: Int) -> String {
        switch band {
        case 0: return "Within 10 m"
        case 1: return "10 – 50 m"
        case 2: return "50 – 100 m"
        case 3: return "100 – 500 m"
        case 4: return "500 m – 1 km"
        case 5: return "1 km and beyond"
        case noFixBand: return "No position yet"
        default: return "Far away"
        }
    }

    /// Indices of `distances` in display order: band, then 5 m bucket, then
    /// `previousRanks`. Rows sharing a band and bucket keep the previous
    /// display order, so sub-bucket movement does not shuffle the list.
    ///
    /// `previousRanks` must be pairwise distinct (e.g. last display position,
    /// with a large unique fallback for rows that are new this pass).
    public static func orderedIndices(distances: [Double?], previousRanks: [Int]) -> [Int] {
        precondition(distances.count == previousRanks.count, "parallel arrays")
        func key(_ i: Int) -> (Int, Int, Int) {
            (index(for: distances[i]), bucket(for: distances[i]), previousRanks[i])
        }
        return distances.indices.sorted { key($0) < key($1) }
    }
}
