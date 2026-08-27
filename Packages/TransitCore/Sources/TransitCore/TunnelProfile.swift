import Foundation

// Where the trains that are not on the surface actually are.
//
// A terrain is a picture of the *ground*, and about a fifth of the Swiss
// railway is not on it. The DEM knows the Lötschberg massif is there and knows
// nothing about the hole through it, so a map with the relief switched on took
// a train doing 200 km/h under two thousand metres of rock and drew it standing
// on the summit — climbing the north face, crossing the ridge, going down the
// other side. It is the single most wrong thing the third dimension does, and
// it is wrong in the way that matters most: not a rendering artefact somebody
// squints at, but a train in the wrong place by a vertical mile.
//
// The data to fix it is already on the device. The routing graph carries a
// `tunnel` bit per edge, and `RailNet.lines` already refuses to weld a surface
// approach onto the tunnel it disappears into — "the portal is exactly where
// the drawing has to change". So a tunnel comes back as its own run of track,
// and the two ends of that run *are* its portals. Everything here follows from
// that: find the run a vehicle is on, measure how far along it the vehicle has
// got, and put the vehicle on the straight line between the two portals.
//
// **A straight line, and no apology for it.** A real tunnel is not quite
// straight in section — it has a summit for drainage, or it climbs at a
// constant grade from end to end — and none of that is in any data this app
// has. What *is* known is that the train is between the two portals and inside
// the hill, and a straight line between the portals says exactly that and
// nothing more. It is right at both ends, where the reader can see the train
// meet the ground, and it is unfalsifiable in the middle, where the reader
// cannot see anything at all.

/// The tunnels near the camera, and where a vehicle is inside one.
///
/// Built from the runs of track the routing graph marks as tunnel, and rebuilt
/// only when the viewport moves — there are a handful in view at the zooms this
/// matters at, and they do not move.
public struct TunnelIndex: Sendable {

    /// How far a vehicle may sit from a bore and still be *that bore's*
    /// vehicle. Generous on purpose: a vehicle's drawn position comes off its
    /// journey's own geometry and a tunnel comes off the routing graph, and the
    /// two traces of the same railway disagree by a track's width most of the
    /// time and a station throat's width occasionally.
    ///
    /// It is not the test for "is this train underground". That one is
    /// `onTrackMetres`. This one only picks a candidate; without the split a
    /// surface line twenty metres from a bypass tunnel became the bypass, and
    /// the train on it a ghost.
    public static let searchMetres = 30.0
    /// How far from the centreline a wagon may sit and still be on the tunnel
    /// rather than on the track beside it.
    ///
    /// Two tracks and a little: Swiss practice is 4.0–4.8 m between centres,
    /// the two geometries disagree by about that, and anything looser starts
    /// swallowing the surface line that runs past a portal.
    public static let onTrackMetres = 10.0
    /// How far into a bore a wagon fades from solid to gone, in metres.
    ///
    /// About a coach and a half. Shorter and a train pops off at the arch;
    /// longer and it is still a solid climbing the hill the tunnel is under.
    /// Each wagon is faded on its own distance, so a rake is swallowed
    /// coach by coach rather than switching as a block.
    public static let fadeMetres = 36.0
    /// Ends this close are the same vertex, for welding split runs back
    /// together. See `weld`.
    public static let joinMetres = 8.0

    /// One tunnel: its centreline, and how far along it each vertex is.
    public struct Bore: Sendable {
        public var points: [Coord]
        /// Metres from the entrance to each vertex, so a position along the
        /// bore is a lookup rather than a walk.
        public var run: [Double]
        /// The box the bore lies in, grown by the search radius.
        ///
        /// The whole of what makes this affordable. Nearly every vehicle on
        /// screen is not in a tunnel, and the Lötschberg is seven hundred
        /// vertices; without a box to reject it against, every bus in Bern
        /// would walk the length of it twice a frame.
        public var box: BBox
        public var length: Double { run.last ?? 0 }
        /// The two portals, which are the two ends.
        public var entrance: Coord { points.first ?? Coord(lon: 0, lat: 0) }
        public var exit: Coord { points.last ?? Coord(lon: 0, lat: 0) }

