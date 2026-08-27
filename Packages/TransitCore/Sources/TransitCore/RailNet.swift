import Foundation

/// Shortest-path routing over the OSM railway network.
///
/// Vehicles are placed by interpolating between consecutive stops. Doing that
/// on a straight line sends trains across lakes and through mountains, so for
/// rail modes we route stop-to-stop over the real track graph and interpolate
/// along that polyline instead.
///
/// Routing the same pair of stations over and over is wasteful — a given line
/// runs the identical leg all day — so results are memoised and persisted.
public final class RailNet: @unchecked Sendable {
    /// A station node can sit a little off the running line.
    static let snapRadius = 900.0
    /// Reject paths this much longer than the direct line.
    static let maxDetour = 3.0
    /// Edge weights are inflated for sidings and yard tracks, so a search bound
    /// in real metres would cut off perfectly good routes through a station
    /// throat. The bound is scaled by the largest penalty so it stays generous;
    /// the honest quality check is the real-length test on the finished path.
    static let maxEdgePenalty = 4.0
    /// ~1.5 km spatial index cells.
    static let gridDegrees = 0.02
    /// How far back along the approach the crossing to a platform may begin.
    public static let approachMetres = 700.0
    /// How far a platform may lie from the track it belongs to.
    ///
    /// Measured perpendicular to the rails rather than to a graph *node*, which
    /// is the whole point — see `platformTarget`. A platform is drawn beside the
    /// rails, not on them, so this cannot be tiny; at Bern the platforms are
    /// about twenty metres apart centre to centre, so it cannot be large either.
    static let platformSnap = 25.0

    /// The turn at which the search stops calling it a curve and calls it a
    /// reversal.
    ///
    /// A railway turnout diverges by a few degrees and even a tram takes a
    /// street corner at ninety, so the threshold has to clear both. What is
    /// left above 135° is a train changing ends, which happens at a station —
    /// that is, at the boundary between two legs, never inside one.
    static let reversalAngle = 135.0

    /// Below this a turn costs nothing: it is the line curving, which is what
    /// railway lines do.
    static let easyTurnAngle = 45.0

    /// What the sharpest turn short of a reversal is charged, in metres of
    /// detour.
    ///
    /// The number that matters is the comparison, not the absolute: two hundred
    /// metres is more than a crossover saves and less than a genuine
    /// alternative route costs, so the search takes the straight way through a
    /// station throat and still takes the sharp way where the sharp way is the
    /// only way. Squared rather than linear so a gentle turn stays nearly free
    /// and the charge climbs steeply as the line doubles back.
    static let turnPenaltyMetres = 200.0

    /// What a turn of `degrees` adds to the cost of the edge taken.
    static func turnCost(_ degrees: Double) -> Double {
        guard degrees > easyTurnAngle else { return 0 }
        let over = min(1, (degrees - easyTurnAngle) / (reversalAngle - easyTurnAngle))
        return turnPenaltyMetres * over * over
    }

    /// How far out to look for the *segments* a platform might sit beside.
    ///
    /// Wider than `platformSnap` on purpose, and measuring a different thing: a
    /// straight run of track can carry a single segment two hundred metres long,
    /// so the node that anchors the right rail may be far away even though the
    /// rail itself is a metre from the platform.
    static let platformEdgeSearch = 250.0

    struct Graph {
        var lons: [Int32]
        var lats: [Int32]
        var offsets: [Int32]
        var targets: [Int32]
        var weights: [Float]
        /// Empty for a graph built before track classes existed; treated as
        /// "anything goes" so the app still works rather than refusing every
        /// edge.
        var kinds: [UInt8]
        var kindBits: [String: UInt8]
        var nodeCount: Int
        /// The node each edge leaves, which the adjacency array alone does not
        /// say: it is grouped *by* source, so the source is the index you came
        /// in on rather than anything stored. The search needs it per edge to
        /// know which way that edge points, and deriving it by binary search
        /// over `offsets` would put a log in the innermost loop.
        var sources: [Int32] = []
    }

    private var graph: Graph?
    private var grid: [GridKey: [Int32]] = [:]
    struct GridKey: Hashable { var x: Int32; var y: Int32 }

    /// Memoised legs. `nil` value means "asked, and there is no sensible route"
    /// — worth remembering, since the caller would otherwise re-run the search
    /// on every refresh for the legs that can never succeed.
    private var legCache: [String: [Coord]?] = [:]
    /// Memoised run-ups, kept apart from `legCache` because that one is
    /// written to `leg-cache.json` and shipped: a run-up is cheap to recompute
    /// and would only bloat a file whose point is the expensive Dijkstras.
    private var behindCache: [String: [Coord]] = [:]
    private let cacheLock = NSLock()

    /// Scratch for the search, kept between calls and stamped rather than
    /// cleared. Held under its own lock: the arrays are the size of the edge
    /// list, so one set shared and serialised beats one set per caller, and the
    /// answers are memoised anyway.
    private var cost: [Double] = []
    private var cameFrom: [Int32] = []
    private var stamp: [Int32] = []
    private var visit: Int32 = 0
    private let searchLock = NSLock()

    public init() {}

    public var isReady: Bool { graph != nil }
    public var nodeCount: Int { graph?.nodeCount ?? 0 }
    public var cachedLegs: Int { cacheLock.withLock { legCache.count } }

    // MARK: - Loading

