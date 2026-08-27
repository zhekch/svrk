import Foundation

/// A stop the map draws: one of the 33,000 stop places, not the poll lattice.
public struct StopPlace: Sendable, Equatable {
    public var id: String
    public var name: String
    public var lon: Double
    public var lat: Double
    /// Whether this is a railway station — the one thing the official register
    /// does not record, joined in from the crawl by identifier.
    public var rail: Bool
    public var kerbs: Int

    public init(id: String, name: String, lon: Double, lat: Double, rail: Bool, kerbs: Int) {
        self.id = id
        self.name = name
        self.lon = lon
        self.lat = lat
        self.rail = rail
        self.kerbs = kerbs
    }

    /// Where the dots come in, and where the local ones hand over to the kerb
    /// plates. The map's layers carry these same numbers as their zoom bands.
    public enum Dot {
        public static let railMinZoom = 9.0
        public static let localMinZoom = 12.0
        public static let plateMinZoom = 16.0
    }

    /// Whether this stop's dot is actually drawn at `zoom`.
    ///
    /// A tap is answered from the same rule, because a marker nobody can see is
    /// not one anybody can be aiming at. Below zoom 12 the local stops are not
    /// drawn, and a tap meant for a train was coming back with a bus kerb in the
    /// next village — the search radius at that scale is over a kilometre, so
    /// the nearest thing to a finger is very often something invisible.
    public func dotDrawn(at zoom: Double) -> Bool {
        if rail { return zoom >= Dot.railMinZoom }
        guard zoom >= Dot.localMinZoom else { return false }
        // Above the handover a stop with kerbs of its own is drawn as its
        // plates instead, and they are what answers for it.
        return kerbs == 0 || zoom < Dot.plateMinZoom
    }
}

/// Every stop the map draws, with a grid so a viewport query is not a scan.
public final class StopPlaceStore: @unchecked Sendable {
    private var places: [StopPlace] = []
    private var grid: [Cell: [Int]] = [:]
    private static let gridDegrees = 0.05

    /// `places[i].id` → `i`, so a lookup by identity is not a scan of 33,000
    /// strings. It was one, and it is on the path a tap on a call takes.
    private var byID: [String: Int] = [:]
    /// Each name folded once at load: lowercased, diacritics removed. Searching
    /// folds the *query* instead of the register, which is the difference
    /// between one `folding` call per keystroke and thirty-three thousand.
    private var folded: [String] = []

    struct Cell: Hashable { var x: Int32; var y: Int32 }

    public init() {}

    public var count: Int { places.count }

    public func load(_ url: URL) throws {
        var reader = BinaryReader(try MappedFile(url: url))
        try reader.expect(magic: "SVPLACES", version: 1)
        let strings = try reader.readStringTable()
        try reader.align(to: 4)

        let count = Int(try reader.readUInt32())
        var loaded: [StopPlace] = []
        loaded.reserveCapacity(count)
        for _ in 0..<count {
            let id = strings[Int(try reader.readUInt32())]
            let name = strings[Int(try reader.readUInt32())]
            let lon = BinaryFormat.decode(try reader.readInt32())
            let lat = BinaryFormat.decode(try reader.readInt32())
            let rail = try reader.readUInt32() == 1
            let kerbs = Int(try reader.readUInt32())
            loaded.append(StopPlace(id: id, name: name, lon: lon, lat: lat, rail: rail, kerbs: kerbs))
        }
        places = loaded

        var built: [Cell: [Int]] = [:]
        var identifiers: [String: Int] = [:]
        identifiers.reserveCapacity(loaded.count)
        var names: [String] = []
        names.reserveCapacity(loaded.count)
        for (i, place) in loaded.enumerated() {
            built[Self.cell(place.lon, place.lat), default: []].append(i)
            identifiers[place.id] = i
            names.append(StopPlaceStore.fold(place.name))
        }
        grid = built
        byID = identifiers
        folded = names
    }

