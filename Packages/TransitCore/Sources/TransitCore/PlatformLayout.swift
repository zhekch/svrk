import Foundation

/// Where a platform's plate is drawn, and where the platform actually is.
public struct PlacedPlate: Sendable, Equatable {
    public var stop: RegisteredStop
    /// Where the plate is drawn — the stop's own position unless it had to move.
    public var lon: Double
    public var lat: Double
    public var moved: Bool

    /// The code written on the plate: the signed one, or the letter this map
    /// assigned, or nothing at all for a bare kerb.
    public var code: String? { stop.platform ?? stop.assigned }
    /// True when the code is ours rather than signage.
    public var isAssigned: Bool { stop.platform == nil && stop.assigned != nil }
}

/// Nudge overlapping plates apart instead of deleting them.
///
/// A renderer's collision detection has exactly one move available: when two
/// labels overlap it drops one. For street names that is right — there is
/// another chance to read the street further along. For a platform code it is
/// wrong, because the code *is* the object; dropping it takes a bay off a map
/// whose whole claim is to show which bay. A forecourt with a dozen bays loses
/// most of its letters that way, which is the report "if there are a lot of bus
/// stops, some of them don't show".
///
/// So the overlap is resolved by displacement, and every plate is then drawn
/// unconditionally. Each is projected to pixels at the current zoom, given the
/// box it will occupy, and offered candidate positions outward from its own stop
/// until one is free. Whatever displacement it ends up with is baked back into
/// the drawn coordinate and tethered with a leader line.
///
/// Pixels, not metres: overlap is a property of the screen, and two bays 20 m
/// apart collide at zoom 15 and not at zoom 18. That is also why this reruns
/// whenever the view settles.
public enum PlatformLayout {
    /// Web Mercator, in the 512-pixel tile scheme both MapLibre and Mapbox GL
    /// define zoom against.
    private static let tileSize = 512.0

