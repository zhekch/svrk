import Foundation

/// A run of coordinates read straight out of the mapped relation store.
///
/// The relation store is 32 MB of geometry — roughly 3.7 million coordinates.
/// Materialising that as `[Coord]` would cost 60 MB of heap at launch for data
/// that is mostly never touched: a journey reads the one relation it runs on.
/// So a path is a *view*, decoding Int32 pairs on subscript.
///
/// `isReversed` is how `orientPath` is applied without rewriting the file. See
/// `RelationStore.orient`.
public struct CoordView: RandomAccessCollection {
    let bytes: UnsafeRawBufferPointer
    let offset: Int
    public let count: Int
    let isReversed: Bool

    public var startIndex: Int { 0 }
    public var endIndex: Int { count }

    public subscript(position: Int) -> Coord {
        let i = isReversed ? count - 1 - position : position
        let at = offset + i * 8
        return Coord(
            lon: BinaryFormat.decode(bytes.loadUnaligned(fromByteOffset: at, as: Int32.self)),
            lat: BinaryFormat.decode(bytes.loadUnaligned(fromByteOffset: at + 4, as: Int32.self))
        )
    }

    public func toArray() -> [Coord] {
        var out = [Coord]()
        out.reserveCapacity(count)
        for i in 0..<count { out.append(self[i]) }
        return out
    }
}

/// One OSM public-transport route relation.
public struct RouteRelation: Sendable {
    public let id: Int32
    /// The OSM `route` value: `tram`, `bus`, `train`, `light_rail`…
    public let route: String
    public let ref: String?
    public let name: String?
    public let operatorName: String?
    public let network: String?
    public let from: String?
    public let to: String?

    let stopOffset: Int
    public let stopCount: Int
    let pathOffset: Int
    public let pathCount: Int
    let wayOffset: Int
    public let wayCount: Int

    /// Whether the stitched polyline runs opposite to the stop list. See
    /// `RelationStore.orient`.
    var pathReversed: Bool = false
}

/// Bind a timetable journey to the OSM route relation it actually runs on.
///
/// This replaces guessing. Routing a train stop-to-stop over the rail graph
/// picks whatever track is nearest, which is why a train alongside a tram line
/// could end up drawn on the tram rails. A route relation states outright which
/// ways the line uses, so once a journey is matched to one there is nothing
/// left to infer: the vehicle is placed on the mapped alignment, buses included.
///
/// Matching is by mode and line number to narrow the field, then by how well
/// the journey's stop coordinates line up, in order, with the relation's stop
/// nodes. The stop sequence is what actually discriminates: a city can have a
/// bus 10 and a tram 10, each relation exists once per direction, and long
/// lines are often split into several variants.
public final class RelationStore: @unchecked Sendable {
    /// How close a journey stop must be to a relation's stop node to count.
    static let stopMatchMetres = 200.0
    /// Reject a match that only lines up on a couple of stops.
    static let minCoverage = 0.6
    /// Threshold for matching without a line number to narrow the field.
    /// Higher, because the stop sequence is then the only evidence there is.
    static let minCoverageUnrefed = 0.8
    /// A partial match has to account for at least this many stops in a row.
    static let minSegmentStops = 3
    /// How many times a journey may be split before we stop looking.
    static let maxSegmentDepth = 3

    /// Which OSM `route` values can serve each of our draw modes.
    static let modeRoutes: [Mode: Set<String>] = [
        .train: ["train", "light_rail"],
        .tram: ["tram", "light_rail"],
        .metro: ["subway", "light_rail"],
        .bus: ["bus", "trolleybus", "share_taxi"],
        .boat: ["ferry"],
        .cable: ["funicular", "monorail"],
    ]

    private var file: MappedFile?
    private var bytes = UnsafeRawBufferPointer(start: nil, count: 0)
    private var relations: [RouteRelation] = []

