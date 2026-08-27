import Foundation

/// One disruption notice, from either half of SIRI-SX.
///
/// The platform publishes the two under separate paths and they share nothing —
/// not a situation number, not a producer, not a shape of content:
///
/// - **Planned** (`/la/siri-sx`) is the works catalogue: 1,388 notices, every
///   one `Planned=true`, mostly `constructionWork`, validity running years out.
///   It names the individual journeys it affects — 130,982 of them — by the
///   same `DatedVehicleJourneyRef` the estimated timetable keys on, which is
///   what makes it joinable to a train rather than merely to a line.
/// - **Unplanned** (`/la/siri-sx-unplanned`) is the incident wire: 38 notices,
///   `serviceDisruption`, `vehicleFailure`, `liftFailure`, a fire brigade
///   operation. It carries no journey references at all.
///
/// So neither is a superset of the other and the app reads both. What they do
/// share is the text, and the text is the point: four languages per notice,
/// English among them, which is the first thing in this app's sources that
/// arrives already translated.
public struct Situation: Sendable, Equatable, Identifiable, Codable {
    /// `SituationNumber`. Stable across revisions of the same notice — the
    /// operator raises `Version` instead — so it is what a "seen this already"
    /// check keys on.
    public var id: String
    /// Whether this came from the planned feed. Not read from `<Planned>`,
    /// which the unplanned feed omits entirely: it is which path answered.
    public var planned: Bool
    /// `AlertCause`, as the feed spells it — `serviceDisruption`,
    /// `liftFailure`, `constructionWork`. Kept raw; `causeText` prints it.
    public var cause: String?
    /// `VersionedAtTime`: when the operator last revised this. Shown rather
    /// than hidden, because a notice about a cable car that has been out since
    /// July reads very differently from one raised eleven minutes ago.
    public var updated: Timestamp?

    /// The windows this notice applies in.
    ///
    /// A list rather than one span, because a notice with two windows —
    /// weekends either side of a working week — is active in neither of the
    /// days between them, and a single `from...until` collapsed from the
    /// extremes would claim it was.
    public var windows: [Window]

    public struct Window: Sendable, Equatable, Codable {
        public var from: Timestamp
        /// Absent where the feed states no end: "Duration: not known".
        public var until: Timestamp?

        public init(from: Timestamp, until: Timestamp?) {
            self.from = from
            self.until = until
        }

        public func covers(_ moment: Timestamp) -> Bool {
            moment >= from && (until.map { moment <= $0 } ?? true)
        }
    }

    /// The five texts, in English where the feed has it and German otherwise.
    public var summary: String?
    /// `DescriptionText` — what specifically is affected, where the operator
    /// says: "Affected: elevator platform 2, access Bahnhofstrasse".
    public var detail: String?
    public var reason: String?
    public var consequence: String?
    public var duration: String?
    public var advice: String?
    /// The operator's own page. 84 of the 38 unplanned notices carry one —
    /// several have more than one, and the first is kept.
    public var link: String?

    /// `PublishedLineName`: the number on the front of the vehicle. The join
    /// that works for the unplanned feed, whose `LineRef` is in the Swiss
    /// `85:…` numbering that the estimated timetable never uses.
    public var lines: [String]
    /// `StopPlaceRef`, station-level SLOIDs — `ch:1:sloid:3202`. The exact
    /// join: all 21 in the unplanned feed resolve through `StopRegister`.
    public var stopPlaces: [String]
    /// `DatedVehicleJourneyRef`. Planned feed only; empty for the other.
    public var journeys: [String]
    /// `OperatorRef` — `ch:1:sboid:100001`. Carried because a line *number* is
    /// not unique in Switzerland: a bare "2" is a tram in Zurich, a bus in
    /// Lugano and several other things besides, so matching a vehicle to a
    /// notice on its line name alone attaches a Ticino landslide to a Zurich
    /// tram. The operator is what makes the pair specific.
    public var operators: [String]

    public init(
        id: String, planned: Bool, cause: String? = nil, updated: Timestamp? = nil,
        windows: [Window] = [], summary: String? = nil, detail: String? = nil,
        reason: String? = nil,
        consequence: String? = nil, duration: String? = nil, advice: String? = nil,
        link: String? = nil, lines: [String] = [], stopPlaces: [String] = [],
        journeys: [String] = [], operators: [String] = []
    ) {
        self.id = id
        self.planned = planned
        self.cause = cause
        self.updated = updated
        self.windows = windows
        self.summary = summary
        self.detail = detail
        self.reason = reason
        self.consequence = consequence
        self.duration = duration
        self.advice = advice
        self.link = link
        self.lines = lines
        self.stopPlaces = stopPlaces
        self.journeys = journeys
        self.operators = operators
    }

    public func isActive(at moment: Timestamp) -> Bool {
        windows.isEmpty || windows.contains { $0.covers(moment) }
    }

    /// Whether this notice is worth keeping in memory at `now`.
    ///
    /// The planned feed's validity runs from 2024 to 2027 and most of it is
    /// about a weekend two months away. Holding all of it would mean holding
    /// 130,982 journey references for the sake of the thousand that are about
    /// today, so everything outside the horizon is dropped as it is parsed.
    public func isWithin(_ horizon: TimeInterval, of now: Timestamp) -> Bool {
        guard !windows.isEmpty else { return true }
        let edge = now + Timestamp(horizon)
        return windows.contains { $0.from <= edge && ($0.until.map { $0 >= now } ?? true) }
    }

    /// The cause in words, or nil where the feed declined to give one.
    ///
    /// `undefinedAlertCause` and `unknown` are the feed saying nothing, and
    /// printing "Undefined alert cause" beside a disruption is worse than
    /// printing nothing: it reads as a fault in the app rather than as a
    /// silence in the source. The rest are split out of their camel case.
    public var causeText: String? {
        guard let cause, !cause.isEmpty,
              cause != "undefinedAlertCause", cause != "unknown"
        else { return nil }
        var out = ""
        for character in cause {
            if character.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(out.isEmpty ? Character(character.uppercased()) : Character(character.lowercased()))
        }
        return out
    }

    /// The one line to print where there is room for one line.
    public var headline: String? { summary ?? reason ?? consequence }
}
