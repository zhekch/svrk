import XCTest
@testable import TransitCore

final class ServiceConnectionTests: XCTestCase {
    private var root: URL {
        if let path = ProcessInfo.processInfo.environment["SVRK_TEST_ROOT"] {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func data() throws -> URL {
        let data = root.appendingPathComponent("SwissTransit/Resources/Data")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: data.appendingPathComponent("timetable.bin").path))
        return data
    }

    private func stamp(_ time: String) -> Int {
        Int(ISO8601DateFormatter().date(from: "2026-09-05T\(time)+02:00")!.timeIntervalSince1970)
    }

    func testForeignScheduledStopPointsIndexByUIC() {
        XCTAssertEqual(TimetableStore.station(ofSlotRef: "ch:1:ScheduledStopPoint:8301003"), "8301003")
        XCTAssertEqual(TimetableStore.station(ofSlotRef: "8301003"), "8301003")
        XCTAssertEqual(TimetableStore.station(ofSlotRef: "ch:1:sloid:7000:0:1"), "ch:1:sloid:7000")
    }

    func testGeneratedSectorReferencesBelongToTheirStation() {
        for ref in [
            "ch:1:sloid:8005_gen:ch:1:sloid:8005:3:4_pf:4AB",
            "ch:1:sloid:8005_gen:ch:1:sloid:8005:3:4_pf:4C",
            "ch:1:sloid:8005:3:4_gen_pf:4AB",
            "ch:1:sloid:8005:3:4", "ch:1:sloid:8005", "8508005"
        ] {
            XCTAssertEqual(TimetableStore.station(ofSlotRef: ref), StopRegister.stationOf(ref))
        }
    }

