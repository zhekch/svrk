import Foundation

/// Decorations measured from the original route origin, before viewport
/// clipping, simplification or the moving travelled/remaining split.
public struct RoutePattern: Sendable {
    public struct Mark: Sendable {
        public let coordinate: Coord
        public let direction: Coord
        public let distance: Double
        public let scale: Double
    }

    private let path: [Coord]
    private let distances: [Double]
    private let chunks: [(indices: Range<Int>, bounds: BBox)]

    public init(path: [Coord]) {
        self.path = path
        var distances = Array(repeating: 0.0, count: path.count)
        for i in path.indices.dropFirst() {
            distances[i] = distances[i - 1] + Geo.metres(path[i - 1], path[i])
        }
        self.distances = distances
        var chunks: [(indices: Range<Int>, bounds: BBox)] = []
        for start in stride(from: 1, to: path.count, by: 128) {
            let end = min(path.count, start + 128)
            var box = BBox(west: .infinity, south: .infinity, east: -.infinity, north: -.infinity)
            for i in (start - 1)..<end {
                box.west = min(box.west, path[i].lon); box.east = max(box.east, path[i].lon)
                box.south = min(box.south, path[i].lat); box.north = max(box.north, path[i].lat)
            }
            chunks.append((start..<end, box))
        }
        self.chunks = chunks
    }

    public func distance(from start: Int, to end: Int, progress: Double, trailing: Double = 0) -> Double {
        guard distances.indices.contains(start), distances.indices.contains(end) else { return 0 }
        let progress = progress.isFinite ? min(1, max(0, progress)) : 0
        return max(0, distances[start] + (distances[end] - distances[start]) * progress - trailing)
    }

    /// Estimate visible decoration work without allocating any markers.
    public func visibleLength(in bounds: BBox) -> Double {
        var length = 0.0
        for chunk in chunks where chunk.bounds.intersects(bounds) {
              for i in chunk.indices {
                    if let segment = Geo.clipSegment(from: path[i - 1], to: path[i], box: bounds) {
                        length += Geo.metres(segment.start, segment.end)
                    }
                }
            }
            return length
        }
    
        /// Zoom reveals intermediate marks on a nested metre grid. Existing marks
        /// never change coordinates; intermediate ones grow/shrink in place.
        public func marks(spacing: Double, in bounds: BBox, through limit: Double = .infinity) -> [Mark] {
            guard path.count > 1, spacing.isFinite, spacing > 0 else { return [] }
            let step = pow(2, floor(log2(max(4, spacing))))
            let intermediateScale = sqrt(max(0, min(1, 2 - spacing / step)))
            var result: [Mark] = []
            for chunk in chunks where chunk.bounds.intersects(bounds) {
              for i in chunk.indices {
                let start = distances[i - 1], end = min(distances[i], limit)
                guard end > start else { continue }
                let a = path[i - 1], b = path[i]
                guard let clipped = Geo.clipSegment(from: a, to: b, box: bounds) else { continue }
                let length = distances[i] - start
                // Jump straight to the visible part of a long segment. At street
                // zoom a sparse intercity leg must not enumerate offscreen dots.
                func fraction(_ point: Coord) -> Double {
                    abs(b.lon - a.lon) > abs(b.lat - a.lat)
                        ? (point.lon - a.lon) / (b.lon - a.lon)
                        : (point.lat - a.lat) / (b.lat - a.lat)
                }
                let first = start + length * fraction(clipped.start)
                let last = min(end, start + length * fraction(clipped.end))
                var index = max(1, Int(floor(start / step)) + 1, Int(ceil(first / step)))
                while Double(index) * step <= last {
                    let distance = Double(index) * step
                    let t = (distance - start) / length
                    let at = Coord(lon: a.lon + (b.lon - a.lon) * t, lat: a.lat + (b.lat - a.lat) * t)
                    if bounds.contains(lon: at.lon, lat: at.lat) {
                        // A short, fixed ground tangent makes the arrow rotate with
                        // the map without depending on the visible line endpoints.
                        let direction = Coord(lon: at.lon + (b.lon - a.lon) * 2 / length,
                                              lat: at.lat + (b.lat - a.lat) * 2 / length)
                        result.append(Mark(coordinate: at, direction: direction, distance: distance,
                                           scale: index.isMultiple(of: 2) ? 1 : intermediateScale))
                    }
                    index += 1
                }
            }
        }
        return result
    }
}
