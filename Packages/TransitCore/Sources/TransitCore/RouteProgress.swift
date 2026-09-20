import Foundation

/// Converts the train's ground-distance progress to the renderer's Mercator
/// line metrics. Mixing those units moves the dotted/solid seam off the train,
/// especially on a long south-to-north route such as Iselle → Bern.
public struct RouteProgress: Sendable {
    private let path: [Coord]
    private let projected: [Coord]
    private let ground: [Double]
    private let lengths: [Double]

    public init(path: [Coord]) {
        self.path = path
        projected = path.map(Self.project)
        var ground = Array(repeating: 0.0, count: path.count)
        var lengths = ground
        for i in path.indices.dropFirst() {
            ground[i] = ground[i - 1] + Geo.metres(path[i - 1], path[i])
            lengths[i] = lengths[i - 1] + hypot(
                projected[i].lon - projected[i - 1].lon,
                projected[i].lat - projected[i - 1].lat
            )
        }
        self.ground = ground
        self.lengths = lengths
    }

    /// Convert an absolute ground distance to the native line's metric space.
    public func fraction(atGroundDistance distance: Double) -> Double {
        guard let total = ground.last, total > 0 else { return 0 }
        return fraction(from: 0, to: path.count - 1, progress: distance / total)
    }

    /// Estimated stop-to-stop connections must not look like mapped track.
    /// Keep their distance ranges in the full journey, including repeat visits.
    public func inferredRanges(in geometry: JourneyGeometry) -> [ClosedRange<Double>] {
        guard let total = ground.last, total > 0 else { return [] }
        guard geometry.legSources.count == geometry.legs.count - 1 else {
            return geometry.source == .straight ? [0...total] : []
        }
        var ranges: [ClosedRange<Double>] = []
        for leg in geometry.legSources.indices where geometry.legSources[leg] == .chord {
            let a = geometry.legs[leg], b = geometry.legs[leg + 1]
            guard ground.indices.contains(a), ground.indices.contains(b), ground[b] > ground[a] else { continue }
            let range = ground[a]...ground[b]
            if let previous = ranges.last, previous.upperBound >= range.lowerBound {
                ranges[ranges.count - 1] = previous.lowerBound...max(previous.upperBound, range.upperBound)
            } else { ranges.append(range) }
        }
        return ranges
    }

    /// The leg bounds select the correct visit even if the route doubles back.
    /// Distances are cached once; each frame needs only a binary search.
    public func fraction(from start: Int, to end: Int, progress: Double) -> Double {
        guard path.indices.contains(start), let total = lengths.last, total > 0
        else { return 0 }
        guard path.indices.contains(end), end > start,
              ground[end] > ground[start], progress.isFinite
        else { return lengths[start] / total }
        let fraction = min(1, max(0, progress))
        if fraction == 0 { return lengths[start] / total }
        if fraction == 1 { return lengths[end] / total }
        let target = ground[start] + (ground[end] - ground[start]) * fraction
        var low = start + 1, high = end
        while low < high {
            let mid = (low + high) / 2
            if ground[mid] < target { low = mid + 1 } else { high = mid }
        }
        let a = low - 1, b = low
        let span = ground[b] - ground[a]
        let local = span > 0 ? (target - ground[a]) / span : 0
        // Positioning interpolates longitude/latitude within this segment.
        // Project that same point, not a fraction of the whole projected leg.
        let point = Self.project(Coord(
            lon: path[a].lon + (path[b].lon - path[a].lon) * local,
            lat: path[a].lat + (path[b].lat - path[a].lat) * local
        ))
        let dx = projected[b].lon - projected[a].lon
        let dy = projected[b].lat - projected[a].lat
        let squared = dx * dx + dy * dy
        let along = squared > 0
            ? ((point.lon - projected[a].lon) * dx + (point.lat - projected[a].lat) * dy) / squared
            : 0
        return min(1, max(0, (lengths[a]
            + (lengths[b] - lengths[a]) * min(1, max(0, along))) / total))
    }

