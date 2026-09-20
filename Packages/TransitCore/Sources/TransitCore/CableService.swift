import Foundation

/// Presentation of repeated cable departures as a service rather than a cabin.
public enum CableService {
    public struct Summary: Sendable, Equatable {
        public var headwaySeconds: Int?
        public var journeySeconds: Int?
        public var usesServiceCard: Bool

        public var frequencyText: String? {
            guard let seconds = headwaySeconds else { return nil }
            if seconds < 60 { return "About every \(seconds) sec" }
            let minutes = Int((Double(seconds) / 60).rounded())
            return TimetableCadence.intervalDescription(minutes, prefix: "About every")
        }

        public var journeyTimeText: String? {
            guard let seconds = journeySeconds else { return nil }
            if seconds < 60 { return "Under 1 min" }
            return "\(Int((Double(seconds) / 60).rounded())) min"
        }
    }

    private static func stopKey(_ call: Call) -> String {
        if let ref = call.ref, !ref.isEmpty { return StopRegister.stationOf(ref) }
        return call.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Keep intermediate stations in the identity so different branches and
    /// express routes are never pooled merely because they share terminals.
    static func routeKey(_ stops: [Call], directed: Bool) -> String {
        let forward = stops.map(stopKey).joined(separator: "/")
        guard !directed else { return forward }
        return min(forward, stops.reversed().map(stopKey).joined(separator: "/"))
    }

    public static func isPointLift(_ vehicle: VehicleSnapshot) -> Bool {
        guard vehicle.mode == .cable, let first = vehicle.stops.first else { return false }
        if vehicle.category?.uppercased() == "ASC" { return true }
        return vehicle.stops.count >= 2 && vehicle.stops.allSatisfy {
            Geo.metres(first.coord, $0.coord) <= 60
        }
    }

    public static func summarize(_ vehicle: VehicleSnapshot, journeys: [Journey]) -> Summary {
        let route = routeKey(vehicle.stops, directed: true)
        let matching = journeys.filter {
            $0.mode == .cable && $0.line == vehicle.line
                && $0.operatorName == vehicle.operatorName && !$0.cancelled
                && routeKey($0.stops, directed: true) == route
        }
        // A live and a timetable copy of a departure count only once. Opposite
        // directions are separate; simultaneous departures never halve a rate.
        let departures = Set(matching.compactMap { $0.stops.first?.dep }).sorted()
        let gaps = zip(departures, departures.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
        let headway = gaps.count >= 2 ? gaps[gaps.count / 2] : nil
        let durations = matching.compactMap { journey -> Int? in
            guard let first = journey.stops.first, let last = journey.stops.last,
                  last.arr >= first.dep else { return nil }
            return last.arr - first.dep
        }.sorted()
        let duration: Int?
        if !durations.isEmpty { duration = durations[durations.count / 2] }
        else if let first = vehicle.stops.first, let last = vehicle.stops.last,
                last.arr >= first.dep { duration = last.arr - first.dep }
        else { duration = nil }
        return Summary(headwaySeconds: headway, journeySeconds: duration,
                       usesServiceCard: isPointLift(vehicle) || headway.map { $0 <= 180 } == true)
    }

    /// Merge only nearby cable runs on the same route, including reverse runs
    /// at a shared terminal. Distance testing also works across grid boundaries.
    public static func collapse(_ vehicles: [VehicleSnapshot], selectedID: String?) -> [VehicleSnapshot] {
        struct Key: Hashable {
            var line: String
            var operatorName: String?
            var route: String
        }
        let cables = vehicles.filter { $0.mode == .cable && $0.stops.count >= 2 }
        guard cables.count > 1 else { return vehicles }
        var result: [VehicleSnapshot] = []
        var hidden = Set<String>()
        var groups: [Key: [Int]] = [:]
        for vehicle in cables.sorted(by: {
            if ($0.id == selectedID) != ($1.id == selectedID) { return $0.id == selectedID }
            return $0.id < $1.id
        }) {
            let key = Key(line: vehicle.line, operatorName: vehicle.operatorName,
                          route: routeKey(vehicle.stops, directed: false))
            let point = Coord(lon: vehicle.lon, lat: vehicle.lat)
            if (groups[key] ?? []).contains(where: { index in
                let other = result[index]
                return Geo.metres(point, Coord(lon: other.lon, lat: other.lat)) <= 25
            }) {
                hidden.insert(vehicle.id)
                continue
            }
            groups[key, default: []].append(result.count)
            result.append(vehicle)
        }
        return vehicles.filter { !hidden.contains($0.id) }
    }
}
