import Foundation

/// A published through-service: two numbered workings that are one vehicle.
///
/// This is the fact `Chains` used to infer. The feed states it outright — GTFS
/// files it as `transfer_type=4`, "the passenger stays on board" — and a stated
/// fact beats the best inference available, because the inference has no way to
/// tell a train that rolls through from a train that merely followed another
/// onto the same platform.
///
/// Each side is *every name that working answers to*, because the two sources
/// spell a run differently and both reach here: the packed timetable files a
/// journey under its GTFS `trip_id`, SIRI files the same run under its Swiss
/// Journey ID. A link offering only one of them would join packed legs and
/// never live ones.
///
/// **Names are lower-cased.** The feeds disagree on the case of the namespace
/// — `CH:1:sjyid:` against `ch:1:sjyid:` — so matching has to ignore case, and
/// the fold belongs here, once, rather than at each of the 75,000 comparisons
/// a chain rebuild makes. Anything matched against these must be folded too.
public struct ThroughLink: Sendable, Equatable {
    public var from: [String]
    public var to: [String]

    public init(from: [String], to: [String]) {
        self.from = from
        self.to = to
    }
}

/// Every published through-service for one operating day.
///
/// Whole-day rather than per-train: nationally a day is around 18,800 links,
/// which is small enough that there is no reason for a query narrower than
/// "give me the day and let the caller index it".
public struct ThroughGraph: Sendable, Equatable {
    public var links: [ThroughLink]

    public static let empty = ThroughGraph(links: [])

    public init(links: [ThroughLink]) {
        self.links = links
    }

    public var isEmpty: Bool { links.isEmpty }

    /// Fold another source's links in. Duplicates are harmless — resolution is
    /// by set — so this does not try to be clever about them.
    public func merging(_ other: ThroughGraph) -> ThroughGraph {
        other.isEmpty ? self : ThroughGraph(links: links + other.links)
    }
}
