import Foundation

/// Attach real track geometry to a journey.
///
/// For each consecutive pair of stops we ask, in order: does an OSM route
/// relation describe this leg, can the rail graph route it, and failing both,
/// the straight line. The result is one flat polyline plus `legs[i]`, the index
/// in that polyline where stop `i` sits — enough to interpolate along the
/// actual alignment instead of cutting straight across country.
///
/// Legs that cannot be routed (bus runs, a stop far from any track, a gap in
/// OSM) fall back to the two stop coordinates, so a partial failure degrades
/// one leg rather than the whole journey.
public final class GeometryBuilder: @unchecked Sendable {
    private let relations: RelationStore
    private let railnet: RailNet

    /// Off switch, so the bend can be measured against its own absence.
    ///
    /// Every claim made for it — how close a line ends to its platform, how
    /// often one doubles back — is a comparison, and a comparison needs the
    /// other side of it available in the same build.
    public var bendToPlatforms = true

    /// The same, for the throat hinges the bend escalates through. See
    /// `reaches`.
    public var crossThroats = true

    /// And for the join repair, so what it takes back can be measured.
    public var repairJoins = true

    /// Diagnostic hook: each decision the bend makes, as
    /// `outcome|line|stop|platform`. Nil in the app.
    nonisolated(unsafe) public static var trace: ((String) -> Void)?

    /// Below this the relation is already on the right track; leave it alone.
    ///
    /// Twelve metres was too generous, and generous in the worst direction. A
    /// platform sits one to three metres from its own rail, but the *next* rail
    /// along is only ten to twenty metres away — so a leg ending on the wrong
    /// track was often inside the threshold and never bent at all. That is the
    /// "one platform off" the map kept showing.
    ///
    /// Measured over 25,624 calls at multi-platform stations in a national
    /// snapshot, with the edge snap of `RailNet.platformTarget` in place:
    ///
    /// | threshold | drawn on the reported track |
    /// |---|---|
    /// | 12 m | 91% |
    /// | 6 m  | 95% |
    /// | 3 m  | 96% |
    ///
    /// Six, not three: three would bend even where the line already ends at the
    /// platform, which costs a graph search per call to move nothing and makes
    /// the constant meaningless. Six clears the platform-to-own-rail distance
    /// with room to spare while still catching a neighbouring track.
    static let bendIfOffByMetres = 6.0

    public init(relations: RelationStore, railnet: RailNet) {
        self.relations = relations
        self.railnet = railnet
    }

    @discardableResult
    public func attach(to journey: Journey, refined: Bool = true) -> Journey {
        if journey.geometry != nil { return journey }
        guard journey.stops.count >= 2 else { return journey }

        // Best source first: the OSM route relation for this line names the
        // ways the vehicle uses, so nothing is inferred from proximity — and it
        // is the only source that covers buses, which run on roads we do not
        // route over.
        let mapped = relations.isReady ? matchGeometry(journey) : nil
        // The corridor pass skips the graph. Matching a relation is the cheap
        // half of this function and is what takes a train off the chord; the
        // Dijkstra, the platform bend and the run-up are the rest, and they
        // are what the draw loop cannot afford for every train in a national
        // view. See `Fleet.alignToTrack`.
        let routable = refined && journey.mode.isRail && railnet.isReady

        var legPoints: [[Coord]] = []
        var legSources: [LegSource] = []
        var fromRoute = 0
        var fromGraph = 0

        for i in 1..<journey.stops.count {
            let from = journey.stops[i - 1]
            let to = journey.stops[i]
            let chord = [from.coord, to.coord]

            // A relation does not always describe every leg — its ways can have
            // ordering gaps — so each leg falls back independently rather than
            // one bad leg costing the whole journey its geometry.
            if let fromRelation = mapped?.legs[i - 1], fromRelation.count >= 2 {
                // A relation joins its ways end to end, and a way ends where
                // its author stopped drawing rather than where the vehicle
                // turns — so a leg out of a station a service reverses in
                // begins with a run past the platform and back. See
                // `Geo.withoutSpurs`.
                legPoints.append(Geo.withoutSpurs(fromRelation))
                legSources.append(.route)
                fromRoute += 1
                continue
            }

            if routable {
                let key = String(format: "%.5f,%.5f|%.5f,%.5f", from.lat, from.lon, to.lat, to.lon)
                if let routed = railnet.routeLeg(key: key, from: from.coord, to: to.coord, mode: journey.mode),
                   routed.count > 1 {
                    // Keep the snapped track nodes at each end: they sit on the
                    // rails, which is exactly where the line and the vehicle belong.
                    legPoints.append(routed)
                    legSources.append(.graph)
                    fromGraph += 1
                    continue
                }
            }

            legPoints.append(chord)
            legSources.append(.chord)
        }

        // Bring each end of each leg onto the platform's own track, over the
        // points. Done before the legs are joined, so the indices come out right.
        if routable && bendToPlatforms {
            bend(journey, &legPoints, legSources)
        }

        // Make each pair of legs meet at one point, and let neither of them
        // double back. Both passes work on the legs rather than on the joined
        // path, because `legs[i]` has to keep naming the vertex stop `i` sits
        // on and the join is where the assembly below puts it.
        stitch(journey, &legPoints)
        for leg in legPoints.indices {
            legPoints[leg] = Geo.withoutFolds(legPoints[leg])
            // After the folds, because removing one can leave a leg beginning
            // or ending on the stub that the fold was hiding.
            legPoints[leg] = Geo.withoutEndStubs(legPoints[leg])
        }

        var path: [Coord] = []
        var legs: [Int] = [0]
        for (i, points) in legPoints.enumerated() {
            if i == 0 {
                path.append(contentsOf: points)
            } else {
                // Consecutive legs usually share their join vertex; where they
                // do not (a mapped leg meeting an inferred one) both points are
                // kept so the line stays continuous.
                let joined = path.last == points.first
                path.append(contentsOf: joined ? Array(points.dropFirst()) : points)
            }
            legs.append(path.count - 1)
        }

        journey.legsFromRoute = fromRoute
        journey.legsFromGraph = fromGraph
        journey.geometry = JourneyGeometry(
            path: path,
            legs: legs,
            // Describe the journey by where most of its geometry came from.
            source: fromRoute > 0 ? .osmRoute : (fromGraph > 0 ? .railGraph : .straight),
            mixed: fromRoute > 0 && fromRoute < journey.stops.count - 1,
            legSources: legSources,
            relation: mapped?.relation,
            ways: mapped?.ways ?? [],
            routeName: mapped?.name,
            approach: refined ? runUp(journey, path, legSources) : [],
            refined: refined
        )
        return journey
    }

    /// Per-leg geometry, matching each numbered leg separately when the journey
    /// is a through-service.
    ///
    /// A train that changes number en route is one vehicle to us but two lines
    /// to OpenStreetMap — an S2 joined from two workings is described by two
    /// relations and by no single one. Matching the joined run as a whole
    /// therefore found nothing and the service fell back to inferred geometry.
    private func matchGeometry(_ journey: Journey) -> RelationStore.LegGeometry? {
        guard let parts = journey.parts, parts.count >= 2 else {
            return relations.legPaths(RelationStore.MatchProbe(journey))
        }

        var legs = [[Coord]?](repeating: nil, count: journey.stops.count - 1)
        var ways: [Int64] = []
        var relationIds: [Int32] = []
        var names: [String] = []

        for part in parts {
            guard part.end > part.start, part.end < journey.stops.count else { continue }
            let stops = Array(journey.stops[part.start...part.end])
            guard stops.count >= 2 else { continue }

            let probe = RelationStore.MatchProbe(
                mode: part.mode, line: part.line, number: part.number,
                category: part.category, stops: stops
            )
            guard let matched = relations.legPaths(probe) else { continue }

            // The leg's own legs[] are relative to its slice; place them in the whole.
            for (i, points) in matched.legs.enumerated() where part.start + i < legs.count {
                legs[part.start + i] = points
            }
            ways.append(contentsOf: matched.ways)
            relationIds.append(matched.relation)
            if let name = matched.name { names.append(name) }
        }

        guard let first = relationIds.first else { return nil }
        return RelationStore.LegGeometry(
            legs: legs, relation: first, ways: ways,
            name: names.isEmpty ? nil : names.joined(separator: " → ")
        )
    }

    // MARK: - Meeting at the stop

    /// How far apart two legs may end and begin and still be made to meet.
    ///
    /// The gap this closes is a leg drawn to the platform meeting one drawn to
    /// the track node beside it — tens of metres, the width of a station
    /// throat. A gap much larger than that is not two spellings of the same
    /// place: it is a relation with a hole in it, where the straight line
    /// across is the honest drawing and pulling either end to the other would
    /// invent track that is not there.
    static let seamMetres = 200.0