    public func load(_ url: URL) throws {
        var reader = BinaryReader(try MappedFile(url: url))
        try reader.expect(magic: "SVRAILNT", version: 1)
        let strings = try reader.readStringTable()
        try reader.align(to: 4)

        let nodeCount = Int(try reader.readUInt32())
        let edgeCount = Int(try reader.readUInt32())
        let kindCount = Int(try reader.readUInt32())

        var kindBits: [String: UInt8] = [:]
        for _ in 0..<kindCount {
            let name = strings[Int(try reader.readUInt32())]
            kindBits[name] = UInt8(truncatingIfNeeded: try reader.readUInt32())
        }
        try reader.align(to: 8)

        let lons = try reader.readArray(Int32.self, count: nodeCount)
        let lats = try reader.readArray(Int32.self, count: nodeCount)
        let offsets = try reader.readArray(Int32.self, count: nodeCount + 1)
        let targets = try reader.readArray(Int32.self, count: edgeCount)
        let weights = try reader.readArray(Float.self, count: edgeCount)
        let kinds = try reader.readArray(UInt8.self, count: edgeCount)

        var sources = [Int32](repeating: 0, count: edgeCount)
        for node in 0..<nodeCount {
            let from = Int(offsets[node]), to = Int(offsets[node + 1])
            guard from <= to, to <= edgeCount else { continue }
            for e in from..<to { sources[e] = Int32(node) }
        }

        let loaded = Graph(
            lons: lons, lats: lats, offsets: offsets, targets: targets,
            weights: weights, kinds: kinds, kindBits: kindBits, nodeCount: nodeCount,
            sources: sources
        )
        graph = loaded
        buildGrid(loaded)
    }

    private func buildGrid(_ graph: Graph) {
        var built = [GridKey: [Int32]](minimumCapacity: graph.nodeCount / 8)
        for i in 0..<graph.nodeCount {
            let key = Self.cell(
                BinaryFormat.decode(graph.lons[i]),
                BinaryFormat.decode(graph.lats[i])
            )
            built[key, default: []].append(Int32(i))
        }
        grid = built
    }

    private static func cell(_ lon: Double, _ lat: Double) -> GridKey {
        GridKey(x: Int32(floor(lon / gridDegrees)), y: Int32(floor(lat / gridDegrees)))
    }

    // MARK: - Track classes

    /// Track classes each draw mode may run on, as a bitmask.
    ///
    /// A train alongside a tram line was drawn on the tram rails simply because
    /// they were the nearest track; restricting the search by class is what
    /// stops that. Light rail is shared deliberately — Swiss lines like the
    /// Forchbahn genuinely run as both.
    private func allowedKinds(_ mode: Mode) -> UInt8 {
        guard let bits = graph?.kindBits, !bits.isEmpty else { return 0 }
        let heavy = bits["heavy"] ?? 0
        let tram = bits["tram"] ?? 0
        let light = bits["light"] ?? 0
        let narrow = bits["narrow"] ?? 0
        let funicular = bits["funicular"] ?? 0

        switch mode {
        case .tram: return tram | light
        case .metro: return light | tram
        case .cable: return funicular | narrow
        default: return heavy | narrow | light
        }
    }

    // MARK: - Snapping

    struct Candidate { var node: Int32; var offset: Double }

    /// Candidate graph nodes near a coordinate, nearest first.
    ///
    /// Snapping to the single closest node is fragile: a station coordinate is
    /// the building, not the rails, so the nearest node is sometimes on a
    /// parallel line or a siding, and routing from there detours absurdly or
    /// fails outright. Offering the search several entry points lets it pick
    /// the one that actually connects.
    private func snapCandidates(
        _ graph: Graph, lon: Double, lat: Double, radius: Double,
        wanted: Int = 6, spacing: Double = 120
    ) -> [Candidate] {
        let span = Int32(ceil(radius / 1000 / (Self.gridDegrees * 111))) + 1
        let centre = Self.cell(lon, lat)

        var found: [(Double, Int32)] = []
        for dx in -span...span {
            for dy in -span...span {
                for i in grid[GridKey(x: centre.x + dx, y: centre.y + dy)] ?? [] {
                    let nodeLon = BinaryFormat.decode(graph.lons[Int(i)])
                    let nodeLat = BinaryFormat.decode(graph.lats[Int(i)])
                    let d = Geo.metres(lon, lat, nodeLon, nodeLat)
                    if d <= radius { found.append((d, i)) }
                }
            }
        }
        found.sort { $0.0 < $1.0 }

        // Nodes on one line sit metres apart, so the top N would all be the
        // same track. Spacing the candidates out is what actually reaches other
        // lines — and at a station throat, where the tracks are five metres
        // apart, is exactly what must not happen. Hence the parameter.
        var picked: [Candidate] = []
        for (d, i) in found {
            if picked.count >= wanted { break }
            let iLon = BinaryFormat.decode(graph.lons[Int(i)])
            let iLat = BinaryFormat.decode(graph.lats[Int(i)])
            let tooClose = picked.contains { p in
                Geo.metres(iLon, iLat,
                           BinaryFormat.decode(graph.lons[Int(p.node)]),
                           BinaryFormat.decode(graph.lats[Int(p.node)])) < spacing
            }
            if !tooClose { picked.append(Candidate(node: i, offset: d)) }
        }
        return picked
    }

    /// Which track a platform belongs to, and where on it a vehicle stands.
    ///
    /// The old rule took the nearest graph **node** and called that the
    /// platform's track. A node is a vertex, not a rail: OSM records a straight
    /// run as few points, so the nearest vertex of the correct track can be ten
    /// metres away along the rail while a neighbouring track happens to have one
    /// right beside the platform. At Bern the nearest node to a platform is up
    /// to 10 m away where the nearest *track* is 1 m — and the platforms are
    /// only about 20 m apart, so that error is half the way to the next one.
    /// That is the "one platform off" the map kept showing: never far, and
    /// consistently across rather than along.
    ///
    /// Measuring to the segment instead asks the question that was meant: which
    /// rail is this platform beside. The vehicle is then placed at the
    /// perpendicular foot on that rail, which is where it physically stands.
    /// Where a vehicle stands for a platform at this coordinate: the foot of
    /// the perpendicular on the rail the platform is beside, or nil where no
    /// rail is near enough to name.
    ///
    /// The binding every platform correction rests on, exposed so it can be
    /// checked on its own. A crossing routed perfectly to the wrong rail is
    /// still the wrong platform, and only this says which rail was meant.
    public func platformLanding(lon: Double, lat: Double, mode: Mode = .train) -> Coord? {
        guard let graph else { return nil }
        return platformTarget(graph, lon: lon, lat: lat, kindMask: allowedKinds(mode))?.landing
    }