    private static func project(_ lon: Double, _ lat: Double, scale: Double) -> (x: Double, y: Double) {
        let s = min(0.9999, max(-0.9999, sin(lat * .pi / 180)))
        return (
            ((lon + 180) / 360) * scale,
            (0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * scale
        )
    }

    private static func unproject(_ x: Double, _ y: Double, scale: Double) -> (lon: Double, lat: Double) {
        let n = Double.pi - 2 * .pi * (y / scale)
        return (
            (x / scale) * 360 - 180,
            (180 / .pi) * atan(0.5 * (exp(n) - exp(-n)))
        )
    }

    /// The plate layer's own `text-size`, evaluated by hand for the box estimate.
    static func plateTextSize(_ zoom: Double) -> Double {
        let t = min(1, max(0, (zoom - 15) / 3))
        return 9.5 + t * (12 - 9.5)
    }

    /// Breathing room between two plates, so they read as separate signs.
    private static let gap = 2.0

    /// How far a plate may be pushed before it stops labelling anything the eye
    /// will connect it to, leader line or not. A plate that finds no free slot
    /// inside it is drawn at its true position and allowed to overlap.
    /// Overlapping is bad; vanishing is worse, and vanishing is what this
    /// replaces.
    private static let maxShift = 88.0
    private static let ringStep = 4.0

    /// Where a plate is allowed to land, in the order it is offered.
    ///
    /// The order *is* the policy. The stop's own position comes first, so a
    /// plate with room around it does not move at all; then rings at four-pixel
    /// steps outward, and within a ring straight up and straight down before the
    /// diagonals and the sides. A row of bays along a kerb therefore stacks into
    /// a column rather than smearing along the street, and every plate stays as
    /// close to its kerb as the crowd allows.
    private static let candidates: [(dx: Double, dy: Double)] = {
        var out: [(Double, Double)] = [(0, 0)]
        let angles: [Double] = [-90, 90, -60, 60, -120, 120, -30, 30, -150, 150, 0, 180]
        var r = ringStep
        while r <= maxShift {
            for degrees in angles {
                let rad = degrees * .pi / 180
                out.append((cos(rad) * r, sin(rad) * r))
            }
            r += ringStep
        }
        return out
    }()

    private struct Node {
        var stop: RegisteredStop
        var fixed: Bool
        var anchorX: Double
        var anchorY: Double
        var x: Double
        var y: Double
        var halfWidth: Double
        var halfHeight: Double
    }

    private struct Cell: Hashable { var x: Int; var y: Int }

    public static func place(_ stops: [RegisteredStop], zoom: Double) -> [PlacedPlate] {
        guard !stops.isEmpty else { return [] }
        let scale = tileSize * pow(2, zoom)
        let size = plateTextSize(zoom)

        var nodes: [Node] = stops.map { stop in
            let point = project(stop.lon, stop.lat, scale: scale)
            // The plate is `icon-text-fit: both` around the code, padded 5 pt
            // either side and 2 pt above and below, over a bold face that
            // averages a little under two thirds of its point size per
            // character.
            let code = stop.platform ?? stop.assigned
            let characters = Double(code?.count ?? 0)
            let width = code != nil ? characters * size * 0.62 + 14 : 8.2
            let height = code != nil ? size + 8 : 8.2
            // A codeless stop is a marker, not a label: the only thing it says
            // is *here*, so moving it would remove the one fact it carries. It
            // takes part as an obstacle — plates are placed around it — and
            // never moves itself.
            return Node(
                stop: stop, fixed: code == nil,
                anchorX: point.x, anchorY: point.y, x: point.x, y: point.y,
                halfWidth: width / 2 + gap / 2, halfHeight: height / 2 + gap / 2
            )
        }

        // A uniform grid over what has been placed, so a candidate is tested
        // against its neighbours rather than against every plate in the view.
        let cellSize = max(24, nodes.map { max($0.halfWidth, $0.halfHeight) * 2 }.max() ?? 24)
        var buckets: [Cell: [Int]] = [:]

        func cells(_ node: Node, _ x: Double, _ y: Double) -> [Cell] {
            var keys: [Cell] = []
            var gx = Int(floor((x - node.halfWidth) / cellSize))
            let gxEnd = Int(floor((x + node.halfWidth) / cellSize))
            while gx <= gxEnd {
                var gy = Int(floor((y - node.halfHeight) / cellSize))
                let gyEnd = Int(floor((y + node.halfHeight) / cellSize))
                while gy <= gyEnd {
                    keys.append(Cell(x: gx, y: gy))
                    gy += 1
                }
                gx += 1
            }
            return keys
        }

        func isFree(_ index: Int, _ x: Double, _ y: Double) -> Bool {
            let node = nodes[index]
            for key in cells(node, x, y) {
                for other in buckets[key] ?? [] where other != index {
                    let m = nodes[other]
                    if abs(m.x - x) < m.halfWidth + node.halfWidth,
                       abs(m.y - y) < m.halfHeight + node.halfHeight { return false }
                }
            }
            return true
        }

        func insert(_ index: Int) {
            let node = nodes[index]
            for key in cells(node, node.x, node.y) {
                buckets[key, default: []].append(index)
            }
        }

        // The kerbside markers go down first and never move, so the plates are
        // placed around what is fixed rather than the other way about.
        for i in nodes.indices where nodes[i].fixed { insert(i) }

        // Top to bottom, then left to right, then by id: an order that depends
        // only on the data, so a viewport lays out the same way every time it is
        // drawn. Without that the plates would rearrange themselves on every pan.
        let movable = nodes.indices.filter { !nodes[$0].fixed }.sorted {
            let a = nodes[$0], b = nodes[$1]
            if a.anchorY != b.anchorY { return a.anchorY < b.anchorY }
            if a.anchorX != b.anchorX { return a.anchorX < b.anchorX }
            return a.stop.id < b.stop.id
        }

        for i in movable {
            for candidate in candidates {
                let x = nodes[i].anchorX + candidate.dx
                let y = nodes[i].anchorY + candidate.dy
                if !isFree(i, x, y) { continue }
                nodes[i].x = x
                nodes[i].y = y
                break
            }
            insert(i)
        }

        return nodes.map { node in
            let moved = hypot(node.x - node.anchorX, node.y - node.anchorY) > 0.5
            guard moved else {
                return PlacedPlate(stop: node.stop, lon: node.stop.lon, lat: node.stop.lat, moved: false)
            }
            let point = unproject(node.x, node.y, scale: scale)
            return PlacedPlate(stop: node.stop, lon: point.lon, lat: point.lat, moved: true)
        }
    }
}