    /// Make consecutive legs meet at one point, and at the right one.
    ///
    /// Each end of each leg is bent onto its platform on its own — the arrival
    /// and the departure are different approaches over different points, so
    /// they have to be. What nothing did until now was check that the two
    /// agreed, and where only one of them found a route the leg before ended at
    /// a track node and the leg after began at the platform fifty metres behind
    /// it. Joined, that is a line running past the stop, back to it, and out
    /// again: the Z the S1 was drawn as at Bümpliz Süd, at Europaplatz, and at
    /// every other stop the two ends disagreed about.
    ///
    /// The fix is to pick one landing — the end that got closest to the stop,
    /// since that is the one that found the platform — and to trim whichever
    /// leg overshoots it. Trimming rather than bending: a point beyond the
    /// landing is ground the vehicle covers *after* it leaves, and the leg that
    /// owns that ground is the next one.
    private func stitch(_ journey: Journey, _ legPoints: inout [[Coord]]) {
        guard legPoints.count >= 2 else { return }
        for stop in 1..<legPoints.count {
            let before = stop - 1, after = stop
            guard let tail = legPoints[before].last, let head = legPoints[after].first,
                  stop < journey.stops.count
            else { continue }

            let gap = Geo.flatMetres(tail.lon, tail.lat, head.lon, head.lat)
            if gap < 0.5 {
                // Already the same place to within the precision the two
                // sources carry it at, but not the same `Coord` — so the
                // assembly keeps both and draws a zero-length segment. Say it
                // once and the join disappears.
                legPoints[after][0] = tail
                continue
            }
            guard gap <= Self.seamMetres else { continue }

            let at = journey.stops[stop].coord
            let landing = Geo.flatMetres(tail.lon, tail.lat, at.lon, at.lat)
                <= Geo.flatMetres(head.lon, head.lat, at.lon, at.lat) ? tail : head

            trimOvershoot(&legPoints[before], to: landing, fromTail: true)
            trimOvershoot(&legPoints[after], to: landing, fromTail: false)
        }
    }

    /// Drop the vertices at one end of a leg that lie beyond `landing`, then
    /// finish there.
    ///
    /// "Beyond" is measured along the leg's own last step rather than as a
    /// distance from the stop: a vertex is past the landing when the step that
    /// reaches it is longer than the step to the landing would have been, which
    /// is the same question as whether the line has already gone by.
    private func trimOvershoot(_ points: inout [Coord], to landing: Coord, fromTail: Bool) {
        while points.count >= 2 {
            let end = fromTail ? points[points.count - 1] : points[0]
            let inward = fromTail ? points[points.count - 2] : points[1]
            let toEnd = Geo.flatMetres(inward.lon, inward.lat, end.lon, end.lat)
            let toLanding = Geo.flatMetres(inward.lon, inward.lat, landing.lon, landing.lat)
            guard toEnd > toLanding else { break }
            if fromTail { points.removeLast() } else { points.removeFirst() }
        }
        guard let end = fromTail ? points.last : points.first else {
            points = [landing]
            return
        }
        guard Geo.flatMetres(end.lon, end.lat, landing.lon, landing.lat) > 0.5 else {
            // Already there, give or take the last digit — but the two legs
            // have to carry the *same* value or the assembly will keep both.
            if fromTail { points[points.count - 1] = landing } else { points[0] = landing }
            return
        }
        if fromTail { points.append(landing) } else { points.insert(landing, at: 0) }
    }

    // MARK: - Bending onto the booked platform

    /// Replace the last and first stretch of each leg with a route over the
    /// rails to the platform the trip is booked for.
    ///
    /// The alternative, and what this replaces, was to slide the drawn position
    /// sideways onto the platform. That is honest about *where* the train ends
    /// up and silent about how it gets there, and at Bern it drew a white line
    /// straight across five tracks. A train crosses at the points.
    ///
    /// Every step here can decline. A leg is only bent when the stop's
    /// coordinate is the platform's own, when the relation's endpoint is far
    /// enough off it to be worth moving, and when the graph comes back with a
    /// route that is not absurd — otherwise the leg is left exactly as the
    /// relation had it.
    private func bend(_ journey: Journey, _ legPoints: inout [[Coord]], _ legSources: [LegSource]) {
        guard crossThroats, journey.mode.hasThroats else {
            bendAll(journey, &legPoints, legSources, throats: false)
            return
        }

        let original = legPoints
        let escalated = bendAll(journey, &legPoints, legSources, throats: true)

        // Nothing reached past the close hinge, so the close hinge on its own
        // would have produced exactly this. Most journeys take this exit —
        // every end that crossed cleanly from close in, and every stop with
        // only one platform to be wrong about — so the second pass below is
        // paid for by the few that actually needed the throat.
        guard escalated else { return }

        // What the close hinge alone would have drawn: the shape anything
        // longer has to beat.
        var close = original
        bendAll(journey, &close, legSources, throats: false)

        // Join by join, keep whichever of the two doubles back less.
        //
        // Judging each end as it is bent cannot settle this, because at a join
        // both ends move and the second is measured against a baseline the
        // first has already spoiled. Nor is the route relation the right thing
        // to measure against: where a service reverses, the relation runs past
        // the platform and back on its own, so *any* amount of retracing looks
        // like no change against it.
        //
        // The honest comparison is against the other drawing of the same join.
        // An ICE standing at Basel SBB 4 is the case: reaching back into the
        // throat straightened its arrival and its departure into two long
        // segments that met at the platform as a spike, where the close hinge
        // left the relation's own curve through the throat and drew a lens. The
        // close hinge wins that join and the throat keeps the rest, which is
        // the point of having both.
        guard repairJoins else { return }
        for stop in 1..<legPoints.count {
            let before = stop - 1, after = stop
            let now = joinRetraced(legPoints[before], legPoints[after])
            let was = joinRetraced(close[before], close[after])
            guard now > Self.crossoverRetrace, now > was + Self.retraceSlack else { continue }
            Self.trace?("repair \(Int(was))->\(Int(now))|\(journey.line)|"
                + "\(stop < journey.stops.count ? journey.stops[stop].name : "?")|"
                + "\(stop < journey.stops.count ? (journey.stops[stop].platform ?? "-") : "-")")
            legPoints[before] = close[before]
            legPoints[after] = close[after]
        }
    }

    /// True where some end had to reach past its close hinge to be placed.
    @discardableResult
    private func bendAll(
        _ journey: Journey, _ legPoints: inout [[Coord]], _ legSources: [LegSource], throats: Bool
    ) -> Bool {
        var escalated = false
        for leg in legPoints.indices {
            if legSources[leg] == .chord || legPoints[leg].count < 2 { continue }
            // The arriving end first: replacing the tail cannot disturb the head.
            escalated = bendEnd(journey, &legPoints, leg, tail: true, throats: throats) || escalated
            escalated = bendEnd(journey, &legPoints, leg, tail: false, throats: throats) || escalated
        }
        return escalated
    }

    /// Line retraced across a join, over the three vertices either side of it.
    ///
    /// Three rather than two because the two legs *share* the vertex they meet
    /// at, so a two-and-two window is really three distinct points and has no
    /// room to see a turn on both sides of the stop.
    private func joinRetraced(_ before: [Coord], _ after: [Coord]) -> Double {
        retraced(Array(before.suffix(3)) + Array(after.prefix(3)))
    }

    /// True where this end was placed from a hinge further back than its first.
    private func bendEnd(
        _ journey: Journey, _ legPoints: inout [[Coord]], _ leg: Int, tail: Bool, throats: Bool
    ) -> Bool {
        let points = legPoints[leg]
        guard points.count >= 2 else { return false }
        let stopIndex = tail ? leg + 1 : leg
        guard stopIndex < journey.stops.count else { return false }
        let stop = journey.stops[stopIndex]
        guard stop.precise else { return false }

        let end = tail ? points[points.count - 1] : points[0]
        let offBy = Geo.flatMetres(end.lon, end.lat, stop.lon, stop.lat)
        let what = "\(journey.line)|\(stop.name)|\(stop.platform ?? "-")|\(tail ? "arr" : "dep")"
        if offBy < Self.bendIfOffByMetres {
            Self.trace?("near \(Int(offBy))m|" + what)
            return false
        }

        for (step, reach) in Self.reaches(
            mode: journey.mode, offBy: offBy, along: points, throats: throats
        ).enumerated() {
            if attempt(journey, &legPoints, leg, tail: tail, from: points, stop: stop, reach: reach) {
                Self.trace?("bent@\(Int(reach)) off \(Int(offBy))m|" + what)
                return step > 0
            }
        }
        Self.trace?("declined off \(Int(offBy))m|" + what)
        return false
    }

