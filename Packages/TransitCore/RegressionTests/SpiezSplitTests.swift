import XCTest
@testable import TransitCore

final class SpiezSplitTests: XCTestCase {
    private func formation(_ json: String) throws -> TrainFormation {
        try XCTUnwrap(JSONDecoder().decode(FormationResponse.self, from: Data(json.utf8)).digest())
    }

    private func stamp(_ time: String) -> Int {
        Int(ISO8601DateFormatter().date(from: "2026-09-05T\(time)+02:00")!.timeIntervalSince1970)
    }

    func testDepartingHalvesDoNotIncludeOtherWorkingOnPlatform() throws {
        let incoming = try formation(SpiezSplitFixtures.incoming)
        XCTAssertEqual(incoming.stops[0].coaches.count, 12)
        for json in [SpiezSplitFixtures.re1, SpiezSplitFixtures.r11] {
            let train = try formation(json)
            let spiez = try XCTUnwrap(train.stops.first)
            XCTAssertEqual(spiez.coaches.count, 6)
            XCTAssertEqual(spiez.coaches.map(\.position), Array(1...6))
            XCTAssertTrue(spiez.coaches.allSatisfy { !$0.isClosed })
            XCTAssertEqual(spiez.padded.filter { !$0.belongsToTrain && $0.kind != .fictitious }.count, 6)
            XCTAssertEqual(train.stops[1].coaches.count, 6)
            let livery = LayoutLibrary.livery(operatorName: "BLS", mode: .train, modeColour: "#ff3b30")
            for stop in train.stops {
                let layout = try XCTUnwrap(VehicleLayoutStore.layout(
                    from: train, at: try XCTUnwrap(stop.departure ?? stop.arrival), livery: livery
                ))
                XCTAssertEqual(layout.units.count, 6)
                XCTAssertTrue(layout.units.allSatisfy { !$0.closed })
            }
        }
        let r11 = try formation(SpiezSplitFixtures.r11)
        XCTAssertTrue(r11.stops[0].coaches.allSatisfy { $0.typeName?.hasPrefix("RABe528_RE_") == true })
    }

    func testMembershipSpansSectorsAndKeepsClosedCarsInsideTrain() {
        let padded = FormationShortString.parse("@A,-2,-1@B,[(-2,12@C,2)],-1")
        let own = padded.filter(\.isTrainVehicle)
        XCTAssertEqual(own.map(\.position), [1, 2, 3])
        XCTAssertEqual(own.map(\.kind), [.second, .mixed, .second])
        XCTAssertEqual(own.map(\.sector), ["B", "B", "C"])
        XCTAssertTrue(own[0].isClosed)
        XCTAssertTrue(padded.filter { !$0.belongsToTrain }.allSatisfy { $0.position == 0 })
        XCTAssertEqual(FormationShortString.parse("(2,1,2)").filter(\.isTrainVehicle).count, 3)
    }

