import XCTest
@testable import TransitActivity

final class TripActivityTests: XCTestCase {
    func testDepartureCaptionNamesTheStation() {
        XCTAssertEqual(
            TripActivityFormat.caption(kind: .departure, station: "Spiez"),
            "Departure from Spiez"
        )
    }

    func testArrivalCaptionNamesTheStation() {
        XCTAssertEqual(
            TripActivityFormat.caption(kind: .arrival, station: "Thun"),
            "Arrival to Thun"
        )
    }

    func testDepartureHeadlineIsTheDestination() {
        XCTAssertEqual(
            TripActivityFormat.headline(kind: .departure, station: "Spiez", destination: "Basel SBB"),
            "Basel SBB"
        )
    }

    func testArrivalHeadlineIsTheTrainDestination() {
        XCTAssertEqual(
            TripActivityFormat.headline(kind: .arrival, station: "Mülenen", destination: "Bern"),
            "Bern"
        )
    }

    func testTrainDelayIsSilentBelowThreeMinutes() {
        XCTAssertNil(TripActivityFormat.delayText(minutes: 2, mode: "train"))
        XCTAssertEqual(TripActivityFormat.delayText(minutes: 3, mode: "train"), "+3")
    }

    func testBusDelayIsShownFromTwoMinutes() {
        XCTAssertNil(TripActivityFormat.delayText(minutes: 1, mode: "bus"))
        XCTAssertEqual(TripActivityFormat.delayText(minutes: 2, mode: "bus"), "+2")
    }

    func testPresencePhrasing() {
        XCTAssertEqual(
            TripActivityFormat.presence(currentStop: "Spiez", atStop: true),
            "Currently at Spiez"
        )
        XCTAssertEqual(
            TripActivityFormat.presence(currentStop: "Thun", atStop: false),
            "Next stop Thun"
        )
        XCTAssertNil(TripActivityFormat.presence(currentStop: nil, atStop: false))
        XCTAssertNil(TripActivityFormat.presence(currentStop: "", atStop: true))
    }

    func testClockIsTwentyFourHour() {
        let date = Calendar.current.date(bySettingHour: 13, minute: 6, second: 0, of: Date())!
        XCTAssertEqual(TripActivityFormat.clock(date), "13:06")
    }

    func testRemainingPhraseIsWholeMinutes() {
        XCTAssertEqual(TripActivityFormat.remainingPhrase(minutes: 9), "in 9 min")
        XCTAssertEqual(TripActivityFormat.remainingPhrase(minutes: 0), "now")
        XCTAssertEqual(TripActivityFormat.remainingPhrase(minutes: -1), "now")
        XCTAssertEqual(TripActivityFormat.remainingPhrase(minutes: 72), "in 1 hr")
        XCTAssertEqual(TripActivityFormat.remainingPhrase(minutes: 149), "in 2 hr")
        XCTAssertEqual(TripActivityFormat.remainingPhrase(minutes: 150), "in 3 hr")
        XCTAssertEqual(TripActivityFormat.remainingPhrase(minutes: 154), "in 3 hr")
        XCTAssertEqual(TripActivityFormat.compactRemaining(minutes: 9), "9 min")
        let parts = TripActivityFormat.remainingParts(minutes: 8)
        XCTAssertEqual(parts.lead, "in")
        XCTAssertEqual(parts.value, "8 min")
        XCTAssertEqual(TripActivityFormat.remainingParts(minutes: 0).lead, nil)
        XCTAssertEqual(TripActivityFormat.remainingParts(minutes: 0).value, "now")
    }

    func testRemainingMinutesFollowsThePrintedClock() {
        let calendar = Calendar.current
        func date(_ hour: Int, _ minute: Int, _ second: Int) -> Date {
            calendar.date(from: DateComponents(
                year: 2026, month: 9, day: 11, hour: hour, minute: minute, second: second
            ))!
        }
        let expected = date(15, 30, 40)
        XCTAssertEqual(TripActivityFormat.remainingMinutes(until: expected, from: date(15, 7, 0)), 23)
        XCTAssertEqual(TripActivityFormat.remainingMinutes(until: expected, from: date(15, 7, 40)), 23)
        XCTAssertEqual(TripActivityFormat.remainingMinutes(until: expected, from: date(15, 7, 59)), 23)
        XCTAssertEqual(TripActivityFormat.remainingMinutes(until: expected, from: date(15, 8, 0)), 22)
        XCTAssertEqual(TripActivityFormat.clock(expected), "15:30")
    }

