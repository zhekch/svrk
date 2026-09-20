import XCTest
@testable import TransitCore

final class ReconcileReplacementTests: XCTestCase {
    func testUnknownProductStillRequiresCompleteBookedRouteAndMatchingMode() {
        let original = ICEReplacementFixture.original()
        let replacement = ICEReplacementFixture.original()
        replacement.extra = true
        replacement.line = "ext"
        replacement.stops[1].ref = "ch:1:sloid:10:21:31"
        XCTAssertTrue(Reconcile.isPlatformReplacement(replacement, of: original))
        replacement.line = "IR"
        XCTAssertFalse(Reconcile.isPlatformReplacement(replacement, of: original))
        replacement.line = "ext"
        replacement.mode = .bus
        XCTAssertFalse(Reconcile.isPlatformReplacement(replacement, of: original))
        replacement.mode = .train
        replacement.stops[3].sched! += 600
        XCTAssertFalse(Reconcile.isPlatformReplacement(replacement, of: original))
        replacement.stops.remove(at: 3)
        XCTAssertFalse(Reconcile.isPlatformReplacement(replacement, of: original))
    }

    private func call(ref: String, dep: Timestamp, sched: Timestamp? = nil) -> Call {
        Call(
            key: ref, ref: ref, name: ref, lat: 46.95, lon: 7.44,
            arr: dep, dep: dep, sched: sched ?? dep
        )
    }

    private func journey(id: String, extra: Bool, cancelled: Bool, stops: [Call]) -> Journey {
        Journey(
            id: id, mode: .train, category: "S", line: "S1", number: "1",
            operatorName: nil, operatorFull: nil,
            to: stops.last?.name, from: stops[0].name,
            delay: nil, start: stops[0].dep, end: stops[stops.count - 1].arr,
            complete: true, monitored: true, cancelled: cancelled,
            source: "test", stops: stops, extra: extra
        )
    }

    func testDelayedPlatformChangeIsTheSameTrain() {
        let booked = 1_000_000
        let original = journey(id: "tt", extra: false, cancelled: true, stops: [
            call(ref: "ch:1:sloid:7000:0:7", dep: booked),
            call(ref: "ch:1:sloid:7100:0:4", dep: booked + 1_800),
        ])
        let extra = journey(id: "add", extra: true, cancelled: false, stops: [
            call(ref: "ch:1:sloid:7000:0:5", dep: booked + 8 * 60, sched: booked),
            call(ref: "ch:1:sloid:7100:0:4", dep: booked + 1_800 + 8 * 60, sched: booked + 1_800),
        ])
        XCTAssertTrue(Reconcile.isPlatformReplacement(extra, of: original))
    }

    func testOnTimeSamePlatformsAreNotAReplacement() {
        let booked = 1_000_000
        let original = journey(id: "tt", extra: false, cancelled: true, stops: [
            call(ref: "ch:1:sloid:7000:0:7", dep: booked),
            call(ref: "ch:1:sloid:7100:0:4", dep: booked + 1_800),
        ])
        let extra = journey(id: "add", extra: true, cancelled: false, stops: [
            call(ref: "ch:1:sloid:7000:0:7", dep: booked),
            call(ref: "ch:1:sloid:7100:0:4", dep: booked + 1_800),
        ])
        XCTAssertFalse(Reconcile.isPlatformReplacement(extra, of: original))
    }

    func testExceptionalStopDoesNotBreakReplacementIdentity() {
        let booked = 1_000_000
        let original = journey(id: "tt", extra: false, cancelled: false, stops: [
            call(ref: "ch:1:sloid:7000", dep: booked),
            call(ref: "ch:1:sloid:7003", dep: booked + 600),
            call(ref: "ch:1:sloid:7100", dep: booked + 1_800),
        ])
        let extra = journey(id: "add", extra: true, cancelled: false, stops: [
            call(ref: "ch:1:sloid:7000", dep: booked + 25 * 60, sched: booked),
            call(ref: "ch:1:sloid:6161", dep: booked + 25 * 60 + 240, sched: booked + 240),
            call(ref: "ch:1:sloid:7003", dep: booked + 600 + 25 * 60, sched: booked + 600),
            call(ref: "ch:1:sloid:7100", dep: booked + 1_800 + 25 * 60, sched: booked + 1_800),
        ])
        XCTAssertTrue(Reconcile.isPlatformReplacement(extra, of: original))
    }

    func testLaterExtraWithChangedPlatformNeedsMatchingBookedTimes() {
        let booked = 1_000_000
        let original = journey(id: "tt", extra: false, cancelled: true, stops: [
            call(ref: "ch:1:sloid:7000:0:7", dep: booked),
            call(ref: "ch:1:sloid:7100:0:4", dep: booked + 1_800),
        ])
        let extra = journey(id: "add", extra: true, cancelled: false, stops: [
            call(ref: "ch:1:sloid:7000:0:5", dep: booked + 10 * 60),
            call(ref: "ch:1:sloid:7100:0:4", dep: booked + 1_800 + 10 * 60),
        ])
        XCTAssertFalse(Reconcile.isPlatformReplacement(extra, of: original))
    }

    func testNextHourWorkingIsNotAReplacement() {
        let booked = 1_000_000
        let original = journey(id: "tt", extra: false, cancelled: false, stops: [
            call(ref: "ch:1:sloid:7000:0:7", dep: booked),
            call(ref: "ch:1:sloid:7100:0:4", dep: booked + 1_800),
        ])
        let extra = journey(id: "add", extra: true, cancelled: false, stops: [
            call(ref: "ch:1:sloid:7000:0:7", dep: booked + 38 * 60),
            call(ref: "ch:1:sloid:7100:0:4", dep: booked + 1_800 + 38 * 60),
        ])
        XCTAssertFalse(Reconcile.isPlatformReplacement(extra, of: original))
    }
}
