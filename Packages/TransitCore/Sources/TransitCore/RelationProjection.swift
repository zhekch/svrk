import Foundation

extension RelationStore {
    /// How far a stop may sit from the way that serves it.
    ///
    /// Scaled by mode because the two are not comparable: a bus stop is a pole
    /// at the kerb, metres from the road, while a railway station's published
    /// coordinate is the centre of the whole station — often several hundred
    /// metres from the particular track a given service runs on. Applying the
    /// bus figure to trains rejected most railway matches outright.
    struct Projection { var close: Double; var reject: Double }

    static func projection(for mode: Mode) -> Projection {
        switch mode {
        case .train: return Projection(close: 300, reject: 900)
        case .cable: return Projection(close: 200, reject: 600)
        case .boat: return Projection(close: 300, reject: 900)
        case .metro: return Projection(close: 150, reject: 400)
        case .tram: return Projection(close: 100, reject: 300)
        case .bus: return Projection(close: 100, reject: 300)
        case .other: return Projection(close: 150, reject: 400)
        }
    }

    /// Per stop: where it lands, as a segment index plus a fraction along it.
    struct Foot {
        var segment: Int
        var t: Double
        var lon: Double
        var lat: Double
        var distance: Double
    }

    /// Where each stop falls along the route polyline, as advancing indices,
    /// with nil for stops the polyline does not actually reach.
    ///
    /// Taking each stop's globally nearest vertex looks obvious and is wrong:
    /// plenty of routes pass the same street twice — city loops, out-and-back
    /// branches — so a later stop can land nearest to an earlier pass and the
    /// indices jump backwards. Scanning forward from the last placed stop makes
    /// the ordering structural, and stopping at the first close approach rather
    /// than the global minimum keeps a stop from being pinned to a later pass
    /// down the same street.
    /// Off switch for the neighbourhood scan, so it can be measured against its
    /// own absence — the same reason `GeometryBuilder.bendToPlatforms` has one.
    /// A stop's landing point moves when this changes, and every leg boundary
    /// with it, so "did this change that" is a question worth being able to ask
    /// of a real snapshot rather than of a fixture.
    nonisolated(unsafe) static var scanWholeNeighbourhood = true

    func projectStops(_ path: [Coord], _ stops: [Call], _ mode: Mode) -> (path: [Coord], cuts: [Int?]) {
        let limits = Self.projection(for: mode)
        var placed: [Foot?] = []
        var from = 0

        for stop in stops {
            var bestIndex = -1
            var bestDist = Double.infinity

            // Scan the whole of the stop's *neighbourhood*, not up to the
            // first time the line turns away inside it.
            //
            // Breaking at the first local minimum is what lost every turning
            // loop. A tram reaching Brünnen Westside comes down Ramuzstrasse,
            // passes within forty metres of its terminal platform, then swings
            // west round the balloon loop and comes back east into it. The
            // first minimum is on the approach arm: forty metres out, well
            // inside `close`, and the next vertex is further away — so the
            // stop was pinned there and the two hundred metres of loop behind
            // it were dropped from the path altogether. `bend` then found the
            // leg ending forty metres off the platform, asked the rail graph
            // for a way there, and was handed the *opposite direction's* track,
            // which is how a tram came to be drawn crossing the pavement.
            //
            // Guisanplatz Expo is the same shape one stop further on. OSM puts
            // the stop node at 7.464232,46.959244 — the far end of the loop —
            // and the line was cut at 7.463934,46.959104, its near end, so the
            // whole excursion was charged to the leg *after* the stop and the
            // tram was drawn diving into it on departure.
            //
            // A neighbourhood is a contiguous run of vertices within `close`.
            // Entering one and leaving it again is what ends the search, so a
            // loop that stays beside its own stop is followed to the end and
            // the nearest point in it wins. A genuine second pass down the same
            // street is a *separate* neighbourhood — the line has to leave the
            // first one to get there — so the earlier call still wins it, which
            // is what the break was there to protect.
            var i = from
            var beside = false
            while i < path.count {
                let d = Geo.metres(stop.lon, stop.lat, path[i].lon, path[i].lat)
                if d < bestDist {
                    bestDist = d
                    bestIndex = i
                }
                if Self.scanWholeNeighbourhood {
                    if d <= limits.close {
                        beside = true
                    } else if beside {
                        break // we were beside the stop and have now left it behind
                    }
                } else if d > bestDist, bestDist <= limits.close {
                    break // the original rule: the first turn away, and stop
                }
                i += 1
            }

            if bestIndex == -1 || bestDist > limits.reject {
                placed.append(nil) // this stop is not on the retained polyline
                continue
            }

            // The nearest *vertex* is not the nearest *place*, and on a tram
            // reservation that difference is the whole bug. OSM draws a
            // straight run of track as two nodes however long it is, so a stop
            // halfway along one gets pinned to whichever end happens to be
            // nearer — a hundred metres up the road from the platform it
            // belongs to. The foot of the perpendicular is where the vehicle
            // actually stands.
            let foot = footOnSegments(path, bestIndex, stop, from)
            placed.append(foot)
            from = foot.segment
        }

        return spliceFeet(path, placed)
    }