    /// How far back from the platform to hinge, in the order the hinges are
    /// tried. The first that yields a route wins.
    ///
    /// **A tram gets one, and a train gets the throat as well.** The two are
    /// not the same problem wearing different clothes.
    ///
    /// A tram runs in the street. Its "platform" is a kerb beside the one pair
    /// of rails it was always going to be on, so the only correction it ever
    /// needs is a metre or two sideways, and a hinge further back than that is
    /// actively harmful: at Guisanplatz a flat seven hundred metres put it
    /// round the far side of the turning loop, and the graph — asked, quite
    /// reasonably, for the shortest way from there to the stop — answered with
    /// the chord straight across the middle. Two hundred metres of real route
    /// replaced by a line through the grass, which is the "it thinks the tram
    /// switches sides and breaks the path" report. So a tram keeps the reach
    /// scaled to its own error: eight times the offset is a shallower diagonal
    /// than any real turnout, and nothing longer is ever tried.
    ///
    /// A train is the opposite case and the offset lies about it. Being fifteen
    /// metres off at Zürich HB does not mean the correction is a fifteen-metre
    /// nudge — it means the train is on the wrong track, and the place where
    /// the two tracks were one is not fifteen metres back but somewhere out in
    /// the throat, three or four hundred metres before the platform. Hinging at
    /// `8 × 15 = 120 m` asks the graph for a crossover that does not exist
    /// there, and the graph either finds nothing or finds a way round through
    /// half the station — which is what `routeApproach`'s length guard then
    /// throws out. Measured over a national snapshot, that single rejection is
    /// the largest cause of a train drawn on the wrong platform: 91% of calls
    /// on the booked track without the throat hinges against 98% with, and the
    /// failures it accounts for — Zürich HB, Bern, Lausanne, Luzern, Genève,
    /// Renens, Brig — are throats, every one of them. `ThroatApproachTests`.
    ///
    /// So a train that cannot be corrected from close in steps its hinge back
    /// through the throat until one of them works. Ordered nearest first, so
    /// nothing that already crosses cleanly is disturbed and no more of the
    /// route relation is given up than the correction actually needs — which
    /// is the whole of "disregard the relation near the station": not a blanket
    /// rule, but as much of it as it takes to reach the right platform.
    ///
    /// Cost is one extra graph search per end that the close hinge could not
    /// place, and only at a station with more than one platform to be wrong
    /// about. `RailNet` memoises each by its hinge, so the second and later
    /// trains through the same throat pay nothing.
    static let throatHinges: [Double] = [220, 400, 700]


    static func reaches(
        mode: Mode, offBy: Double, along points: [Coord], throats: Bool = true
    ) -> [Double] {
        let half = Geo.length(of: points) / 2
        let close = min(RailNet.approachMetres, max(120, offBy * 8), half)
        guard throats, mode.hasThroats else { return [close] }
        var out = [close]
        for hinge in throatHinges where hinge < half && hinge > out[out.count - 1] + 40 {
            out.append(hinge)
        }
        return out
    }

    /// One hinge, tried. True when the leg was replaced.
    private func attempt(
        _ journey: Journey, _ legPoints: inout [[Coord]], _ leg: Int, tail: Bool,
        from points: [Coord], stop: Call, reach: Double
    ) -> Bool {
        // Both of the corrections below are for the modes with a throat, and
        // for nothing else. A tram's geometry came out of this file byte for
        // byte as it did before either was written: it keeps the vertex-snapped
        // hinge and the length test on its own, because its stop is a kerb
        // beside the one pair of rails it was always on and neither the reach
        // nor the shape of its crossing was ever the problem. See `reaches`.
        let throated = journey.mode.hasThroats
        guard let walked = walkIn(points, fromTail: tail, reach: reach, exact: throated)
        else { return false }
        let hinge = walked.index
        let at = walked.at
        let key = String(format: "%.5f,%.5f|%.5f,%.5f", at.lat, at.lon, stop.lat, stop.lon)
        guard let routed = railnet.routeApproach(
            key: key, from: at, to: stop.coord, mode: journey.mode, reach: RailNet.approachMetres
        ), routed.count >= 2 else { return false }

        // The graph answers from the hinge outward; a departure needs it the
        // other way.
        let crossing = tail ? routed : routed.reversed()

        // The graph enters and leaves at its own node, which is near the hinge
        // rather than on it, so the relation can resume a few metres *behind*
        // where the crossing ended — drawn, a thirty-metre kink at the seam.
        // Ground the crossing has already covered is dropped: over this short
        // stretch the line only ever moves away from the platform.
        let seam = tail ? crossing[0] : crossing[crossing.count - 1]
        let covered = Geo.flatMetres(seam.lon, seam.lat, stop.lon, stop.lat)
        func beyondSeam(_ point: Coord) -> Bool {
            Geo.flatMetres(point.lon, point.lat, stop.lon, stop.lat) > covered
        }

        // A crossover changes a leg's shape, not its extent: it is a diagonal
        // between two parallel tracks, so it costs a few metres and never saves
        // a hundred. A replacement that comes out materially *shorter* than
        // what it replaced has not crossed anything — it has taken a short cut,
        // which is what cutting the corner off a turning loop looks like from
        // here. Measured on the whole leg, because that is what the drawing
        // shows and what the vehicle is interpolated along.
        //
        // And it must not come back on itself. Reaching further back for a
        // hinge is what lets a crossing find the points it needs, and it is
        // also what lets the graph answer with a route that leaves the
        // relation's rail by the wrong end, runs out, and comes back — drawn,
        // the long white Z through the station that `Geo.withoutFolds` cannot
        // take out because its two arms are hundreds of metres apart rather
        // than a track's width. Counted against the leg as it stood, so a
        // service that genuinely reverses keeps its reversal and only the
        // folds this pass would have *added* are refused. The next hinge out is
        // then tried, which is usually the one that crosses cleanly.
        func acceptable(_ replacement: [Coord]) -> Bool {
            let was = Geo.length(of: points)
            let now = Geo.length(of: replacement)
            guard now >= was - max(30, was * 0.1) else {
                Self.trace?("reject:shorter \(Int(was))->\(Int(now))|\(journey.line)|\(stop.name)|\(stop.platform ?? "-")")
                return false
            }
            guard throated else { return true }
            let wasFold = retraced(seamed(points)), nowFold = retraced(seamed(replacement))
            guard nowFold > Self.crossoverRetrace,
                  nowFold > wasFold + Self.retraceSlack
            else { return true }
            Self.trace?("reject:fold \(Int(wasFold))->\(Int(nowFold))|\(journey.line)|\(stop.name)|\(stop.platform ?? "-")")
            return false
        }

        // The neighbouring leg's own end, so a fold *at the join* is seen.
        //
        // Half these folds are not inside a leg at all: they are the arriving
        // line ending at the platform and the departing line starting a
        // hundred metres the other side of it, which is a reversal drawn at
        // exactly the point the eye is looking at. A leg examined by itself is
        // straight and the pair is a Z. The departing end is the one that can
        // see both — by the time it is bent the arriving end already has its
        // final shape — so that is where the pair is judged.
        func seamed(_ line: [Coord]) -> [Coord] {
            let neighbour = tail ? leg + 1 : leg - 1
            guard legPoints.indices.contains(neighbour),
                  let touching = tail ? legPoints[neighbour].first : legPoints[neighbour].last
            else { return line }
            return tail ? line + [touching] : [touching] + line
        }

        if tail {
            var kept = Array(points[0..<hinge])
            while let last = kept.last, !beyondSeam(last) { kept.removeLast() }
            let replacement = kept + crossing
            guard acceptable(replacement) else { return false }
            legPoints[leg] = replacement
        } else {
            var kept = Array(points[(hinge + 1)...])
            while let first = kept.first, !beyondSeam(first) { kept.removeFirst() }
            let replacement = crossing + kept
            guard acceptable(replacement) else { return false }
            legPoints[leg] = replacement
        }
        return true
    }

