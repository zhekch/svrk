import Foundation

// When a formation is the formation.
//
// The learned database filed one answer per line, and that was one answer too
// few. A line does not run one train all day. The RE1 is two units coupled in
// the morning peak and one of them at eleven o'clock; the IC strengthened on a
// Saturday is a different train from the Tuesday working of the same number.
// Filed against the line alone, those observations are not two facts, they are
// one fact and a contradiction — and the incumbent-and-challenger count that
// resolves contradictions resolved it the only way it could, by picking
// whichever had been seen more often and drawing every other working wrong.
//
// The fix is to stop asking "what does the RE1 run" and start asking "what does
// the RE1 run at this hour". The Swiss timetable makes that a better question
// than it would be anywhere else: the whole network is a *Taktfahrplan*, an
// hourly cycle repeated all day, so the working at 07:17 and the working at
// 08:17 really are the same train and the working at 11:17 really is a
// different one. The hour is not an arbitrary bucket here; it is the period of
// the thing being measured.
//
// Two properties are worth stating, because both were design decisions.
//
// **The hour comes from the train, not from the clock.** A vehicle carries its
// own timetable, so the slot a working belongs to is a fact about the working
// and does not change from frame to frame. That is what keeps this off the
// draw path's critical section: the answer for one vehicle is stable, so it
// caches like everything else.
//
// **A slot never makes the drawing worse.** Slots are a tier in front of the
// line-wide record, not a replacement for it. A slot nobody has observed falls
// through to what the line usually runs, which is exactly what the app drew
// before any of this existed. Learning strictly adds.

/// Which working of a line this is, to the resolution the timetable repeats at.
///
/// Two fields, and both earn their place. The hour separates the peak from the
/// middle of the day, which is the case this exists for. The weekend flag
/// separates the Saturday IC from the Tuesday one — the same line, the same
/// hour, reliably different trains, and without the flag they would be filed
/// as one and fight exactly the way lines used to.
public struct TimeSlot: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Local hour of the day, 0 through 23.
    public var hour: Int
    /// Saturday or Sunday. Not "a public holiday", which the app has no
    /// calendar for — a holiday files as the weekday it falls on and is one
    /// odd observation among many, which is what the challenger count is for.
    public var weekend: Bool

    public init(hour: Int, weekend: Bool) {
        // Clamped rather than trusted. Everything that reaches here is derived
        // arithmetic, and an hour of 24 would be a silently separate bucket
        // that nothing ever looks up again.
        self.hour = min(max(hour, 0), 23)
        self.weekend = weekend
    }

    /// The slot a moment falls in, given the local offset from UTC.
    ///
    /// Integer arithmetic, and deliberately not `Calendar`. This is reached
    /// once per vehicle whose layout is not already resolved, and
    /// `Calendar.component(_:from:)` builds date components — an allocation and
    /// a good deal more — to answer a question that is two divisions. The
    /// offset is handed in because looking *that* up is the expensive half, and
    /// it is constant for months at a time; see `ZoneOffset`.
    public init(epochSeconds: Int, offsetFromUTC: Int) {
        let local = epochSeconds + offsetFromUTC
        // Floored division, so the arithmetic is still right before 1970 and,
        // more to the point, for any negative offset applied near the epoch.
        // Swift's `/` truncates toward zero, which would put 23:00 of the
        // previous day in hour 0. Done in integers rather than by rounding a
        // `Double`: this is on the draw path, and it is two instructions.
        let day = local >= 0 ? local / 86_400 : ((local + 1) / 86_400) - 1
        let secondOfDay = local - day * 86_400
        // 1 January 1970 was a Thursday, so day 0 is weekday 4 counting Sunday
        // as 0. The `+ 7` before the modulo keeps a negative day index from
        // producing a negative weekday.
        let weekday = ((day + 4) % 7 + 7) % 7
        self.init(hour: secondOfDay / 3_600, weekend: weekday == 0 || weekday == 6)
    }

    public var description: String {
        String(format: "%@%02d", weekend ? "weekend " : "", hour)
    }
}

/// The local offset from UTC, looked up rarely and remembered.
///
/// `TimeZone.secondsFromGMT(for:)` walks a table of transitions, and the draw
/// path asks for the offset of a moment several dozen times a frame. It is the
/// same answer every time for months on end — Swiss time changes twice a year
/// — so it is worked out once and kept until the transition it was valid up to.
///
/// A value type with the window in it rather than a cache with a policy: the
/// only thing that can invalidate this is time passing, and the answer already
/// says when it stops being true.
struct ZoneOffset: Sendable {
    var seconds: Int
    /// The window this offset applies over, as epoch seconds.
    ///
    /// Two-sided, so that scrubbing the clock backwards past a March morning
    /// recomputes rather than answering with the summer's offset. One-sided it
    /// was cheaper by one comparison and wrong for the whole winter behind it.
    var validFrom: Int
    var validUntil: Int

    /// Whether this offset can answer for a given moment.
    ///
    /// Two integer comparisons, and deliberately nothing else. This is the
    /// whole of the hot path: reading `TimeZone.current` here to check the
    /// phone had not moved meant retaining a time zone and comparing two
    /// identifier strings per vehicle per frame, to confirm something that
    /// changes when somebody gets off a plane. That is handled by watching for
    /// it instead — see `VehicleLayoutStore.init`.
    func covers(_ epochSeconds: Int) -> Bool {
        epochSeconds >= validFrom && epochSeconds < validUntil
    }

    /// Work out the offset that applies at a moment, and how long it lasts.
    static func around(_ date: Date, zone: TimeZone) -> ZoneOffset {
        let seconds = zone.secondsFromGMT(for: date)
        // A zone with no transitions either side — UTC, or a phone parked
        // somewhere that does not observe summer time — never expires. Half a
        // century is not "never", but it is past every horizon this app has.
        let horizon: TimeInterval = 50 * 365 * 24 * 3_600
        let next = zone.nextDaylightSavingTimeTransition(after: date)
            ?? date.addingTimeInterval(horizon)
        // Foundation will only look forwards, so the near edge is found by
        // stepping back far enough to be before the previous transition and
        // asking for the next one after *that*. Six months clears the widest
        // gap between two changes anywhere that has them.
        let halfYear = date.addingTimeInterval(-183 * 24 * 3_600)
        let previous = zone.nextDaylightSavingTimeTransition(after: halfYear)
            .flatMap { $0 <= date ? $0 : nil }
            ?? date.addingTimeInterval(-horizon)
        return ZoneOffset(
            seconds: seconds,
            validFrom: Int(previous.timeIntervalSince1970),
            validUntil: Int(next.timeIntervalSince1970)
        )
    }
}

/// A line, at an hour of the day.
///
/// Kept as its own key rather than as an optional field on `PatternKey` so the
/// two tiers cannot be confused for one another — a lookup that means "the RE1
/// generally" and a lookup that means "the RE1 at eight in the morning" are
/// different questions, and a single dictionary holding both would answer the
/// first with the second whenever a `nil` slipped through.
public struct SlotKey: Hashable, Sendable, Codable {
    public var pattern: PatternKey
    public var slot: TimeSlot

    public init(pattern: PatternKey, slot: TimeSlot) {
        self.pattern = pattern
        self.slot = slot
    }
}