        /// Height of the straight line between the portals at this distance
        /// from the entrance. The DEM over a tunnel is the mountain, not the
        /// railway; this is the height the railway actually runs at.
        public func altitude(along: Double, entrance: Double, exit: Double) -> Double {
            let fraction = length > 0.5 ? min(1, max(0, along / length)) : 0
            return entrance + (exit - entrance) * fraction
        }
    }

    public var bores: [Bore]

    /// A vehicle's position inside a tunnel.
    public struct Inside: Sendable {
        /// Which bore, so the caller can ask about its portals.
        public var bore: Int
        /// How far through, 0 at the entrance and 1 at the exit.
        public var fraction: Double
        /// The same, in metres from the entrance — what a train's other wagons
        /// are placed against.
        public var along: Double
        /// How long the bore is, so a wagon behind this one can be positioned
        /// without asking again.
        public var length: Double
        /// How far the vehicle is from the near portal, in metres. What the
        /// fade at the mouth is driven off: a train is not suddenly
        /// underground the instant its nose crosses the arch.
        public var fromPortal: Double
        /// How far the vehicle is from the bore's centreline, in metres.
        ///
        /// The match radius has to be generous — see `find` — and generosity is
        /// what lets a *surface* line running beside a bypass tunnel be matched
        /// to it. Two different questions are being asked of one match: "which
        /// bore is this train's" tolerates being wrong, because a train not in
        /// a tunnel is simply drawn on the ground either way, and "is this
        /// train inside the hill" does not. So the distance comes back with the
        /// answer, and the second question can insist on a tighter one.
        public var offset: Double
        /// Compass heading of the matched segment, entrance → exit. A train
        /// on the same rails faces this or its reverse; a road crossing the
        /// portal faces neither.
        public var heading: Double
    }

    public init(_ runs: [[Coord]]) {
        bores = Self.makeBores(Self.weld(runs))
    }