    /// The track a vehicle standing at its first stop has behind it.
    ///
    /// Nothing in the journey describes it — a route relation begins where the
    /// service begins — so it comes from the railway graph, which is the same
    /// OSM track the rest of this file routes over. See
    /// `JourneyGeometry.approach` for why it is not simply spliced onto the
    /// front of the path.
    ///
    /// Asked for only where it can be used and would be believed: a rail
    /// vehicle, whose first leg is real geometry rather than a chord. A bus is
    /// not on this graph at all, and a vehicle already drawn on a straight line
    /// between two stops is not standing on track we could name.
    private func runUp(_ journey: Journey, _ path: [Coord], _ sources: [LegSource]) -> [Coord] {
        guard journey.mode.isRail, railnet.isReady,
              sources.first != .chord, path.count >= 2
        else { return [] }

        // The heading the vehicle faces at its origin, taken over a real step
        // rather than the first one: consecutive vertices at a platform can be
        // centimetres apart, and a bearing off two of those is noise.
        var ahead = 1
        while ahead < path.count, Geo.flatMetres(
            path[0].lon, path[0].lat, path[ahead].lon, path[ahead].lat
        ) < 2 { ahead += 1 }
        guard ahead < path.count else { return [] }

        return railnet.trackBehind(
            from: path[0],
            heading: Geo.bearing(path[0], path[ahead]),
            mode: journey.mode,
            metres: RailNet.runUpMetres(journey.mode)
        )
    }

    /// The turn at which a line has come back on itself rather than bent. The
    /// same threshold `DoublingBackTests` measures against.
    static let foldAngle = 150.0

    /// How much of a line is retraced: at every vertex it comes back on itself,
    /// the shorter of the two arms.
    ///
    /// Metres rather than a count, because the count cannot see the thing that
    /// actually went wrong. A service that reverses at a station reverses in
    /// both drawings — one fold before, one fold after — and a rule comparing
    /// counts calls that no change. What changed is the *size*: the relation
    /// takes the train round the throat over a dozen vertices, none of which
    /// turns far enough to register, while a crossing straight from a hinge
    /// three hundred metres out to the platform and straight back is a single
    /// spike. Same count, and on the map the difference between a curve and
    /// the long white V through the middle of Basel.
    private func retraced(_ raw: [Coord]) -> Double {
        // Repeats first. Two legs share the vertex they meet at, so a window
        // spanning a join carries the stop twice — and a turn measured through
        // a zero-length step is not a shallow turn, it is no turn at all. The
        // spike at Basel SBB was invisible to this for exactly that reason:
        // the guard was reading a duplicated platform vertex and finding a
        // straight line either side of it.
        var line: [Coord] = []
        for point in raw {
            if let last = line.last,
               Geo.flatMetres(last.lon, last.lat, point.lon, point.lat) < 0.5 { continue }
            line.append(point)
        }
        guard line.count >= 3 else { return 0 }
        var metres = 0.0
        for v in 1..<(line.count - 1)
        where Geo.turnDegrees(line[v - 1], line[v], line[v + 1]) > Self.foldAngle {
            metres += min(Geo.metres(line[v - 1], line[v]), Geo.metres(line[v], line[v + 1]))
        }
        return metres
    }

    /// Slack, so a bend is not refused over a metre of jitter in a shape that
    /// already doubled back.
    static let retraceSlack = 10.0

    /// The most line a crossover can honestly retrace.
    ///
    /// The guards below refuse a correction that doubles back more than what it
    /// replaced. On its own that rule has no sense of scale, and scale is the
    /// whole difference between the two things it has to tell apart.
    ///
    /// A crossover is a shallow diagonal between neighbouring tracks. Coming
    /// onto it and leaving it, the drawn line turns twice, and where those
    /// turns are sharp enough to register the arm between them is a few tens of
    /// metres — the length of the diagonal itself. An ICE crossing into Bern 7
    /// measures 29 m by this rule and an IC6 into Bern 5 measures 49 m, and both
    /// are simply what a crossover looks like.
    ///
    /// The artefact this exists to catch is a different order of thing: a
    /// crossing that leaves the relation's rail by the wrong end, runs out into
    /// the station and comes back, meeting itself at the platform as a spike.
    /// At Basel SBB that measured 288 m. There is a factor of six between the
    /// two and nothing in between, so the threshold sits in the gap: retracing
    /// under this is a crossover and always allowed, over it is a shape no
    /// crossover explains and allowed only where the line already had it.
    ///
    /// Without this the rule took back every correction it had just made. Both
    /// trains in the report — an IC6 booked for Bern 7 and one booked for Bern
    /// 5 — were routed onto their platforms correctly and then reverted, 29 m
    /// and 49 m being "worse" than the nothing the relation had. The measured
    /// cost at Bern was 43 platforms.
    static let crossoverRetrace = 120.0

    /// The point exactly `reach` metres in from one end, with the index that
    /// separates the part of the line being kept from the part being replaced.
    /// Nil where the line is too short to give that much up.
    ///
    /// **Exactly, not "the first vertex past it".** A leg out of the rail graph
    /// can be three vertices over two kilometres — OSM records a straight run
    /// with almost no points, and the search returns the nodes it visited — so
    /// stepping to the next vertex was not a rounding error but a different
    /// question: asked for a hinge seven hundred metres back, it answered with
    /// one two thousand metres back, at the far end of the leg. `routeApproach`
    /// then declined it as out of range, and the correction that would have
    /// brought the line to the platform never ran. That is a train drawn four
    /// hundred metres short of the station it is standing in.
    ///
    /// Interpolating costs one vertex and makes the reach mean what every
    /// caller already assumed it meant.
    private func walkIn(
        _ points: [Coord], fromTail: Bool, reach: Double, exact: Bool
    ) -> (index: Int, at: Coord)? {
        guard reach > 0, points.count >= 2 else { return nil }
        var run = 0.0
        if fromTail {
            var i = points.count - 1
            while i > 0 {
                let step = Geo.flatMetres(points[i].lon, points[i].lat, points[i - 1].lon, points[i - 1].lat)
                run += step
                if run >= reach {
                    guard exact else { return (i - 1, points[i - 1]) }
                    // Back off the overshoot along this step, from `i - 1`
                    // towards `i`. `points[0..<i]` is then everything on the
                    // near side of the hinge, `points[i - 1]` included.
                    let back = step > 0 ? (run - reach) / step : 0
                    return (i, Geo.interpolate(points[i - 1], points[i], back))
                }
                i -= 1
            }
            return nil
        }
        for i in 1..<points.count {
            let step = Geo.flatMetres(points[i - 1].lon, points[i - 1].lat, points[i].lon, points[i].lat)
            run += step
            if run >= reach {
                guard exact else { return (i, points[i]) }
                // Same, mirrored: `points[(i - 1 + 1)...]` is the far side.
                let back = step > 0 ? (run - reach) / step : 0
                return (i - 1, Geo.interpolate(points[i], points[i - 1], back))
            }
        }
        return nil
    }
}

/// Where a vehicle is, and which way it is facing.
public struct VehiclePosition: Sendable, Equatable {
    public var lon: Double
    public var lat: Double
    public var bearing: Double
    public var moving: Bool
    /// The call the vehicle is at, or the leg it is running.
    public var index: Int
    public var progress: Double
    /// km/h, averaged over the leg's true length rather than instantaneous.
    public var speed: Double
    /// Whether the position came from mapped geometry rather than a chord.
    public var onTrack: Bool
}

public enum Positioning {
    /// Where stop `index` sits on the mapped track, once geometry has been built.
    ///
    /// `legs[index]` is the vertex the stop was projected onto, i.e. the point
    /// on the way nearest the stop. That is where the vehicle physically
    /// stands; the stop's published coordinate is the centre of the station,
    /// which for a railway station can be a hundred metres from the track in
    /// use.
    public static func trackPoint(_ journey: Journey, _ index: Int) -> Coord? {
        guard let geometry = usableGeometry(journey),
              index >= 0, index < geometry.legs.count
        else { return nil }
        let at = geometry.legs[index]
        guard at >= 0, at < geometry.path.count else { return nil }
        return geometry.path[at]
    }

    /// The vehicle's geometry, but only while it still describes *this* stop
    /// list.
    ///
    /// `legs` carries one index per stop, so a mismatch is proof the geometry
    /// was built for a different version of the journey. Read anyway, leg 3 of
    /// a six-stop sighting answers for stop 3 of the nine-stop journey that
    /// replaced it — which is why a train the timetable put at Thun was drawn
    /// at Bern.
    public static func usableGeometry(_ journey: Journey) -> JourneyGeometry? {
        guard let geometry = journey.geometry,
              !geometry.path.isEmpty,
              geometry.legs.count == journey.stops.count
        else { return nil }
        return geometry
    }