    @available(macOS 15.0, iOS 18.0, *)
    func testSystemCountdownKeepsMinuteOnlyPhrasingWithoutActivityUpdates() {
        let minute = Date(timeIntervalSince1970: 1_800_000_000)
        let expected = minute.addingTimeInterval(36 * 60 + 51)
        let style = TripActivityFormat.countdownStyle(until: expected)
        XCTAssertEqual(TripActivityFormat.countdownEnd(expected), minute.addingTimeInterval(36 * 60))

        // The anchor stays unchanged as the system clock moves, including while locked.
        for (elapsed, text) in [(0.0, "in 36 min"), (9, "in 36 min"), (59.9, "in 36 min"),
                                (60, "in 35 min"), (35 * 60 + 59.9, "in 1 min")] {
            XCTAssertEqual(style.format(minute.addingTimeInterval(elapsed)), text)
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    func testSystemCountdownStaleBoundaryAndDelayedTime() {
        let minute = Date(timeIntervalSince1970: 1_800_000_000)
        let expected = minute.addingTimeInterval(36 * 60 + 51)
        let end = TripActivityFormat.countdownEnd(expected)
        XCTAssertEqual(TripActivityFormat.remainingMinutes(until: expected, from: end), 0)
        XCTAssertEqual(
            TripActivityFormat.countdownEnd(expected.addingTimeInterval(3 * 60)),
            end.addingTimeInterval(3 * 60)
        )
        let style = TripActivityFormat.countdownStyle(until: expected)
        XCTAssertEqual(style.format(end.addingTimeInterval(-0.001)), "in 1 min")
        // The widget replaces this with "now" when the zero-minute app update
        // or ActivityKit's stale presentation arrives; the formatter alone cannot.
        XCTAssertEqual(style.format(end), "in 0 min")
    }

    @available(macOS 15.0, iOS 18.0, *)
    func testSystemCountdownRoundsHoursAndReturnsToMinutes() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let style = TripActivityFormat.countdownStyle(until: end)
        for (minutes, text) in [(154.0, "in 3 hr"), (150, "in 3 hr"), (149, "in 2 hr"),
                                (90, "in 2 hr"), (89, "in 1 hr"), (59, "in 59 min"),
                                (36, "in 36 min")] {
            XCTAssertEqual(style.format(end.addingTimeInterval(-minutes * 60)), text)
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    func testMinimalSystemCountdownFitsTheSmallIsland() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let style = TripActivityFormat.countdownStyle(until: end, minimal: true)
        XCTAssertEqual(style.format(end.addingTimeInterval(-60)), "in 1m")
        XCTAssertEqual(style.format(end.addingTimeInterval(-59 * 60)), "in 59m")
        XCTAssertEqual(style.format(end.addingTimeInterval(-154 * 60)), "in 3h")
    }

    @available(macOS 15.0, iOS 18.0, *)
    func testSystemCountdownFormatSurvivesEncodingAndExposesItsNextTick() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let original = TripActivityFormat.countdownStyle(until: now.addingTimeInterval(36 * 60))
        // Live Activity text must carry a system-decodable style, not a custom formatter.
        let data = try JSONEncoder().encode(original)
        let style = try JSONDecoder().decode(Date.AnchoredRelativeFormatStyle.self, from: data)
        let next = try XCTUnwrap(style.discreteInput(after: now.addingTimeInterval(9)))
        XCTAssertEqual(next.timeIntervalSince(now), 60, accuracy: 0.001)
        XCTAssertEqual(style.format(now), "in 36 min")
        XCTAssertEqual(style.format(next), "in 35 min")
    }

    func testRemainingAtQuarterPastMatchesThePrintedClock() {
        let calendar = Calendar.current
        func date(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(
                year: 2026, month: 9, day: 11, hour: hour, minute: minute, second: 0
            ))!
        }
        XCTAssertEqual(
            TripActivityFormat.remainingMinutes(until: date(17, 35), from: date(17, 10)),
            25
        )
        XCTAssertEqual(TripActivityFormat.clock(date(17, 35)), "17:35")
    }

    func testSubMinuteJitterDoesNotChangeThePrintedClock() {
        let calendar = Calendar.current
        func date(_ hour: Int, _ minute: Int, _ second: Int) -> Date {
            calendar.date(from: DateComponents(
                year: 2026, month: 9, day: 11, hour: hour, minute: minute, second: second
            ))!
        }
        let pinned = date(17, 34, 50)
        let jitter = date(17, 35, 10)
        XCTAssertFalse(TripActivityFormat.shouldAcceptLiveTime(current: pinned, incoming: jitter))
        XCTAssertEqual(TripActivityFormat.clock(pinned), "17:34")
        XCTAssertTrue(
            TripActivityFormat.shouldAcceptLiveTime(current: date(17, 35, 0), incoming: date(17, 36, 5))
        )
    }

    func testSecondsUntilNextMinuteLandsOnTheBoundary() {
        let now = Date(timeIntervalSince1970: 1_000_000 * 60 + 15)
        XCTAssertEqual(TripActivityFormat.secondsUntilNextMinute(from: now), 45, accuracy: 0.01)
        let onTheMinute = Date(timeIntervalSince1970: 1_000_000 * 60)
        XCTAssertEqual(TripActivityFormat.secondsUntilNextMinute(from: onTheMinute), 60, accuracy: 0.01)
    }

    func testPlatformPhrase() {
        XCTAssertEqual(
            TripActivityFormat.platformPhrase(kind: .departure, platform: "3"),
            "From platform 3"
        )
        XCTAssertEqual(
            TripActivityFormat.platformPhrase(kind: .arrival, platform: "1"),
            "On platform 1"
        )
    }
}
