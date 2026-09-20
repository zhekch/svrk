import Foundation
import TransitCore

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

        // National zoom is a handful of long strokes, so 40 m of simplification
        // still looks like a curve on a watch while staying well under a
        // megabyte. The previous 150 m pass left most runs as two- or
        // three-point chords.
        // Keep short junction pieces long enough to weld a corridor back
        // together, then drop leftover stubs. Filtering by length first left
        // the overlay as two-point chords that no longer touched.
        let national = welded(
            clipped(
                welded(
                    railnet.lines(
                            in: country,
                            limit: 50_000,
                            kindMask: mainMask,
                            minLength: 40,
                            simplify: 40
                        )
                        .map { OverlayLine(points: $0.points, style: railStyle(for: $0.kind)) },
                    within: 12
                ).filter { Geo.length(of: $0.points) >= 800 },
                to: swissBoundary
            ),
            within: 12
        )
        // City zoom uses the physical graph, not fragmented route relations.
        // Join junction-to-junction runs into continuous alignments *before*
        // dropping parallel tracks, otherwise the overlap filter eats the
        // connectors and the overlay falls back into short chords.
        let local = welded(
            clipped(
                collapsedPhysicalCorridors(
                    from: railnet,
                    in: country,
                    kindMask: mainMask | tram | light | funicular,
                    style: railStyle
                ),
                to: swissBoundary
            ),
            within: 10
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

    /// One drawable centreline per physical corridor, built from the routing
    /// graph rather than from OSM route relations.
    ///
    /// Relation members are already a simplification of the same ways, and the
    /// previous pass then chopped them into 96-point pieces and dropped any
    /// overlap with an earlier corridor. The result on a watch was a field of
    /// short straight chords. `RailNet.lines` walks degree-2 nodes, so each
    /// run is already a continuous alignment; collapsing only lines that lie
    /// almost entirely on an already-kept neighbour drops parallel tracks
    /// without breaking the line that remains.
    private static func collapsedPhysicalCorridors(
        from railnet: RailNet,
        in bounds: BBox,
        kindMask: UInt8,
        style: (UInt8) -> RailStyle
    ) -> [OverlayLine] {
        let raw = railnet.lines(
            in: bounds,
            limit: 80_000,
            kindMask: kindMask,
            minLength: 40,
            simplify: 6
        )
        var grouped: [RailStyle: [[Coord]]] = [:]
        for line in raw {
            grouped[style(line.kind), default: []].append(line.points)
        }

        var output: [OverlayLine] = []
        for railStyle in [RailStyle.tram, .lightRail, .funicular, .heavy, .narrow, .other] {
            guard let group = grouped[railStyle] else { continue }
            let joined = Geo.join(group, within: 10)
            let candidates = joined.map { points in
                (points: points, length: Geo.length(of: points))
            }.sorted { $0.length > $1.length }
            output.append(contentsOf: collapseParallels(candidates, style: railStyle))
        }
        return output
    }

    /// Drop a line only when most of it already sits in a kept corridor of the
    /// same style. A line that merely shares a station throat with a longer
    /// neighbour is kept whole, which is what stops the overlay fragmenting
    /// into the stubs the previous emitter produced.
    private static func collapseParallels(
        _ candidates: [(points: [Coord], length: Double)],
        style: RailStyle
    ) -> [OverlayLine] {
        let gridMetres = 16.0
        let longitudeScale = 111_320.0 * cos(47.0 * .pi / 180)
        var claimed: Set<PointKey> = []
        var output: [OverlayLine] = []

        func node(_ point: Coord) -> PointKey {
            PointKey(
                lon: Int32((point.lon * longitudeScale / gridMetres).rounded()),
                lat: Int32((point.lat * 111_320.0 / gridMetres).rounded())
            )
        }

        func isClaimed(_ point: Coord) -> Bool {
            let key = node(point)
            for longitudeOffset in -1 ... 1 {
                for latitudeOffset in -1 ... 1 {
                    let nearby = PointKey(
                        lon: key.lon + Int32(longitudeOffset),
                        lat: key.lat + Int32(latitudeOffset)
                    )
                    if claimed.contains(nearby) { return true }
                }
            }
            return false
        }

        func samples(of points: [Coord]) -> [Coord] {
            guard points.count >= 2 else { return [] }
            var result: [Coord] = []
            for index in 0 ..< points.count - 1 {
                let first = points[index]
                let second = points[index + 1]
                let distance = max(1, Geo.flatMetres(first.lon, first.lat, second.lon, second.lat))
                let steps = max(1, Int(ceil(distance / 12)))
                for step in 0 ... steps {
                    if index > 0, step == 0 { continue }
                    let progress = Double(step) / Double(steps)
                    result.append(
                        Coord(
                            lon: first.lon + (second.lon - first.lon) * progress,
                            lat: first.lat + (second.lat - first.lat) * progress
                        )
                    )
                }
            }
            return result
        }

        for candidate in candidates {
            let pathSamples = samples(of: candidate.points)
            guard pathSamples.count >= 2 else { continue }
            let claimedCount = pathSamples.reduce(into: 0) { count, point in
                if isClaimed(point) { count += 1 }
            }
            if Double(claimedCount) / Double(pathSamples.count) >= 0.82 {
                continue
            }
            output.append(OverlayLine(points: candidate.points, style: style))
            for point in pathSamples {
                claimed.insert(node(point))
            }
        }
        return output
    }

    private static func welded(
        _ lines: [OverlayLine],
        within metres: Double
    ) -> [OverlayLine] {
        Dictionary(grouping: lines, by: \.style).flatMap { style, group in
            Geo.join(group.map(\.points), within: metres).map { points in
                OverlayLine(points: points, style: style)
            }
        }
    }

    private static func railPriority(_ style: RailStyle) -> Int {
        switch style {
        case .tram, .lightRail, .funicular: return 3
        case .heavy, .narrow: return 2
        case .other: return 1
        }
    }
}