    /// "mode|ref" → candidate relations, so matching never scans all 7,860.
    private var byKey: [String: [Int]] = [:]
    /// OSM way id → the relations that use it, for answering a click on track.
    private var byWay: [Int64: [Int]] = [:]
    /// OSM relation id → index.
    private var byId: [Int32: Int] = [:]
    /// mode → every relation that mode could use, for the ref-less fallback.
    private var byMode: [Mode: [Int]] = [:]

    /// See `buildTrackIndexIfNeeded`. Internal rather than private so the
    /// spatial query can live in its own file next to the geometry it uses.
    private(set) var trackIndex: [TrackCell: [Int32]] = [:]
    private(set) var trackIndexBuilt = false

    func setTrackIndex(_ index: [TrackCell: [Int32]]) {
        trackIndex = index
        trackIndexBuilt = true
    }

    /// The same idea over the relations' *calls* rather than their geometry.
    ///
    /// Kept apart from `trackIndex` because the two answer different questions:
    /// a line whose rails pass a stop is not a line that stops at it, and the
    /// tram that runs straight through Bärenplatz without calling should not be
    /// listed among the ones you can board there.
    private(set) var stopIndex: [TrackCell: [Int32]] = [:]
    private(set) var stopIndexBuilt = false

    func setStopIndex(_ index: [TrackCell: [Int32]]) {
        stopIndex = index
        stopIndexBuilt = true
    }

    private var matchCache: [String: Match?] = [:]
    private var segmentCache: [String: Match?] = [:]
    private var offsetCache: [Int32: [Double]] = [:]
    private let lock = NSLock()

    public struct Match: Sendable {
        public var relationIndex: Int
        public var indices: [Int]
    }

    public init() {}

    public var isReady: Bool { !relations.isEmpty }
    public var count: Int { relations.count }

    // MARK: - Loading

    public func load(_ url: URL) throws {
        let mapped = try MappedFile(url: url)
        var reader = BinaryReader(mapped)
        try reader.expect(magic: "SVROUTES", version: 1)
        let strings = try reader.readStringTable()
        try reader.align(to: 4)

        let count = Int(try reader.readUInt32())
        var loaded: [RouteRelation] = []
        loaded.reserveCapacity(count)

        func string(_ index: UInt32) -> String? {
            index == BinaryFormat.noString ? nil : strings[Int(index)]
        }

        for _ in 0..<count {
            let id = try reader.readInt32()
            let route = strings[Int(try reader.readUInt32())]
            let ref = string(try reader.readUInt32())
            let name = string(try reader.readUInt32())
            let operatorName = string(try reader.readUInt32())
            let network = string(try reader.readUInt32())
            let from = string(try reader.readUInt32())
            let to = string(try reader.readUInt32())

            let stopCount = Int(try reader.readUInt32())
            let pathCount = Int(try reader.readUInt32())
            let wayCount = Int(try reader.readUInt32())

            let stopOffset = try reader.skip(stopCount * 8)
            let pathOffset = try reader.skip(pathCount * 8)
            let wayOffset = try reader.skip(wayCount * 8)

            loaded.append(RouteRelation(
                id: id, route: route, ref: ref, name: name, operatorName: operatorName,
                network: network, from: from, to: to,
                stopOffset: stopOffset, stopCount: stopCount,
                pathOffset: pathOffset, pathCount: pathCount,
                wayOffset: wayOffset, wayCount: wayCount
            ))
        }

        file = mapped
        bytes = mapped.buffer
        relations = loaded
        buildIndexes()
    }

    private func buildIndexes() {
        byKey = [:]
        byWay = [:]
        byId = [:]
        byMode = [:]
        matchCache = [:]
        segmentCache = [:]
        offsetCache = [:]
        trackIndex = [:]
        trackIndexBuilt = false

        for i in relations.indices { orient(&relations[i]) }

        for (i, relation) in relations.enumerated() {
            byId[relation.id] = i
            // Which lines run over a given OSM way. The map already answers
            // "what is running over this track" from the live fleet, and at
            // half past eleven at night the answer is nothing — which leaves a
            // click on a line plainly drawn on the map returning nothing at all.
            for way in ways(of: relation) {
                byWay[way, default: []].append(i)
            }
        }

        for (i, relation) in relations.enumerated() {
            for (mode, kinds) in Self.modeRoutes where kinds.contains(relation.route) {
                byKey["\(mode.rawValue)|\(Self.normaliseRef(relation.ref))", default: []].append(i)
                byMode[mode, default: []].append(i)
            }
        }
    }