    /// Where `target` sits on this path, as a Mercator length fraction.
    ///
    /// Used to place `line-trim-offset` on a *displayed* slice of the journey
    /// — a viewport window, not the whole run — so the seam stays on the
    /// vehicle even though the feature is no longer the full polyline.
    ///
    /// Along-segment distance is the projected foot's fraction of the already
    /// projected segment. Mixing ground metres into `lengths` (Mercator) made
    /// `min(span, along)` always equal `span` on any real railway, so the seam
    /// snapped to the end of the nearest segment: the whole line dotted when
    /// simplify left one segment, or a dotted start a station ahead of the
    /// train when it left a long one.
    public func fraction(nearestTo target: Coord) -> Double {
        guard path.count >= 2, let total = lengths.last, total > 0 else { return 0 }
        var best = Double.infinity
        var fraction = 0.0
        for i in 1..<path.count {
            let hit = Geo.projectOnSegment(
                lon: target.lon, lat: target.lat, a: path[i - 1], b: path[i]
            )
            guard hit.distance <= best else { continue }
            best = hit.distance
            let foot = Self.project(hit.foot)
            let dx = projected[i].lon - projected[i - 1].lon
            let dy = projected[i].lat - projected[i - 1].lat
            let squared = dx * dx + dy * dy
            let along = squared > 0
                ? ((foot.lon - projected[i - 1].lon) * dx
                   + (foot.lat - projected[i - 1].lat) * dy) / squared
                : 0
            fraction = (lengths[i - 1]
                + (lengths[i] - lengths[i - 1]) * min(1, max(0, along))) / total
        }
        return min(1, max(0, fraction))
    }

    /// Split this path at the closest point to `target`, so the two halves
    /// meet on the vehicle rather than at a line-metrics fraction Mapbox may
    /// not share.
    public func split(at target: Coord) -> (before: [Coord], after: [Coord]) {
        guard path.count >= 2 else { return (path, []) }
        var best = Double.infinity
        var index = 1
        var foot = path[0]
        for i in 1..<path.count {
            let hit = Geo.projectOnSegment(
                lon: target.lon, lat: target.lat, a: path[i - 1], b: path[i]
            )
            guard hit.distance <= best else { continue }
            best = hit.distance
            index = i
            foot = hit.foot
        }
        var before = Array(path[..<index])
        if before.last.map({ Geo.metres($0, foot) > 0.4 }) ?? true {
            before.append(foot)
        }
        var after = Array(path[index...])
        if after.first.map({ Geo.metres(foot, $0) > 0.4 }) ?? true {
            after.insert(foot, at: 0)
        }
        return (before, after)
    }

    /// Locate the current visit before clipping/simplifying the drawing. A
    /// nearest point on a simplified viewport can belong to a return journey,
    /// or put an off-screen vehicle's seam at the edge of the screen.
    public func split(
        at target: Coord, from start: Int, to end: Int, progress: Double,
        trailingMetres: Double = 0, within window: ClosedRange<Int>
    ) -> (before: [Coord], after: [Coord]) {
        guard path.count > 1, path.indices.contains(start), path.indices.contains(end),
              start <= end, path.indices.contains(window.lowerBound),
              path.indices.contains(window.upperBound) else { return ([], []) }
        let advance = progress.isFinite ? min(1, max(0, progress)) : 0
        let expected = max(0, ground[start] + (ground[end] - ground[start]) * advance - trailingMetres)
        func index(at distance: Double) -> Int {
            var low = 1, high = path.count - 1
            while low < high {
                let mid = (low + high) / 2
                if ground[mid] < distance { low = mid + 1 } else { high = mid }
            }
            return low
        }
        let lo = index(at: max(0, expected - 80))
        let hi = index(at: expected + 80)
        var chosen = index(at: expected)
        var best = Double.infinity, bestAlong = Double.infinity
        for i in lo...hi {
            let hit = Geo.projectOnSegment(lon: target.lon, lat: target.lat, a: path[i - 1], b: path[i])
            let along = abs(ground[i - 1] + Geo.metres(path[i - 1], hit.foot) - expected)
            if hit.distance < best - 0.05 || (abs(hit.distance - best) <= 0.05 && along < bestAlong) {
                chosen = i; best = hit.distance; bestAlong = along
            }
        }
        if chosen <= window.lowerBound { return ([], Array(path[window])) }
        if chosen > window.upperBound { return (Array(path[window]), []) }
        // Preserve the actual marker coordinate as a mandatory vertex. In
        // particular, Douglas–Peucker must not straighten the bend under it.
        var before = Array(path[window.lowerBound..<chosen])
        var after = Array(path[chosen...window.upperBound])
        before.append(target)
        after.insert(target, at: 0)
        return (before, after)
    }

    private static func project(_ point: Coord) -> Coord {
        let latitude = min(85.051129, max(-85.051129, point.lat)) * .pi / 180
        return Coord(lon: point.lon * .pi / 180, lat: log(tan(.pi / 4 + latitude / 2)))
    }
}
