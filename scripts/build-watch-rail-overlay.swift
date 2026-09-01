import Foundation

private extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

private enum RailStyle: UInt8, Hashable {
    case other = 0
    case heavy = 1
    case narrow = 2
    case tram = 3
    case lightRail = 4
    case funicular = 5
}

private struct Band {
    var level: UInt8
    var lines: [OverlayLine]
}

private struct OverlayLine {
    var points: [Coord]
    var style: RailStyle
}

private struct BoundaryGeometry: Decodable {
    var type: String
    var coordinates: [[[Double]]]
}

private struct WatchRouteRelation {
    var id: Int32
    var route: String
    var ref: String?
    var name: String?
    var operatorName: String?
    var network: String?
    var from: String?
    var to: String?
    var stops: [Coord]
    var path: [Coord]
}

private struct WatchStringTable {
    private var indices: [String: UInt32] = [:]
    private var values: [String] = []

    mutating func index(_ value: String?) -> UInt32 {
        guard let value else { return BinaryFormat.noString }
        if let index = indices[value] { return index }
        let index = UInt32(values.count)
        indices[value] = index
        values.append(value)
        return index
    }

    func append(to data: inout Data) {
        data.appendInteger(UInt32(values.count))
        var offsets: [UInt32] = []
        var blob = Data()
        offsets.reserveCapacity(values.count + 1)
        for value in values {
            offsets.append(UInt32(blob.count))
            blob.append(contentsOf: value.utf8)
        }
        offsets.append(UInt32(blob.count))
        for offset in offsets { data.appendInteger(offset) }
        data.append(blob)
    }
}

private struct PointKey: Hashable, Comparable {
    var lon: Int32
    var lat: Int32

    static func < (lhs: PointKey, rhs: PointKey) -> Bool {
        lhs.lon == rhs.lon ? lhs.lat < rhs.lat : lhs.lon < rhs.lon
    }

}

@main
private enum BuildWatchRailOverlay {
    static func main() throws {
        guard CommandLine.arguments.count == 5 else {
            FileHandle.standardError.write(
                Data(
                    "usage: build-watch-rail-overlay INPUT_RAILNET INPUT_ROUTES "
                        .appending("OVERLAY_OUTPUT ROUTES_OUTPUT\n").utf8
                )
            )
            Foundation.exit(2)
        }

        let railInput = URL(fileURLWithPath: CommandLine.arguments[1])
        let routesInput = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = URL(fileURLWithPath: CommandLine.arguments[3])
        let routeOutput = URL(fileURLWithPath: CommandLine.arguments[4])
        let railnet = RailNet()
        try railnet.load(railInput)
        let relations = RelationStore()
        try relations.load(routesInput)
        let swissBoundary = try loadSwissBoundary()

        // Slightly beyond Switzerland so border services do not stop at the
        // edge of the screen. The watch never needs the worldwide OSM graph.
        let country = BBox(west: 5.45, south: 45.45, east: 10.95, north: 48.15)
        let mainMask = railnet.kindBit("heavy") | railnet.kindBit("narrow")
        let heavy = railnet.kindBit("heavy")
        let narrow = railnet.kindBit("narrow")
        let tram = railnet.kindBit("tram")
        let light = railnet.kindBit("light")
        let funicular = railnet.kindBit("funicular")

        func railStyle(for kind: UInt8) -> RailStyle {
            if kind & funicular != 0 { return .funicular }
            if kind & tram != 0 { return .tram }
            if kind & light != 0 { return .lightRail }
            if kind & narrow != 0 { return .narrow }
            if kind & heavy != 0 { return .heavy }
            return .other
        }

        let national = clipped(
            railnet.lines(
                    in: country,
                    limit: 50_000,
                    kindMask: mainMask,
                    minLength: 3_000,
                    simplify: 150
                )
                .map { OverlayLine(points: $0.points, style: railStyle(for: $0.kind)) },
            to: swissBoundary
        )
        let local = clipped(
            serviceCorridors(from: relations, in: country),
            to: swissBoundary
        )
        let bands = [
            Band(level: 0, lines: national),
            Band(level: 1, lines: local),
        ]

        var archive = Data("SVWRAIL1".utf8)
        archive.appendInteger(UInt32(1))
        archive.appendInteger(UInt32(bands.count))

        for band in bands {
            archive.appendInteger(band.level)
            archive.append(contentsOf: [0, 0, 0])
            archive.appendInteger(UInt32(band.lines.count))

            for line in band.lines {
                guard line.points.count >= 2 else { continue }
                let encoded = line.points.map {
                    (lon: BinaryFormat.encode($0.lon), lat: BinaryFormat.encode($0.lat))
                }
                let west = encoded.map(\.lon).min()!
                let south = encoded.map(\.lat).min()!
                let east = encoded.map(\.lon).max()!
                let north = encoded.map(\.lat).max()!

                // Everything after this field. The byte count lets future
                // readers skip a record without decoding its coordinates.
                archive.appendInteger(UInt32(24 + encoded.count * 8))
                archive.appendInteger(line.style.rawValue)
                archive.append(contentsOf: [0, 0, 0])
                archive.appendInteger(west)
                archive.appendInteger(south)
                archive.appendInteger(east)
                archive.appendInteger(north)
                archive.appendInteger(UInt32(encoded.count))
                for point in encoded {
                    archive.appendInteger(point.lon)
                    archive.appendInteger(point.lat)
                }
            }
        }

        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try archive.write(to: output, options: .atomic)
        print(
            "wrote \(output.path): \(archive.count) bytes, "
                + bands.map { "level \($0.level)=\($0.lines.count) lines" }.joined(separator: ", ")
        )
        try writeRouteRelations(from: relations, in: country, to: routeOutput)
    }