    /// Make a relation's polyline run the same way as its stop list.
    ///
    /// Stitching the member ways together has to flip individual ways to make
    /// their ends meet, and can end up assembling the whole line back to front.
    /// The stop members are always in travel order, so they are the reference:
    /// if the start of the polyline sits nearer the last stop than the first,
    /// the polyline is reversed. Without this, one direction of every affected
    /// line projected its stops backwards along the path and lost its geometry
    /// entirely — this single fix took mapped train legs from 36% to 78%.
    private func orient(_ relation: inout RouteRelation) {
        guard relation.pathCount >= 2, relation.stopCount >= 2 else { return }
        let path = CoordView(bytes: bytes, offset: relation.pathOffset, count: relation.pathCount, isReversed: false)
        let stops = CoordView(bytes: bytes, offset: relation.stopOffset, count: relation.stopCount, isReversed: false)

        let head = path[0], tail = path[path.count - 1]
        let first = stops[0], last = stops[stops.count - 1]

        let forward = Geo.metres(head, first) + Geo.metres(tail, last)
        let backward = Geo.metres(head, last) + Geo.metres(tail, first)
        relation.pathReversed = backward < forward
    }

    // MARK: - Accessors

    public func relation(at index: Int) -> RouteRelation { relations[index] }

    /// One relation, by its OSM id.
    public func relation(id: Int32) -> RouteRelation? {
        byId[id].map { relations[$0] }
    }

    public func indexOf(id: Int32) -> Int? { byId[id] }

    public func path(of relation: RouteRelation) -> CoordView {
        CoordView(bytes: bytes, offset: relation.pathOffset, count: relation.pathCount,
                  isReversed: relation.pathReversed)
    }

    public func stops(of relation: RouteRelation) -> CoordView {
        CoordView(bytes: bytes, offset: relation.stopOffset, count: relation.stopCount, isReversed: false)
    }

    public func ways(of relation: RouteRelation) -> [Int64] {
        var out = [Int64]()
        out.reserveCapacity(relation.wayCount)
        for i in 0..<relation.wayCount {
            out.append(bytes.loadUnaligned(fromByteOffset: relation.wayOffset + i * 8, as: Int64.self))
        }
        return out
    }

    /// OSM `ref` and the feed's line number agree on digits but not decoration.
    static func normaliseRef(_ ref: String?) -> String {
        guard let ref else { return "" }
        return String(ref.uppercased().unicodeScalars.filter {
            ("A"..."Z").contains(String($0)) || ("0"..."9").contains(String($0))
        }.map(Character.init))
    }

    // MARK: - Matching

    /// The line identifiers a relation might be tagged with.
    ///
    /// The two sources label lines differently and neither is wrong: the feed
    /// splits an S-Bahn into category "S" and number "1", while OSM tags the
    /// relation ref "S1". A bus is the reverse. Trying both forms took train
    /// matching from 86% to 93%.
    static func lineKeys(mode: Mode, line: String?, number: String?, category: String?) -> [String] {
        var forms: [String] = []
        func add(_ value: String?) {
            let n = normaliseRef(value)
            if !n.isEmpty, !forms.contains(n) { forms.append(n) }
        }
        add(number)
        add(line)
        if let category, let number { add(category + number) }
        return forms.map { "\(mode.rawValue)|\($0)" }
    }

