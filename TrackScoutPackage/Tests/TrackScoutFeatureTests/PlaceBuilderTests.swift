import Foundation
import Testing
@testable import TrackScoutFeature

struct PlaceBuilderTests {
    func dto(
        _ id: String,
        group: String = "gamma",
        page: Int = 1,
        order: Int = 1,
        lat: Double = 52.5,
        lon: Double = 13.4,
        building: String? = nil
    ) -> QuestionDTO {
        let building = building ?? "Building \(id)"
        return QuestionDTO(
            id: id, page: page, order: order, group: group, building: building,
            lat: lat, lon: lon, context: "", question: "Q \(id)", type: "text",
            options: [], images: []
        )
    }

    @Test func groupOrderComparator() {
        // Labels sort by their index in the project's `groups` array…
        let order = PlaceBuilder.groupOrder(["alpha", "beta"])
        #expect(order("alpha", "beta"))
        #expect(!order("beta", "alpha"))
        // …labels missing from the array sort last, ties alphabetically.
        #expect(order("beta", "zeta"))
        #expect(order("delta", "zeta"))
        #expect(!order("zeta", "delta"))
        #expect(order("alpha", "zeta"))
        // Case-insensitive for the alphabetical tie-break.
        #expect(order("Apple", "banana"))
        // Without an array: plain alphabetical.
        let alphabetical = PlaceBuilder.groupOrder()
        #expect(alphabetical("delta", "zeta"))
        #expect(!alphabetical("zeta", "delta"))
    }

    @Test func groupsByRoundedCoordinate() {
        // 52.523539 and 52.523541 both round to 52.52354 → one place.
        let a = dto("a", lat: 52.523539, lon: 13.413463)
        let b = dto("b", lat: 52.523541, lon: 13.413461)
        let c = dto("c", lat: 52.52351, lon: 13.413463)
        let places = PlaceBuilder.build(questions: [a, b, c])
        #expect(places.count == 2)
        let shared = places.first { $0.questionIDs.count == 2 }
        #expect(shared != nil)
        #expect(shared?.key == "52.52354,13.41346")
    }

    @Test func displayOrderIsGroupThenPageThenOrder() {
        let gamma1 = dto("gamma1", group: "gamma", page: 1, order: 1)
        let alphaLate = dto("alpha2", group: "alpha", page: 9, order: 9)
        let beta1 = dto("beta1", group: "beta", page: 1, order: 1)
        let alphaEarly = dto("alpha1", group: "alpha", page: 2, order: 5)
        let places = PlaceBuilder.build(
            questions: [gamma1, alphaLate, beta1, alphaEarly],
            groupOrder: PlaceBuilder.groupOrder(["alpha", "beta", "gamma"])
        )
        #expect(places.count == 1)
        #expect(places.first?.questionIDs == ["alpha1", "alpha2", "beta1", "gamma1"])
        // The place takes the coordinates and building of its first question.
        #expect(places.first?.building == "Building alpha1")
    }

    @Test func outputIsDeterministicRegardlessOfInputOrder() {
        let questions = (1...30).map {
            dto("q\($0)", group: $0.isMultiple(of: 3) ? "alpha" : "gamma",
                page: $0 % 7, order: $0 % 5,
                lat: 52.5 + Double($0 % 4) * 1e-6, lon: 13.4)
        }
        let forward = PlaceBuilder.build(questions: questions)
        let backward = PlaceBuilder.build(questions: questions.reversed())
        #expect(forward == backward)
    }
}