    /// Natural Earth 1:50m is detailed enough for a watch display while keeping
    /// the generated overlay strictly inside Switzerland. The source dataset is
    /// public domain: https://www.naturalearthdata.com/.
    private static func loadSwissBoundary() throws -> [Coord] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("switzerland-boundary-50m.geojson")
        let geometry = try JSONDecoder().decode(
            BoundaryGeometry.self,
            from: Data(contentsOf: url)
        )
        guard geometry.type == "Polygon", let ring = geometry.coordinates.first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let points = ring.compactMap { position -> Coord? in
            guard position.count >= 2 else { return nil }
            return Coord(lon: position[0], lat: position[1])
        }
        guard points.count >= 4 else { throw CocoaError(.fileReadCorruptFile) }
        return points
    }

    private static func clipped(
        _ lines: [OverlayLine],
        to polygon: [Coord]
    ) -> [OverlayLine] {
        lines.flatMap { line in
            clipped(line.points, to: polygon).map {
                OverlayLine(points: $0, style: line.style)
            }
        }
    }

    /// Split a polyline at every country-border crossing and retain only the
    /// intervals whose midpoint lies inside Switzerland. This avoids the false
    /// chords produced by simply discarding out-of-country vertices.
    private static func clipped(
        _ points: [Coord],
        to polygon: [Coord]
    ) -> [[Coord]] {
        guard points.count >= 2, polygon.count >= 3 else { return [] }
        var result: [[Coord]] = []
        var current: [Coord] = []

        func appendDistinct(_ point: Coord) {
            guard let last = current.last else {
                current.append(point)
                return
            }
            if abs(last.lon - point.lon) > 0.000_000_1
                || abs(last.lat - point.lat) > 0.000_000_1 {
                current.append(point)
            }
        }

        func finish() {
            if current.count >= 2 { result.append(current) }
            current.removeAll(keepingCapacity: true)
        }

        for index in 0 ..< points.count - 1 {
            let from = points[index]
            let to = points[index + 1]
            var cuts = [0.0, 1.0]
            for edge in 0 ..< polygon.count {
                let edgeFrom = polygon[edge]
                let edgeTo = polygon[(edge + 1) % polygon.count]
                if let parameter = intersectionParameter(
                    from: from,
                    to: to,
                    edgeFrom: edgeFrom,
                    edgeTo: edgeTo
                ) {
                    cuts.append(parameter)
                }
            }
            cuts.sort()
            var uniqueCuts: [Double] = []
            for cut in cuts where uniqueCuts.last.map({ abs($0 - cut) > 0.000_000_1 }) ?? true {
                uniqueCuts.append(cut)
            }

            for cut in 0 ..< uniqueCuts.count - 1 {
                let start = uniqueCuts[cut]
                let end = uniqueCuts[cut + 1]
                let midpoint = interpolate(from, to, (start + end) / 2)
                if contains(midpoint, polygon: polygon) {
                    appendDistinct(interpolate(from, to, start))
                    appendDistinct(interpolate(from, to, end))
                } else if !current.isEmpty {
                    finish()
                }
            }
        }
        if !current.isEmpty { finish() }
        return result
    }

    private static func interpolate(_ from: Coord, _ to: Coord, _ t: Double) -> Coord {
        Coord(
            lon: from.lon + (to.lon - from.lon) * t,
            lat: from.lat + (to.lat - from.lat) * t
        )
    }

    private static func intersectionParameter(
        from: Coord,
        to: Coord,
        edgeFrom: Coord,
        edgeTo: Coord
    ) -> Double? {
        let rx = to.lon - from.lon
        let ry = to.lat - from.lat
        let sx = edgeTo.lon - edgeFrom.lon
        let sy = edgeTo.lat - edgeFrom.lat
        let denominator = rx * sy - ry * sx
        guard abs(denominator) > 0.000_000_000_001 else { return nil }
        let qx = edgeFrom.lon - from.lon
        let qy = edgeFrom.lat - from.lat
        let t = (qx * sy - qy * sx) / denominator
        let u = (qx * ry - qy * rx) / denominator
        guard t > 0.000_000_1, t < 0.999_999_9,
              u >= -0.000_000_1, u <= 1.000_000_1
        else { return nil }
        return t
    }

    private static func contains(_ point: Coord, polygon: [Coord]) -> Bool {
        var inside = false
        var previous = polygon.count - 1
        for index in polygon.indices {
            let current = polygon[index]
            let last = polygon[previous]
            if (current.lat > point.lat) != (last.lat > point.lat) {
                let crossingLongitude = (last.lon - current.lon)
                    * (point.lat - current.lat)
                    / (last.lat - current.lat)
                    + current.lon
                if point.lon < crossingLongitude { inside.toggle() }
            }
            previous = index
        }
        return inside
    }

    /// The full iOS relation store is 31 MB. The watch keeps the ordered stops
    /// needed for matching but simplifies the route paths and drops OSM way
    /// identifiers, which are irrelevant to placing a dot. The result remains
    /// a normal `SVROUTES` file, so it stays memory-mapped and uses the same
    /// well-tested matcher as iOS without loading an object graph at launch.
    private static func writeRouteRelations(
        from store: RelationStore,
        in bounds: BBox,
        to output: URL
    ) throws {
        let supported = Set([
            "train", "tram", "light_rail", "subway", "monorail", "funicular",
            "bus", "trolleybus", "share_taxi", "ferry",
        ])
        var relations: [WatchRouteRelation] = []
        relations.reserveCapacity(store.count)

        for index in 0 ..< store.count {
            let relation = store.relation(at: index)
            guard supported.contains(relation.route) else { continue }
            let rawPath = store.path(of: relation).toArray()
            guard rawPath.count >= 2 else { continue }
            let box = BBox(
                west: rawPath.map(\.lon).min()!,
                south: rawPath.map(\.lat).min()!,
                east: rawPath.map(\.lon).max()!,
                north: rawPath.map(\.lat).max()!
            )
            guard bounds.intersects(box) else { continue }

            let path = Geo.simplify(rawPath, toleranceMetres: 12)
            guard path.count >= 2 else { continue }
            relations.append(WatchRouteRelation(
                id: relation.id,
                route: relation.route,
                ref: relation.ref,
                name: relation.name,
                operatorName: relation.operatorName,
                network: relation.network,
                from: relation.from,
                to: relation.to,
                stops: store.stops(of: relation).toArray(),
                path: path
            ))
        }

        var strings = WatchStringTable()
        var body = Data()
        body.appendInteger(UInt32(relations.count))
        for relation in relations {
            body.appendInteger(relation.id)
            body.appendInteger(strings.index(relation.route))
            body.appendInteger(strings.index(relation.ref))
            body.appendInteger(strings.index(relation.name))
            body.appendInteger(strings.index(relation.operatorName))
            body.appendInteger(strings.index(relation.network))
            body.appendInteger(strings.index(relation.from))
            body.appendInteger(strings.index(relation.to))
            body.appendInteger(UInt32(relation.stops.count))
            body.appendInteger(UInt32(relation.path.count))
            body.appendInteger(UInt32(0)) // No way-id index on watch.
            for point in relation.stops {
                body.appendInteger(BinaryFormat.encode(point.lon))
                body.appendInteger(BinaryFormat.encode(point.lat))
            }
            for point in relation.path {
                body.appendInteger(BinaryFormat.encode(point.lon))
                body.appendInteger(BinaryFormat.encode(point.lat))
            }
        }

        var archive = Data("SVROUTES".utf8)
        archive.appendInteger(UInt32(1))
        strings.append(to: &archive)
        while archive.count % 4 != 0 { archive.append(0) }
        archive.append(body)

        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try archive.write(to: output, options: .atomic)
        print(
            "wrote \(output.path): \(archive.count) bytes, "
                + "\(relations.count) simplified route relations"
        )
    }

    /// Build the local band as one physical centreline per OSM transit
    /// corridor. This is done in the downloadable/bundled archive builder, not
    /// on the watch: the watch should decode one line, never merge three rails
    /// every time its camera moves.
    ///
    /// Exact snapped-edge deduplication is insufficient. Two tracks only a few
    /// metres apart frequently land on neighbouring grid cells and survive as
    /// parallel strokes. Instead, a claimed corridor occupies its own cell and
    /// the eight neighbours. A later relation contributes only the genuinely
    /// new branches outside that corridor. Branch endpoints reuse the nearest
    /// claimed coordinate, keeping junctions visibly connected.
    private static func serviceCorridors(
        from store: RelationStore,
        in bounds: BBox
    ) -> [OverlayLine] {
        struct Candidate {
            var style: RailStyle
            var points: [Coord]
            var length: Double
        }

        struct Sample {
            var point: Coord
            var node: PointKey
        }

        // A cell maps to the actual smooth coordinate that claimed it. Keeping
        // that coordinate lets a truly coincident branch reuse the junction;
        // nearby parallel tracks are merely deduplicated and never connected.
        var claimed: [PointKey: Coord] = [:]
        var output: [OverlayLine] = []

        func style(for route: String) -> RailStyle? {
            switch route {
            case "train": return .heavy
            case "tram": return .tram
            case "light_rail", "subway", "monorail": return .lightRail
            case "funicular": return .funicular
            default: return nil
            }
        }

        // Samples still use a grid for a cheap neighbourhood lookup, but a
        // neighbouring cell alone is not proof that two tracks connect. The
        // old code accepted the full 3x3 neighbourhood (up to roughly 45 m at
        // a cell corner) and then drew a straight join to it. In station
        // throats that manufactured the triangular chords this archive is
        // specifically meant to avoid.
        let gridMetres = 18.0
        let corridorMetres = 18.0
        let joinMetres = 6.0
        let longitudeScale = 111_320.0 * cos(47.0 * .pi / 180)

        func node(_ point: Coord) -> PointKey {
            PointKey(
                lon: Int32((point.lon * longitudeScale / gridMetres).rounded()),
                lat: Int32((point.lat * 111_320.0 / gridMetres).rounded())
            )
        }

        func nearestClaim(to sample: Sample) -> Coord? {
            var nearest: (point: Coord, distance: Double)?
            for longitudeOffset in -1 ... 1 {
                for latitudeOffset in -1 ... 1 {
                    let nearby = PointKey(
                        lon: sample.node.lon + Int32(longitudeOffset),
                        lat: sample.node.lat + Int32(latitudeOffset)
                    )
                    guard let point = claimed[nearby] else { continue }
                    let distance = Geo.metres(sample.point, point)
                    if nearest == nil || distance < nearest!.distance {
                        nearest = (point, distance)
                    }
                }
            }
            guard let nearest, nearest.distance <= corridorMetres else { return nil }
            return nearest.point
        }

        func samples(of points: [Coord]) -> [Sample] {
            guard points.count >= 2 else { return [] }
            var result: [Sample] = []
            for segment in 0 ..< points.count - 1 {
                let first = points[segment]
                let second = points[segment + 1]
                let distance = max(1, Geo.metres(first, second))
                let steps = max(1, Int(ceil(distance / 8)))
                for step in 0 ... steps {
                    if segment > 0, step == 0 { continue }
                    let progress = Double(step) / Double(steps)
                    let point = Coord(
                        lon: first.lon + (second.lon - first.lon) * progress,
                        lat: first.lat + (second.lat - first.lat) * progress
                    )
                    let sample = Sample(point: point, node: node(point))
                    if result.last?.node != sample.node { result.append(sample) }
                }
            }
            return result
        }

        func emit(_ raw: [Coord], style: RailStyle) {
            let points = Geo.simplify(raw, toleranceMetres: 10)
            guard points.count >= 2 else { return }
            let chunkPoints = 96
            var start = 0
            while start < points.count - 1 {
                let end = min(points.count, start + chunkPoints)
                let chunk = Array(points[start ..< end])
                let box = BBox(
                    west: chunk.map(\.lon).min()!,
                    south: chunk.map(\.lat).min()!,
                    east: chunk.map(\.lon).max()!,
                    north: chunk.map(\.lat).max()!
                )
                if bounds.intersects(box) {
                    output.append(OverlayLine(points: chunk, style: style))
                }
                start = end - 1
            }
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(store.count)
        for index in 0 ..< store.count {
            let relation = store.relation(at: index)
            guard let style = style(for: relation.route) else { continue }
            let path = store.path(of: relation)
            guard path.count >= 2 else { continue }

            // OSM relations occasionally walk to the end of a way and back
            // before continuing. Those folds are valid member ordering but
            // invalid drawable geometry. Clean them once here rather than
            // spending watch CPU on them for every viewport.
            var cleaned = Geo.withoutSpurs(path.toArray())
            cleaned = Geo.withoutFolds(cleaned)
            cleaned = Geo.withoutEndStubs(cleaned)
            let simplified = Geo.simplify(cleaned, toleranceMetres: 12)
            guard simplified.count >= 2 else { continue }
            let length = zip(simplified, simplified.dropFirst()).reduce(0.0) {
                $0 + Geo.metres($1.0, $1.1)
            }
            candidates.append(Candidate(style: style, points: simplified, length: length))
        }

        // Prefer the visually useful local modes, then the longest continuous
        // representative. Train relations sharing those rails are collapsed
        // too, so the result is one stroke rather than one per mode/route.
        candidates.sort { lhs, rhs in
            let lhsPriority = railPriority(lhs.style)
            let rhsPriority = railPriority(rhs.style)
            if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
            return lhs.length > rhs.length
        }

        for candidate in candidates {
            let pathSamples = samples(of: candidate.points).filter {
                bounds.contains(lon: $0.point.lon, lat: $0.point.lat)
            }
            guard pathSamples.count >= 2 else { continue }
            let wasClaimed = pathSamples.map { nearestClaim(to: $0) }

            var branchStart: Int?
            var newSampleCount = 0

            func finishBranch(at end: Int) {
                guard let start = branchStart else { return }
                defer {
                    branchStart = nil
                    newSampleCount = 0
                }
                // Ignore sub-40-metre switches and mapping jitter. They are
                // expensive texture on a watch, not useful route context.
                guard newSampleCount >= 5, end > start else { return }
                var branch = pathSamples[start ... end].map(\.point)
                // Reuse a claimed coordinate only for a genuinely coincident
                // OSM junction. Parallel tracks may be close enough to share
                // one visual corridor, but drawing a connector between them
                // invents track that does not exist.
                if let anchor = wasClaimed[start],
                   Geo.metres(branch[0], anchor) <= joinMetres {
                    branch[0] = anchor
                }
                if let anchor = wasClaimed[end],
                   Geo.metres(branch[branch.count - 1], anchor) <= joinMetres {
                    branch[branch.count - 1] = anchor
                }
                emit(branch, style: candidate.style)

                for sample in pathSamples[start ... end] where nearestClaim(to: sample) == nil {
                    claimed[sample.node] = sample.point
                }
            }

            for index in pathSamples.indices {
                if wasClaimed[index] == nil {
                    if branchStart == nil { branchStart = max(pathSamples.startIndex, index - 1) }
                    newSampleCount += 1
                } else if branchStart != nil {
                    finishBranch(at: index)
                }
            }
            if branchStart != nil { finishBranch(at: pathSamples.index(before: pathSamples.endIndex)) }
        }
        return output
    }

    private static func railPriority(_ style: RailStyle) -> Int {
        switch style {
        case .tram, .lightRail, .funicular: return 3
        case .heavy, .narrow: return 2
        case .other: return 1
        }
    }
}