    /// How well a journey's stops follow this relation's stop sequence.
    ///
    /// Walks both lists forward together, so stops matched out of order do not
    /// count — that is what tells the two directions of a line apart.
    struct Coverage {
        var matched = 0
        var ratio = 0.0
        var indices: [Int] = []
        /// The longest unbroken run of journey stops this relation accounts
        /// for. A relation describing half a run scores poorly on `ratio`
        /// however perfectly it fits that half, which is the situation whenever
        /// the two sources disagree about where a line ends.
        var runLength = 0
        var runFrom = -1
        var runTo = -1
    }

    func coverage(_ journeyStops: [Call], _ relation: RouteRelation) -> Coverage {
        let relStops = stops(of: relation)
        var out = Coverage()
        var cursor = 0
        var run = 0

        for (at, stop) in journeyStops.enumerated() {
            var hit = false
            var i = cursor
            while i < relStops.count {
                let point = relStops[i]
                if Geo.metres(stop.lon, stop.lat, point.lon, point.lat) <= Self.stopMatchMetres {
                    out.matched += 1
                    out.indices.append(i)
                    cursor = i + 1
                    hit = true
                    break
                }
                i += 1
            }
            if !hit {
                run = 0
                continue
            }
            run += 1
            if run > out.runLength {
                out.runLength = run
                out.runTo = at
                out.runFrom = at - run + 1
            }
        }

        out.ratio = journeyStops.isEmpty ? 0 : Double(out.matched) / Double(journeyStops.count)
        return out
    }

    /// A journey-shaped thing to match: the fields the matcher actually reads.
    ///
    /// A struct rather than the whole `Journey`, because `cover` matches
    /// *slices* of a run, and a through-service matches each numbered part
    /// under its own line number.
    public struct MatchProbe {
        public var mode: Mode
        public var line: String?
        public var number: String?
        public var category: String?
        public var stops: [Call]

        public init(mode: Mode, line: String?, number: String?, category: String?, stops: [Call]) {
            self.mode = mode
            self.line = line
            self.number = number
            self.category = category
            self.stops = stops
        }

        public init(_ journey: Journey) {
            self.init(mode: journey.mode, line: journey.line, number: journey.number,
                      category: journey.category, stops: journey.stops)
        }
    }

    /// Find the relation a journey runs on, or nil if none fits well enough to
    /// trust. Cached per line and stop pattern, since every run of a line
    /// during the day resolves to the same relation.
    public func matchRoute(_ probe: MatchProbe) -> Match? {
        guard !relations.isEmpty, !probe.stops.isEmpty else { return nil }

        let keys = Self.lineKeys(mode: probe.mode, line: probe.line, number: probe.number, category: probe.category)
        let cacheKey = "\(keys.joined(separator: ","))|\(probe.stops[0].name)|\(probe.stops[probe.stops.count - 1].name)|\(probe.stops.count)"
        if let hit = lock.withLock({ matchCache[cacheKey] }) { return hit }

        var candidates: [Int] = []
        var seen = Set<Int>()
        for key in keys {
            for i in byKey[key] ?? [] where !seen.contains(i) {
                seen.insert(i)
                candidates.append(i)
            }
        }

        // Some services carry no usable line number — the feed puts the trip
        // number in the `number` field, so there is nothing to key on. Falling
        // back to every relation of the same mode and letting the stop sequence
        // decide recovers them, at a stricter threshold since the sequence is
        // the only evidence.
        let unrefed = candidates.isEmpty
        let pool = unrefed ? (byMode[probe.mode] ?? []) : candidates
        let threshold = unrefed ? Self.minCoverageUnrefed : Self.minCoverage

        var best: Match?
        var bestScore = 0.0

        for i in pool {
            let result = coverage(probe.stops, relations[i])
            if result.ratio < threshold { continue }
            // Prefer the fuller match; break ties towards the relation whose own
            // stop list is closest in length, i.e. the variant covering this
            // exact working.
            let tightness = 1 - min(1, Double(abs(relations[i].stopCount - probe.stops.count)) / 40)
            let score = result.ratio * 100 + tightness
            if score > bestScore {
                bestScore = score
                best = Match(relationIndex: i, indices: result.indices)
            }
        }

        lock.withLock { matchCache[cacheKey] = best }
        return best
    }