    private func platformTarget(
        _ graph: Graph, lon: Double, lat: Double, kindMask: UInt8
    ) -> (goals: [Candidate], landing: Coord)? {
        let radius = Self.platformEdgeSearch
        let span = Int32(ceil(radius / 1000 / (Self.gridDegrees * 111))) + 1
        let centre = Self.cell(lon, lat)

        var best: (distance: Double, a: Int32, b: Int32)?
        for dx in -span...span {
            for dy in -span...span {
                for i in grid[GridKey(x: centre.x + dx, y: centre.y + dy)] ?? [] {
                    let ui = Int(i)
                    let from = Int(graph.offsets[ui]), to = Int(graph.offsets[ui + 1])
                    guard from <= to, to <= graph.targets.count else { continue }
                    let aLon = BinaryFormat.decode(graph.lons[ui])
                    let aLat = BinaryFormat.decode(graph.lats[ui])
                    for e in from..<to {
                        // Only rails this vehicle could stand on: a tram stop
                        // must not bind to the main line running past it.
                        if kindMask != 0, !graph.kinds.isEmpty, (graph.kinds[e] & kindMask) == 0 { continue }
                        let v = graph.targets[e]
                        let vi = Int(v)
                        guard vi >= 0, vi < graph.nodeCount else { continue }
                        let bLon = BinaryFormat.decode(graph.lons[vi])
                        let bLat = BinaryFormat.decode(graph.lats[vi])
                        let d = Geo.distanceToSegment(
                            lon: lon, lat: lat,
                            a: Coord(lon: aLon, lat: aLat), b: Coord(lon: bLon, lat: bLat)
                        )
                        if d < (best?.distance ?? .infinity) { best = (d, i, v) }
                    }
                }
            }
        }

        guard let best, best.distance <= Self.platformSnap else { return nil }

        let a = Coord(lon: BinaryFormat.decode(graph.lons[Int(best.a)]),
                      lat: BinaryFormat.decode(graph.lats[Int(best.a)]))
        let b = Coord(lon: BinaryFormat.decode(graph.lons[Int(best.b)]),
                      lat: BinaryFormat.decode(graph.lats[Int(best.b)]))
        // Either end of that rail will do as a goal; the search takes whichever
        // it reaches more cheaply, and the landing point is on the segment
        // between them either way.
        let goals = [
            Candidate(node: best.a, offset: Geo.metres(a, Coord(lon: lon, lat: lat))),
            Candidate(node: best.b, offset: Geo.metres(b, Coord(lon: lon, lat: lat))),
        ]
        return (goals, Geo.footOnSegment(lon: lon, lat: lat, a: a, b: b))
    }

    // MARK: - Search

    /// Shortest path from any of `starts` to whichever of `goals` is cheapest
    /// to reach, bounded by `limit` so a stop fenced off from the network
    /// cannot trigger a search of the whole country.
    ///
    /// Running one search over all candidate entry and exit nodes — rather than
    /// one search per pair — costs no more than a single search while letting
    /// the graph itself decide which snap was right. Each candidate is seeded at
    /// its distance from the stop, so a closer entry point is preferred unless
    /// the track layout says otherwise.
    ///
    /// **The state is the edge arrived on, not the node reached.** A node has no
    /// direction, so a search over nodes is free to run up a track and back down
    /// it — which is what the graph legs were doing, and what a train cannot do
    /// between two of its own stops. Carrying the arriving edge is what makes
    /// the turn at each node a thing the search can be charged for; it doubles
    /// the state space and pays for itself several times over in the paths it
    /// stops considering.
    ///
    /// `allowReversal` exists for the retry: a hard ban can leave a leg with no
    /// route at all, and a straight line across country is worse than a route
    /// that doubles back. See `search`.
    private func shortestPath(
        _ graph: Graph, starts: [Candidate], goals: [Candidate],
        limit: Double, kindMask: UInt8, allowReversal: Bool = false
    ) -> [Coord]? {
        let edgeCount = graph.targets.count
        guard edgeCount > 0 else { return nil }

        var goalCost: [Int32: Double] = [:]
        for g in goals { goalCost[g.node] = min(goalCost[g.node] ?? .infinity, g.offset) }

        @inline(__always) func point(_ node: Int32) -> (lon: Double, lat: Double) {
            (BinaryFormat.decode(graph.lons[Int(node)]), BinaryFormat.decode(graph.lats[Int(node)]))
        }

        // What it must still cost to finish, at worst. Edge weights are the real
        // length inflated for sidings and yards, so the straight line to the
        // nearest goal never overstates the remainder and the search stays
        // exact — it simply stops walking away from the answer, which on a
        // national graph is most of what it used to do.
        let targets: [(lon: Double, lat: Double, offset: Double)] = goals.map {
            let p = point($0.node)
            return (p.lon, p.lat, $0.offset)
        }
        @inline(__always) func remaining(_ node: Int32) -> Double {
            let p = point(node)
            var best = Double.infinity
            for t in targets {
                let d = Geo.flatMetres(p.lon, p.lat, t.lon, t.lat) + t.offset
                if d < best { best = d }
            }
            return best
        }

        // One set of scratch arrays for the whole run of the app rather than
        // three allocations of half a million entries per leg. Stamped instead
        // of cleared: writing 582,000 zeroes between legs costs more than the
        // searches themselves on the short legs, which are most of them.
        searchLock.lock()
        defer { searchLock.unlock() }
        if cost.count != edgeCount {
            cost = [Double](repeating: .infinity, count: edgeCount)
            cameFrom = [Int32](repeating: -1, count: edgeCount)
            stamp = [Int32](repeating: 0, count: edgeCount)
            visit = 0
        }
        visit &+= 1
        if visit == Int32.max { stamp = [Int32](repeating: 0, count: edgeCount); visit = 1 }
        let epoch = visit

        @inline(__always) func known(_ e: Int) -> Double {
            stamp[e] == epoch ? cost[e] : .infinity
        }

        var heap = MinHeap()
        for start in starts {
            let node = Int(start.node)
            let from = Int(graph.offsets[node]), to = Int(graph.offsets[node + 1])
            guard from <= to, to <= edgeCount else { continue }
            for e in from..<to {
                if kindMask != 0, !graph.kinds.isEmpty, (graph.kinds[e] & kindMask) == 0 { continue }
                let v = graph.targets[e]
                guard v >= 0, Int(v) < graph.nodeCount else { continue }
                let d = start.offset + Double(graph.weights[e])
                if d > limit || d >= known(e) { continue }
                cost[e] = d
                cameFrom[e] = -1
                stamp[e] = epoch
                heap.push(key: d + remaining(v), value: Int32(e))
            }
        }

        var reached: Int32 = -1
        var reachedCost = Double.infinity

        while let popped = heap.pop() {
            let e = Int(popped.value)
            if stamp[e] != epoch || popped.key > cost[e] + remaining(graph.targets[e]) + 1e-6 { continue }
            // Nothing left in the heap can beat the goal already in hand: every
            // key is a lower bound on the total through that state.
            if reached != -1, popped.key >= reachedCost { break }

            let d = cost[e]
            if d > limit { continue }
            let u = graph.targets[e]
            let ui = Int(u)

            if let extra = goalCost[u], d + extra < reachedCost {
                reachedCost = d + extra
                reached = Int32(e)
            }

            let previous = graph.sources[e]
            let a = point(previous), b = point(u)

            let from = Int(graph.offsets[ui]), to = Int(graph.offsets[ui + 1])
            guard from <= to, to <= edgeCount else { continue }
            for f in from..<to {
                if kindMask != 0, !graph.kinds.isEmpty, (graph.kinds[f] & kindMask) == 0 { continue }
                let v = graph.targets[f]
                let vi = Int(v)
                if vi < 0 || vi >= graph.nodeCount { continue }
                // Straight back down the edge it arrived on. The turn test below
                // would catch this too, but only where the geometry is
                // well-behaved; this is the case that must never survive.
                if v == previous { continue }

                let c = point(v)
                let turn = Geo.turnDegrees(
                    Coord(lon: a.lon, lat: a.lat),
                    Coord(lon: b.lon, lat: b.lat),
                    Coord(lon: c.lon, lat: c.lat)
                )
                if !allowReversal, turn > Self.reversalAngle { continue }

                let nd = d + Double(graph.weights[f]) + Self.turnCost(turn)
                if nd > limit || nd >= known(f) { continue }
                cost[f] = nd
                cameFrom[f] = Int32(e)
                stamp[f] = epoch
                heap.push(key: nd + remaining(v), value: Int32(f))
            }
        }

        guard reached != -1 else { return nil }

        var edges: [Int32] = [reached]
        var e = reached
        while cameFrom[Int(e)] != -1 {
            e = cameFrom[Int(e)]
            edges.append(e)
        }
        edges.reverse()

        var nodes: [Int32] = [graph.sources[Int(edges[0])]]
        for edge in edges { nodes.append(graph.targets[Int(edge)]) }
        return nodes.map {
            Coord(lon: BinaryFormat.decode(graph.lons[Int($0)]),
                  lat: BinaryFormat.decode(graph.lats[Int($0)]))
        }
    }

