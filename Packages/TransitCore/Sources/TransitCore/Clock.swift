import Foundation

/// The clock the map is drawn against.
///
/// Positions are computed from the timetable rather than observed, which means
/// "now" is just a number the renderer is handed — so the same code can show
/// this morning or this evening simply by handing it a different one. This
/// holds that number, advancing it in real time (or faster) from an anchor so
/// playback stays smooth without accumulating drift.
public final class Clock: @unchecked Sendable {
    private var anchorReal: Double
    private var anchorVirtual: Double
    public private(set) var speed: Double
    public private(set) var isPlaying: Bool

    public init() {
        anchorReal = Date().timeIntervalSince1970
        anchorVirtual = anchorReal
        speed = 1
        isPlaying = true
    }

    /// Seconds since the epoch, in the timeline being viewed.
    public func now() -> Double {
        guard isPlaying else { return anchorVirtual }
        return anchorVirtual + (Date().timeIntervalSince1970 - anchorReal) * speed
    }

    public func nowSeconds() -> Timestamp { Int(now()) }

    /// Re-anchor so the current virtual instant is preserved across changes.
    private func reanchor() {
        anchorVirtual = now()
        anchorReal = Date().timeIntervalSince1970
    }

    /// How far the view is from real time, in seconds.
    public func offset() -> Double { now() - Date().timeIntervalSince1970 }

    public func setOffset(_ seconds: Double) {
        anchorReal = Date().timeIntervalSince1970
        anchorVirtual = anchorReal + seconds
    }

    public func setSpeed(_ value: Double) {
        reanchor()
        speed = value
    }

    public func setPlaying(_ value: Bool) {
        reanchor()
        isPlaying = value
    }

    public func reset() {
        anchorReal = Date().timeIntervalSince1970
        anchorVirtual = anchorReal
        speed = 1
        isPlaying = true
    }

    /// True when the view is close enough to now to count as live.
    public var isLive: Bool {
        isPlaying && speed == 1 && abs(offset()) < 120
    }

    public static func formatOffset(_ seconds: Double) -> String {
        let total = Int((abs(seconds) / 60).rounded())
        if total == 0 { return "live" }
        let sign = seconds < 0 ? "−" : "+"
        let h = total / 60, m = total % 60
        return h > 0 ? "\(sign)\(h)h \(m)m" : "\(sign)\(m)m"
    }
}
