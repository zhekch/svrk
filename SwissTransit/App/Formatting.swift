import Foundation
import SwiftUI
import TransitCore

/// Presentation helpers shared by every panel.
enum Format {
    static let delayColor = Color(red: 1, green: 149.0 / 255, blue: 0)

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func time(_ stamp: Timestamp) -> String {
        clock.string(from: Date(timeIntervalSince1970: TimeInterval(TransitCore.Clock.displayMinute(stamp))))
    }

    /// "Tue 3 Mar" — enough to tell one day from another without a year nobody
    /// is in doubt about.
    static let dayName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter
    }()

    static func day(_ date: Date) -> String { dayName.string(from: date) }

    /// "in 4 min", "in 6h", "now", "2 min ago".
    ///
    /// With the "in". A bare "23 min" beside a clock time reads as a duration —
    /// a journey of twenty-three minutes — and the one word settles it.
    ///
    /// Counted from the printed clocks, not rounded seconds: a 15:30 departure
    /// at 15:07 is "in 23 min", the same figure the Live Activity shows.
    ///
    /// An hour out it is whole hours, and the nearest one rather than the one
    /// the wait is in: 2h40 is nearly three hours away, not two. Nobody leaves
    /// for a train on 5h 53min's notice, so the minutes past the hour were
    /// precision spent on the one row that needed it least — and they were
    /// spending it out of every other row's width, since the column holds the
    /// longest thing in the section and "in 5h 53min" is nearly twice "in 4
    /// min". That was the gap between the platform badges and the clocks on a
    /// board reaching into tomorrow.
    static func relative(_ stamp: Timestamp, from now: Timestamp) -> String {
        let minutes = Clock.remainingMinutes(until: stamp, from: now)
        if minutes == 0 { return "now" }
        let magnitude = abs(minutes)
        let duration = magnitude < 60
            ? "\(magnitude) min"
            : "\((magnitude + 30) / 60)h"
        return minutes < 0 ? "\(duration) ago" : "in \(duration)"
    }

    private static let weekdayName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    static func weekday(_ stamp: Timestamp) -> String {
        weekdayName.string(from: Date(timeIntervalSince1970: TimeInterval(stamp)))
    }

    /// A call note from the feed, in English, or nil where it says nothing.
    ///
    /// SIRI's `CallNote` is German. Almost all of a national snapshot is
    /// `Aussteigeseite: Links` or `Rechts`, which this app does not show —
    /// nothing currently live publishes an exit side, and the geometric guess
    /// is gone with it. What remains worth saying is a partial cancellation.
    /// Bare reference numbers are dropped: a row reading "99871" under a
    /// station name is worse than an empty one.
    static func note(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch text {
        case "Aussteigeseite: Links", "Aussteigeseite: Rechts": return nil
        case "Teilausfall Ankunft": return "Arrival cancelled"
        case "Teilausfall Abfahrt": return "Departure cancelled"
        default: break
        }
        // A reference number is not a note.
        if text.isEmpty || text.allSatisfy(\.isNumber) { return nil }
        return text
    }

    /// The smallest delay worth a badge, in minutes.
    ///
    /// Real-time systems revise by the second, and the small end of that is
    /// jitter rather than information. A train three minutes down is already a
    /// platform change; a bus or tram two minutes down is already a missed
    /// connection. One minute is still noise on every mode.
    static func smallestWorthShowing(_ mode: Mode?) -> Int {
        switch mode {
        case .bus, .tram: return 2
        default: return 3
        }
    }

    /// A platform, as a board should print it: the number, without the sectors.
    ///
    /// The feed books a train into the part of the platform it will actually
    /// stand in — `13D-F`, `12A-C`, `5A-D` — and on a board that is the wrong
    /// answer to the wrong question. Scanning a list of departures, what you
    /// need is which platform to walk to; which end of it to stand at is what
    /// you need once you have chosen the train, and that is where the full
    /// booking stays. See `PlatformSign` in `VehiclePanel`, which prints it
    /// whole.
    ///
    /// Only a sector suffix is dropped, and only where it is unmistakably one:
    /// digits, then capitals and the hyphens that join them. Capitals because
    /// sectors are lettered `A` upward and a lower-case run is a word — a bay
    /// called `2 Bus` keeps its name, where `13D-F` and `12A-C` do not need
    /// theirs. A platform that is not a number at all is a bay of its own —
    /// `N`, `G` — and `31/32` is two platforms rather than a number and some
    /// sectors. All of those are left exactly as the feed gave them.
    static func platform(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return raw }
        var sectors = raw.dropFirst(digits.count)
        if sectors.first == " " { sectors = sectors.dropFirst() }
        guard let first = sectors.first, first.isUppercase else { return raw }
        guard sectors.allSatisfy({ $0.isUppercase || $0 == "-" || $0 == "\u{2013}" })
        else { return raw }
        return String(digits)
    }

    /// A delay, in the form a departure board prints it, or nil for silence.
    ///
    /// Early running is never shown. A scheduled service may not leave before
    /// its published time, so a negative figure is measurement noise rather than
    /// something a passenger can act on — "−1" beside a departure tells nobody
    /// anything.
    static func delay(_ minutes: Int?, mode: Mode? = nil) -> String? {
        guard let minutes, minutes >= smallestWorthShowing(mode) else { return nil }
        return "+\(minutes)"
    }

    static func duration(_ seconds: Int) -> String {
        let total = max(0, seconds) / 60
        let h = total / 60, m = total % 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }

    static func distance(_ metres: Double) -> String {
        metres < 1000 ? "\(Int(metres)) m" : String(format: "%.1f km", metres / 1000)
    }
}

extension Mode {
    var color: Color {
        switch self {
        case .train: return Color(red: 1.00, green: 0.23, blue: 0.19)
        case .tram: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .bus: return Color(red: 0.04, green: 0.52, blue: 1.00)
        case .metro: return Color(red: 0.75, green: 0.35, blue: 0.95)
        case .boat: return Color(red: 0.35, green: 0.78, blue: 0.98)
        case .cable: return Color(red: 1.00, green: 0.62, blue: 0.04)
        case .other: return Color(red: 0.60, green: 0.60, blue: 0.62)
        }
    }

    /// The same colours as hex, for the style layers.
    var hex: String {
        switch self {
        case .train: return "#ff3b30"
        case .tram: return "#34c759"
        case .bus: return "#0a84ff"
        case .metro: return "#bf5af2"
        case .boat: return "#5ac8fa"
        case .cable: return "#ff9f0a"
        case .other: return "#98989d"
        }
    }

    var label: String {
        switch self {
        case .train: return "Trains"
        case .tram: return "Trams"
        case .bus: return "Buses"
        case .metro: return "Metro"
        case .boat: return "Boats"
        case .cable: return "Cable / funicular"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .train: return "tram.fill.tunnel"
        case .tram: return "tram.fill"
        case .bus: return "bus.fill"
        case .metro: return "tram.fill"
        case .boat: return "ferry.fill"
        case .cable: return "cablecar.fill"
        case .other: return "circle.fill"
        }
    }
}