    /// The search, with the reversal ban lifted only if it found nothing.
    ///
    /// The ban is the right rule and it is not free: a stop whose only mapped
    /// connection is through a stub the graph draws as a spike would come back
    /// with no route, and the caller's fallback is a straight line across
    /// country. A doubled-back route is a worse drawing than a clean one and a
    /// far better drawing than that, so it is what a second pass settles for.
    private func search(
        _ graph: Graph, starts: [Candidate], goals: [Candidate],
        limit: Double, kindMask: UInt8
    ) -> [Coord]? {
        if let path = shortestPath(
            graph, starts: starts, goals: goals, limit: limit, kindMask: kindMask
        ), path.count > 1 {
            return path
        }
        return shortestPath(
            graph, starts: starts, goals: goals,
            limit: limit, kindMask: kindMask, allowReversal: true
        )
    }

    // MARK: - Public routing

    /// Track geometry between two stops, or nil when no sensible route exists
    /// (the caller then falls back to a straight line). `key` identifies the
    /// stop pair so repeated legs are only routed once.
    public func routeLeg(key: String, from: Coord, to: Coord, mode: Mode = .train) -> [Coord]? {
        guard let graph else { return nil }
        let cacheKey = "\(mode.rawValue)|\(key)"
        if let hit = cacheLock.withLock({ legCache[cacheKey] }) { return hit }

        let direct = Geo.metres(from, to)
        var result: [Coord]?

        // Beyond ~120 km a leg is almost always a non-stop run whose search
        // cost is not worth it, and below ~40 m the straight line is already
        // correct.
        if direct > 40 && direct < 120_000 {
            // Between adjacent stops the snap radius must stay well under the
            // gap itself. Otherwise the two candidate sets overlap and the
            // cheapest "route" the search can find is a single shared node — a
            // zero-length path that looks like a routing failure.
            let radius = min(Self.snapRadius, max(120, direct * 0.4))
            let a = snapCandidates(graph, lon: from.lon, lat: from.lat, radius: radius)
            let b = snapCandidates(graph, lon: to.lon, lat: to.lat, radius: radius)
            if !a.isEmpty && !b.isEmpty {
                let limit = max(6000, direct * Self.maxDetour) * Self.maxEdgePenalty
                if let path = search(graph, starts: a, goals: b, limit: limit, kindMask: allowedKinds(mode)),
                   path.count > 1 {
                    // A wildly longer path means the snap landed on the wrong line.
                    if Geo.length(of: path) <= direct * Self.maxDetour {
                        result = Geo.simplify(path)
                    }
                }
            }
        }

        cacheLock.withLock { legCache[cacheKey] = result }
        return result
    }

