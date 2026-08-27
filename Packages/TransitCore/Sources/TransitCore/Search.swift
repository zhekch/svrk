import Foundation

/// One service the search found.
///
/// Deliberately not a `VehicleSnapshot`: a result list is a list of *labels*,
/// and building a snapshot means attaching geometry, which for eight results
/// is eight relation matches and possibly eight graph searches for rows the
/// reader is going to scroll straight past. The snapshot is built when one is
/// chosen.
public struct VehicleHit: Sendable, Equatable, Identifiable {
    public var id: String
    public var mode: Mode
    /// What the badge says — "IC8", "S1", "12".
    public var line: String
    public var category: String?
    /// The service number, where the feed carries one. This is the other half
    /// of what a person means by "that train": IC1 runs all day, 726 is one of
    /// them.
    public var number: String?
    public var from: String
    public var to: String?
    public var departure: Timestamp
    public var arrival: Timestamp
    /// Where the vehicle is, or where it starts when it has not left yet.
    public var lon: Double
    public var lat: Double
    /// Whether a vehicle is actually on this journey at the moment searched.
    /// A result that is not running is still worth showing — it is how you find
    /// the 17:04 at 16:50 — but it sorts below one that is.
    public var running: Bool

    public init(
        id: String, mode: Mode, line: String, category: String?, number: String?,
        from: String, to: String?, departure: Timestamp, arrival: Timestamp,
        lon: Double, lat: Double, running: Bool
    ) {
        self.id = id
        self.mode = mode
        self.line = line
        self.category = category
        self.number = number
        self.from = from
        self.to = to
        self.departure = departure
        self.arrival = arrival
        self.lon = lon
        self.lat = lat
        self.running = running
    }
}

public struct SearchResults: Sendable, Equatable {
    public var stations: [StopPlace]
    public var vehicles: [VehicleHit]

    public init(stations: [StopPlace] = [], vehicles: [VehicleHit] = []) {
        self.stations = stations
        self.vehicles = vehicles
    }

    public var isEmpty: Bool { stations.isEmpty && vehicles.isEmpty }
}

extension Journey {
    /// The service number, as a string with no leading zeros.
    ///
    /// The feed's own `TrainNumber` where it sends one — most of the country's
    /// does not — and otherwise out of the journey reference, which is where it
    /// always is. A Swiss Journey ID is `ch:1:sjyid:<sboid>:<train>-<variant>`,
    /// and `FormationKey` already reads the same two fields out of it for the
    /// formation service. Nil for a bus filed as `plan:4c07ee05-…`, which has no
    /// number to find.
    public var trainNumber: String? {
        if let number, !number.isEmpty, number.allSatisfy(\.isNumber) {
            return Journey.trimZeros(number)
        }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 5, parts[2] == "sjyid" else { return nil }
        let tail = parts[4]
        let head = tail.split(separator: "-", maxSplits: 1).first ?? tail
        guard !head.isEmpty, head.allSatisfy(\.isNumber) else { return nil }
        return Journey.trimZeros(String(head))
    }

    static func trimZeros(_ text: String) -> String {
        let trimmed = text.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    /// The line as it is compared: no case, no spaces, no punctuation.
    ///
    /// "IC 8", "ic8" and "IC-8" are one line typed three ways, and a search that
    /// told them apart would be a search that fails for the two thirds of people
    /// who do not type it the way the feed spells it.
    var searchableLine: String {
        line.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}

extension Fleet {
    /// Stations and services matching `query`.
    ///
    /// Two kinds of answer in one call because they are one question: a person
    /// tapping search on a transit map is looking for a place or for a service,
    /// and which of the two it is is obvious from what they type — but not until
    /// they have typed it.
    ///
    /// `near` is where the map is looking, which is what "the closest ones"
    /// means. Without it the ranking falls back to the name alone, which is the
    /// right behaviour before the first camera update rather than a special
    /// case worth refusing.
    public func search(
        _ query: String, near: Coord? = nil, at now: Timestamp, limit: Int = 8
    ) -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return SearchResults() }

        return SearchResults(
            stations: stopPlaces.search(
                trimmed, near: near, limit: limit, traffic: stationTraffic()
            ),
            vehicles: services(matching: trimmed, near: near, at: now, limit: limit)
        )
    }