    /// Stitch tunnel polylines that share an endpoint into longer bores.
    ///
    /// `RailNet.lines` already welds along degree-2 nodes, but the graph splits
    /// at every turnout, so one alpine tunnel arrives as many short runs whose
    /// "portals" are underground junctions. DEM sampled at those junctions is
    /// the mountain, not the railway — which is how a train in the Lötschberg
    /// ended up on the ridge. Welding by shared endpoints, taking the unique
    /// continuation through a simple join and the straightest one through a
    /// fork, puts the real portals back at the two ends.
    public static func weld(_ runs: [[Coord]], joinWithin metres: Double = joinMetres) -> [[Coord]] {
        struct Piece {
            var points: [Coord]
            var used = false
        }
        var pieces = runs.filter { $0.count >= 2 }.map { Piece(points: $0) }
        guard pieces.count > 1 else { return pieces.map(\.points) }

        func turn(_ a: Double, _ b: Double) -> Double {
            let delta = abs(a - b).truncatingRemainder(dividingBy: 360)
            return min(delta, 360 - delta)
        }

        func candidates(at: Coord) -> [(index: Int, atStart: Bool)] {
            var out: [(Int, Bool)] = []
            for (index, piece) in pieces.enumerated() where !piece.used {
                let start = piece.points[0]
                let end = piece.points[piece.points.count - 1]
                if Geo.flatMetres(at.lon, at.lat, start.lon, start.lat) <= metres {
                    out.append((index, true))
                }
                if Geo.flatMetres(at.lon, at.lat, end.lon, end.lat) <= metres {
                    out.append((index, false))
                }
            }
            return out
        }

        /// The next unused piece off this end. One neighbour is always the
        /// continuation, even through a hairpin; several is a fork, and only
        /// the straightest one is taken, and only if it is actually straight.
        func pick(at: Coord, incoming: Double) -> (index: Int, atStart: Bool)? {
            let found = candidates(at: at)
            guard !found.isEmpty else { return nil }
            if found.count == 1 { return found[0] }
            var best: (Int, Bool, Double)?
            for (index, atStart) in found {
                let pts = pieces[index].points
                let outgoing = atStart
                    ? Geo.bearing(pts[0], pts[1])
                    : Geo.bearing(pts[pts.count - 1], pts[pts.count - 2])
                let delta = turn(incoming, outgoing)
                if delta <= 80, best == nil || delta < best!.2 {
                    best = (index, atStart, delta)
                }
            }
            return best.map { ($0.0, $0.1) }
        }

        func append(_ chain: inout [Coord], piece: [Coord], atStart: Bool) {
            let extra = atStart ? piece : piece.reversed()
            if chain.isEmpty {
                chain = Array(extra)
                return
            }
            chain.append(contentsOf: extra.dropFirst())
        }

        var welded: [[Coord]] = []
        welded.reserveCapacity(pieces.count)
        for i in pieces.indices where !pieces[i].used {
            pieces[i].used = true
            var chain = pieces[i].points
            while chain.count >= 2 {
                let incoming = Geo.bearing(chain[chain.count - 2], chain[chain.count - 1])
                guard let next = pick(at: chain[chain.count - 1], incoming: incoming) else { break }
                pieces[next.index].used = true
                append(&chain, piece: pieces[next.index].points, atStart: next.atStart)
            }
            chain.reverse()
            while chain.count >= 2 {
                let incoming = Geo.bearing(chain[chain.count - 2], chain[chain.count - 1])
                guard let next = pick(at: chain[chain.count - 1], incoming: incoming) else { break }
                pieces[next.index].used = true
                append(&chain, piece: pieces[next.index].points, atStart: next.atStart)
            }
            chain.reverse()
            welded.append(chain)
        }
        return welded
    }

    private static func makeBores(_ runs: [[Coord]]) -> [Bore] {
        runs.compactMap { points in
            guard points.count >= 2 else { return nil }
            var run: [Double] = [0]
            run.reserveCapacity(points.count)
            for i in 1..<points.count {
                run.append(run[i - 1] + Geo.metres(points[i - 1], points[i]))
            }
            guard let total = run.last, total > 1 else { return nil }
            // Half a kilometre of margin, which at these latitudes is well
            // over the search radius and costs a rejection test nothing.
            let pad = 0.005
            return Bore(
                points: points, run: run,
                box: BBox(
                    west: (points.map(\.lon).min() ?? 0) - pad,
                    south: (points.map(\.lat).min() ?? 0) - pad,
                    east: (points.map(\.lon).max() ?? 0) + pad,
                    north: (points.map(\.lat).max() ?? 0) + pad
                )
            )
        }
    }

    public var isEmpty: Bool { bores.isEmpty }

    /// Which tunnel a point is nearest, if any, within `metres`.
    ///
    /// This is the generous match — see `searchMetres`. It is not the answer
    /// to "is this wagon underground"; `onTrack` is.
    public func find(_ point: Coord, within metres: Double = searchMetres) -> Inside? {
        var best: Inside?
        var bestDistance = metres
        for (index, bore) in bores.enumerated() {
            guard bore.box.contains(lon: point.lon, lat: point.lat) else { continue }
            for i in 1..<bore.points.count {
                let hit = Geo.projectOnSegment(
                    lon: point.lon, lat: point.lat,
                    a: bore.points[i - 1], b: bore.points[i]
                )
                guard hit.distance < bestDistance else { continue }
                bestDistance = hit.distance
                let along = bore.run[i - 1] + Geo.metres(bore.points[i - 1], hit.foot)
                best = Inside(
                    bore: index,
                    fraction: min(1, max(0, along / max(1, bore.length))),
                    along: along, length: bore.length,
                    fromPortal: min(along, bore.length - along),
                    offset: hit.distance,
                    heading: Geo.bearing(bore.points[i - 1], bore.points[i])
                )
            }
        }
        return best
    }