    /// Track geometry from a point already on the running line to a specific
    /// platform, over the real crossovers rather than straight across the
    /// tracks.
    ///
    /// A route relation describes **one** alignment through a station, because
    /// that is what a relation is — a fixed list of ways for the whole line. It
    /// cannot know that today's S1 is booked for platform 12. So the drawn line
    /// ran down whatever track the relation uses and the vehicle was slid
    /// sideways onto its platform, which on the approach to Bern is a white
    /// line cutting diagonally across five other tracks. Trains do not do that.
    /// They cross at the points, and the graph knows where the points are.
    ///
    /// What makes this a different question from `routeLeg` is the snapping,
    /// and that is the whole difficulty: at a throat the tracks are five metres
    /// apart, so a candidate set spaced out to reach *other lines* is the one
    /// thing that must not happen here.
    public func routeApproach(
        key: String, from: Coord, to: Coord, mode: Mode = .train,
        reach: Double = RailNet.approachMetres
    ) -> [Coord]? {
        guard let graph else { return nil }
        let cacheKey = "approach|\(mode.rawValue)|\(key)"
        if let hit = cacheLock.withLock({ legCache[cacheKey] }) { return hit }

        let direct = Geo.metres(from, to)
        var result: [Coord]?

        if direct > 20 && direct < reach * 3 {
            // The crossing has to begin on the rail the relation is *already*
            // on, and nothing weaker than that will do.
            //
            // Sixty metres with four candidates ten metres apart was an attempt
            // at "tight" and is not tight at all in a station throat, where the
            // tracks are five metres apart: it offers the search four different
            // tracks, and the search takes whichever reaches the platform
            // cheapest — which is frequently not the one the train is on. The
            // relation's line then meets the crossing's first node sideways,
            // and that lateral jump is drawn as a straight segment: the right
            // angle an IR15 into Bern 10 was drawn as, and the jump across the
            // tracks on an IC8.
            //
            // The hinge is a point on a mapped railway way, so its own rail is
            // metres away and can be named rather than guessed at. Both ends of
            // that one rail are offered — the search still chooses which way to
            // leave — and the foot of the perpendicular is kept so the crossing
            // starts exactly where the relation stops.
            let mask = allowedKinds(mode)
            let ownRail = nearestRail(graph, to: from, mask: mask)
            let starts: [Candidate]
            if let ownRail {
                func at(_ node: Int32) -> Coord {
                    Coord(lon: BinaryFormat.decode(graph.lons[Int(node)]),
                          lat: BinaryFormat.decode(graph.lats[Int(node)]))
                }
                starts = [
                    Candidate(node: ownRail.a, offset: Geo.metres(from, at(ownRail.a))),
                    Candidate(node: ownRail.b, offset: Geo.metres(from, at(ownRail.b))),
                ]
            } else {
                // The relation is on track the graph does not carry. Rare, and
                // a wider snap is still better than no crossing at all.
                starts = snapCandidates(
                    graph, lon: from.lon, lat: from.lat, radius: 60, wanted: 4, spacing: 10
                )
            }
            let target = platformTarget(graph, lon: to.lon, lat: to.lat, kindMask: allowedKinds(mode))
            if !starts.isEmpty, let target {
                let goals = target.goals
                let limit = max(3000, direct * 3) * Self.maxEdgePenalty
                if var path = search(graph, starts: starts, goals: goals, limit: limit, kindMask: allowedKinds(mode)),
                   path.count > 1 {
                    // Finish beside the platform rather than at whichever end of
                    // its rail the search happened to reach. The foot of the
                    // perpendicular lies on that same rail, so this runs along
                    // real track rather than cutting across it.
                    if let last = path.last, Geo.metres(last, target.landing) > 1 {
                        // Trim back to it rather than turning off towards it.
                        //
                        // The search stops at whichever end of the platform's
                        // rail it reached, and that can be *past* the landing —
                        // so appending the landing drew a step back and across,
                        // a right angle at the very last vertex. That is the
                        // corner an IR15 into Bern 10 ended on. A vertex is
                        // past the landing when the step reaching it is longer
                        // than the step to the landing would have been.
                        while path.count >= 2 {
                            let inward = path[path.count - 2]
                            let end = path[path.count - 1]
                            guard Geo.metres(inward, end) > Geo.metres(inward, target.landing)
                            else { break }
                            path.removeLast()
                        }
                        if let last = path.last, Geo.metres(last, target.landing) > 1 {
                            path.append(target.landing)
                        }
                    }

                    // Start beside the hinge for the same reason: the foot is
                    // on the relation's own rail, so leaving from it is the
                    // seam being tangential rather than a step sideways. Not
                    // where that would make the line double back — the search
                    // is free to leave by either end of the rail, and from the
                    // far end the foot is behind it.
                    if let foot = ownRail?.foot, path.count >= 2,
                       Geo.metres(foot, path[0]) > 1,
                       Geo.turnDegrees(foot, path[0], path[1]) < 90 {
                        path.insert(foot, at: 0)
                    }
                    var length = 0.0
                    // The furthest the path ever gets from the platform it aims at.
                    var strayed = 0.0
                    for i in 1..<path.count {
                        length += Geo.metres(path[i - 1], path[i])
                        strayed = max(strayed, Geo.metres(path[i], to))
                    }

                    // Two guards, and the second is the one that matters.
                    //
                    // A crossover is a short diagonal: it lengthens the approach
                    // by a half at the very most. But length alone does not
                    // catch a detour, because a detour can be long in a straight
                    // line too. What catches it is that a train approaching a
                    // platform never moves *away* from it: a path that ends up
                    // further off than it began is not an approach, whatever its
                    // length.
                    let sane = length <= max(350, direct * 1.5) && strayed <= direct * 1.1
                    if sane { result = Geo.simplify(path) }
                }
            }
        }

        cacheLock.withLock { legCache[cacheKey] = result }
        return result
    }

    // MARK: - Cache persistence