    /// How long before it leaves a vehicle appears at its first platform.
    ///
    /// A train waiting to go is a train, and it is the one a passenger on that
    /// platform is looking for — but the map used to conjure it into existence
    /// at the moment it pulled out, which is exactly when it stops being useful
    /// to find. Three minutes is the walk from the concourse.
    ///
    /// It is a *lead*, not a dwell: the vehicle stands at stop 0 until its
    /// booked departure and then runs the timetable unchanged, so nothing said
    /// beside it moves.
    public static let preDepartureLead = 3 * 60

    /// The first moment this journey is drawn.
    ///
    /// Never while the platform is still occupied by the working that brought
    /// the train in — that vehicle is already on the map, held there by
    /// `Chains.markLayovers`, and drawing the departure early too would put two
    /// dots on one track. See `Journey.heldUntil`.
    public static func appearsAt(_ journey: Journey) -> Timestamp {
        // `stops.first` binds a whole `Call` — six reference-counted strings —
        // to read one integer off it. This and `standsUntil` are the gate every
        // journey in the country passes through on every frame, so the field is
        // read where it lies. See `answer`, which says the same thing.
        guard !journey.stops.isEmpty else { return 0 }
        let early = journey.stops[0].dep - preDepartureLead
        guard let held = journey.heldUntil else { return early }
        return max(early, held + 1)
    }

    /// Where is this journey at unix time `now`?
    ///
    /// Returns nil before it appears and after it has left its last platform,
    /// so callers can simply drop vehicles that are not currently standing or
    /// running. The last platform is held for `terminusHold` even when the
    /// timetable's final arrival and departure are the same second.
    public static func position(of journey: Journey, at now: Timestamp) -> VehiclePosition? {
        position(of: journey, at: Double(now))
    }

    /// The same question asked to better than a second.
    ///
    /// `Timestamp` is whole seconds, and for most of this app's life that was
    /// exactly right: a dot two cantons away moves a metre in a second, and the
    /// draw loop refreshing fifteen times a second over a number that changes
    /// once was work nobody could see the absence of. A two-hundred-metre train
    /// drawn to scale at zoom 17 moves thirty metres in that second — seventy
    /// points — so the whole fleet advanced in one visible jerk per second
    /// however often the map redrew. Everything else here still takes and
    /// returns whole seconds; this is the one entry point that does not.
    public static func position(of journey: Journey, at now: Double) -> VehiclePosition? {
        position(of: journey, at: now, settling: true)
    }

    /// Where a correction in flight has already put the vehicle, rather than
    /// where it is being drawn on the way there.
    ///
    /// `settling: false` is the destination — the honest answer, and the one
    /// anything that has to *aim* at the vehicle needs. The camera catch-up is
    /// the case that matters: it fires on the frame a re-time lands, when the
    /// glide has by construction not moved the vehicle at all yet, so comparing
    /// drawn positions would measure nothing and leave the camera behind while
    /// the train slid out from under it.
    /// `spanChecked` is for the one caller that has already asked whether this
    /// journey is running: `Fleet.vehicles` gates the whole national fleet on
    /// exactly this bound before it decides who is worth locating, and paying
    /// for it twice on everyone who survives is the largest thing left in that
    /// loop at the zooms where most of the fleet survives.
    public static func position(
        of journey: Journey, at now: Double, settling: Bool, spanChecked: Bool = false
    ) -> VehiclePosition? {
        let stops = journey.stops
        guard stops.count >= 2 else { return nil }
        if !spanChecked {
            guard now >= Double(appearsAt(journey)), now <= Double(standsUntil(journey)) else {
                return nil
            }
        }

        // A correction still being walked off. Asked first, because a glide
        // that has expired should cost the frame nothing at all.
        if settling, let shift = settleShift(journey, at: now) {
            // The run is gated on the real clock above and read on the wound-on
            // one here, so a vehicle near either end of its run cannot blink out
            // because the glide asked about a moment outside it. Where the wound
            // clock falls off the stop list, the glide is simply over.
            if let found = located(journey, at: now + shift) { return found }
            journey.settle = nil
        }

        return located(journey, at: now)
    }

    /// How far the clock has to be wound on to reproduce the position this
    /// vehicle was drawn at before its times moved, decaying to nothing.
    ///
    /// Nil once the correction has been spent, which clears it: a settle is
    /// checked on every vehicle of every frame, so the common answer has to be
    /// one comparison.
    ///
    /// Eased out rather than run off linearly. A correction is largest at the
    /// instant it lands and the eye is least able to follow it then, so the
    /// glide covers most of the ground early and arrives gently — which reads
    /// as the map correcting itself rather than as the vehicle being dragged.
    static func settleShift(_ journey: Journey, at now: Double) -> Double? {
        guard let settle = journey.settle else { return nil }
        let age = now - settle.from
        // Behind the correction, or so far past it that the clock has been
        // scrubbed rather than ticked. Either way there is nothing to walk off.
        guard age >= 0, age < settle.over else {
            journey.settle = nil
            return nil
        }
        let left = 1 - age / settle.over

        // Two different shapes, because the two directions are not the same
        // thing to watch.
        //
        // A correction that moves the vehicle *forward* — the run turned out to
        // be earlier than the map thought — is eased out: most of the ground
        // covered early and arriving gently, which reads as the map correcting
        // itself. Nothing about it can look wrong, because going forward is
        // what a vehicle does.
        //
        // A correction that moves it *backwards* is given back at a constant
        // rate instead, spread over the rest of the leg so that the rate is
        // always slower than the vehicle's own progress. The wound-on clock
        // therefore still runs forward, only slower, and the vehicle is drawn
        // losing the ground it never made up rather than reversing over it.
        // See `settleOver`.
        return settle.seconds > 0 ? settle.seconds * left : settle.seconds * left * left
    }

    /// The position the stop list alone puts this vehicle at, with no
    /// correction in flight taken into account.
    private static func located(_ journey: Journey, at now: Double) -> VehiclePosition? {
        let stops = journey.stops
        guard stops.count >= 2 else { return nil }

        // Waiting to leave. The stop-list loop below cannot answer this: it
        // matches a call from its arrival, and an origin has no arrival before
        // its departure to match against.
        if now < Double(stops[0].dep) {
            let on = trackPoint(journey, 0)
            let at = on ?? stops[0].coord
            return VehiclePosition(
                lon: at.lon, lat: at.lat,
                bearing: (on.flatMap { _ in trackBearing(journey, 0) })
                    ?? Geo.bearing(stops[0].coord, stops[1].coord),
                moving: false, index: 0, progress: 0, speed: 0, onTrack: on != nil
            )
        }

        // Where it was last time, then the call after that, then everywhere.
        //
        // Time moves a little between frames and a vehicle stays on one leg for
        // minutes, so the hint is right on all but a handful of the fifteen
        // thousand journeys asked about each frame. Scanning from the beginning
        // instead walked every call of every running journey — and each step
        // copied a `Call`, which is six reference-counted strings, so the cost
        // was retain traffic rather than arithmetic and it dominated the frame.
        let hint = min(max(0, journey.searchHint), stops.count - 1)
        if let found = answer(journey, at: hint, now: now) { return found }
        if hint + 1 < stops.count, let found = answer(journey, at: hint + 1, now: now) {
            journey.searchHint = hint + 1
            return found
        }
        for i in 0..<stops.count {
            if let found = answer(journey, at: i, now: now) {
                journey.searchHint = i
                return found
            }
        }
        return nil
    }

