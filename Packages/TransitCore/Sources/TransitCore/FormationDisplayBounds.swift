import Foundation

/// The useful part of a formation diagram, in any consistent drawing units.
/// Sector bounds crop the unlabelled platform ends, but never crop a coach.
/// Without sector data, retain the full platform as the fallback.
public struct FormationDisplayBounds: Sendable {
    public let lower: Double
    public let upper: Double
    public var width: Double { upper - lower }

    public init(
        platformWidth: Double, trainStart: Double, trainWidth: Double,
        sectorStart: Double, sectorWidth: Double
    ) {
        if sectorWidth > 0 {
            // Sector padding is schematic; the mapped stopping point and
            // platform length need not leave that much room before the train.
            // Preserve a negative sector origin and translate the whole
            // drawing together, rather than shifting sectors under coaches.
            lower = min(sectorStart, trainStart)
            upper = max(lower, sectorStart + sectorWidth, trainStart + trainWidth)
        } else {
            lower = 0
            upper = max(0, platformWidth, trainStart + trainWidth)
        }
    }

    /// An access point outside the cropped diagram is omitted, not moved to
    /// the nearest end (which would falsely put the stairs in that sector).
    public func position(of point: Double) -> Double? {
        guard point >= lower, point <= upper else { return nil }
        return point - lower
    }
}
