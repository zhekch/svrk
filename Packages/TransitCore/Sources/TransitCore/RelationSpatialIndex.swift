import Foundation

extension RelationStore {
    /// Cells are about 1.5 km across, which is the scale at which "is this line
    /// under my finger" is a useful question.
    static let trackCellDegrees = 0.02

    struct TrackCell: Hashable { var x: Int32; var y: Int32 }

    static func trackCell(_ lon: Double, _ lat: Double) -> TrackCell {
        TrackCell(x: Int32(floor(lon / trackCellDegrees)), y: Int32(floor(lat / trackCellDegrees)))
    }

    /// Which relations pass through each cell.
    ///
    /// Built on first use rather than at load. Walking 3.7 million path vertices
    /// costs a few hundred milliseconds, and the great majority of sessions
    /// never tap a piece of track — paying for it during launch, where every
    /// millisecond is visible, to save it on an interaction that may not happen
    /// is the wrong trade.
    func buildTrackIndexIfNeeded() {
        if trackIndexBuilt { return }
        var built: [TrackCell: [Int32]] = [:]

        for i in 0..<count {
            let relation = self.relation(at: i)
            let path = self.path(of: relation)
            guard path.count > 1 else { continue }

            var lastCell: TrackCell?
            for p in 0..<path.count {
                let point = path[p]
                let cell = Self.trackCell(point.lon, point.lat)
                // A relation's vertices are metres apart along straight track, so
                // the same cell repeats for hundreds of them in a row. Only
                // recording changes turns 3.7 million inserts into a fraction of
                // that.
                if cell == lastCell { continue }
                lastCell = cell
                if built[cell]?.last != Int32(i) {
                    built[cell, default: []].append(Int32(i))
                }
            }
        }
        setTrackIndex(built)
    }

    /// Every line whose mapped geometry passes within `metres` of a point.
    ///
    /// This is what answers a tap on a piece of track. The web app does the same
    /// job by reading OpenRailwayMap's vector tiles for the OSM way under the
    /// cursor and matching those ids against the relations; here the relations
    /// carry the geometry themselves, so the question is answered directly —
    /// exactly, and with no tile server involved.
    public func linesNear(lon: Double, lat: Double, within metres: Double, limit: Int = 20) -> [LineOnWay] {
        buildTrackIndexIfNeeded()

        let span = Int32(max(1, ceil(metres / 1000 / (Self.trackCellDegrees * 111))))
        let centre = Self.trackCell(lon, lat)

        var candidates = Set<Int32>()
        for dx in -span...span {
            for dy in -span...span {
                for i in trackIndex[TrackCell(x: centre.x + dx, y: centre.y + dy)] ?? [] {
                    candidates.insert(i)
                }
            }
        }

        var scored: [(distance: Double, index: Int)] = []
        for i in candidates {
            let relation = self.relation(at: Int(i))
            let path = self.path(of: relation)
            guard path.count > 1 else { continue }

            var best = Double.infinity
            for p in 1..<path.count {
                let d = Self.distanceToSegment(lon: lon, lat: lat, a: path[p - 1], b: path[p])
                if d < best { best = d }
                if best <= 1 { break }
            }
            if best <= metres { scored.append((best, Int(i))) }
        }

        scored.sort { $0.distance < $1.distance }
        return scored.prefix(limit).map { entry in
            let r = self.relation(at: entry.index)
            return LineOnWay(
                id: r.id, mode: r.route, ref: r.ref, name: r.name,
                operatorName: r.operatorName, from: r.from, to: r.to, stops: r.stopCount
            )
        }
    }

    /// Metres from a point to a segment, flat-projected locally.
    static func distanceToSegment(lon: Double, lat: Double, a: Coord, b: Coord) -> Double {
        let perLon = Geo.metresPerDegree * cos(Geo.toRad(lat))
        let ax = (a.lon - lon) * perLon, ay = (a.lat - lat) * Geo.metresPerDegree
        let bx = (b.lon - lon) * perLon, by = (b.lat - lat) * Geo.metresPerDegree
        let dx = bx - ax, dy = by - ay
        let lengthSq = dx * dx + dy * dy
        if lengthSq == 0 { return (ax * ax + ay * ay).squareRoot() }
        var t = -(ax * dx + ay * dy) / lengthSq
        t = max(0, min(1, t))
        let cx = ax + dx * t, cy = ay + dy * t
        return (cx * cx + cy * cy).squareRoot()
    }
}

/// A line that calls at a stop, from the mapped routes rather than the feed.
///
/// This is what the track panel has always been able to say and the departure
/// board could not: the relations describe the network, so they answer at three
/// in the morning exactly as they do at rush hour.
public struct ServingLine: Sendable, Equatable, Identifiable {
    public var id: Int32
    public var ref: String
    public var mode: Mode
    /// The line's name, or where it runs between.
    public var headline: String
    public var operatorName: String?
}