    /// The relation that describes the longest unbroken *part* of a journey.
    ///
    /// The two sources do not agree on where a line ends. A Swiss RE1 leaves
    /// Bern as one train and divides at Spiez, and the feed reports the
    /// Zweisimmen half as RE1 for its whole run — but OSM maps that half as its
    /// own line, because the branch beyond Spiez is a different line to anyone
    /// standing on it. So the journey is real, both relations are right, and no
    /// single relation covers it.
    ///
    /// The whole mode is searched, not just relations carrying this line
    /// number, because the number is exactly what the two sources disagree
    /// about.
    func matchSegment(_ probe: MatchProbe) -> Match? {
        guard !relations.isEmpty, !probe.stops.isEmpty else { return nil }

        let stops = probe.stops
        let cacheKey = "\(probe.mode.rawValue)|\(stops[0].name)|\(stops[stops.count - 1].name)|\(stops.count)"
        if let hit = lock.withLock({ segmentCache[cacheKey] }) { return hit }

        var best: Match?
        var bestScore = 0.0

        for i in byMode[probe.mode] ?? [] {
            let result = coverage(stops, relations[i])
            if result.runLength < min(Self.minSegmentStops, stops.count) { continue }
            // Longest run wins; ties go to the relation that stays closest in
            // size, the same tie-break whole-journey matching uses.
            let tightness = 1 - min(1, Double(abs(relations[i].stopCount - stops.count)) / 40)
            let score = Double(result.runLength) * 100 + tightness
            if score > bestScore {
                bestScore = score
                best = Match(relationIndex: i, indices: result.indices)
            }
        }

        lock.withLock { segmentCache[cacheKey] = best }
        return best
    }

    // MARK: - Way queries

    /// Every `mode|ref` key that could possibly run over these ways.
    ///
    /// A cheap prefilter, and it matters more than it looks. Answering "what is
    /// running over this track" used to attach geometry to every journey in the
    /// country — seventeen thousand of them, each matched against the relation
    /// store and, failing that, routed through a 573,000-node graph — and then
    /// keep the handful whose ways included this one. Measured on one click:
    /// 21.5 seconds.
    public func keysOnWays(_ wayIds: [Int64]) -> Set<String> {
        var keys = Set<String>()
        for way in wayIds {
            for i in byWay[way] ?? [] {
                let relation = relations[i]
                for (mode, kinds) in Self.modeRoutes where kinds.contains(relation.route) {
                    keys.insert("\(mode.rawValue)|\(Self.normaliseRef(relation.ref))")
                }
            }
        }
        return keys
    }

    /// A line summary, for the list a click on track hands back.
    public struct LineOnWay: Sendable, Equatable, Identifiable {
        public var id: Int32
        public var mode: String
        public var ref: String?
        public var name: String?
        public var operatorName: String?
        public var from: String?
        public var to: String?
        public var stops: Int
    }

    /// Every line that uses any of `wayIds`, deduped, most-used way first.
    public func linesOnWays(_ wayIds: [Int64], limit: Int = 40) -> [LineOnWay] {
        var seen: [Int: Int] = [:]
        for way in wayIds {
            for i in byWay[way] ?? [] { seen[i, default: 0] += 1 }
        }

        return seen.sorted {
            $0.value != $1.value ? $0.value > $1.value
                : (relations[$0.key].ref ?? "") < (relations[$1.key].ref ?? "")
        }
        .prefix(limit)
        .map { entry in
            let r = relations[entry.key]
            return LineOnWay(id: r.id, mode: r.route, ref: r.ref, name: r.name,
                             operatorName: r.operatorName, from: r.from, to: r.to, stops: r.stopCount)
        }
    }