    /// The closest point to `stop` on the two segments meeting at `index`.
    ///
    /// Only those two are considered: the nearest vertex has already been found
    /// by the forward scan, and the nearest point on the whole line is on one
    /// of the segments touching it. Keeping the search local is also what
    /// preserves the forward-only ordering — hence `minSegment`.
    private func footOnSegments(_ path: [Coord], _ index: Int, _ stop: Call, _ minSegment: Int) -> Foot {
        var best = Foot(segment: index, t: 0, lon: path[index].lon, lat: path[index].lat, distance: .infinity)

        for segment in [index - 1, index] {
            guard segment >= minSegment, segment >= 0, segment + 1 < path.count else { continue }
            let a = path[segment], b = path[segment + 1]

            // Flat projection in local metres. Over one OSM segment the
            // curvature of the earth is far below the precision anything here
            // is claiming.
            let perLon = Geo.metresPerDegree * cos(Geo.toRad(a.lat))
            let dx = (b.lon - a.lon) * perLon
            let dy = (b.lat - a.lat) * Geo.metresPerDegree
            let lengthSq = dx * dx + dy * dy
            if lengthSq == 0 { continue }

            let ex = (stop.lon - a.lon) * perLon
            let ey = (stop.lat - a.lat) * Geo.metresPerDegree
            let t = max(0, min(1, (ex * dx + ey * dy) / lengthSq))

            let lon = a.lon + (b.lon - a.lon) * t
            let lat = a.lat + (b.lat - a.lat) * t
            let distance = Geo.metres(stop.lon, stop.lat, lon, lat)
            if distance < best.distance {
                best = Foot(segment: segment, t: t, lon: lon, lat: lat, distance: distance)
            }
        }

        if best.distance == .infinity {
            return Foot(segment: index, t: 0, lon: path[index].lon, lat: path[index].lat, distance: 0)
        }
        // Within a metre of an end is that end: inserting a duplicate vertex
        // there would only give the leg a zero-length first step.
        if Geo.metres(best.lon, best.lat, path[best.segment].lon, path[best.segment].lat) < 1 {
            best.t = 0
        } else if best.segment + 1 < path.count,
                  Geo.metres(best.lon, best.lat, path[best.segment + 1].lon, path[best.segment + 1].lat) < 1 {
            best.segment += 1
            best.t = 0
        }
        return best
    }

    /// Put the projected feet into the polyline and say where each one ended up.
    ///
    /// Everything downstream indexes the path by vertex, so a stop that lands
    /// between two vertices has to become a vertex before it can be pointed at.
    /// Returned as a new path so the relation's own geometry, shared by every
    /// run of the line, is never mutated.
    private func spliceFeet(_ path: [Coord], _ placed: [Foot?]) -> (path: [Coord], cuts: [Int?]) {
        var bySegment: [Int: [(stop: Int, foot: Foot)]] = [:]
        for (i, foot) in placed.enumerated() {
            guard let foot else { continue }
            bySegment[foot.segment, default: []].append((i, foot))
        }
        for key in bySegment.keys {
            bySegment[key]?.sort { $0.foot.t < $1.foot.t }
        }

        var out: [Coord] = []
        out.reserveCapacity(path.count + placed.count)
        var cuts = [Int?](repeating: nil, count: placed.count)

        for v in 0..<path.count {
            out.append(path[v])
            for entry in bySegment[v] ?? [] {
                if entry.foot.t == 0 {
                    cuts[entry.stop] = out.count - 1
                    continue
                }
                out.append(Coord(lon: entry.foot.lon, lat: entry.foot.lat))
                cuts[entry.stop] = out.count - 1
            }
        }

        return (out, cuts)
    }

