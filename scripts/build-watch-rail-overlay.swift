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

private struct PointKey: Hashable, Comparable {
    var lon: Int32
    var lat: Int32

    static func < (lhs: PointKey, rhs: PointKey) -> Bool {
        lhs.lon == rhs.lon ? lhs.lat < rhs.lat : lhs.lon < rhs.lon
    }

}

private struct StyledNode: Hashable, Comparable {
    var style: RailStyle
    var point: PointKey

    static func < (lhs: StyledNode, rhs: StyledNode) -> Bool {
        if lhs.style.rawValue != rhs.style.rawValue {
            return lhs.style.rawValue < rhs.style.rawValue
        }
        return lhs.point < rhs.point
    }
}

private struct EdgeKey: Hashable, Comparable {
    var first: StyledNode
    var second: StyledNode

    init(_ lhs: StyledNode, _ rhs: StyledNode) {
        if lhs < rhs {
            first = lhs
            second = rhs
        } else {
            first = rhs
            second = lhs
        }
    }

    static func < (lhs: EdgeKey, rhs: EdgeKey) -> Bool {
        lhs.first == rhs.first ? lhs.second < rhs.second : lhs.first < rhs.first
    }
}

@main
private enum BuildWatchRailOverlay {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            FileHandle.standardError.write(
                Data("usage: build-watch-rail-overlay INPUT_RAILNET INPUT_ROUTES OUTPUT\n".utf8)
            )
            Foundation.exit(2)
        }

        let railInput = URL(fileURLWithPath: CommandLine.arguments[1])
        let routesInput = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = URL(fileURLWithPath: CommandLine.arguments[3])
        let railnet = RailNet()
        try railnet.load(railInput)
        let relations = RelationStore()
        try relations.load(routesInput)

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

        let national = railnet.lines(
                    in: country,
                    limit: 50_000,
                    kindMask: mainMask,
                    minLength: 3_000,
                    simplify: 150
                )
            .map { OverlayLine(points: $0.points, style: railStyle(for: $0.kind)) }
        let local = serviceCorridors(from: relations, in: country)
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
    }

    /// Build the local band from the physical corridor union of OSM transit
    /// relations. Relations are deliberately not emitted as polylines: every
    /// line, direction and short-working repeats the same rails and produced a
    /// fan of green strokes at a tram junction. Sampling onto a small ground
    /// grid and letting the first relation claim every shared segment yields
    /// long centreline runs without bringing yard/siding texture back.
    private static func serviceCorridors(
        from store: RelationStore,
        in bounds: BBox
    ) -> [OverlayLine] {
        var claimed = Set<EdgeKey>()
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

        // Twenty-two metres merges the two rails of a street-running tramway and
        // minor relation-to-relation offsets, but keeps neighbouring streets
        // and genuinely separate alignments apart.
        let gridMetres = 22.0
        let longitudeScale = 111_320.0 * cos(47.0 * .pi / 180)

        func node(_ point: Coord, style: RailStyle) -> StyledNode {
            StyledNode(
                style: style,
                point: PointKey(
                    lon: Int32((point.lon * longitudeScale / gridMetres).rounded()),
                    lat: Int32((point.lat * 111_320.0 / gridMetres).rounded())
                )
            )
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

        for index in 0 ..< store.count {
            let relation = store.relation(at: index)
            guard let style = style(for: relation.route) else { continue }
            let path = store.path(of: relation)
            guard path.count >= 2 else { continue }

            let simplified = Geo.simplify(path.toArray(), toleranceMetres: 12)
            guard simplified.count >= 2 else { continue }

            var segments: [(edge: EdgeKey, from: Coord, to: Coord)] = []
            var previousNode: StyledNode?
            var previousPoint: Coord?
            for segment in 0 ..< simplified.count - 1 {
                let first = simplified[segment]
                let second = simplified[segment + 1]
                let distance = max(1, Geo.metres(first, second))
                let steps = max(1, Int(ceil(distance / 9)))

                for step in 0 ... steps {
                    if segment > 0, step == 0 { continue }
                    let progress = Double(step) / Double(steps)
                    let point = Coord(
                        lon: first.lon + (second.lon - first.lon) * progress,
                        lat: first.lat + (second.lat - first.lat) * progress
                    )
                    let current = node(point, style: style)
                    if let previousNode, let previousPoint, current != previousNode {
                        let isInside = bounds.contains(lon: point.lon, lat: point.lat)
                            || bounds.contains(lon: previousPoint.lon, lat: previousPoint.lat)
                        if isInside {
                            segments.append((
                                edge: EdgeKey(previousNode, current),
                                from: previousPoint,
                                to: point
                            ))
                        }
                    }
                    previousNode = current
                    previousPoint = point
                }
            }
            guard !segments.isEmpty else { continue }

            let relationEdges = Set(segments.map(\.edge))
            let newEdges = relationEdges.filter { !claimed.contains($0) }
            let novelty = Double(newEdges.count) / Double(relationEdges.count)

            if novelty >= 0.65 {
                // A substantially new alignment earns its original smooth
                // relation geometry. Its shared tail is worth the continuity.
                emit(simplified, style: style)
                claimed.formUnion(relationEdges)
                continue
            }

            // A mostly duplicate relation contributes only meaningful new
            // branches. Shorter fragments are mapping jitter and station
            // switches—the exact fan of extra lines this watch layer avoids.
            var branch: [Coord] = []
            var branchEdges: [EdgeKey] = []
            func finishBranch() {
                guard branchEdges.count >= 5 else {
                    branch.removeAll(keepingCapacity: true)
                    branchEdges.removeAll(keepingCapacity: true)
                    return
                }
                emit(branch, style: style)
                claimed.formUnion(branchEdges)
                branch.removeAll(keepingCapacity: true)
                branchEdges.removeAll(keepingCapacity: true)
            }

            for segment in segments {
                if !claimed.contains(segment.edge) {
                    if branch.isEmpty { branch.append(segment.from) }
                    branch.append(segment.to)
                    branchEdges.append(segment.edge)
                } else if !branch.isEmpty {
                    finishBranch()
                }
            }
            if !branch.isEmpty { finishBranch() }
        }
        return output
    }
}