extension Mode {
    /// The OSM `route` value in this app's vocabulary.
    ///
    /// `light_rail` is the one that has to be decided rather than looked up: it
    /// serves trains, trams and metros in `modeRoutes`, and the Swiss things
    /// tagged with it are interurban tramways, so a tram is the closer answer
    /// than a train.
    public init(osmRoute: String) {
        switch osmRoute {
        case "train": self = .train
        case "tram", "light_rail": self = .tram
        case "subway": self = .metro
        case "bus", "trolleybus", "share_taxi": self = .bus
        case "ferry": self = .boat
        case "funicular", "monorail": self = .cable
        default: self = .other
        }
    }
}

extension RelationStore {
    /// Which relations *call* in each cell.
    ///
    /// Far cheaper than the track index — a relation has tens of stops and
    /// thousands of path vertices — so this is a fraction of the work and is
    /// built on the same terms: on first use, not at launch.
    func buildStopIndexIfNeeded() {
        if stopIndexBuilt { return }
        var built: [TrackCell: [Int32]] = [:]
        for i in 0..<count {
            let relation = self.relation(at: i)
            let stops = self.stops(of: relation)
            for s in 0..<stops.count {
                let point = stops[s]
                let cell = Self.trackCell(point.lon, point.lat)
                if built[cell]?.last != Int32(i) {
                    built[cell, default: []].append(Int32(i))
                }
            }
        }
        setStopIndex(built)
    }

    /// Every line with a call within `metres` of a point.
    ///
    /// The join is by distance, and it is worth saying why here of all places.
    /// Everywhere else in this app a stop is resolved by identifier — the
    /// register's SLOID, OSM's `ref`/`local_ref`/`uic_ref` — because the nearest
    /// point to a click is routinely the wrong one. The packed relations carry
    /// no stop identifiers at all, only the coordinates of their calls, so there
    /// is no identifier to join on and distance is the only relationship
    /// available. Two things keep that honest: the radius is tight enough that
    /// neighbouring stop places stay distinct — Bern's Bahnhof and Bollwerk are
    /// 150 m apart — and nothing is *placed* or *attributed* by it. It lists
    /// which lines call here, and the panel says the list came from the mapped
    /// routes rather than from the feed.
    public func linesStopping(
        lon: Double, lat: Double, within metres: Double, limit: Int = 24
    ) -> [ServingLine] {
        buildStopIndexIfNeeded()

        let span = Int32(max(1, ceil(metres / 1000 / (Self.trackCellDegrees * 111))))
        let centre = Self.trackCell(lon, lat)

        var candidates = Set<Int32>()
        for dx in -span...span {
            for dy in -span...span {
                for i in stopIndex[TrackCell(x: centre.x + dx, y: centre.y + dy)] ?? [] {
                    candidates.insert(i)
                }
            }
        }

        var scored: [(distance: Double, index: Int)] = []
        for i in candidates {
            let relation = self.relation(at: Int(i))
            let stops = self.stops(of: relation)
            var best = Double.infinity
            for s in 0..<stops.count {
                let d = Geo.flatMetres(stops[s].lon, stops[s].lat, lon, lat)
                if d < best { best = d }
            }
            if best <= metres { scored.append((best, Int(i))) }
        }

        // One row per line, not per relation. Every tram line is mapped twice —
        // once each way — and often once more per short working, so listing
        // relations would show "8, 8, 8, 8" where the useful answer is "8".
        var seen = Set<String>()
        var out: [ServingLine] = []
        for entry in scored.sorted(by: { $0.distance < $1.distance }) {
            let r = self.relation(at: entry.index)
            guard let ref = r.ref, !ref.isEmpty else { continue }
            let mode = Mode(osmRoute: r.route)
            let key = "\(mode.rawValue)|\(ref)"
            if !seen.insert(key).inserted { continue }
            out.append(ServingLine(
                id: r.id, ref: ref, mode: mode,
                headline: r.name ?? "\(r.from ?? "?") → \(r.to ?? "?")",
                operatorName: r.operatorName
            ))
            if out.count >= limit { break }
        }
        // Numbers in numeric order, so a board reads 6, 7, 8, 9, 12 rather than
        // 12, 6, 7, 8, 9.
        return out.sorted {
            let a = Int($0.ref.prefix { $0.isNumber }), b = Int($1.ref.prefix { $0.isNumber })
            if let a, let b, a != b { return a < b }
            if (a == nil) != (b == nil) { return a != nil }
            return $0.ref < $1.ref
        }
    }
}