    /// Whether the vehicle is at call `i` or on the leg that leaves it, and
    /// where that puts it.
    ///
    /// Fields are read off `stops[i]` one at a time rather than through a bound
    /// `let stop = stops[i]`: the binding copies the whole struct, and on the
    /// hot path that is six string retains per call per journey per frame.
    private static func answer(
        _ journey: Journey, at i: Int, now: Double
    ) -> VehiclePosition? {
        let stops = journey.stops
        guard i >= 0, i < stops.count else { return nil }
        // Not `stop.dep`: a call the timetable gives no dwell to still holds the
        // vehicle for half a minute, borrowed off the leg that follows.
        let leaves = Double(departsAt(journey, i))

        if now >= Double(stops[i].arr), now <= leaves {
            // Standing at a platform is where the station coordinate is
            // furthest from the truth, so the mapped track wins here just as it
            // does in motion — and it keeps arrival and departure continuous
            // with the leg either side instead of snapping across to the
            // station and back.
            let on = trackPoint(journey, i)
            let at = on ?? stops[i].coord
            let next = i + 1 < stops.count ? stops[i + 1].coord : nil
            return VehiclePosition(
                lon: at.lon, lat: at.lat,
                bearing: (on.flatMap { _ in trackBearing(journey, i) })
                    ?? next.map { Geo.bearing(stops[i].coord, $0) } ?? 0,
                moving: false, index: i, progress: 0, speed: 0, onTrack: on != nil
            )
        }

        guard i + 1 < stops.count, now > leaves, now < Double(stops[i + 1].arr) else { return nil }

        // The leg is run in whatever is left after the hold, so the vehicle is
        // still exactly on time at the next stop.
        let span = Double(stops[i + 1].arr) - leaves
        let elapsed = span > 0 ? (now - leaves) / span : 0
        // Not at a constant speed through the leg. Run at the leg average, a
        // train leaps off the platform at line speed and stops dead at the next
        // one — which is the one thing about a train that everybody has watched
        // happen differently.
        let motion = Motion.profile(elapsed, seconds: span)
        let f = motion.distance

        if let tracked = alongTrack(journey, leg: i, f: f) {
            return VehiclePosition(
                lon: tracked.point.lon, lat: tracked.point.lat, bearing: tracked.bearing,
                moving: true, index: i, progress: f,
                speed: span > 0 ? (tracked.length / span) * 3.6 * motion.rate : 0,
                onTrack: true
            )
        }

        let here = stops[i].coord, next = stops[i + 1].coord
        let point = Geo.interpolate(here, next, f)
        return VehiclePosition(
            lon: point.lon, lat: point.lat, bearing: Geo.bearing(here, next),
            moving: true, index: i, progress: f,
            speed: span > 0 ? (Geo.metres(here, next) / span) * 3.6 * motion.rate : 0,
            onTrack: false
        )
    }

    /// How long a vehicle is held at a call the timetable gives no time to
    /// stand at.
    ///
    /// A tram timetable is written in whole minutes, so most tram calls arrive
    /// and depart in the same one and the dwell computes to zero. Drawn
    /// literally, a tram never stops: it runs the whole line at a constant
    /// crawl and touches each stop for a single frame, which is the one thing
    /// about a tram everybody knows to be wrong.
    ///
    /// The hold is taken *out of the following leg*, not added on the end.
    /// Adding it would push the vehicle past its own next arrival and make the
    /// map disagree with the times printed beside it.
    /// How long a vehicle is held at a call the timetable gives no time for,
    /// by what kind of vehicle it is.
    ///
    /// One number for everything was too long at both ends. A bus pulls in,
    /// opens the doors and goes — ten seconds is the whole of it, and holding
    /// one for thirty made a city bus look permanently stuck. A tram dwells a
    /// little longer for its wider doors and its crossing traffic.
    ///
    /// A train held for thirty spent half a minute sitting on a platform it had
    /// already been booked out of, which read as a stall rather than a stop, so
    /// it takes the bus's ten as well. Only the tram now stands longer.
    static func minDwell(for mode: Mode) -> Int {
        switch mode {
        case .bus: return 10
        case .tram: return 20
        default: return 10
        }
    }
    /// Never eat more than this share of a leg, so a short block still gets run.
    static let maxHoldShare = 0.34

    /// When the vehicle actually pulls out of stop `index`.
    ///
    /// The single source of truth for "has it left yet", so the ring in the
    /// call list and the marker on the map are never in two minds about whether
    /// a tram is still at the stop.
    public static func departsAt(_ journey: Journey, _ index: Int) -> Timestamp {
        let stops = journey.stops
        guard index >= 0, index < stops.count else { return 0 }
        let stop = stops[index]
        // The end of the run is not always the end of the vehicle standing
        // there; see `standsUntil`.
        guard index + 1 < stops.count else { return max(stop.dep, standsUntil(journey)) }

        let missing = minDwell(for: journey.mode) - (stop.dep - stop.arr)
        if missing <= 0 { return stop.dep }
        let span = max(0, stops[index + 1].arr - stop.dep)
        return stop.dep + min(missing, Int(Double(span) * maxHoldShare))
    }

    /// How long a vehicle stays on its last platform after it has arrived,
    /// when nothing else is taking the track.
    ///
    /// A run ends at its final arrival; a *vehicle* does not. Three minutes is
    /// a train discharging and the driver changing ends — the same window
    /// `preDepartureLead` uses at the other end of the run. A bus or a tram
    /// is emptied and gone in one; holding either for three made a city
    /// terminus look like a depot.
    public static func terminusHold(for mode: Mode) -> Int {
        switch mode {
        case .train: return 3 * 60
        default: return 60
        }
    }

    /// The last moment the vehicle is still where it terminated.
    ///
    /// A run ends at its final arrival; a *vehicle* does not. Every mode is
    /// held for `terminusHold` so the marker, the call list and the panel still
    /// describe something standing on the platform. Where the same platform is
    /// booked for a departure a few minutes later — a turnback, which the feed
    /// files as an unrelated journey — `Chains.markLayovers` says how long, and
    /// that bound wins: the platform holds one vehicle at a time.
    public static func standsUntil(_ journey: Journey) -> Timestamp {
        guard !journey.stops.isEmpty else { return 0 }
        return standsUntil(
            mode: journey.mode,
            arrived: journey.stops[journey.stops.count - 1].arr,
            layover: journey.layover
        )
    }

    /// The same bound, from the pieces a snapshot already carries.
    public static func standsUntil(
        mode: Mode, arrived: Timestamp, layover: Layover?
    ) -> Timestamp {
        if let layover { return max(arrived, layover.until) }
        return arrived + terminusHold(for: mode)
    }

    // MARK: - Corrections in flight

    /// How small a re-time is not worth animating.
    ///
    /// Only ever reached in the *forward* direction. A run that turns out to be
    /// a second or two earlier than the map thought is drawn a second or two
    /// further on, and going forwards is what a vehicle does — at the zooms
    /// that shows, it is a vehicle that got on with it.
    ///
    /// Backwards has no floor at all, and that is deliberate — see
    /// `settleFloorBackwards`.
    static let settleFloor: Double = 3

    /// And how small a re-time is not worth animating when it runs *backwards*.
    ///
    /// Nothing is, which is what this number says: every backwards move there
    /// is gets given back by running slow rather than by stepping back, and
    /// this is only here to recognise the move that is not a move at all.
    ///
    /// It used to share `settleFloor`, and that was the whole of "it moves back
    /// every single time, even without delays". A national tick restates every
    /// run in a three-hour window, and the restatement of a train that is
    /// perfectly on time still lands a second or two either way — under the
    /// floor, so no correction was made and the times were simply folded, which
    /// *is* the vehicle stepping. Two seconds of an intercity is fifty-five
    /// metres, and at the zoom a train is drawn as a train that is most of its
    /// own length, hopping backwards every tick.
    ///
    /// It then sat at one second, on the reasoning that times are whole seconds
    /// so a second is the smallest move there is. That stopped being true when
    /// the correction started being measured as a *fraction of a leg* rather
    /// than as the anchor's own shift — see `Retime.along`. A fold that
    /// stretches a leg by a minute moves a vehicle a third of the way through
    /// it by twenty seconds and one a hundredth of the way through it by a
    /// fifth of a second, and neither is a whole number. Under a floor of one
    /// second every vehicle near the start of its leg stepped instead of
    /// gliding — which for a train at line speed is thirty metres.
    ///
    /// So it is a twentieth of a second now: under three metres even for an
    /// intercity, which is below `Fleet.continuityFloor` and therefore below
    /// what the map eases or the reader can see. A tick that restates the times
    /// without changing them still costs nothing — the shift is exactly zero.
    static let settleFloorBackwards: Double = 0.05

    /// How large a re-time stops being a correction.
    ///
    /// Past half an hour the fold is not "this run is late", it is a different
    /// run arriving under the same id — a reused trip number, a replacement
    /// filed against the cancelled working. Gliding across that would draw a
    /// vehicle travelling a route it never took, so it snaps.
    static let settleCeiling: Double = 30 * 60