    /// Persist the memoised legs so a restart starts warm.
    ///
    /// Stamped with a version, because a cached leg is *geometry produced by
    /// this file* and is only reusable while the rules that produced it hold.
    /// When the simplification tolerance changed on the server, every cached
    /// leg silently kept the shape the old rule gave it — the fix looked like it
    /// had not worked, on exactly the legs drawn most often.
    ///
    /// 4: crossings onto a booked platform now start on the rail the route
    /// relation is already on rather than on whichever of four nearby tracks
    /// reached the platform cheapest, so every cached `approach|` is the old
    /// shape — and the old shape is the right angle this changed to remove.
    ///
    /// 5: the hinge a crossing starts from moved. A train that cannot be placed
    /// from close in now steps its hinge back through the station throat, and
    /// every hinge is interpolated to the exact distance rather than snapped to
    /// the next vertex — so an `approach|` key written by an earlier build
    /// names a point this one never asks about. Nothing in the file is *wrong*,
    /// which is the reason to throw it away rather than keep it: an entry that
    /// can never be hit is indistinguishable from one that is answering the old
    /// question, and a cache nobody can tell the state of is worse than a cold
    /// start. One launch pays for it. See `GeometryBuilder.reaches`.
    static let cacheVersion = 5

    public func saveCache(to url: URL) throws {
        let snapshot = cacheLock.withLock { legCache }
        var payload: [String: [[Double]]?] = [:]
        for (key, value) in snapshot {
            // `updateValue(nil, forKey:)` and not `payload[key] = nil`. The
            // value type is itself optional, so plain subscript assignment of
            // nil *removes the key* rather than storing a null — and a removed
            // key is not "no route", it is "never asked".
            //
            // A third of this file is negative: 415 of the 1302 legs the seed
            // covers have no route through the graph at all, and knowing that
            // is exactly as valuable as knowing the other 887, because it is
            // what stops the search being run again. Dropped on save, every
            // launch re-ran every one of them — a cold Dijkstra apiece, on the
            // actor the draw loop is queued behind.
            payload.updateValue(value.map { $0.map { [$0.lon, $0.lat] } }, forKey: key)
        }
        let wrapper = LegCacheFile(version: Self.cacheVersion, legs: payload)
        try JSONEncoder().encode(wrapper).write(to: url, options: .atomic)
    }

    public func loadCache(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let wrapper = try? JSONDecoder().decode(LegCacheFile.self, from: data),
              wrapper.version == Self.cacheVersion
        else { return }

        cacheLock.withLock {
            for (key, value) in wrapper.legs {
                // `updateValue`, for the reason `saveCache` gives: the value
                // type is optional, so subscript-assigning nil would drop the
                // key instead of recording "no route" — and the drop is silent
                // on both sides, so a seed written correctly still loaded a
                // third short.
                legCache.updateValue(
                    value.map { $0.map { Coord(lon: $0[0], lat: $0[1]) } }, forKey: key)
            }
        }
    }

    struct LegCacheFile: Codable {
        var version: Int
        var legs: [String: [[Double]]?]
    }
}

/// Binary heap keyed on distance; a sorted array is far too slow here.
struct MinHeap {
    private var keys: [Double] = []
    private var values: [Int32] = []

    var isEmpty: Bool { values.isEmpty }

    mutating func push(key: Double, value: Int32) {
        keys.append(key)
        values.append(value)
        var i = values.count - 1
        while i > 0 {
            let parent = (i - 1) >> 1
            if keys[parent] <= keys[i] { break }
            keys.swapAt(parent, i)
            values.swapAt(parent, i)
            i = parent
        }
    }

    mutating func pop() -> (key: Double, value: Int32)? {
        guard let top = values.first else { return nil }
        let topKey = keys[0]
        let lastKey = keys.removeLast()
        let lastValue = values.removeLast()
        if !values.isEmpty {
            keys[0] = lastKey
            values[0] = lastValue
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var smallest = i
                if l < values.count && keys[l] < keys[smallest] { smallest = l }
                if r < values.count && keys[r] < keys[smallest] { smallest = r }
                if smallest == i { break }
                keys.swapAt(smallest, i)
                values.swapAt(smallest, i)
                i = smallest
            }
        }
        return (topKey, top)
    }
}

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

extension RailNet {
    /// One drawable run of railway: a chain of nodes, not a single edge.
    public struct TrackLine: Sendable {
        public var points: [Coord]
        /// The graph's own track class bits, so a tram line can be drawn as one.
        public var kind: UInt8
    }