    // MARK: - Leg geometry

    /// Per-leg geometry from the matched relation, with gaps left as nil.
    ///
    /// All-or-nothing was the wrong shape. A relation's ways do not always
    /// stitch into one unbroken line — ordering gaps and mapping errors split
    /// it — so a single stop landing kilometres from the retained path used to
    /// discard the whole journey, including the many legs that were perfectly
    /// good.
    public struct LegGeometry: Sendable {
        public var legs: [[Coord]?]
        /// The relation the journey is chiefly running on; what the panel links to.
        public var relation: Int32
        public var ways: [Int64]
        public var name: String?
    }

    public func legPaths(_ probe: MatchProbe) -> LegGeometry? {
        guard probe.stops.count >= 2 else { return nil }
        var legs = [[Coord]?](repeating: nil, count: probe.stops.count - 1)
        var relationIds: [Int32] = []
        var ways: [Int64] = []
        var names: [String] = []

        cover(probe, 0, probe.stops.count - 1, &legs, &relationIds, &ways, &names, 0)
        guard let first = relationIds.first else { return nil }

        var uniqueNames: [String] = []
        for name in names where !uniqueNames.contains(name) { uniqueNames.append(name) }

        return LegGeometry(
            legs: legs, relation: first, ways: ways,
            name: uniqueNames.isEmpty ? nil : uniqueNames.joined(separator: " + ")
        )
    }

    /// Fill in `legs[from..<to]` from whatever relation best describes stops
    /// `from...to`, then ask the same question about the stops it could not
    /// place.
    ///
    /// A relation's ways do not always stitch into one unbroken line, and a
    /// line's two sources do not always agree where it ends, so insisting that
    /// one relation describe a whole journey threw away the many legs that were
    /// perfectly good. Recursing into the gaps means each part of a run is
    /// drawn on the relation that actually covers it — which is what took
    /// trains from 88% mapped to 94% and trams from 77% to 88%.
    private func cover(
        _ probe: MatchProbe, _ from: Int, _ to: Int,
        _ legs: inout [[Coord]?], _ relationIds: inout [Int32],
        _ ways: inout [Int64], _ names: inout [String], _ depth: Int
    ) {
        guard to - from >= 1, depth <= Self.maxSegmentDepth else { return }

        let stops = Array(probe.stops[from...to])
        var slice = probe
        slice.stops = stops

        // A relation for this line number first; only then the wider search, so
        // an unrelated line can never outrank the one the service is numbered.
        let match = matchRoute(slice) ?? (depth < Self.maxSegmentDepth ? matchSegment(slice) : nil)
        guard let match else { return }

        let relation = self.relation(at: match.relationIndex)
        let (path, cuts) = projectStops(self.path(of: relation).toArray(), stops, probe.mode)

        var filled = [Bool](repeating: false, count: stops.count - 1)
        for i in 1..<stops.count {
            // Both ends must sit on the line, and the route must move forward
            // between them; anything else means this leg is not described by
            // the relation.
            guard let a = cuts[i - 1], let b = cuts[i], b > a else { continue }
            // Inclusive of both ends: the endpoints are the points *on the
            // mapped way* nearest each stop, and they are what the drawn line
            // should start and end at. Handing back only the interior and
            // letting the caller cap it with the stop's own coordinate is what
            // put a spike on the map at every station.
            legs[from + i - 1] = Array(path[a...b])
            filled[i - 1] = true
        }

        // Nothing placed means this relation has nothing to say about these
        // stops. Returning here is also what stops the recursion: a sub-range
        // that matches the same relation again fills the same nothing and goes
        // no deeper.
        guard filled.contains(true) else { return }

        relationIds.append(relation.id)
        ways.append(contentsOf: self.ways(of: relation))
        if let name = relation.name { names.append(name) }

        var i = 0
        while i < filled.count {
            if filled[i] {
                i += 1
                continue
            }
            var end = i
            while end < filled.count && !filled[end] { end += 1 }
            cover(probe, from + i, from + end, &legs, &relationIds, &ways, &names, depth + 1)
            i = end
        }
    }
}