    func testCorrectedWorkingSurvivesRestartAndOldRecordsAreRechecked() throws {
        let url = URL.temporaryDirectory.appendingPathComponent("spiez-layouts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VehicleLayoutStore(url: url)
        let re1 = try formation(SpiezSplitFixtures.re1)
        let incoming = try formation(SpiezSplitFixtures.incoming)
        let key = LayoutKey(operatorCode: "BLSP", trainNumber: 4273)
        let at = Date(timeIntervalSince1970: Double(stamp("14:12:00")))
        // The line's majority is twelve coaches, but this working has six.
        for _ in 0..<3 {
            store.learn(incoming, key: LayoutKey(operatorCode: "BLSP", trainNumber: 4173), at: at,
                        mode: .train, category: "RE", line: "RE1", operatorName: "BLS", modeColour: "#ff3b30")
        }
        store.learn(re1, key: key, at: at, mode: .train, category: "RE", line: "RE1", operatorName: "BLS", modeColour: "#ff3b30")
        let vehicle = VehicleSnapshot(
            id: "ch:1:sjyid:100015:4273-001", mode: .train, category: "RE", line: "RE1",
            operatorName: "BLS", from: "Spiez", lon: 7.68, lat: 46.68,
            bearing: 0, moving: true, index: 0, progress: 0,
            stops: [Call(key: "Spiez", ref: nil, name: "Spiez", lat: 46.68, lon: 7.68,
                         platform: "2CD", precise: true, arr: stamp("14:12:00"), dep: stamp("14:12:00"))]
        )
        let before = store.layout(for: vehicle, modeColour: "#ff3b30")
        XCTAssertEqual(before.units.count, 6)
        store.save()
        let reopened = VehicleLayoutStore(url: url)
        reopened.load()
        XCTAssertFalse(reopened.needsFormation(for: key))
        let after = reopened.layout(for: vehicle, modeColour: "#ff3b30")
        XCTAssertEqual(after.units.count, 6)
        XCTAssertEqual(after.units.map(\.silhouette), before.units.map(\.silhouette))
        var tomorrow = vehicle
        tomorrow.stops[0].arr += 86_400
        tomorrow.stops[0].dep += 86_400
        XCTAssertEqual(reopened.layout(for: tomorrow, modeColour: "#ff3b30").units.count, 12)

        // Strip the revision to simulate an existing installation. The old
        // database stays readable, and its observations become fetchable.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        for i in entries.indices {
            var record = try XCTUnwrap(entries[i]["record"] as? [String: Any])
            record.removeValue(forKey: "r")
            entries[i]["record"] = record
        }
        json["entries"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let legacy = VehicleLayoutStore(url: url)
        legacy.load()
        XCTAssertNotNil(legacy.record(for: key))
        XCTAssertTrue(legacy.needsFormation(for: key))
    }

    private func dataDirectory() throws -> URL {
        let root = ProcessInfo.processInfo.environment["SVRK_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.appendingPathComponent("timetable.bin").path))
        return dir
    }

    private func openTimetable() throws -> TimetableStore {
        try TimetableStore(url: try dataDirectory().appendingPathComponent("timetable.bin"))
    }

    private func journeys() throws -> [Journey] {
        let dir = try dataDirectory()
        let register = StopRegister()
        try register.load(stopsFile: dir.appendingPathComponent("stops.bin"), foreignFile: dir.appendingPathComponent("foreign.bin"))
        let timetable = try openTimetable()
        let wanted: Set<String> = ["ch:1:sjyid:100015:4173-001", "ch:1:sjyid:100015:4273-001", "ch:1:sjyid:100015:6825-001"]
        let runs = timetable.journeys(
            callingAt: ["ch:1:sloid:7483"], from: stamp("14:00:00"), to: stamp("14:20:00"),
            place: { register.lookup($0) }, operatorName: { _ in "BLS" }
        ).filter { wanted.contains($0.journeyRef ?? "") }
        XCTAssertEqual(runs.count, 3)
        return runs
    }

    private func assertHandover(_ runs: [Journey], at time: Int, file: StaticString = #filePath, line: UInt = #line) {
        let before = runs.filter { Positioning.position(of: $0, at: time - 1) != nil }
        XCTAssertEqual(before.map(\.journeyRef), ["ch:1:sjyid:100015:4173-001"], file: file, line: line)
        XCTAssertNil(before.first?.layover?.id, "a split must not switch the panel to one arbitrary half", file: file, line: line)
        let after = runs.filter { Positioning.position(of: $0, at: time) != nil }
        XCTAssertEqual(Set(after.compactMap(\.journeyRef)), ["ch:1:sjyid:100015:4273-001", "ch:1:sjyid:100015:6825-001"], file: file, line: line)
    }

    func testSimultaneousDeparturesBothWaitForIncomingRegardlessOfOrder() throws {
        let runs = try journeys()
        assertHandover(Chains.build(runs), at: stamp("14:12:00"))
        assertHandover(Chains.build(runs.reversed()), at: stamp("14:12:00"))
    }

    /// The split as the formation service publishes it, in the shared shape.
    private func publishedSplit() throws -> ThroughGraph {
        let incoming = try formation(SpiezSplitFixtures.incoming)
        let links = incoming.throughLinks(ownedBy: ["ch:1:sjyid:100015:4173-001"])
        // Both halves, or it is not a split. `T` names two workings and taking
        // only the first hands back the reader's own train as "the other half".
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(Set(links.flatMap(\.to)),
                       ["ch:1:sjyid:100015:4273-001", "ch:1:sjyid:100015:6825-001"])
        return ThroughGraph(links: links)
    }

    func testPublishedSplitOverridesHeuristicAndTracksDelayedDeparture() throws {
        let published = try publishedSplit()
        let runs = try journeys()
        // Identical platform refs would otherwise make RE1 the favoured
        // continuation and flatten away the actual split.
        for run in runs where run.journeyRef != "ch:1:sjyid:100015:4173-001" {
            run.stops[0].ref = "ch:1:sloid:7483:0:341164"
        }
        let built = Chains.build(runs, published: published)
        XCTAssertEqual(built.count, 3)
        assertHandover(built, at: stamp("14:12:00"))
        for run in runs where run.journeyRef != "ch:1:sjyid:100015:4173-001" {
            run.stops[0].dep += 60
        }
        assertHandover(Chains.build(runs, published: published), at: stamp("14:13:00"))
        let waiting = try XCTUnwrap(runs.first { $0.journeyRef == "ch:1:sjyid:100015:6825-001" })
        waiting.stops[0].dep += 5 * 60
        assertHandover(Chains.build(runs, published: published), at: stamp("14:13:00"))
        XCTAssertFalse(try XCTUnwrap(Positioning.position(of: waiting, at: stamp("14:13:00"))).moving)
    }

    /// A split whose halves are not on screen still suppresses the inference.
    ///
    /// The map draws ninety minutes, so this is routine rather than exotic.
    /// The feed has said this working parts; guessing a continuation for it
    /// anyway is how one branch got folded into the parent while the other was
    /// drawn beside it.
    func testDeclaredSplitWithNoVisibleHalvesStillRefusesToChain() throws {
        let published = try publishedSplit()
        let runs = try journeys()
        let incoming = try XCTUnwrap(runs.first { $0.journeyRef == "ch:1:sjyid:100015:4173-001" })
        let alone = Chains.build([incoming], published: published)
        XCTAssertEqual(alone.count, 1)
        XCTAssertNil(alone[0].parts)
        XCTAssertTrue(alone[0].splitContinuations.isEmpty)
    }

    /// Links naming workings this fleet has never heard of change nothing.
    func testUnrelatedPublishedLinksAreIgnored() throws {
        let runs = try journeys()
        let nonsense = ThroughGraph(links: [
            ThroughLink(from: ["ch:1:sjyid:100015:9991-001"], to: ["ch:1:sjyid:100015:9992-001"]),
        ])
        XCTAssertEqual(Chains.build(runs, published: nonsense).count,
                       Chains.build(runs).count)
    }

    /// The packed timetable publishes this split itself, on the day it runs.
    ///
    /// This is the half that needs no network and no formation request: the
    /// national graph ships in `timetable.bin`.
    func testPackedTimetablePublishesTheSpiezSplit() throws {
        let store = try openTimetable()
        let day = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-09-21T12:00:00+02:00")
        )
        let links = store.throughServices(on: day)
        try XCTSkipIf(links.isEmpty, "timetable.bin predates the through-service graph")
        // By journey reference, not by number: "4173" is also a Menziken bus
        // and a Thun bus that day, and it is a substring of unrelated trip ids.
        let fromRE1 = links.filter { $0.from.contains("ch:1:sjyid:100015:4173-001") }
        XCTAssertEqual(fromRE1.count, 2, "RE1 4173 parts into exactly two workings at Spiez")
        let halves = Set(fromRE1.flatMap(\.to).filter { $0.contains(":sjyid:") })
        XCTAssertEqual(halves, ["ch:1:sjyid:100015:4273-001", "ch:1:sjyid:100015:6825-001"])
    }
}