    /// The railway network inside a viewport, as polylines.
    ///
    /// The web app gets this for free by loading OpenRailwayMap's vector tiles
    /// over the basemap. There are no tiles here and there need be none: the
    /// routing graph *is* the railway network — 573,025 nodes and 582,444 edges
    /// of OSM railway, already on the device — so the same picture is drawn from
    /// it, offline, with no second source to keep in step.
    ///
    /// **Edges are joined into runs before they are handed over.** One edge per
    /// feature is the obvious version and it does not survive contact with a
    /// city: central Zürich alone is past fourteen thousand of them, which was
    /// the first cap, and a cap reached while sweeping cells from one corner
    /// fills the south of the screen and leaves the north empty. Joining a
    /// straight run of track into one feature cuts the count by roughly an order
    /// of magnitude, so the whole viewport fits under a limit that is now rarely
    /// reached at all.
    /// `kindMask` keeps the picture readable as the map pulls back. Zoomed out,
    /// tram reservations and yard sidings are a grey haze over every city and
    /// the main lines are what carry meaning — which is the same call the
    /// railway cartographers make, and why OpenRailwayMap thins its own network
    /// the same way.
    /// `minLength` drops the stubs. A station throat is dozens of crossovers a
    /// few tens of metres long, and pulled back to a national view they are
    /// invisible individually and a smudge collectively — while being most of
    /// the feature count. Dropping them is what lets the whole country fit
    /// under a limit instead of the sweep running out of budget somewhere over
    /// Aargau and leaving Ticino blank.
    ///
    /// `simplify` thins each run to a tolerance in metres, because at low zoom
    /// the vertices of a curve are far finer than a pixel.
    public func lines(
        in bbox: BBox, limit: Int = 20_000, kindMask: UInt8 = 0,
        minLength: Double = 0, simplify: Double = 0
    ) -> [TrackLine] {
        guard let graph else { return [] }

        let span = Self.gridDegrees
        let x0 = Int32(floor(bbox.west / span)), x1 = Int32(floor(bbox.east / span))
        let y0 = Int32(floor(bbox.south / span)), y1 = Int32(floor(bbox.north / span))
        guard x0 <= x1, y0 <= y1 else { return [] }

        var candidates: [Int32] = []
        for x in x0...x1 {
            for y in y0...y1 {
                candidates.append(contentsOf: grid[GridKey(x: x, y: y)] ?? [])
            }
        }
        guard !candidates.isEmpty else { return [] }

        @inline(__always) func point(_ node: Int) -> Coord {
            Coord(lon: BinaryFormat.decode(graph.lons[node]),
                  lat: BinaryFormat.decode(graph.lats[node]))
        }
        @inline(__always) func degree(_ node: Int) -> Int {
            Int(graph.offsets[node + 1]) - Int(graph.offsets[node])
        }

        /// Edges already drawn, keyed by their position in the adjacency array.
        var used = Set<Int>()
        var out: [TrackLine] = []

        /// Walk from `node` along `edge`, absorbing every node that simply
        /// carries the track onward, and stop at a junction, a dead end, or the
        /// edge of what we are drawing.
        func follow(from node: Int, edge: Int) -> TrackLine? {
            guard !used.contains(edge) else { return nil }
            if kindMask != 0, edge < graph.kinds.count, (graph.kinds[edge] & kindMask) == 0 {
                return nil
            }
            var points = [point(node)]
            var current = node
            var step = edge
            let kind = step < graph.kinds.count ? graph.kinds[step] : 0

            while !used.contains(step) {
                used.insert(step)
                let next = Int(graph.targets[step])
                guard next >= 0, next < graph.nodeCount else { break }
                // Mark the reverse edge too, or the same run is drawn again from
                // the other end.
                for back in Int(graph.offsets[next])..<Int(graph.offsets[next + 1])
                where Int(graph.targets[back]) == current {
                    used.insert(back)
                }
                points.append(point(next))
                current = next

                // Only a node that carries the track straight through continues
                // the run; anything else ends it, which is what keeps junctions
                // from being welded into one shape.
                guard degree(next) == 2 else { break }
                var onward = -1
                for candidate in Int(graph.offsets[next])..<Int(graph.offsets[next + 1])
                where !used.contains(candidate) {
                    onward = candidate
                    break
                }
                guard onward != -1 else { break }
                // And only while it stays the same sort of track. The run
                // carries one class for the whole of its length, so welding a
                // surface approach to the tunnel it disappears into would draw
                // both as whichever the first edge happened to be — the portal
                // is exactly where the drawing has to change.
                guard (onward < graph.kinds.count ? graph.kinds[onward] : 0) == kind else { break }
                step = onward
            }

            guard points.count >= 2 else { return nil }
            if minLength > 0, Geo.length(of: points) < minLength { return nil }
            let drawn = simplify > 0 ? Geo.simplify(points, toleranceMetres: simplify) : points
            return drawn.count >= 2 ? TrackLine(points: drawn, kind: kind) : nil
        }

        // Junctions and dead ends first, so runs come out whole rather than cut
        // in half wherever the sweep happened to start.
        for pass in 0..<2 {
            for node32 in candidates {
                let node = Int(node32)
                if pass == 0 && degree(node) == 2 { continue }
                for edge in Int(graph.offsets[node])..<Int(graph.offsets[node + 1]) {
                    if out.count >= limit { return out }
                    if let line = follow(from: node, edge: edge) { out.append(line) }
                }
            }
        }
        return out
    }

    /// Which bit of the track-class mask means what, so the drawing can tell a
    /// tram from a main line.
    public func kindBit(_ name: String) -> UInt8 { graph?.kindBits[name] ?? 0 }

    // MARK: - The track behind an origin

    /// How far back a run-up is followed, by mode.
    ///
    /// Long enough for the longest thing that can be drawn standing on it: a
    /// sixteen-coach intercity is about four hundred metres, a tram under
    /// seventy. Walking four hundred metres of tram network to lay out a
    /// forty-metre body is work for nothing.
    static func runUpMetres(_ mode: Mode) -> Double { mode == .train ? 420 : 120 }

    /// Real track leading *into* the point a journey starts from.
    ///
    /// A journey's geometry begins at its first stop, so a vehicle standing
    /// there has nothing behind it to lay its body along — and
    /// `VehicleFootprint` had no choice but to run the whole thing out along
    /// one bearing. On a curved platform that draws a two-hundred-metre train
    /// straight through the trackwork it is standing on, and at a tram terminus
    /// it points the body across the pavement: a 3 at Weissenbühl is drawn due
    /// south because the first two vertices of its route happen to run due
    /// north.
    ///
    /// This is the track that is actually there, taken from the same graph the
    /// app routes over. Returned nearest-first, so the caller continues its
    /// backward walk straight into it.
    ///
    /// Which way "behind" is, is the only judgement here, and it is made the
    /// same way the search makes it: follow the straightest continuation.
    /// Reversals are refused outright — the way back out of a terminus is not
    /// the way in — and a node already used is never re-entered, so a walk
    /// cannot sit in a crossover shuffling between two nodes.
    public func trackBehind(
        from: Coord, heading: Double, mode: Mode, metres limit: Double
    ) -> [Coord] {
        guard let graph, limit > 0 else { return [] }

        let key = String(format: "%@|%.5f,%.5f|%.0f|%.0f",
                         mode.rawValue, from.lat, from.lon, heading, limit)
        if let hit = cacheLock.withLock({ behindCache[key] }) { return hit }

        let walked = walkBehind(graph, from: from, heading: heading, mode: mode, limit: limit)
        cacheLock.withLock { behindCache[key] = walked }
        return walked
    }

