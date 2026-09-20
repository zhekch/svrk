import Foundation
@testable import TransitCore

// Public GTFS-RT entry retrieved 2026-09-13, shortly after the screenshots.
// Includes the foreign prefix that our Swiss stop register cannot place.
enum ICEReplacementFixture {
    static let id = "ojp:91003:Y:R:j26.85:11_2871_ch:1:sjyid:100001:2871-874_20260913"
    static var update: TripUpdate {
        TripUpdate(tripID: id, routeID: "ojp:91003:Y:R:j26", startDate: "20260913", relationship: .added, stops: [
            StopTimeUpdate(stopID: "8010053", sequence: 1, arrival: nil, departure: 1789270560, arrivalDelay: nil, departureDelay: 0),
            StopTimeUpdate(stopID: "ch:1:sloid:90:0:856397", sequence: 2, arrival: 1789288560, departure: 1789288860, arrivalDelay: 0, departureDelay: 0),
            StopTimeUpdate(stopID: "ch:1:sloid:10:21:31", sequence: 3, arrival: 1789289664, departure: 1789289952, arrivalDelay: 384, departureDelay: 72),
            StopTimeUpdate(stopID: "ch:1:sloid:23:2:4", sequence: 4, arrival: 1789290420, departure: 1789290528, arrivalDelay: -60, departureDelay: 48),
            StopTimeUpdate(stopID: "ch:1:sloid:218:3:4", sequence: 5, arrival: 1789291464, departure: 1789291824, arrivalDelay: -36, departureDelay: 84),
            StopTimeUpdate(stopID: "ch:1:sloid:7000:1:2", sequence: 6, arrival: 1789293360, departure: 1789294062, arrivalDelay: 0, departureDelay: 42),
            StopTimeUpdate(stopID: "ch:1:sloid:7100:2:3", sequence: 7, arrival: 1789295190, departure: 1789295298, arrivalDelay: 30, departureDelay: 78),
            StopTimeUpdate(stopID: "ch:1:sloid:7483:0:954324", sequence: 8, arrival: 1789295790, departure: 1789295964, arrivalDelay: -30, departureDelay: 84),
            StopTimeUpdate(stopID: "ch:1:sloid:1605:4:6", sequence: 9, arrival: 1789297440, departure: 1789297596, arrivalDelay: 0, departureDelay: 96),
            StopTimeUpdate(stopID: "ch:1:sloid:1609:2:4", sequence: 10, arrival: 1789297980, departure: nil, arrivalDelay: 0, departureDelay: nil),
        ])
    }

    static func original() -> Journey {
        let rows: [(String, String, Int, Int)] = [
            ("Basel Bad Bf", "ch:1:sloid:90", 1789288860, 1789288860),
            ("Basel SBB", "ch:1:sloid:10:2:4", 1789289280, 1789289880),
            ("Liestal", "ch:1:sloid:23:1:1", 1789290480, 1789290480),
            ("Olten", "ch:1:sloid:218:6:11", 1789291500, 1789291740),
            ("Bern", "ch:1:sloid:7000:3:6", 1789293360, 1789294020),
            ("Thun", "ch:1:sloid:7100:2:2", 1789295160, 1789295220),
            ("Spiez", "ch:1:sloid:7483:0:954324", 1789295820, 1789295880),
            ("Visp", "ch:1:sloid:1605:4:7", 1789297440, 1789297500),
            ("Brig", "ch:1:sloid:1609:2:3", 1789297980, 1789297980)
        ]
        let stops = rows.map { name, ref, arr, dep in
            Call(key: ref, ref: ref, name: name, lat: 46.7, lon: 7.6,
                 arr: arr, dep: dep, sched: dep, scheduledArrival: arr)
        }
        return Journey(id: ".ojp-91-3-Y.1.TA.368.j26", mode: .train,
                       category: "ICE", line: "ICE", number: "101",
                       operatorName: "SBB", operatorFull: "SBB",
                       to: "Brig", from: "Basel Bad Bf", delay: nil,
                       start: stops[0].dep, end: stops.last!.arr,
                       complete: true, monitored: false, cancelled: false,
                       source: Journey.timetableSource, stops: stops,
                       journeyRef: "ch:1:sjyid:100001:101-002")
    }
}