    /// How long a correction of `shift` seconds takes to walk off.
    ///
    /// Short, and only weakly longer for a bigger jump. The glide is there to
    /// give the eye something to follow, not to show the correction happening:
    /// a minute of lateness is a kilometre or two of track, and stretching that
    /// over a second and a half reads as a train that has slipped its brakes
    /// rather than as a map that has just learned something.
    static func settleOver(_ shift: Double, arrivingIn remaining: Double) -> Double {
        // A run that turned out to be *earlier* is eased forward over a
        // fraction of a second. Nothing about going forwards can look wrong, so
        // there is nothing to spread.
        guard shift > 0 else { return 0.45 + min(0.55, abs(shift) / 240) }

        // A run that turned out to be later has to give ground back, and there
        // is exactly one way to give ground back without running backwards:
        // run slow. So it is given back over *the rest of the leg* — the time
        // the vehicle still has before the call it is running towards, on the
        // times it has just been handed.
        //
        // Which is not an arbitrary duration, it is the only honest one. The
        // fold moved that arrival later by the same `shift` it moved everything
        // else, so the room to give the ground back in always contains the
        // ground to give: the rate below is `shift / (remaining + shift)`,
        // strictly under one, and the vehicle therefore always goes forwards.
        // It is spent exactly when the vehicle reaches the platform, so the
        // correction never outlives the leg it landed on and the map is never
        // wrong about a stop by the time anybody is standing at it.
        //
        // And it is what a late train *is*. A train two minutes down did not
        // reverse two minutes; it ran slow, or stood at a signal, and this
        // draws precisely that — the vehicle loses the time over the run in
        // rather than giving it back in one place.
        //
        // Bounded, though, and that bound wins over landing exactly at the
        // platform: the rest of the leg is only enough room if giving the
        // ground back over it leaves the vehicle still visibly moving. Where it
        // does not, the correction outlives the leg rather than the vehicle
        // being drawn crawling. See `settleAbsorbFastest`.
        return max(0.45, remaining, shift / settleAbsorbFastest)
    }

    /// The most of its own progress a correction may ever eat, as a share.
    ///
    /// **This is the number that decides whether the correction can be seen at
    /// all**, and it is a hard cap rather than a backstop.
    ///
    /// Spreading a correction over the rest of the leg is the right *shape* —
    /// it is what a late train does, and it lands the vehicle exactly right at
    /// the platform. What it is not is bounded: a run that turns out to be two
    /// minutes down with one minute left to the next stop needs two thirds of
    /// its remaining progress to give that back, and a vehicle drawn at a third
    /// of its speed beside traffic moving normally does not read as a late
    /// train. At the extreme it reads as a train that has stopped dead, which
    /// is a bug report rather than a correction — and the speedometer beside it
    /// goes on reporting the *scheduled* speed, so the two visibly disagree.
    ///
    /// So the rate is capped here and the duration gives way instead. At a
    /// quarter the vehicle runs at three quarters of its booked speed, which
    /// beside its neighbours is nothing anybody can pick out, and a correction
    /// that needs longer than the leg simply takes longer than the leg — by
    /// which time it is small, and most likely superseded by the next tick
    /// anyway. Being imperceptibly ahead of the truth for a few minutes is a
    /// far better trade than being conspicuously stopped for one.
    static let settleAbsorbFastest: Double = 0.25

    /// Where this vehicle sits in its own timetable, read before a fold so the
    /// fold can be measured as the distance it moves the vehicle.
    ///
    /// The call taken is the one the vehicle is running *towards*, because that
    /// is the one whose time decides where it is: a run is rarely late by one
    /// number over its whole length, and the lateness at the far terminus says
    /// nothing about a vehicle two stops in.
    public struct Retime: Sendable, Equatable {
        var index: Int
        var arr: Timestamp
        var dep: Timestamp
        /// How far along the leg it was, as a share of that leg's length — nil
        /// for a vehicle standing at a call.
        ///
        /// **The correction has to be measured in this and not in the anchor's
        /// own shift.** A fold moves a call's time; where the vehicle is drawn
        /// is a *fraction of a leg*, and the two are only the same number when
        /// the fold moved both ends of that leg together. It very often does
        /// not: a run that left its last stop on time and picked up a minute on
        /// the way to the next one has its arrival pushed out and its departure
        /// left where it was, which does not shift the leg, it *stretches* it.
        /// Winding the clock on by the minute then walks the vehicle to a
        /// completely different fraction of a longer leg, and the difference
        /// between the two lands in one frame — the train that hops back down
        /// its line the moment a delay arrives. Held as a fraction, the
        /// correction is by construction the one that puts the vehicle exactly
        /// where it already was, whatever the fold did to the numbers.
        ///
        /// Distance along the leg and not time through it, because
        /// `Motion.profile` is a function of how long the leg *takes*: a
        /// stretched leg gets a shorter ramp as a share of itself, so the same
        /// time-fraction of it is a different place. Distance is what the
        /// vehicle is actually drawn at, and `Motion.elapsed` puts the clock
        /// back to it.
        var along: Double?
    }

    /// Take that reading, for a journey that is currently on the map.
    ///
    /// Nil for one that is not, which is most of them: a national tick restates
    /// every run in a three-hour window and only the few hundred actually
    /// standing or moving can be seen to jump.
    public static func retimeAnchor(_ journey: Journey, at now: Timestamp) -> Retime? {
        let stops = journey.stops
        guard stops.count >= 2 else { return nil }
        guard now >= appearsAt(journey), now <= standsUntil(journey) else { return nil }

        // Fields read one at a time rather than through a bound `let stop`,
        // for the reason `answer` gives: the binding retains six strings.
        var index = stops.count - 1
        for i in stops.indices where stops[i].arr >= now {
            index = i
            break
        }

        // And how far along the leg that leads to it, where it is running one.
        // The two numbers are exactly the pair `answer` interpolates between,
        // so the fraction taken here is the one that reproduces the drawn
        // position and not an approximation of it.
        var along: Double?
        if index >= 1 {
            let leaves = Double(departsAt(journey, index - 1))
            let arrives = Double(stops[index].arr)
            if Double(now) > leaves, Double(now) < arrives, arrives > leaves {
                let span = arrives - leaves
                along = Motion.profile((Double(now) - leaves) / span, seconds: span).distance
            }
        }
        return Retime(
            index: index, arr: stops[index].arr, dep: stops[index].dep, along: along
        )
    }

    /// How far the clock has to be wound on for the *new* times to put the
    /// vehicle back at the point of the leg it was drawn at.
    ///
    /// Nil where there is no leg to measure against — a vehicle standing at a
    /// call, one waiting to leave its origin, or a fold that has left the leg
    /// no duration at all — and the caller then measures the anchor's own shift
    /// instead. See `Retime.along` for why that is the fallback rather than
    /// the rule.
    private static func windToFraction(
        _ journey: Journey, _ anchor: Retime, at now: Timestamp
    ) -> Double? {
        guard let along = anchor.along, anchor.index >= 1,
              anchor.index < journey.stops.count
        else { return nil }
        let leaves = Double(departsAt(journey, anchor.index - 1))
        let arrives = Double(journey.stops[anchor.index].arr)
        guard arrives > leaves else { return nil }
        let span = arrives - leaves
        return leaves + Motion.elapsed(at: along, seconds: span) * span - Double(now)
    }

    /// Note that a fold has moved this journey's times, so the vehicle glides
    /// to where they now put it rather than jumping there.
    ///
    /// Call with the anchor taken before the fold. A no-op where the times did
    /// not really move, where the journey was not on the map to begin with, and
    /// where the move is too large to be a correction.
    public static func noteRetimed(_ journey: Journey, from anchor: Retime?, at now: Timestamp) {
        guard let anchor, anchor.index < journey.stops.count else { return }
        // How far the fold moved the call the vehicle is running towards: the
        // *arrival* where it moved, and the departure only where it did not.
        //
        // Which way round that goes is not a detail. `answer` interpolates the
        // leg from the previous departure to exactly this call's `arr`, so
        // `arr` is the number a running vehicle's position depends on. Read off
        // `dep` instead, a fold that moves the two differently is measured
        // against a time that decides nothing — a train given a longer stand at
        // the stop it is heading for has its departure pushed out by minutes
        // while its arrival barely moves, and winding the clock by the
        // departure's shift walks the drawn position clean past the arrival,
        // where `answer` hands back the *standing at the platform* branch at
        // zero speed. That is the "I tap the train and it freezes" report.
        //
        // A terminus has no departure of its own — `Call` fills it equal to the
        // arrival — so both move together there and either reads the same.
        let movedArrival = Double(journey.stops[anchor.index].arr - anchor.arr)
        let fold = movedArrival != 0
            ? movedArrival
            : Double(journey.stops[anchor.index].dep - anchor.dep)

        // **How big a fold this is, and how far it moves the vehicle, are two
        // different questions, and the ceiling is asking the first one.**
        // Whether an hour's fold is a late train or a different train under a
        // reused id is settled by the hour, not by where the vehicle happens to
        // be standing when it lands — the same hour on a call a vehicle has
        // nearly reached moves it a few minutes' worth of track, which would
        // read as an ordinary correction and be glided across.
        guard abs(fold) <= settleCeiling else { return }

        // The correction itself, which is the other question. See `Retime.along`.
        let shift = windToFraction(journey, anchor, at: now) ?? fold
        let floor = shift > 0 ? settleFloorBackwards : settleFloor
        guard abs(shift) >= floor else { return }

        // Added to whatever is still in flight rather than replacing it. Two
        // folds inside one glide — a sweep landing on the frame a tap does —
        // would otherwise throw away the ground the first had left to cover and
        // put the vehicle back where it started.
        let outstanding = settleShift(journey, at: Double(now)) ?? 0
        let total = shift + outstanding
        guard abs(total) >= (total > 0 ? settleFloorBackwards : settleFloor) else {
            journey.settle = nil
            return
        }
        // How long the vehicle still has before it reaches the call it is
        // running towards, on the times it has just been given. That is the
        // room a correction has to be given back in. See `settleOver`.
        let remaining = Double(journey.stops[anchor.index].arr) - Double(now)

        // And the correction may not wind the clock past that arrival.
        //
        // Past it the vehicle is not running at all: `answer` hands back the
        // *standing at the platform* branch, at zero speed, and it stays there
        // for as long as the correction lasts. A train stopped dead on the map
        // while the panel beside it reports line speed is the "I tap it and it
        // freezes" report.
        //
        // Clamped rather than refused, because the correction is still real —
        // it is only the amount of it that can be spent by winding a clock that
        // is bounded by the vehicle still being on its way somewhere.
        //
        // A backstop rather than a working part now. `windToFraction` lands
        // inside the leg by construction, so for a running vehicle this cannot
        // bind at all; what is left for it to catch is the fallback, where a
        // vehicle standing at a call is measured by the anchor's own shift.
        let windable = max(0, min(total, remaining))
        guard windable >= (windable > 0 ? settleFloorBackwards : settleFloor) || total < 0
        else {
            journey.settle = nil
            return
        }
        let spend = total > 0 ? windable : total
        journey.settle = Journey.Settle(
            seconds: spend, from: Double(now),
            over: settleOver(spend, arrivingIn: remaining)
        )
    }