    func testS44BothBranchesAreAvailableOutsideTheMapFleet() async throws {
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: try data())
        let now = stamp("13:15:00")
        let split = stamp("14:08:00")
        let solothurn = await fleet.onward(
            from: "Burgdorf", stopUIC: 8508005, notBefore: split,
            to: "Solothurn", destinationUIC: 8500207, mode: .train,
            operatorName: "BLS", line: "S44", at: now
        )
        let sumiswald = await fleet.onward(
            from: "Burgdorf", stopUIC: 8508005, notBefore: split,
            to: "Sumiswald-Gruenen", destinationUIC: 8508272, mode: .train,
            operatorName: "BLS", line: "S44", at: now
        )
        XCTAssertEqual(solothurn?.journeyRef, "ch:1:sjyid:100015:16649-001")
        XCTAssertEqual(solothurn?.stops.first?.dep, stamp("14:15:00"))
        XCTAssertEqual(solothurn?.stops.last?.name, "Solothurn")
        XCTAssertEqual(solothurn?.stops.count, 9)
        XCTAssertEqual(sumiswald?.journeyRef, "ch:1:sjyid:100015:16549-001")
        XCTAssertEqual(sumiswald?.stops.first?.dep, stamp("14:11:00"))
        XCTAssertEqual(sumiswald?.stops.last?.name, "Sumiswald-Grünen")
        XCTAssertEqual(sumiswald?.stops.count, 8)
        // A nearby service with a different line is not a split connection.
        let unrelated = await fleet.onward(
            from: "Burgdorf", stopUIC: 8508005, notBefore: split,
            to: "Solothurn", destinationUIC: 8500207, mode: .train,
            operatorName: "BLS", line: "S99", at: now
        )
        XCTAssertNil(unrelated)
        // A published SJYID takes priority over an advertised line change.
        let named = await fleet.onward(
            from: "Burgdorf", stopUIC: 8508005, notBefore: split,
            to: "Solothurn", destinationUIC: 8500207, mode: .train,
            operatorName: "BLS", line: "S99",
            workings: [.init(trainNumber: nil, journeyID: "ch:1:sjyid:100015:16649-001")], at: now
        )
        XCTAssertEqual(named?.id, solothurn?.id)
    }

    private func re1() throws -> Journey {
        let directory = try data()
        let register = StopRegister()
        try register.load(stopsFile: directory.appendingPathComponent("stops.bin"), foreignFile: directory.appendingPathComponent("foreign.bin"))
        let timetable = try TimetableStore(url: directory.appendingPathComponent("timetable.bin"))
        let journeys = timetable.journeys(
            callingAt: ["ch:1:sloid:7483"], from: stamp("12:40:00"), to: stamp("13:00:00"),
            place: { register.lookup($0) }
        )
        let incoming = try XCTUnwrap(journeys.first { $0.journeyRef == "ch:1:sjyid:100015:4268-001" })
        let outgoing = try XCTUnwrap(journeys.first { $0.journeyRef == "ch:1:sjyid:100015:4168-001" })
        return Chains.join([incoming, outgoing])
    }

    func testSpiezDomodossolaAndZweisimmenBranchesAt1612() async throws {
        let directory = try data()
        let fleet = Fleet(snapshotURL: URL(fileURLWithPath: "/dev/null"))
        _ = await fleet.load(from: directory)
        let formation = try XCTUnwrap(JSONDecoder().decode(
            FormationResponse.self, from: Data(SpiezDestinationFixture.incoming.utf8)
        ).digest())
        let split = try XCTUnwrap(formation.split)
        XCTAssertEqual(split.portions.map(\.destination), ["Brig", "Zweisimmen"])
        let workings = try XCTUnwrap(formation.separation).branches
        let domodossola = await fleet.onward(
            from: "Spiez", stopUIC: 8507483, notBefore: stamp("16:12:00"),
            to: "Brig", destinationUIC: 8501609, mode: .train,
            operatorName: "BLS", line: "RE1", workings: workings, at: stamp("16:02:00")
        )
        XCTAssertEqual(domodossola?.journeyRef, "ch:1:sjyid:100015:4277-001")
        XCTAssertEqual(domodossola?.stops.last?.name, "Domodossola (I)")
        XCTAssertTrue(domodossola?.stops.contains { $0.name == "Brig" } == true)
        let zweisimmen = await fleet.onward(
            from: "Spiez", stopUIC: 8507483, notBefore: stamp("16:12:00"),
            to: "Zweisimmen", destinationUIC: 8507290, mode: .train,
            operatorName: "BLS", line: "RE1", workings: workings, at: stamp("16:02:00")
        )
        XCTAssertEqual(zweisimmen?.journeyRef, "ch:1:sjyid:100015:6829-001")
        XCTAssertEqual(zweisimmen?.stops.last?.name, "Zweisimmen")

        // A destination along the route is only sufficient with a published
        // working link. It must not match unrelated departures by proximity.
        let unlinked = await fleet.onward(
            from: "Spiez", stopUIC: 8507483, notBefore: stamp("16:12:00"),
            to: "Brig", destinationUIC: 8501609, mode: .train,
            operatorName: "BLS", line: "RE1", at: stamp("16:02:00")
        )
        XCTAssertNil(unlinked)
        let foreign = await fleet.onward(
            from: "Spiez", stopUIC: 8507483, notBefore: stamp("16:12:00"),
            to: "Domodossola", destinationUIC: 8301003, mode: .train,
            operatorName: "BLS", line: "RE1", workings: workings, at: stamp("16:02:00")
        )
        XCTAssertEqual(foreign?.id, domodossola?.id)
    }

    func testRE1FormationCoversEarlierStopsAndUsesCoupledDepartureAtSpiez() throws {
        let journey = try re1()
        let incoming = try XCTUnwrap(try JSONDecoder().decode(FormationResponse.self, from: Data(ServiceConnectionFixtures.re1Incoming.utf8)).digest())
        let outgoing = try XCTUnwrap(try JSONDecoder().decode(FormationResponse.self, from: Data(ServiceConnectionFixtures.re1Outgoing.utf8)).digest())
        let parts = try XCTUnwrap(journey.parts)
        let legs = zip(parts, [incoming, outgoing]).map { part, formation in
            (leg: FormationLeg(key: FormationKey(operatorCode: .bls, trainNumber: formation.trainNumber, operationDate: "2026-09-05"), stops: part.start...part.end), formation: formation)
        }
        // Fetching the active leg first must not change chronological order.
        let combined = try XCTUnwrap(TrainFormation.combining(legs.reversed(), calls: journey.stops))
        XCTAssertEqual(combined.stops.map(\.stopName), journey.stops.map(\.name))
        XCTAssertEqual(combined.stops.count, 14)
        XCTAssertEqual(combined.stop(named: "Mülenen")?.coaches.count, 6)
        XCTAssertEqual(combined.stop(named: "Spiez")?.coaches.count, 12)
        XCTAssertEqual(combined.stop(named: "Spiez")?.arrival, Date(timeIntervalSince1970: Double(stamp("12:44:00"))))
        XCTAssertEqual(combined.stop(named: "Spiez")?.departure, Date(timeIntervalSince1970: Double(stamp("12:50:00"))))
        XCTAssertEqual(combined.stop(named: "Bern")?.coaches.count, 12)
        XCTAssertNil(combined.split)
        XCTAssertEqual(parts.map(\.to), ["Spiez", "Bern"], "Runs as shows the numbered legs, not a through destination twice")
    }

    func testMissingFormationDoesNotBorrowCoachesFromAnotherLeg() throws {
        let journey = try re1()
        let incoming = try XCTUnwrap(try JSONDecoder().decode(FormationResponse.self, from: Data(ServiceConnectionFixtures.re1Incoming.utf8)).digest())
        let key = FormationKey(operatorCode: .bls, trainNumber: 4268, operationDate: "2026-09-05")
        let combined = try XCTUnwrap(TrainFormation.combining([
            (FormationLeg(key: key, stops: 0...10), incoming)
        ], calls: journey.stops))
        XCTAssertEqual(combined.stops.count, 11)
        XCTAssertNil(combined.stop(named: "Bern"))
    }

    func testSnapshotKeepsEveryFormationKeyAndUsesOutgoingLayoutAtJunction() throws {
        let journey = try re1()
        var vehicle = VehicleSnapshot(
            id: journey.id, mode: .train, line: "RE1", from: "Brig",
            lon: 7.68, lat: 46.69, index: 10,
            stops: journey.stops, parts: journey.parts
        )
        XCTAssertEqual(vehicle.formationLegs.map(\.key.trainNumber), [4268, 4168])
        XCTAssertEqual(vehicle.formationLegs.map(\.stops), [0...10, 10...13])
        let layouts = VehicleLayoutStore()
        XCTAssertEqual(layouts.key(for: vehicle)?.trainNumber, 4168)
        vehicle.index = 9
        XCTAssertEqual(layouts.key(for: vehicle)?.trainNumber, 4268)
        vehicle.index = 13
        XCTAssertEqual(vehicle.formationLegs.map(\.key.trainNumber), [4268, 4168])
    }

    func testOccupancyContinuesAfterRenumberingAndReplacesJunctionPlatform() {
        let incoming = JourneyLoad(journeyID: "4268", day: "2026-09-05", byStop: [
            "ch:1:sloid:7481:1:2": Occupancy(secondClass: .manySeatsAvailable),
            "ch:1:sloid:7483:1:5": Occupancy(secondClass: .fewSeatsAvailable)
        ])
        let outgoing = JourneyLoad(journeyID: "4168", day: "2026-09-05", byStop: [
            "ch:1:sloid:7483:2:5": Occupancy(secondClass: .manySeatsAvailable),
            "ch:1:sloid:7100:1:2": Occupancy(secondClass: .standingRoomOnly)
        ])
        let merged = incoming.merging(outgoing)
        XCTAssertEqual(merged.at("ch:1:sloid:7481")?.secondClass, .manySeatsAvailable)
        XCTAssertEqual(merged.at("ch:1:sloid:7483:1:5")?.secondClass, .manySeatsAvailable)
        XCTAssertEqual(merged.at("ch:1:sloid:7100")?.secondClass, .standingRoomOnly)
        XCTAssertEqual(merged.byStop.count, 3)
        XCTAssertEqual(merged.merging(outgoing), merged)
    }
}
