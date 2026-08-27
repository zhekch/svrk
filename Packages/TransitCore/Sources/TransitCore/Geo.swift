import Foundation

/// A longitude/latitude pair, in that order — the order the whole data set uses.
///
/// The JavaScript this is ported from passes coordinates as bare `[lon, lat]`
/// arrays, and the generated data files store them that way too. Naming the
/// members is the one change worth making: `path[i][0]` reads as nothing in
/// particular, and every `x`/`y` mix-up in the original's history came from a
/// pair whose order had to be remembered rather than read.
public struct Coord: Equatable, Hashable, Sendable, Codable {
    public var lon: Double
    public var lat: Double

    public init(lon: Double, lat: Double) {
        self.lon = lon
        self.lat = lat
    }
}

/// A west/south/east/north bounding box.
public struct BBox: Hashable, Sendable, Codable {
    public var west: Double
    public var south: Double
    public var east: Double
    public var north: Double

    public init(west: Double, south: Double, east: Double, north: Double) {
        self.west = west
        self.south = south
        self.east = east
        self.north = north
    }

    public func contains(lon: Double, lat: Double) -> Bool {
        lat >= south && lat <= north && lon >= west && lon <= east
    }

    /// Whether the two boxes overlap at all.
    ///
    /// Used to reject a journey whose entire route is elsewhere before
    /// anything asks where its vehicle currently is. See `Journey.drawnWithin`.
    public func intersects(_ other: BBox) -> Bool {
        west <= other.east && east >= other.west
            && south <= other.north && north >= other.south
    }

    /// The same box grown by a fraction of its own size on each axis.
    ///
    /// Used so vehicles do not pop into existence exactly at the screen edge.
    public func padded(by fraction: Double) -> BBox {
        let latPad = (north - south) * fraction
        let lonPad = (east - west) * fraction
        return BBox(west: west - lonPad, south: south - latPad, east: east + lonPad, north: north + latPad)
    }

    /// Whether `other` describes a meaningfully different view from this one.
    ///
    /// Every edge has to have moved less than `tolerance` for the answer to be
    /// no, so a pan is caught on the leading edge before anything has scrolled
    /// far enough to matter. Written in degrees because that is what the box
    /// carries and the comparison is against a threshold chosen in the same
    /// unit — see `MapCoordinator.reportViewport`, the one caller.
    public func moved(from other: BBox, by tolerance: Double) -> Bool {
        abs(west - other.west) > tolerance || abs(east - other.east) > tolerance
            || abs(south - other.south) > tolerance || abs(north - other.north) > tolerance
    }

    /// The same box grown by a fixed distance on the ground.
    ///
    /// A fraction is the wrong unit once the thing being looked for is longer
    /// than the box. Zoomed in on a platform the viewport is a couple of
    /// hundred metres across, a fifteenth of that is a few metres, and a train
    /// whose *head* has gone off the top of the screen is dropped from the
    /// query — so the whole train vanishes at exactly the zoom somebody went in
    /// to look at it.
    public func padded(byMetres metres: Double) -> BBox {
        let latPad = metres / Geo.metresPerDegree
        let midLat = (north + south) / 2
        let lonPad = metres / (Geo.metresPerDegree * max(0.2, cos(Geo.toRad(midLat))))
        return BBox(west: west - lonPad, south: south - latPad, east: east + lonPad, north: north + latPad)
    }
}

public enum Geo {
    static let earthRadius = 6_371_000.0
    /// Metres per degree of latitude. Constant enough at this scale; the
    /// original uses the same figure throughout.
    static let metresPerDegree = 111_320.0

