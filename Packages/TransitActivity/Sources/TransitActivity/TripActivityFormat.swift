import Foundation
import SwiftUI

/// Words and colours the Live Activity draws, independent of ActivityKit so
/// they can be tested on the host.
public enum TripActivityFormat {
    public static let delayColor = Color(red: 1, green: 149.0 / 255, blue: 0)

    public static func caption(kind: TripWatchKind, station: String) -> String {
        switch kind {
        case .departure: return "Departure from \(station)"
        case .arrival: return "Arrival to \(station)"
        }
    }

    /// Whole minutes between the two printed clocks. 15:30 at 15:07 is 23,
    /// even when the live estimate still has seconds — rounding that up to 24
    /// made the island disagree with SBB and with the clock beside it.
    public static func remainingMinutes(until expected: Date, from now: Date = Date()) -> Int {
        let event = Int(expected.timeIntervalSince1970) / 60
        let current = Int(now.timeIntervalSince1970) / 60
        return event - current
    }

    /// Both the system countdown and ActivityKit's stale transition use the
    /// printed event minute. This keeps 15:30 at 15:07:59 equal to 23 minutes.
    public static func countdownEnd(_ expected: Date) -> Date {
        Date(timeIntervalSince1970: floor(expected.timeIntervalSince1970 / 60) * 60)
    }

    /// Keep the built-in formatter intact so the system can decode it and tick
    /// while the app is suspended. One field gives "in 3 hr" or "in 36 min".
    @available(iOS 18.0, macOS 15.0, *)
    public static func countdownStyle(
        until expected: Date, minimal: Bool = false
    ) -> Date.AnchoredRelativeFormatStyle {
        // Relative formatting rounds seconds and then minutes. Anchor just below
        // the half-minute boundary so the countdown follows the printed clocks
        // throughout each minute, rather than reaching zero 30 seconds early.
        let anchor = Date(timeIntervalSinceReferenceDate:
            (countdownEnd(expected).timeIntervalSinceReferenceDate + 29.5).nextDown
        )
        return Date.AnchoredRelativeFormatStyle(
            anchor: anchor,
            allowedFields: [.hour, .minute],
            presentation: .numeric,
            unitsStyle: minimal ? .narrow : .abbreviated,
            locale: Locale(identifier: minimal ? "en_US" : "en_GB")
        )
    }

    /// A few seconds of OJP jitter must not flip the printed `HH:mm`.
    /// 17:34:50 → 17:35:10 is the same departure, not a minute of delay.
    public static func shouldAcceptLiveTime(current: Date, incoming: Date) -> Bool {
        let oldMinute = Int(current.timeIntervalSince1970) / 60
        let newMinute = Int(incoming.timeIntervalSince1970) / 60
        if oldMinute == newMinute { return true }
        return abs(incoming.timeIntervalSince(current)) >= 60
    }

    /// Sleep this long to land on the next wall-clock minute.
    public static func secondsUntilNextMinute(from now: Date = Date()) -> TimeInterval {
        let remainder = now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
        return max(0.05, 60 - remainder)
    }

    /// Legacy countdown: "in 9 min", "now", or rounded hours ("in 3 hr").
    public static func remainingPhrase(minutes: Int) -> String {
        if minutes <= 0 { return "now" }
        return "in \(duration(minutes))"
    }

    /// Compact island: "9 min" without the "in".
    public static func compactRemaining(minutes: Int) -> String {
        if minutes <= 0 { return "now" }
        return duration(minutes)
    }

    /// Split so the lock screen can put "in" on one line and "8 min" on the next.
    public static func remainingParts(minutes: Int) -> (lead: String?, value: String) {
        if minutes <= 0 { return (nil, "now") }
        return ("in", duration(minutes))
    }

    public static func platformPhrase(kind: TripWatchKind, platform: String) -> String {
        switch kind {
        case .departure: return "From platform \(platform)"
        case .arrival: return "On platform \(platform)"
        }
    }

    private static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        return "\(Int((Double(minutes) / 60).rounded())) hr"
    }

    /// Same threshold the departure board uses: one minute is noise, two is a
    /// missed bus, three is a missed train.
    public static func smallestWorthShowing(mode: String) -> Int {
        switch mode {
        case "bus", "tram": return 2
        default: return 3
        }
    }

    public static func delayText(minutes: Int, mode: String) -> String? {
        guard minutes >= smallestWorthShowing(mode: mode) else { return nil }
        return "+\(minutes)"
    }

    public static func presence(currentStop: String?, atStop: Bool) -> String? {
        guard let currentStop, !currentStop.isEmpty else { return nil }
        return atStop ? "Currently at \(currentStop)" : "Next stop \(currentStop)"
    }

    public static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    /// The line plate colour, matching the map and the board.
    public static func color(mode: String) -> Color {
        switch mode {
        case "train": return Color(red: 1.00, green: 0.23, blue: 0.19)
        case "tram": return Color(red: 0.20, green: 0.78, blue: 0.35)
        case "bus": return Color(red: 0.04, green: 0.52, blue: 1.00)
        case "metro": return Color(red: 0.75, green: 0.35, blue: 0.95)
        case "boat": return Color(red: 0.35, green: 0.78, blue: 0.98)
        case "cable": return Color(red: 1.00, green: 0.62, blue: 0.04)
        default: return Color(red: 0.60, green: 0.60, blue: 0.62)
        }
    }

    /// The train's destination, for both watches. The caption already names
    /// the watched station ("Arrival to Mülenen"); repeating it beside the
    /// line plate hid where the service is actually going.
    public static func headline(kind: TripWatchKind, station: String, destination: String) -> String {
        destination.isEmpty ? station : destination
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

}

public enum TripWatchKind: String, Codable, Hashable, Sendable {
    case departure
    case arrival
}