    private func walkBehind(
        _ graph: Graph, from: Coord, heading: Double, mode: Mode, limit: Double
    ) -> [Coord] {
        let mask = allowedKinds(mode)
        func point(_ node: Int32) -> Coord {
            Coord(lon: BinaryFormat.decode(graph.lons[Int(node)]),
                  lat: BinaryFormat.decode(graph.lats[Int(node)]))
        }

        // Snap to the *rail*, not to the nearest node on it.
        //
        // A running line is one long way, and OSM puts nodes on it where it
        // bends rather than where a train stops — so the nearest node can be a
        // hundred and fifty metres away, and on the wrong side of the vehicle
        // as often as not. Starting the walk there opened the run-up with a
        // leap. The foot of the perpendicular is on the rail by construction
        // and within `platformSnap` of the vehicle, so the body carries on from
        // where it actually stands.
        guard let rail = nearestRail(graph, to: from, mask: mask) else { return [] }

        // Of that rail's two ends, the one behind: the walk continues from
        // there, and the foot is the first thing drawn.
        let aBehind = !Self.isAhead(point(rail.a), of: from, heading: heading)
        let start = Candidate(node: aBehind ? rail.a : rail.b, offset: 0)

        // Begin at the rail rather than at the first node *after* it. The
        // graph's nodes are where OSM put them, and on a coarsely drawn way
        // the next one along can be a hundred and fifty metres off — so a
        // run-up that started there opened with a leap from the platform to
        // the far end of the first segment, which is the very thing this is
        // for. The snapped node is within `platformSnap` of the vehicle by
        // construction.
        var node = start.node
        var here = rail.foot
        var out: [Coord] = [here]
        var covered = 0.0
        // Travelling backwards, so the direction of the walk is the reverse of
        // the direction the vehicle faces.
        var direction = heading + 180
        // The rail's forward end is marked as visited along with its rear one:
        // the walk must leave the vehicle going backwards, never turn round on
        // the spot and set off down the track it is about to run.
        var seen: Set<Int32> = [rail.a, rail.b]

        while covered < limit {
            let edgesFrom = Int(graph.offsets[Int(node)])
            let edgesTo = Int(graph.offsets[Int(node) + 1])
            guard edgesFrom <= edgesTo, edgesTo <= graph.targets.count else { break }

            var bestNode: Int32?
            var bestTurn = Double.infinity
            var bestPoint = here
            for edge in edgesFrom..<edgesTo {
                if mask != 0, !graph.kinds.isEmpty, (graph.kinds[edge] & mask) == 0 { continue }
                let next = graph.targets[edge]
                guard next >= 0, Int(next) < graph.nodeCount, !seen.contains(next) else { continue }
                let at = point(next)
                let turn = Geo.turnDegrees(
                    Self.offsetBack(here, bearing: direction), here, at
                )
                if turn >= Self.reversalAngle { continue }
                if turn < bestTurn { bestTurn = turn; bestNode = next; bestPoint = at }
            }

            guard let bestNode else { break }
            let step = Geo.metres(here, bestPoint)
            if step > 0.01 {
                out.append(bestPoint)
                covered += step
                direction = Geo.bearing(here, bestPoint)
            }
            seen.insert(bestNode)
            node = bestNode
            here = bestPoint
        }

        // Drop whatever the walk began with that is still *ahead* of the
        // vehicle.
        //
        // The snap lands on the nearest node, and a platform's own rail is one
        // continuous way whose nodes are wherever OSM put them — so the nearest
        // one is often a few metres the wrong side of the nose. Started there,
        // the run-up opens by going forwards and then turns round, and a body
        // laid along it is drawn down the track the vehicle has not run yet.
        // The walk itself is still right; only its first point or two are.
        while let first = out.first,
              Geo.metres(from, first) > 1,
              Self.isAhead(first, of: from, heading: heading) {
            out.removeFirst()
        }

        return out
    }

    /// The rail nearest a point, as its two graph nodes and the foot of the
    /// perpendicular onto it.
    ///
    /// The same question `platformTarget` asks, kept separate because the
    /// answers differ: that one wants somewhere to route *to* and will take
    /// either end, this one needs the segment itself so it can tell the end
    /// behind the vehicle from the end in front of it.
    private func nearestRail(
        _ graph: Graph, to point: Coord, mask: UInt8
    ) -> (a: Int32, b: Int32, foot: Coord)? {
        let radius = Self.platformSnap
        let span = Int32(ceil(radius / 1000 / (Self.gridDegrees * 111))) + 1
        let centre = Self.cell(point.lon, point.lat)

        var best: (distance: Double, a: Int32, b: Int32, foot: Coord)?
        for dx in -span...span {
            for dy in -span...span {
                for i in grid[GridKey(x: centre.x + dx, y: centre.y + dy)] ?? [] {
                    let ui = Int(i)
                    let from = Int(graph.offsets[ui]), to = Int(graph.offsets[ui + 1])
                    guard from <= to, to <= graph.targets.count else { continue }
                    let a = Coord(lon: BinaryFormat.decode(graph.lons[ui]),
                                  lat: BinaryFormat.decode(graph.lats[ui]))
                    for e in from..<to {
                        if mask != 0, !graph.kinds.isEmpty, (graph.kinds[e] & mask) == 0 { continue }
                        let v = graph.targets[e]
                        let vi = Int(v)
                        guard vi >= 0, vi < graph.nodeCount else { continue }
                        let b = Coord(lon: BinaryFormat.decode(graph.lons[vi]),
                                      lat: BinaryFormat.decode(graph.lats[vi]))
                        let hit = Geo.projectOnSegment(lon: point.lon, lat: point.lat, a: a, b: b)
                        if hit.distance < (best?.distance ?? .infinity) {
                            best = (hit.distance, i, v, hit.foot)
                        }
                    }
                }
            }
        }

        guard let best, best.distance <= radius else { return nil }
        return (best.a, best.b, best.foot)
    }

    /// Whether `point` lies in front of a vehicle at `origin` facing `heading`.
    private static func isAhead(_ point: Coord, of origin: Coord, heading: Double) -> Bool {
        var delta = abs(Geo.bearing(origin, point) - heading)
            .truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta = 360 - delta }
        return delta < 90
    }

    /// A point one metre back along `bearing`, so a turn can be measured about
    /// `here` without a previous vertex to measure it from.
    private static func offsetBack(_ here: Coord, bearing: Double) -> Coord {
        let radians = Geo.toRad(bearing + 180)
        return Coord(
            lon: here.lon + sin(radians) / (Geo.metresPerDegree * cos(Geo.toRad(here.lat))),
            lat: here.lat + cos(radians) / Geo.metresPerDegree
        )
    }
}