    @inline(__always) public static func toRad(_ degrees: Double) -> Double { degrees * .pi / 180 }
    @inline(__always) public static func toDeg(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Haversine distance in metres.
    public static func metres(_ aLon: Double, _ aLat: Double, _ bLon: Double, _ bLat: Double) -> Double {
        let p1 = toRad(aLat), p2 = toRad(bLat)
        let sinLat = sin((p2 - p1) / 2)
        let sinLon = sin(toRad(bLon - aLon) / 2)
        let h = sinLat * sinLat + cos(p1) * cos(p2) * sinLon * sinLon
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }

    public static func metres(_ a: Coord, _ b: Coord) -> Double {
        metres(a.lon, a.lat, b.lon, b.lat)
    }

    /// Flat-earth distance in metres, scaled at `b`'s latitude.
    ///
    /// Deliberately not haversine. The original uses this wherever the two
    /// points are a few hundred metres apart at most — a platform and the track
    /// beside it — where the difference is far below anything being claimed and
    /// the trig is the expensive part of an inner loop.
    public static func flatMetres(_ aLon: Double, _ aLat: Double, _ bLon: Double, _ bLat: Double) -> Double {
        let y = (aLat - bLat) * metresPerDegree
        let x = (aLon - bLon) * metresPerDegree * cos(toRad(bLat))
        return (x * x + y * y).squareRoot()
    }

    /// A compass heading made continuous with the previous one.
    ///
    /// Bearings live in `[0, 360)`, so a wagon that turns through north jumps
    /// from 359 to 1. Linear interpolation of those two — which is what a
    /// renderer does with a rotation transition — takes the long way around,
    /// spinning the coach through 180°. Unwrapped, 359 is followed by 361 and
    /// the short arc is the one that is interpolated.
    public static func unwrapHeading(_ heading: Double, previous: Double?) -> Double {
        guard let previous else { return heading }
        var heading = heading
        while heading - previous > 180 { heading -= 360 }
        while previous - heading > 180 { heading += 360 }
        return heading
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from north.
    public static func bearing(_ a: Coord, _ b: Coord) -> Double {
        let lat1 = toRad(a.lat), lat2 = toRad(b.lat)
        let dLon = toRad(b.lon - a.lon)
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (toDeg(atan2(y, x)) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// East and north, in metres, from `from` to `to`.
    ///
    /// Signed components rather than a distance, so a spring that integrates
    /// the two axes travels in a straight line on the ground. A degree of
    /// longitude is shorter than a degree of latitude here, and springing
    /// lon/lat independently would lean every west–east jump.
    public static func eastNorth(from: Coord, to: Coord) -> (east: Double, north: Double) {
        let north = flatMetres(from.lon, from.lat, from.lon, to.lat)
        let east = flatMetres(from.lon, to.lat, to.lon, to.lat)
        return (
            to.lon >= from.lon ? east : -east,
            to.lat >= from.lat ? north : -north
        )
    }

    /// A point `metres` away on a bearing, flat-earth.
    ///
    /// Deliberately not great-circle, and for the same reason `flatMetres` is
    /// not haversine: everything that asks for this is stepping a few tens of
    /// metres — to the end of a wagon, to the far side of a platform — and over
    /// that the two answers differ by less than the width of the thing being
    /// drawn.
    public static func moved(_ from: Coord, bearing: Double, metres: Double) -> Coord {
        let radians = toRad(bearing)
        let north = metres * cos(radians)
        let east = metres * sin(radians)
        return Coord(
            lon: from.lon + east / (metresPerDegree * cos(toRad(from.lat))),
            lat: from.lat + north / metresPerDegree
        )
    }

    /// Great-circle interpolation. Over a few kilometres this is visually a
    /// straight line, but it is what keeps a long leg — a night train across
    /// Germany — from bowing away from the route it claims to follow.
    public static func interpolate(_ a: Coord, _ b: Coord, _ f: Double) -> Coord {
        let lat1 = toRad(a.lat), lon1 = toRad(a.lon)
        let lat2 = toRad(b.lat), lon2 = toRad(b.lon)
        let sinLat = sin((lat2 - lat1) / 2)
        let sinLon = sin((lon2 - lon1) / 2)
        let h = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLon * sinLon
        let d = 2 * asin(min(1, h.squareRoot()))
        if d == 0 { return a }

        let A = sin((1 - f) * d) / sin(d)
        let B = sin(f * d) / sin(d)
        let x = A * cos(lat1) * cos(lon1) + B * cos(lat2) * cos(lon2)
        let y = A * cos(lat1) * sin(lon1) + B * cos(lat2) * sin(lon2)
        let z = A * sin(lat1) + B * sin(lat2)
        return Coord(lon: toDeg(atan2(y, x)), lat: toDeg(atan2(z, (x * x + y * y).squareRoot())))
    }

    /// Total length of a polyline, in metres.
    public static func length(of points: [Coord]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count {
            total += flatMetres(points[i - 1].lon, points[i - 1].lat, points[i].lon, points[i].lat)
        }
        return total
    }

    /// Douglas–Peucker, tolerance in **metres**.
    ///
    /// The original carried this as `2.5e-4` *degrees* for a while, which is not
    /// a length — read as one it is about 28 m, a quarter of the way across a
    /// football pitch. The routed line left the rails on every bend and cut the
    /// corner at every junction. 1 m is under two pixels at zoom 17, and since
    /// the graph's own nodes are OSM way vertices this discards only genuinely
    /// collinear runs.
    public static func simplify(_ points: [Coord], toleranceMetres: Double = 1) -> [Coord] {
        guard points.count >= 3 else { return points }

        // Longitude scaled to metres at the path's own latitude; a leg spans a
        // few kilometres, over which the factor is constant well below tolerance.
        let kx = metresPerDegree * cos(toRad(points[points.count / 2].lat))
        let ky = metresPerDegree

        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        let limit = toleranceMetres * toleranceMetres

        while let (first, last) = stack.popLast() {
            var maxDist = 0.0
            var idx = -1
            let x1 = points[first].lon * kx, y1 = points[first].lat * ky
            let x2 = points[last].lon * kx, y2 = points[last].lat * ky
            let dx = x2 - x1, dy = y2 - y1
            let lenSq = dx * dx + dy * dy

            if first + 1 < last {
                for i in (first + 1)..<last {
                    let px = points[i].lon * kx, py = points[i].lat * ky
                    var t = lenSq == 0 ? 0 : ((px - x1) * dx + (py - y1) * dy) / lenSq
                    t = max(0, min(1, t))
                    let ddx = px - (x1 + t * dx)
                    let ddy = py - (y1 + t * dy)
                    let d = ddx * ddx + ddy * ddy
                    if d > maxDist {
                        maxDist = d
                        idx = i
                    }
                }
            }

            if idx != -1 && maxDist > limit {
                keep[idx] = true
                stack.append((first, idx))
                stack.append((idx, last))
            }
        }

        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }
}

extension Geo {
    /// How far `(lon, lat)` is from the segment `a`–`b`, and where the foot of
    /// that perpendicular lands.
    ///
    /// Both come from the same projection, so they are computed together: the
    /// distance answers *which* rail a platform belongs to and the foot answers
    /// *where along it* the vehicle stands. Flat-projected about the query
    /// point, which over the tens of metres this is used for is exact enough
    /// that the error is far below the coordinate precision the data carries.
    static func projectOnSegment(
        lon: Double, lat: Double, a: Coord, b: Coord
    ) -> (distance: Double, foot: Coord) {
        let perLon = metresPerDegree * cos(toRad(lat))
        let ax = (a.lon - lon) * perLon, ay = (a.lat - lat) * metresPerDegree
        let bx = (b.lon - lon) * perLon, by = (b.lat - lat) * metresPerDegree
        let dx = bx - ax, dy = by - ay
        let lengthSq = dx * dx + dy * dy
        guard lengthSq > 0 else {
            return ((ax * ax + ay * ay).squareRoot(), a)
        }
        var t = -(ax * dx + ay * dy) / lengthSq
        t = max(0, min(1, t))
        let cx = ax + dx * t, cy = ay + dy * t
        return (
            (cx * cx + cy * cy).squareRoot(),
            Coord(lon: a.lon + (b.lon - a.lon) * t, lat: a.lat + (b.lat - a.lat) * t)
        )
    }

    static func distanceToSegment(lon: Double, lat: Double, a: Coord, b: Coord) -> Double {
        projectOnSegment(lon: lon, lat: lat, a: a, b: b).distance
    }

    static func footOnSegment(lon: Double, lat: Double, a: Coord, b: Coord) -> Coord {
        projectOnSegment(lon: lon, lat: lat, a: a, b: b).foot
    }
}

extension Geo {
    /// How long an out-and-back may be before it is taken to be real.
    ///
    /// Station-scale: what this removes is a way that runs past the platform
    /// and is then walked back, which is the length of a station throat rather
    /// than of a journey. A train that genuinely reverses away from a platform
    /// — up a spur to run round, into a headshunt — travels further than this,
    /// and keeps its excursion.
    public static let spurMetres = 600.0

    /// Drop the excursions a line makes out of its own way and straight back.
    ///
    /// An OSM route relation is a list of ways, and a way is as long as
    /// whoever drew it made it. Where a service reverses at a station, the
    /// relation names the arrival way and then the departure way, and the two
    /// meet at the *end of the way* rather than at the platform — so the
    /// stitched line runs a couple of hundred metres out into the throat and
    /// comes back over its own vertices before setting off. Drawn, that is a
    /// spike on the map at exactly the place a user is looking: IC8 leaving
    /// Bern for Thun ran 220 m west past platform 6 and returned.
    ///
    /// The test is the retracing itself, which is what tells a spur from a
    /// loop. A line that leaves a vertex and comes straight back to it —
    /// `p[j-1] == p[j+1]` — is folded there, and the fold is followed outward
    /// for as long as the two sides match vertex for vertex, so the whole
    /// excursion is measured rather than its tip. A turning loop or a spiral
    /// returns to its junction over *different* vertices and is left alone.
    ///
    /// Exact coordinate equality is the right test and not a fragile one:
    /// these are the same OSM node arriving twice, carried as the same packed
    /// integers, not two points that happen to be close.
    public static func withoutSpurs(_ points: [Coord], limit: Double = spurMetres) -> [Coord] {
        guard points.count >= 3 else { return points }
        var out = points
        var j = 1
        while j + 1 < out.count {
            guard out[j - 1] == out[j + 1] else { j += 1; continue }

            // The whole of the fold, not just its tip: extend outward while the
            // two sides keep matching vertex for vertex.
            var reach = 1
            while j - reach - 1 >= 0, j + reach + 1 < out.count,
                  out[j - reach - 1] == out[j + reach + 1] { reach += 1 }

            let there = length(of: Array(out[(j - reach)...j]))
            if 2 * there > limit { j += 1; continue }

            out.removeSubrange((j - reach + 1)...(j + reach))
            // Removing an inner fold can leave an outer one adjacent, so carry
            // on from where this one began rather than from the far side.
            j = max(1, j - reach)
        }
        return out
    }
}

extension Geo {
    /// The angle the line turns through at `b`, in degrees.
    ///
    /// Zero is straight on and 180 is a reversal, which is the only reading
    /// that matters: every rule below is stated as "the line turned more than
    /// this", and stating it as a bearing change would need the wrap at 360
    /// handled at every call site.
    ///
    /// Segments shorter than half a metre have no meaningful direction — two
    /// sources joining at what is nominally the same point differ in the last
    /// digit — so they report as straight rather than as noise.
    public static func turnDegrees(_ a: Coord, _ b: Coord, _ c: Coord) -> Double {
        let kx = metresPerDegree * cos(toRad(b.lat))
        let ux = (b.lon - a.lon) * kx, uy = (b.lat - a.lat) * metresPerDegree
        let vx = (c.lon - b.lon) * kx, vy = (c.lat - b.lat) * metresPerDegree
        let lu = (ux * ux + uy * uy).squareRoot()
        let lv = (vx * vx + vy * vy).squareRoot()
        guard lu > 0.5, lv > 0.5 else { return 0 }
        let cosine = max(-1, min(1, (ux * vx + uy * vy) / (lu * lv)))
        return toDeg(acos(cosine))
    }

    /// The turn at which a line has stopped bending and started coming back.
    ///
    /// A tram takes a street corner at ninety degrees and a railway curve is
    /// far gentler than that, so the threshold has to clear both: what is left
    /// above 150° is a line that has reversed, which no vehicle does between
    /// two of its own stops.
    public static let foldAngle = 150.0

    /// How long a stub at the very end of a leg may be and still be taken for
    /// a way that was drawn past the platform rather than for real track.
    ///
    /// Station-scale, and much shorter than `spurMetres`: this removes the
    /// overshoot at a join, not an excursion up a headshunt.
    public static let endStubMetres = 150.0

    /// Drop a leg's first or last step where it runs the wrong way and comes
    /// straight back.
    ///
    /// A relation joins its member ways end to end, and a way ends where its
    /// author stopped drawing. Where the join sits beyond the platform, the leg
    /// out of that station opens with a short run past it and a reversal — the
    /// IC8 out of Bern begins twenty-nine metres to the west, turns a hundred
    /// and eighty degrees, and runs back east past where it started. Drawn,
    /// that is the "it jumps across the tracks" report.
    ///
    /// Neither existing pass catches it. `withoutSpurs` wants the two sides to
    /// be the same vertices and they are not; `withoutFolds` asks whether the
    /// line comes back *alongside* what it just covered, and here the way back
    /// clears the stub's own start in one sparse step, so the corridor test
    /// never gets a chance.
    ///
    /// The rule needs neither: at the *end* of a leg there is no earlier line
    /// to compare against, and a vehicle does not reverse between two of its
    /// own stops — that happens at a stop, which is a leg boundary. So a first
    /// or last step that turns back on itself is the join showing through, and
    /// it goes. The endpoint itself is kept: it is where the stop is.
    public static func withoutEndStubs(
        _ points: [Coord], limit: Double = endStubMetres
    ) -> [Coord] {
        var out = points
        while out.count >= 3,
              turnDegrees(out[0], out[1], out[2]) > foldAngle,
              flatMetres(out[0].lon, out[0].lat, out[1].lon, out[1].lat) <= limit {
            out.remove(at: 1)
        }
        while out.count >= 3,
              turnDegrees(out[out.count - 3], out[out.count - 2], out[out.count - 1]) > foldAngle,
              flatMetres(out[out.count - 1].lon, out[out.count - 1].lat,
                         out[out.count - 2].lon, out[out.count - 2].lat) <= limit {
            out.remove(at: out.count - 2)
        }
        return out
    }

    /// How far apart the two arms of a fold may run and still be the same
    /// stretch of line, travelled twice.
    ///
    /// Wide enough for the neighbouring track — platforms at Bern are about
    /// twenty metres apart centre to centre — and far short of the radius of
    /// any turning loop, which is what this must not mistake a fold for.
    public static let foldCorridor = 30.0

    /// Drop the stretches a line runs twice in opposite directions.
    ///
    /// `withoutSpurs` catches the fold whose two sides are the *same OSM
    /// nodes* in reverse, which is what a relation joining two ways end to end
    /// produces. It cannot catch the rest, and the rest is most of them: where
    /// a leg is bent onto its platform and the leg after it is bent onto the
    /// same platform, the two meet at two different points a few tens of
    /// metres apart, so the join runs backwards and then forwards again over
    /// vertices that are near each other and equal to none of them.
    ///
    /// Fifty metres sounds like nothing and is the whole screen at the zoom
    /// somebody actually watches a train at — and the train is drawn *along*
    /// this line, so it folds in half with it. That is the hook the S1 was
    /// drawn as at Bern.
    ///
    /// The test is `withoutSpurs`' own, loosened from equality to nearness: a
    /// vertex the line turns more than `foldAngle` at is an apex, and the two
    /// arms leading out of it are followed — by arc length rather than by
    /// vertex, since retracing over *different* vertices is the case this
    /// exists for — for as long as they stay within `corridor` of each other.
    /// That is what still tells a fold from a turning loop: a loop's arms part
    /// company at once and are left alone.
    public static func withoutFolds(
        _ points: [Coord], limit: Double = spurMetres, corridor: Double = foldCorridor
    ) -> [Coord] {
        guard points.count >= 3 else { return points }
        var out = points
        var apex = 1
        while apex + 1 < out.count {
            guard turnDegrees(out[apex - 1], out[apex], out[apex + 1]) > foldAngle else {
                apex += 1
                continue
            }
            guard let cut = fold(in: out, apex: apex, limit: limit, corridor: corridor) else {
                apex += 1
                continue
            }
            out.removeSubrange((cut.first + 1)...(cut.last - 1))
            // Removing one fold can leave its neighbour adjacent — the S1's
            // seams came in pairs — so carry on from where this one began.
            apex = max(1, cut.first)
        }
        return out
    }

    /// The span to remove for the fold at `apex`, or nil where the line has
    /// genuinely reversed rather than retraced.
    ///
    /// The question asked is the one that separates the two: after turning
    /// back at the apex, does the line come back *alongside the stretch it has
    /// just covered*? A retrace does, within a track's width. A turning loop
    /// swings away and rejoins somewhere else, and a train reversing up a
    /// headshunt runs further than `limit` before it returns at all — so
    /// neither is found here, and both keep their excursion.
    ///
    /// Measured against the outbound segment rather than vertex by vertex,
    /// because the two sides of these folds are different vertices: the way
    /// back is the next track over, or the same track drawn by somebody else.
    private static func fold(
        in points: [Coord], apex: Int, limit: Double, corridor: Double
    ) -> (first: Int, last: Int)? {
        let first = apex - 1
        guard first >= 0 else { return nil }
        let from = points[first], tip = points[apex]

        // The outbound arm, in metres about the apex, so the walk back can be
        // measured along it and across it separately.
        let kx = metresPerDegree * cos(toRad(tip.lat))
        let dx = (tip.lon - from.lon) * kx, dy = (tip.lat - from.lat) * metresPerDegree
        let outbound = (dx * dx + dy * dy).squareRoot()
        guard outbound > 0.5 else { return nil }

        var run = 0.0
        var last = apex
        while last + 1 < points.count {
            run += flatMetres(points[last].lon, points[last].lat,
                              points[last + 1].lon, points[last + 1].lat)
            if run > limit { return nil }
            last += 1

            let px = (points[last].lon - from.lon) * kx
            let py = (points[last].lat - from.lat) * metresPerDegree
            // How far back down the outbound arm this point lies, and how far
            // off it.
            let along = (px * dx + py * dy) / outbound
            let across = abs(px * dy - py * dx) / outbound
            // Back inside the stretch just covered, and beside it. The apex has
            // to still stick out past this point or there was no excursion to
            // remove.
            guard along < outbound - 1, along > -corridor, across <= corridor else { continue }
            guard last - first >= 2 else { return nil }
            return (first, last)
        }
        return nil
    }
}
