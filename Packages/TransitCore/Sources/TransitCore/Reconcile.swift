import Foundation

/// Matching a live SIRI journey to the timetabled run it is a sighting of.
///
/// This exists because the two feeds do not agree on identifiers, and the
/// disagreement is not small. Measured against a recorded national snapshot of
/// 15,997 journeys and the GTFS days it spans:
///
/// | key                                   | resolved |
/// |---------------------------------------|----------|
/// | journey reference, as published       |    55.6% |
/// | + line, origin stop and start minute  |    97.2% |
/// | extra runs, in no timetable by design |     1.2% |
/// | unmatched                             |     1.6% |
///
/// The id alone is not enough because 40% of the fleet arrives under a
/// `ch:1:ServiceJourney:*` namespace that appears **nowhere** in the timetable
/// feed — mostly the regional and urban operators rather than SBB. Those runs
/// are perfectly ordinary otherwise: they have a line, they leave a known stop
/// at a known minute, and that triple identifies them almost uniquely. Only 6 of
/// 6,644 such matches were ambiguous.
public enum Reconcile {
    /// A structural fingerprint of a run: what it is called, where it starts,
    /// and when it is booked to leave.
    ///
    /// The *booked* time, never the live one. A delayed departure moves between
    /// one poll and the next, so keying on it would make the same train a
    /// different train every minute — which is exactly the bug `Call.sched`
    /// exists to prevent elsewhere in this app.
    public struct Key: Hashable, Sendable {
        var line: String
        var origin: String
        var minute: Int

        public init(line: String, origin: String, minute: Int) {
            self.line = line
            self.origin = origin
            self.minute = minute
        }
    }

    /// `IC 8`, `IC8` and `ic8` are one line. The feeds disagree about the space
    /// and about case, and neither disagreement is information.
    static func fold(_ line: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in line.unicodeScalars where !CharacterSet.whitespaces.contains(scalar) {
            out.append(contentsOf: String(scalar).uppercased().unicodeScalars)
        }
        return String(out)
    }

    /// The key for a journey, or nil when it has nothing to be keyed on.
    ///
    /// Uses the origin's *station* rather than its platform. The two feeds
    /// disagree about how specific a stop reference is — one files
    /// `ch:1:sloid:7000:1:21` where the other files `ch:1:sloid:7000` — and a
    /// train leaves the station whichever platform it leaves from.
    public static func key(for journey: Journey, zone: TimeZone) -> Key? {
        guard let first = journey.stops.first, let ref = first.ref, !journey.line.isEmpty else {
            return nil
        }
        // The booked departure, which is `sched` where the parser recorded one
        // and the plain departure for a journey that has never been delayed.
        let booked = first.sched ?? first.dep
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: Date(timeIntervalSince1970: TimeInterval(booked))
        )
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let hour = parts.hour, let minute = parts.minute
        else { return nil }

        return Key(
            line: fold(journey.line),
            origin: StopRegister.stationOf(ref),
            // The date is folded into the minute so two runs of the same line
            // from the same stop at the same clock time on different days are
            // different keys — which they are, and which matters at midnight.
            minute: ((year * 12 + month) * 31 + day) * 1440 + hour * 60 + minute
        )
    }

    /// Index a set of timetabled journeys for matching.
    ///
    /// A key that more than one journey answers to is dropped rather than
    /// guessed at. It happens to 6 keys in 6,644, and a wrong match is worse
    /// than none: it would move a real train's times onto a different real
    /// train.
    public static func index(_ journeys: some Sequence<Journey>, zone: TimeZone) -> [Key: Journey] {
        var out: [Key: Journey] = [:]
        var ambiguous: Set<Key> = []
        for journey in journeys {
            guard let key = key(for: journey, zone: zone) else { continue }
            if out.updateValue(journey, forKey: key) != nil { ambiguous.insert(key) }
        }
        for key in ambiguous { out.removeValue(forKey: key) }
        return out
    }

    /// What a reconciliation did, for a status panel that has to explain why
    /// the map changed.
    public struct Report: Sendable, Equatable {
        public var matchedByRef = 0
        public var matchedByShape = 0
        public var added = 0
        public var unmatched = 0

        public var matched: Int { matchedByRef + matchedByShape }
        public var total: Int { matched + added + unmatched }
    }
}
