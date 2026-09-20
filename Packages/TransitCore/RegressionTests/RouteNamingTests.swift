import XCTest
@testable import TransitCore

final class RouteNamingTests: XCTestCase {
    func testUnnamedMappedRouteDoesNotInventEndpoints() {
        XCTAssertNil(RouteNaming.headline(name: nil, from: nil, to: nil))
        XCTAssertNil(RouteNaming.headline(name: "  ", from: "?", to: "\n"))
        XCTAssertEqual(RouteNaming.headline(name: nil, from: "Zürich Landesmuseum", to: nil),
                       "From Zürich Landesmuseum")
        XCTAssertEqual(RouteNaming.headline(name: nil, from: nil, to: "Zürichhorn"),
                       "To Zürichhorn")
        XCTAssertEqual(RouteNaming.headline(name: nil, from: "Zürich Landesmuseum", to: "Zürichhorn"),
                       "Zürich Landesmuseum → Zürichhorn")
        XCTAssertEqual(RouteNaming.headline(name: "Limmatschiff", from: nil, to: nil),
                       "Limmatschiff")
    }

    func testAllScreenshotServicePrefixesAreRemoved() {
        let cases: [(String, String, String)] = [
            ("GPX", "GoldenPass Express: Interlaken Ost => Zweisimmen", "Interlaken Ost → Zweisimmen"),
            ("GPX", "GoldenPass Express: Zweisimmen → Interlaken Ost", "Zweisimmen → Interlaken Ost"),
            ("IC8", "IC 8: Romanshorn => Brig", "Romanshorn → Brig"),
            ("IC 6", "IC 6: Basel SBB => Brig", "Basel SBB → Brig"),
            ("RE1", "RE1: Bern => Domodossola", "Bern → Domodossola"),
            ("EC", "EC: Basel SBB => Milano Centrale", "Basel SBB → Milano Centrale"),
            ("IC 61", "IC 61: Interlaken Ost => Basel SBB", "Interlaken Ost → Basel SBB"),
            ("IC81", "IC 81: Interlaken Ost => Romanshorn", "Interlaken Ost → Romanshorn")
        ]
        for (ref, name, expected) in cases {
            XCTAssertEqual(RouteNaming.trim(name, ref: ref), expected, name)
        }
    }

    func testRuleDoesNotDependOnKnownBrandsOrTransportMode() {
        XCTAssertEqual(RouteNaming.trim("New Scenic Service: A -> B → C", ref: "NSS"), "A → B → C")
        XCTAssertEqual(RouteNaming.trim("Regional bus: A=>B", ref: "42"), "A → B")
        XCTAssertEqual(RouteNaming.trim("Tram 8: Zoo → Hardturm", ref: "8"), "Zoo → Hardturm")
        XCTAssertEqual(RouteNaming.trim("Unnamed service: A ↔ B", ref: ""), "A ↔ B")
    }

    func testReferenceOnlyFallbackIgnoresSpacingAndCase() {
        XCTAssertEqual(RouteNaming.trim(" IC  8 : Brig ", ref: "ic8"), "Brig")
        XCTAssertEqual(RouteNaming.trim("Tram 8: Zoo", ref: "8"), "Zoo")
        XCTAssertEqual(RouteNaming.trim("Tram 18: Zoo", ref: "8"), "Tram 18: Zoo")
    }

    func testUnprefixedRoutesAndNonRouteColonsSurvive() {
        XCTAssertEqual(RouteNaming.trim("Basel SBB => Brig", ref: "IC6"), "Basel SBB → Brig")
        XCTAssertEqual(RouteNaming.trim("Night service: request stop", ref: "N1"), "Night service: request stop")
        XCTAssertEqual(RouteNaming.trim("Basel → Museum: main entrance", ref: "8"), "Basel → Museum: main entrance")
        XCTAssertEqual(RouteNaming.trim("IC 8:", ref: "IC8"), "IC 8:")
        XCTAssertEqual(RouteNaming.trim("GoldenPass Express", ref: "GPX"), "GoldenPass Express")
    }

    func testCountrySuffixesAndFragmentParenthesesAreNotDisplayed() {
        XCTAssertEqual(StopNaming.display("Basel Bad Bf (D)"), "Basel Bad Bf")
        XCTAssertEqual(StopNaming.display("Domodossola (I)"), "Domodossola")
        XCTAssertEqual(StopNaming.display("(Basel Bad Bf)"), "Basel Bad Bf")
        XCTAssertEqual(StopNaming.display("Müllheim (Baden)"), "Müllheim (Baden)")
        XCTAssertEqual(StopNaming.display("Frankfurt (Main) Hbf"), "Frankfurt (Main) Hbf")
        XCTAssertEqual(
            StopNaming.displayRoute("(Basel Bad Bf) → Müllheim (Baden)"),
            "Basel Bad Bf → Müllheim (Baden)"
        )
        XCTAssertEqual(
            RouteNaming.trim(
                "ICE 60: (Basel Bad Bf =>) Karlsruhe => München", ref: "ICE 60"
            ),
            "Basel Bad Bf → Karlsruhe → München"
        )
        XCTAssertEqual(
            StopNaming.displayRoute(
                RouteNaming.trim(
                    "ICE 60: München => Karlsruhe (=> Basel Bad Bf)", ref: "ICE 60"
                )
            ),
            "München → Karlsruhe → Basel Bad Bf"
        )
    }

    func testBoardDestinationsMatchAcrossFeeds() {
        XCTAssertTrue(StopNaming.sameBoardDestination("Weissenbühl", "Bern, Weissenbühl"))
        XCTAssertTrue(StopNaming.sameBoardDestination("Bern Bahnhof", "Bern, Bahnhof"))
        XCTAssertTrue(StopNaming.sameBoardDestination("Domodossola (I)", "Domodossola"))
        XCTAssertTrue(StopNaming.sameBoardDestination("Bern", "Bern"))
        XCTAssertFalse(StopNaming.sameBoardDestination("Bern", "Bern, Bollwerk"))
        XCTAssertEqual(StopNaming.localDestination("Bern, Weissenbühl"), "Weissenbühl")
        XCTAssertEqual(StopNaming.localDestination("Weissenbühl"), "Weissenbühl")
    }
}