    /// Names as they are compared: no case, no diacritics.
    ///
    /// Swiss stop names are written in four languages and typed in none of
    /// them — nobody reaching for Zurich on a phone keyboard puts the umlaut
    /// in, and Geneve is as often searched for as the accented spelling.
    /// Folding both sides makes those the same string instead of two near
    /// misses.
    static func fold(_ text: String) -> String {
        text.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US")
        )
    }

    private static func cell(_ lon: Double, _ lat: Double) -> Cell {
        Cell(x: Int32(floor(lon / gridDegrees)), y: Int32(floor(lat / gridDegrees)))
    }

    public func within(_ bbox: BBox, railOnly: Bool = false, limit: Int = 2000) -> [StopPlace] {
        let x0 = Int32(floor(bbox.west / Self.gridDegrees)), x1 = Int32(floor(bbox.east / Self.gridDegrees))
        let y0 = Int32(floor(bbox.south / Self.gridDegrees)), y1 = Int32(floor(bbox.north / Self.gridDegrees))
        guard x0 <= x1, y0 <= y1 else { return [] }

        var out: [StopPlace] = []
        for x in x0...x1 {
            for y in y0...y1 {
                for i in grid[Cell(x: x, y: y)] ?? [] {
                    let place = places[i]
                    if railOnly && !place.rail { continue }
                    if bbox.contains(lon: place.lon, lat: place.lat) { out.append(place) }
                }
            }
        }
        if out.count <= limit { return out }
        // Railway stations first when the cap bites: their services reach much
        // further than a bus kerb's, so they are what a zoomed-out map wants.
        out.sort { ($0.rail ? 1 : 0) > ($1.rail ? 1 : 0) }
        return Array(out.prefix(limit))
    }

    /// The nearest stop to a point, optionally only those a caller will accept.
    ///
    /// The filter is how a tap stays honest about what is on screen: the map
    /// draws each band of dots over its own zoom range, and `matching` lets the
    /// tap ask for exactly that set rather than the whole register.
    public func nearest(
        lon: Double, lat: Double, within metres: Double,
        matching: (StopPlace) -> Bool = { _ in true }
    ) -> StopPlace? {
        let dLat = metres / Geo.metresPerDegree
        let dLon = dLat / max(0.2, cos(Geo.toRad(lat)))
        let box = BBox(west: lon - dLon, south: lat - dLat, east: lon + dLon, north: lat + dLat)

        var best: StopPlace?
        var bestDistance = metres
        for place in within(box, limit: .max) where matching(place) {
            let d = Geo.flatMetres(place.lon, place.lat, lon, lat)
            if d < bestDistance {
                bestDistance = d
                best = place
            }
        }
        return best
    }

    /// The stops within reach of a point, nearest first.
    ///
    /// The same query as `nearest`, kept separate rather than folded into it:
    /// "which is nearest" is answered on every tap and wants no allocation,
    /// while "which are near" is asked only when a tap turns out to be
    /// ambiguous and can afford a sort.
    public func nearby(
        lon: Double, lat: Double, within metres: Double, limit: Int,
        matching: (StopPlace) -> Bool = { _ in true }
    ) -> [StopPlace] {
        let dLat = metres / Geo.metresPerDegree
        let dLon = dLat / max(0.2, cos(Geo.toRad(lat)))
        let box = BBox(west: lon - dLon, south: lat - dLat, east: lon + dLon, north: lat + dLat)

        return within(box, limit: .max)
            .filter(matching)
            .compactMap { place -> (StopPlace, Double)? in
                let d = Geo.flatMetres(place.lon, place.lat, lon, lat)
                return d < metres ? (place, d) : nil
            }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    public func place(id: String) -> StopPlace? {
        guard let index = byID[id] else { return nil }
        return places[index]
    }

    /// Stops whose name matches `query`, the ones people mean first.
    ///
    /// Every word of the query has to begin a word of the name, which is what
    /// makes "bern bahn" find "Bern, Bahnhof" without also finding every stop
    /// in the canton with "Bahnhof" in it. What is left is then ordered by
    /// three things, in this order.
    ///
    /// **Railway stations before everything else.** A station serves a region
    /// and a kerb serves a street, and four letters typed into a map of
    /// Switzerland mean the station.
    ///
    /// **Then how well the name matches**: one that *is* what was typed beats
    /// one that starts with it, which beats one that merely contains it as a
    /// later word.
    ///
    /// **Then how busy the stop is, and only then how near.** This is the part
    /// that was wrong. Typing "zurich" at Altstetten put Altstetten first and
    /// Zürich HB sixth, because HB is four kilometres further away — which is
    /// distance answering a question nobody asked. Inside one city everybody
    /// means the big station; distance is what separates the twelve stops
    /// called "Bahnhof" spread over the country, not two stations in the same
    /// town. So proximity is measured in coarse bands that only start to bite
    /// beyond commuting range, and busyness decides everything inside them.
    ///
    /// `traffic` is how many calls the loaded feed has for a place. Empty
    /// before the first snapshot arrives, and the order then falls back to
    /// proximity — which is what it always was.
    public func search(
        _ query: String, near: Coord? = nil, limit: Int = 8, traffic: [String: Int] = [:]
    ) -> [StopPlace] {
        let needle = StopPlaceStore.fold(query).trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return [] }
        let tokens = needle.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }

        var scored: [(place: StopPlace, rank: Int, score: Int, distance: Double)] = []
        for i in 0..<places.count {
            let name = folded[i]
            guard StopPlaceStore.matches(name: name, tokens: tokens) else { continue }
            let place = places[i]

            // 0 is the best.
            var rank = place.rail ? 0 : 4
            if name == needle { rank += 0 } else if name.hasPrefix(needle) { rank += 1 } else { rank += 2 }

            let distance = near.map { Geo.flatMetres(place.lon, place.lat, $0.lon, $0.lat) } ?? 0
            let score = Self.busyness(traffic[place.id] ?? 0) + Self.proximity(distance)
            scored.append((place, rank, score, distance))
        }

        scored.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.place.name < $1.place.name
        }

        // One entry per name. A station mapped as several stop places — Bern's
        // is three — would otherwise fill the whole list with itself.
        var seen = Set<String>()
        var out: [StopPlace] = []
        for hit in scored {
            guard seen.insert(hit.place.name).inserted else { continue }
            out.append(hit.place)
            if out.count == limit { break }
        }
        return out
    }

    /// A penalty from how much service a stop has, 0 for the busiest.
    ///
    /// Banded rather than counted, and the bands are wide: what matters is
    /// "main station", "market town", "wayside halt", not that one has forty
    /// more departures than another. A count that separated neighbours exactly
    /// would also reorder the list every time the feed refreshed.
    static func busyness(_ calls: Int) -> Int {
        switch calls {
        case 400...: return 0
        case 150..<400: return 1
        case 60..<150: return 2
        case 20..<60: return 3
        case 5..<20: return 4
        default: return 5
        }
    }

    /// A penalty from how far a stop is from where the map is looking.
    ///
    /// Deliberately flat out to about twenty-five kilometres: everything inside
    /// that is "here" for the purposes of a search box, and inside it the
    /// busier stop is the one meant. Past it the bands rise fast, which is what
    /// keeps a query like "bahnhof" answering with the one down the road rather
    /// than the one in the biggest city in the country.
    static func proximity(_ metres: Double) -> Int {
        switch metres {
        case ..<25_000: return 0
        case ..<60_000: return 2
        case ..<120_000: return 4
        default: return 6
        }
    }

    /// Whether every query token begins a word of `name`.
    static func matches(name: String, tokens: [String]) -> Bool {
        for token in tokens {
            var found = false
            var index = name.startIndex
            while let range = name.range(of: token, range: index..<name.endIndex) {
                // The start of the name, or anything a name breaks on — Swiss
                // stop names are full of them: "Bern, Bahnhof", "Zurich HB",
                // "Nyon-Saint-Cergue".
                let before = range.lowerBound == name.startIndex
                    ? nil : name[name.index(before: range.lowerBound)]
                if before == nil || before == " " || before == "," || before == "-"
                    || before == "." || before == "(" || before == "/" {
                    found = true
                    break
                }
                index = name.index(after: range.lowerBound)
                if index >= name.endIndex { break }
            }
            guard found else { return false }
        }
        return true
    }
}