    /// Whether this wagon is on tunnel track, not merely near it.
    ///
    /// Asked per wagon, because a "bore" here is still sometimes a short run
    /// between two turnouts: a sixteen-coach train halfway into Geneva is on
    /// four of those runs at once, and testing the whole rake against the
    /// one the head matched put the coaches behind the head back in the open.
    ///
    /// `heading`, when given, refuses a crossing: a road over a portal and the
    /// railway under it share a point and not a direction. Opposite-direction
    /// on the same rails is still on the rails.
    public func onTrack(_ point: Coord, heading: Double? = nil) -> Inside? {
        guard let hit = find(point), hit.offset <= Self.onTrackMetres else { return nil }
        if let heading {
            let delta = abs(heading - hit.heading).truncatingRemainder(dividingBy: 360)
            let acute = min(delta, 360 - delta)
            // 0° = same way, 180° = opposite way, ~90° = a crossing.
            if acute > 50 && acute < 130 { return nil }
        }
        return hit
    }

    /// How hidden a wagon at this point is: 0 in the open, 1 once it is
    /// far enough inside to vanish. See `fadeMetres`.
    public func fade(at point: Coord, heading: Double? = nil) -> Double {
        guard let hit = onTrack(point, heading: heading) else { return 0 }
        return Self.fade(hit.fromPortal)
    }

    /// 0 at the arch, 1 at `fadeMetres` inside.
    public static func fade(_ fromPortal: Double) -> Double {
        min(1, max(0, fromPortal / fadeMetres))
    }

    /// Nose-up grade of the portal line, signed for a train facing `heading`.
    public func grade(
        _ hit: Inside, heading: Double, entranceAltitude: Double, exitAltitude: Double
    ) -> Double {
        guard hit.length > 1 else { return 0 }
        let alongSlope = (exitAltitude - entranceAltitude) / hit.length
        let aligned = cos(Geo.toRad(heading - hit.heading))
        let travel = aligned >= 0 ? alongSlope : -alongSlope
        return max(-50, min(50, atan(travel) * 180 / .pi))
    }

    /// How far a vehicle at this position is inside the hill, 0 to 1.
    ///
    /// Not a switch, because a portal is not a switch. A two-hundred-metre
    /// train takes several seconds to get its whole length inside, and a
    /// vehicle that changed state the instant its centre crossed the arch would
    /// pop — half a train solid and half of it ghosted is a worse picture than
    /// either. Faded across the length of the vehicle itself, which is exactly
    /// the distance over which the statement "this train is in a tunnel" goes
    /// from false to true.
    public static func depth(_ fromPortal: Double, vehicleLength: Double) -> Double {
        let over = max(20, min(240, vehicleLength))
        return min(1, max(0, fromPortal / over))
    }
}

/// One train inside one bore: where its two ends are along it, and how high the
/// two portals are.
///
/// Everything a wagon needs to be put underground, resolved once for the whole
/// train. The two lookups are the expensive part and the interpolation between
/// them is free — and it is also *more* right than asking per wagon would be,
/// because a rigid train inside a bore is exactly a linear interpolation
/// between its ends, and sixteen separate answers would differ from each other
/// by the noise in the samples they came from.
public struct TunnelRun: Sendable {
    /// Metres from the entrance to the head of the train, and to its tail.
    ///
    /// Either may fall outside the bore — negative, or past its length — for a
    /// train only part way in, which is exactly what makes the fade at the
    /// portal come out right without a special case for it.
    public var alongHead: Double
    public var alongTail: Double
    public var boreLength: Double
    public var trainLength: Double
    /// How high the two portals are, in metres above sea level.
    public var entranceAltitude: Double
    public var exitAltitude: Double
    /// How far this train is from the bore's centreline, in metres. See
    /// `TunnelIndex.Inside.offset`, and `buriedness` for what insists on it.
    public var offset: Double

