import Foundation

/// Screen-space hit testing, independent of station/platform selection.
public enum VehicleTap {
    public typealias Point = SIMD2<Double>
    public struct Hit: Sendable, Equatable {
        public var id: String
        public var distance: Double
        public init(id: String, distance: Double) { self.id = id; self.distance = distance }
    }

    /// Padding outside the visible body, in points, at every zoom and pitch.
    public static let reach = 14.0
    public static let ambiguity = 3.0

    public static func candidates(_ hits: [Hit]) -> [Hit] {
        var nearest: [String: Double] = [:]
        for hit in hits where hit.distance.isFinite && hit.distance >= 0 && hit.distance <= reach {
            nearest[hit.id] = min(nearest[hit.id] ?? .infinity, hit.distance)
        }
        let unique: [Hit] = nearest.map { Hit(id: $0.key, distance: $0.value) }
        let sorted = unique.sorted { (lhs: Hit, rhs: Hit) -> Bool in
            if lhs.distance == rhs.distance { return lhs.id < rhs.id }
            return lhs.distance < rhs.distance
        }
        guard let first = sorted.first else { return [] }
        let limit = first.distance <= 0.5 ? 0.5 : first.distance + ambiguity
        return Array(sorted.prefix { $0.distance <= limit }.prefix(4))
    }

    /// Distance to a projected rake, not its head. A tap on the eighth coach
    /// is a tap on that train.
    public static func distance(from point: Point, toLine line: [Point]) -> Double {
        guard point.x.isFinite, point.y.isFinite else { return .infinity }
        guard line.count >= 2 else {
            guard let only = line.first, only.x.isFinite, only.y.isFinite else { return .infinity }
            return hypot(point.x - only.x, point.y - only.y)
        }
        var best = Double.infinity
        for i in 1..<line.count {
            let previous = line[i - 1], next = line[i]
            guard previous.x.isFinite, previous.y.isFinite,
                  next.x.isFinite, next.y.isFinite else { continue }
            let edge = next - previous
            let length = edge.x * edge.x + edge.y * edge.y
            let delta = point - previous
            let t = length > 0 ? max(0, min(1, (delta.x * edge.x + delta.y * edge.y) / length)) : 0
            let away = point - (previous + t * edge)
            best = min(best, hypot(away.x, away.y))
        }
        return best
    }

    /// Zero anywhere inside a coach, otherwise distance to its visible edge.
    /// Uses the projected polygon, including the chord of a coach on a curve.
    public static func distance(from point: Point, to polygon: [Point]) -> Double {
        guard point.x.isFinite, point.y.isFinite, !polygon.isEmpty,
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return .infinity }
        var inside = false
        var best = Double.infinity
        var previous = polygon[polygon.count - 1]
        for next in polygon {
            let edge = next - previous
            let length = edge.x * edge.x + edge.y * edge.y
            let delta = point - previous
            let t = length > 0 ? max(0, min(1, (delta.x * edge.x + delta.y * edge.y) / length)) : 0
            let away = point - (previous + t * edge)
            best = min(best, hypot(away.x, away.y))
            if (previous.y > point.y) != (next.y > point.y),
               point.x < previous.x + (point.y - previous.y) * edge.x / edge.y {
                inside.toggle()
            }
            previous = next
        }
        return inside ? 0 : best
    }
}