    /// Could this journey possibly run over ways whose lines are `keys`?
    ///
    /// A prefilter for "what is on this track", and it has to mirror
    /// `matchRoute` exactly or it will hide services rather than merely skip
    /// work. Three cases, all of them the matcher's own: the journey's line
    /// numbers in every form `lineKeys` produces; its *parts'* line numbers,
    /// since a train that changes number en route is one vehicle here and two
    /// lines to OSM; and no usable line number at all, where the matcher falls
    /// back to every relation of the mode and nothing here can rule it out.
    public func couldRunOn(_ journey: Journey, keys: Set<String>) -> Bool {
        let parts: [(Mode, String?, String?, String?)] = journey.parts?.isEmpty == false
            ? journey.parts!.map { ($0.mode, $0.line, $0.number, $0.category) }
            : [(journey.mode, journey.line, journey.number, journey.category)]

        return parts.contains { mode, line, number, category in
            let forms = Self.lineKeys(mode: mode, line: line, number: number, category: category)
            if !forms.contains(where: { byKey[$0] != nil }) {
                // Exactly the matcher's `unrefed` test: such a journey is
                // matched against every relation of its *mode*, so the only
                // thing that can rule it out here is the mode.
                return keys.contains { $0.hasPrefix("\(mode.rawValue)|") }
            }
            return forms.contains { keys.contains($0) }
        }
    }

    // MARK: - Preceding stops

    /// How far along the relation's polyline each of its stops sits, in metres.
    func stopOffsets(_ relation: RouteRelation) -> [Double] {
        if let hit = lock.withLock({ offsetCache[relation.id] }) { return hit }

        let path = self.path(of: relation)
        let relStops = self.stops(of: relation)
        var cumulative = [Double](repeating: 0, count: path.count)
        if path.count > 1 {
            for i in 1..<path.count {
                cumulative[i] = cumulative[i - 1] + Geo.metres(path[i - 1], path[i])
            }
        }

        var out: [Double] = []
        var from = 0
        for s in 0..<relStops.count {
            let stop = relStops[s]
            var bestIndex = from
            var bestDist = Double.infinity
            // Forward-only, for the same reason projectStops is: a route that
            // passes the same street twice would otherwise pin a later stop to
            // an earlier pass.
            var i = from
            while i < path.count {
                let d = Geo.metres(stop, path[i])
                if d < bestDist {
                    bestDist = d
                    bestIndex = i
                }
                i += 1
            }
            out.append(cumulative.isEmpty ? 0 : cumulative[bestIndex])
            from = bestIndex
        }

        lock.withLock { offsetCache[relation.id] = out }
        return out
    }

    public struct PrecedingStop: Sendable {
        public var lon: Double
        public var lat: Double
        public var index: Int
        /// Track distance from that stop to the journey's first known one.
        public var metresBack: Double
    }

    /// The relation's stops that come *before* a journey's first known stop.
    ///
    /// A stationboard only describes a journey onward from the station queried,
    /// so a bus first seen at Bern Zytglogge looks like it starts there even
    /// though it came from Ostermundigen. The relation knows the full ordered
    /// stop list, so it can say which stops the journey must already have
    /// called at — and those are exactly the boards worth polling.
    public func precedingStops(_ journey: Journey, limit: Int = 4) -> [PrecedingStop] {
        guard let match = matchRoute(MatchProbe(journey)), let firstIndex = match.indices.first,
              firstIndex != 0
        else { return [] }

        let relation = relations[match.relationIndex]
        let offsets = stopOffsets(relation)
        let here = firstIndex < offsets.count ? offsets[firstIndex] : 0
        let relStops = stops(of: relation)

        // Earliest first. Walking back one stop at a time needs a request per
        // stop; the board at the line's *first* stop carries the whole run in
        // one passList, so going straight there usually recovers everything in
        // a single request.
        var out: [PrecedingStop] = []
        var i = 0
        while i < firstIndex && out.count < limit {
            let point = relStops[i]
            out.append(PrecedingStop(
                lon: point.lon, lat: point.lat, index: i,
                metresBack: max(0, here - (i < offsets.count ? offsets[i] : 0))
            ))
            i += 1
        }
        return out
    }
}