    public init(
        alongHead: Double, alongTail: Double, boreLength: Double, trainLength: Double,
        entranceAltitude: Double, exitAltitude: Double, offset: Double = 0
    ) {
        self.alongHead = alongHead
        self.alongTail = alongTail
        self.boreLength = boreLength
        self.trainLength = trainLength
        self.entranceAltitude = entranceAltitude
        self.exitAltitude = exitAltitude
        self.offset = offset
    }

    /// How much ground stands over one wagon, in metres.
    ///
    /// Zero on a map with no relief, where every height here is zero and there
    /// is no mountain to be under in the first place — and zero under a flat
    /// city too, which is why it cannot be the only question asked. See
    /// `buriedness`.
    public func cover(alongTrain: Double, ground: Double) -> Double {
        max(0, ground - at(alongTrain: alongTrain, ground: ground).altitude)
    }

    /// Whether this wagon is drawn as being under something.
    ///
    /// On the centreline of a tunnel run, between its two ends. That is the
    /// whole test. Cover — ground minus the interpolated bore — was the
    /// fallback for a match that had landed beside the rails, and it is what
    /// painted a train ghosted on ordinary alpine track: a surface line over a
    /// tunnel sits inside the generous search radius, the DEM there is the
    /// hillside, and "cover" of a few dozen metres is just a hill.
    ///
    /// City tunnels have no cover at all (portal to portal at street level), so
    /// cover could never have been the thing that buried them; being on the
    /// tunnel track is. Parallel surface track is rejected by `offset`.
    ///
    /// Prefer `TunnelIndex.onTrack` at the wagon's own coordinate. This one
    /// remains for a whole train already resolved onto one bore — a rake
    /// halfway through a portal has the coaches that are inside drawn as
    /// inside and the ones still out in the daylight drawn as out.
    public func buriedness(alongTrain: Double, ground: Double) -> Double {
        guard offset <= TunnelIndex.onTrackMetres else { return 0 }
        let along = alongHead + (alongTail - alongHead) * (
            trainLength > 0.5 ? min(1, max(0, alongTrain / trainLength)) : 0
        )
        return along >= 0 && along <= boreLength ? 1 : 0
    }

    /// Nose-up grade of the straight line between the portals, in degrees.
    ///
    /// The DEM over a tunnel is the mountain, not the railway: a wagon that
    /// takes its tilt from the ground above the Lötschberg stands on its
    /// nose. The bore is a line between two portals, and that line is the
    /// only slope a train inside it can have.
    public func grade() -> Double {
        guard boreLength > 1, trainLength > 0.5 else { return 0 }
        let alongSlope = (exitAltitude - entranceAltitude) / boreLength
        let dh = alongSlope * (alongTail - alongHead) / trainLength
        return max(-50, min(50, -atan(dh) * 180 / .pi))
    }

    public func at(alongTrain: Double, ground: Double) -> (altitude: Double, depth: Double) {
        let through = trainLength > 0.5
            ? min(1, max(0, alongTrain / trainLength))
            : 0
        let along = alongHead + (alongTail - alongHead) * through
        let fraction = boreLength > 0.5 ? min(1, max(0, along / boreLength)) : 0
        let bore = entranceAltitude + (exitAltitude - entranceAltitude) * fraction
        // Inside the run, the altitude is the line between the portals and
        // nothing else. Mixing in the ground above was what put a train on
        // the summit: even fifty metres past the arch the fade had only
        // given up a quarter of the mountain.
        // Strict: on the arch itself the bore *is* the ground, and treating
        // that point as inside would drop a coach through the portal by the
        // first sample of mountain over the entrance.
        let inside = along > 0 && along < boreLength
        if inside {
            return (bore, 1)
        }
        let depth = TunnelIndex.depth(
            min(along, boreLength - along), vehicleLength: trainLength
        )
        return (ground + (bore - ground) * depth, depth)
    }
}