    /// How many calls the loaded feed has at each stop place, keyed the way the
    /// place register keys them.
    ///
    /// This is what "the busiest station" means without a table of passenger
    /// numbers nobody publishes: Zürich HB is first for "zurich" because two
    /// thousand journeys call there today and Altstetten's four hundred do not
    /// come close. Counted once per snapshot and held, because the search box
    /// asks on every keystroke and the fleet changes every half minute.
    ///
    /// Counted by station rather than by platform — a call names
    /// `ch:1:sloid:3000:0:12` and the register knows the place as `8503000` —
    /// and converted to the register's spelling only at the end, over the few
    /// thousand stations that were actually called at rather than the quarter
    /// million calls.
    func stationTraffic() -> [String: Int] {
        if trafficRevision == revision { return traffic }

        var bySloid: [Substring: Int] = [:]
        for journey in fleetVehicles() {
            for call in journey.stops {
                guard let ref = call.ref else { continue }
                bySloid[Fleet.stationPrefix(of: ref), default: 0] += 1
            }
        }

        var byPlace: [String: Int] = [:]
        byPlace.reserveCapacity(bySloid.count)
        for (station, count) in bySloid {
            guard let didok = Fleet.didok(forSloid: station) else { continue }
            byPlace[didok, default: 0] += count
        }
        traffic = byPlace
        trafficRevision = revision
        return byPlace
    }

    /// `ch:1:sloid:3000:0:12` → `ch:1:sloid:3000`, without allocating.
    ///
    /// The same cut `StopRegister.stationOf` makes, kept as a slice: this runs
    /// a quarter of a million times per snapshot and a String per call is a
    /// quarter of a million allocations for a histogram.
    static func stationPrefix(of ref: String) -> Substring {
        var colons = 0
        for index in ref.indices where ref[index] == ":" {
            colons += 1
            if colons == 4 { return ref[ref.startIndex..<index] }
        }
        return ref[...]
    }

    /// `ch:1:sloid:3000` → `8503000`, which is how the place register spells it.
    static func didok(forSloid sloid: Substring) -> String? {
        guard let colon = sloid.lastIndex(of: ":") else { return nil }
        let number = sloid[sloid.index(after: colon)...]
        guard !number.isEmpty, number.count <= 5, number.allSatisfy(\.isNumber)
        else { return nil }
        return "85" + String(repeating: "0", count: 5 - number.count) + number
    }

    /// Services whose line or number matches.
    private func services(
        matching query: String, near: Coord?, at now: Timestamp, limit: Int
    ) -> [VehicleHit] {
        let needle = query.uppercased().filter { $0.isLetter || $0.isNumber }
        guard !needle.isEmpty else { return [] }
        // All digits is a service number and nothing else. "8" would otherwise
        // match every S8, IC8 and bus 8 in the country and bury the one train
        // the reader meant.
        let numeric = needle.allSatisfy(\.isNumber)
        let wantedNumber = numeric ? Journey.trimZeros(needle) : nil

        var scored: [(hit: VehicleHit, rank: Int, distance: Double, when: Timestamp)] = []

        for journey in fleetVehicles() {
            guard journey.stops.count >= 2 else { continue }

            var rank = Int.max
            if let wantedNumber, let number = journey.trainNumber {
                // Exact beats prefix: typing 726 and being shown 7261 first is
                // the search answering a question nobody asked.
                if number == wantedNumber { rank = 0 } else if number.hasPrefix(wantedNumber) { rank = 2 }
            }
            if !numeric {
                let line = journey.searchableLine
                if !line.isEmpty {
                    if line == needle { rank = min(rank, 0) } else if line.hasPrefix(needle) { rank = min(rank, 1) }
                }
            }
            guard rank != Int.max else { continue }

            let position = Positioning.position(of: journey, at: now)
            let coord = position.map { Coord(lon: $0.lon, lat: $0.lat) } ?? journey.stops[0].coord
            // A vehicle that is out there now is the one being asked about;
            // one filed for later is the answer to the same question early.
            if position == nil { rank += 4 }

            let hit = VehicleHit(
                id: journey.id, mode: journey.mode, line: journey.line,
                category: journey.category, number: journey.trainNumber,
                from: journey.from, to: journey.to,
                departure: journey.stops[0].dep,
                arrival: journey.stops[journey.stops.count - 1].arr,
                lon: coord.lon, lat: coord.lat, running: position != nil
            )
            let distance = near.map { Geo.flatMetres(coord.lon, coord.lat, $0.lon, $0.lat) } ?? 0
            scored.append((hit, rank, distance, journey.stops[0].dep))
        }

        scored.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            // Nearest first among equals, in 10 km bands. Exact metres would
            // make the order of a list of country-wide IC departures jitter as
            // the trains move, which is a list that will not hold still long
            // enough to be tapped.
            let a = Int($0.distance / 10_000), b = Int($1.distance / 10_000)
            if a != b { return a < b }
            return $0.when < $1.when
        }

        return scored.prefix(limit).map(\.hit)
    }
}