    /// Which call the vehicle is standing at right now, or -1 while it runs.
    public static func dwellingAt(_ journey: Journey, _ now: Timestamp) -> Int {
        for i in 0..<journey.stops.count {
            if now >= journey.stops[i].arr && now <= departsAt(journey, i) { return i }
            if journey.stops[i].arr > now { break }
        }
        return -1
    }

    /// Which way a stopped vehicle faces: along the track it is about to run
    /// over, or the one it arrived on at a terminus.
    static func trackBearing(_ journey: Journey, _ stopIndex: Int) -> Double? {
        guard let geometry = usableGeometry(journey),
              stopIndex < geometry.legs.count
        else { return nil }
        let at = geometry.legs[stopIndex]
        let path = geometry.path
        guard at >= 0, at < path.count else { return nil }
        let here = path[at]

        var i = at + 1
        while i < path.count {
            if path[i] != here { return Geo.bearing(here, path[i]) }
            i += 1
        }
        i = at - 1
        while i >= 0 {
            if path[i] != here { return Geo.bearing(path[i], here) }
            i -= 1
        }
        return nil
    }

    /// Place the vehicle a fraction `f` along leg `leg` of its geometry, moving
    /// at constant speed over the real alignment rather than the straight line.
    static func alongTrack(
        _ journey: Journey, leg: Int, f: Double
    ) -> (point: Coord, bearing: Double, length: Double)? {
        guard let geometry = usableGeometry(journey),
              leg >= 0, leg + 1 < geometry.legs.count
        else { return nil }

        let path = geometry.path
        let start = geometry.legs[leg]
        let end = geometry.legs[leg + 1]
        guard start >= 0, end < path.count, end > start else { return nil }

        var cumulative: [Double] = [0]
        cumulative.reserveCapacity(end - start + 1)
        for i in (start + 1)...end {
            cumulative.append(cumulative[cumulative.count - 1] + Geo.metres(path[i - 1], path[i]))
        }
        let total = cumulative[cumulative.count - 1]
        guard total > 0 else { return nil }

        let target = f * total
        // Legs are short enough (tens of points) that a linear scan beats
        // maintaining a binary search.
        var i = 1
        while i < cumulative.count && cumulative[i] < target { i += 1 }
        if i >= cumulative.count { i = cumulative.count - 1 }

        let segStart = cumulative[i - 1]
        let segLen = cumulative[i] - segStart
        let t = segLen > 0 ? (target - segStart) / segLen : 0

        let a = path[start + i - 1]
        let b = path[start + i]
        return (
            Coord(lon: a.lon + (b.lon - a.lon) * t, lat: a.lat + (b.lat - a.lat) * t),
            Geo.bearing(a, b),
            total
        )
    }

    /// True once the journey has finished and the map may forget it.
    public static func isFinished(_ journey: Journey, _ now: Timestamp) -> Bool {
        guard journey.stops.last != nil else { return true }
        return now > standsUntil(journey) + 120
    }

    /// Next stop the vehicle will call at, for the info panel.
    public static func nextStop(_ journey: Journey, _ now: Timestamp) -> Call? {
        journey.stops.first { $0.arr > now }
    }
}

/// How a vehicle gets from one stop to the next.
///
/// The timetable says a train leaves Spiez at 14:47 and reaches Thun at 14:56,
/// and that is all it says. Everything between those two numbers is the
/// renderer's to invent, and the obvious invention — constant speed — is wrong
/// in the one place a person is looking: at the platform. A train drawn that
/// way is already at line speed the instant it pulls out and is still at line
/// speed the instant it stops, which reads as a mistake even to somebody who
/// has never thought about it.
///
/// So the leg is run to a trapezoidal speed profile: accelerate, hold,
/// decelerate. Two things about it are deliberate.
///
/// **It still arrives exactly on time.** The area under the curve is one whole
/// leg however the curve is shaped, so the vehicle leaves at its departure and
/// arrives at its arrival, and the map never disagrees with the times printed
/// beside it. That is the invariant this whole positioning module is built on.
///
/// **The ramps are a fixed number of seconds, not a fixed share of the leg.**
/// A tram between two stops forty seconds apart spends the whole leg speeding
/// up and slowing down; an intercity on a twenty-minute run spends about a
/// minute doing each and the rest at line speed. A fixed *share* would give the
/// intercity a ten-minute acceleration, which is not a train, it is a glider.
public enum Motion {
    /// About how long a passenger train takes to reach line speed, and about as
    /// long again to brake for a stop.
    ///
    /// It is not one number in reality — an S-Bahn unit is far quicker off the
    /// mark than a hauled intercity — but the difference between fifty seconds
    /// and eighty is not something a map at this scale can show, and the
    /// difference between fifty and zero is.
    public static let rampSeconds = 55.0

    /// What fraction of the leg is spent on each ramp.
    ///
    /// Capped at a half: at exactly a half the profile is a triangle — straight
    /// from accelerating to braking with no cruise at all — which is precisely
    /// what a short tram hop is, and there is nothing past it.
    public static func rampShare(seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return min(0.5, rampSeconds / seconds)
    }

    /// How far through the leg the vehicle is, and how fast it is going as a
    /// multiple of the leg's average speed.
    public static func profile(_ elapsed: Double, seconds: Double) -> (distance: Double, rate: Double) {
        let t = min(1, max(0, elapsed))
        let a = rampShare(seconds: seconds)
        // A leg long enough that the ramps are a rounding error, or one with no
        // duration at all to shape.
        guard a > 1e-6 else { return (t, 1) }

        // Peak speed, as a multiple of the average. The area under the
        // trapezoid is `peak * (1 - a)` and it has to come to one whole leg.
        let peak = 1 / (1 - a)

        if t <= a {
            return (peak * t * t / (2 * a), peak * t / a)
        }
        if t >= 1 - a {
            let left = 1 - t
            return (1 - peak * left * left / (2 * a), peak * left / a)
        }
        return (peak * (t - a / 2), peak)
    }

    /// The inverse: how far through the leg's *time* a vehicle is that has
    /// covered `distance` of its length.
    ///
    /// Exact rather than iterated — the profile is three quadratic pieces and
    /// each inverts in closed form — because it is what a re-time is measured
    /// against, and an approximation there is a vehicle that hops when a delay
    /// lands. See `Positioning.Retime.along`.
    public static func elapsed(at distance: Double, seconds: Double) -> Double {
        let d = min(1, max(0, distance))
        let a = rampShare(seconds: seconds)
        guard a > 1e-6 else { return d }
        let peak = 1 / (1 - a)

        // The ground each ramp covers, which is where the pieces meet.
        let ramp = peak * a / 2
        if d <= ramp { return (2 * a * d / peak).squareRoot() }
        if d >= 1 - ramp { return 1 - (2 * a * (1 - d) / peak).squareRoot() }
        return d / peak + a / 2
    }
}
