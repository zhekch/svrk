import Foundation

/// How full a vehicle is expected to be, as the operator forecasts it.
///
/// The values are SIRI's `OccupancyEnumeration`, kept whole rather than
/// collapsed at the point of reading: what the feed said is a fact, and how
/// many buckets a drawing wants is a decision the drawing gets to make. Swiss
/// producers use three of them in practice — `manySeatsAvailable`,
/// `fewSeatsAvailable` and `standingRoomOnly` — but the enumeration is larger
/// and a value outside it must not throw away the call it arrived on.
public enum OccupancyLevel: String, Sendable, Codable, Equatable, CaseIterable {
    case empty
    case manySeatsAvailable
    case seatsAvailable
    case fewSeatsAvailable
    case standingAvailable
    case standingRoomOnly
    case crushedStandingRoomOnly
    case full
    case notAcceptingPassengers
    case unknown

    /// The three buckets a passenger actually acts on, which is as fine a
    /// distinction as a forecast of this kind can honestly carry.
    public enum Crowding: Int, Sendable, Comparable {
        case low = 0, medium = 1, high = 2
        public static func < (a: Crowding, b: Crowding) -> Bool { a.rawValue < b.rawValue }
    }

    public var crowding: Crowding? {
        switch self {
        case .empty, .manySeatsAvailable, .seatsAvailable: return .low
        case .fewSeatsAvailable, .standingAvailable: return .medium
        case .standingRoomOnly, .crushedStandingRoomOnly, .full, .notAcceptingPassengers:
            return .high
        // Not a bucket. The feed saying it does not know is not a load, and
        // drawing it as an empty train is worse than drawing nothing.
        case .unknown: return nil
        }
    }

    /// What a board would print.
    public var text: String {
        switch self {
        case .empty: return "Empty"
        case .manySeatsAvailable: return "Many seats free"
        case .seatsAvailable: return "Seats free"
        case .fewSeatsAvailable: return "Few seats free"
        case .standingAvailable: return "Standing room"
        case .standingRoomOnly: return "Standing only"
        case .crushedStandingRoomOnly: return "Very full"
        case .full: return "Full"
        case .notAcceptingPassengers: return "Not boarding"
        case .unknown: return "Unknown"
        }
    }

    /// Read one feed value.
    ///
    /// Trimmed before matching, because the producer really does send
    /// `secondClass ` with a trailing space and there is no reason to assume it
    /// is tidier about this element.
    public init(feedValue: String) {
        let cleaned = feedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self = OccupancyLevel(rawValue: cleaned) ?? .unknown
    }
}

/// The load at one call, by class.
///
/// Both halves optional: a single-class vehicle reports one, and a call the
/// forecast does not cover reports neither.
public struct Occupancy: Sendable, Codable, Equatable {
    public var firstClass: OccupancyLevel?
    public var secondClass: OccupancyLevel?

    public init(firstClass: OccupancyLevel? = nil, secondClass: OccupancyLevel? = nil) {
        self.firstClass = firstClass
        self.secondClass = secondClass
    }

    public var isEmpty: Bool { firstClass == nil && secondClass == nil }

    /// The fuller of the two, for one symbol where there is room for one.
    public var worst: OccupancyLevel? {
        let levels = [firstClass, secondClass].compactMap { $0 }
        return levels.max { ($0.crowding?.rawValue ?? -1) < ($1.crowding?.rawValue ?? -1) }
    }
}

/// One journey's forecast load, call by call.
///
/// Keyed by `StopPointRef`, which OJP states at platform level —
/// `ch:1:sloid:3003:2:2` — the same shape as `Call.ref`, so a panel joins its
/// own stop list to this without going through names or times.
public struct JourneyLoad: Sendable, Codable, Equatable {
    public var journeyID: String
    /// The service day the request was made for, `2026-08-22`.
    public var day: String
    public var byStop: [String: Occupancy]

    public init(journeyID: String, day: String, byStop: [String: Occupancy]) {
        self.journeyID = journeyID
        self.day = day
        self.byStop = byStop
    }

    public var isEmpty: Bool { byStop.values.allSatisfy(\.isEmpty) }

    /// The load at one call, by its reference.
    ///
    /// Falls back to the station where the exact platform is not listed: OJP
    /// answers about the platform it expects the vehicle at, and a stop list
    /// built from a station-level reference would otherwise match nothing.
    public func at(_ ref: String?) -> Occupancy? {
        guard let ref else { return nil }
        if let exact = byStop[ref] { return exact }
        let station = StopRegister.stationOf(ref)
        return byStop.first { StopRegister.stationOf($0.key) == station }?.value
    }

    /// The load a whole vehicle is drawn with: the next call it has not made.
    public func ahead(of index: Int, in stops: [Call]) -> Occupancy? {
        for stop in stops.dropFirst(max(0, index)) {
            if let found = at(stop.ref), !found.isEmpty { return found }
        }
        return nil
    }
}
