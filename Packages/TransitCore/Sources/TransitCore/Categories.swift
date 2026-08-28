import Foundation

/// The handful of modes the map actually draws.
///
/// Both upstream sources name modes in their own vocabulary — SIRI-ET says
/// `rail`/`telecabin`, the stationboard mirror says `IC`/`NFT`/`GB` — and
/// neither is worth carrying past the parser.
public enum Mode: String, CaseIterable, Sendable, Codable, Hashable {
    case train, tram, bus, metro, boat, cable, other

    /// Modes that run on the OSM railway network and can therefore be routed
    /// over the rail graph when no relation describes a leg.
    public var isRail: Bool {
        switch self {
        case .train, .tram, .metro, .cable: return true
        case .bus, .boat, .other: return false
        }
    }

    /// Modes whose stations are a throat of points rather than a kerb.
    ///
    /// The distinction the platform correction turns on. A station with a
    /// throat has several tracks that a service could plausibly be standing
    /// on, they are chosen by the points a few hundred metres out, and which
    /// one today's train is booked for is in the feed and in nothing the map
    /// carries. Everything else stops where it was always going to stop: a
    /// tram at its kerb, a bus at its bay, a funicular on its single wire.
    ///
    /// Trains only, and deliberately not trams. A tram *does* run on rails and
    /// *does* have route relations, so it looks like the same problem — but
    /// correcting it by re-routing over the graph is how a turning loop gets
    /// cut across. See `GeometryBuilder.reaches`.
    public var hasThroats: Bool { self == .train }

    /// Draw order matters: rail modes sit above road modes so trains stay
    /// readable in a city where a hundred buses share the same streets.
    ///
    /// In the module rather than beside the palette because it is no longer
    /// only a paint order. When two vehicles are drawn at the same point the
    /// one on top is the one the reader sees, so this is also what decides
    /// which of them is worth keeping — see `Fleet.thinTheHidden`.
    public var drawOrder: Int {
        switch self {
        case .train: return 6
        case .metro: return 5
        case .tram: return 4
        case .cable: return 3
        case .boat: return 2
        case .bus: return 1
        case .other: return 0
        }
    }
}

public enum Categories {
    /// transport.opendata.ch reports a two-or-three letter product code per
    /// journey. This is that table, unchanged.
    private static let modes: [Mode: [String]] = [
        .train: [
            "IC", "ICE", "IR", "IRE", "RE", "R", "S", "SN", "EC", "EN", "NJ", "RJ", "RJX",
            "TGV", "TER", "PE", "VAE", "GEX", "BEX", "D", "RB", "EXT", "ATZ", "AG", "ARZ",
            "CNL", "ICN", "MAT", "RHB", "SP", "TE2", "UUU", "WB", "ZUG",
        ],
        .tram: ["T", "NFT", "TN", "STR"],
        .bus: ["B", "BUS", "NFB", "NFO", "KB", "RUB", "EXB", "NB", "BN", "TX", "CAR", "RUF"],
        .metro: ["M", "MET", "U"],
        .boat: ["BAT", "FAE", "KAT", "SCH"],
        .cable: ["FUN", "GB", "PB", "LB", "SL", "CC", "ASC", "AS"],
    ]

    private static let lookup: [String: Mode] = {
        var out: [String: Mode] = [:]
        for (mode, codes) in modes {
            for code in codes { out[code] = mode }
        }
        return out
    }()

    /// Map a raw product code (e.g. "IC", "NFT") to a draw mode.
    public static func mode(of category: String?) -> Mode {
        guard let category, !category.isEmpty else { return .other }
        return lookup[category.uppercased()] ?? .other
    }

    /// SIRI's own vehicle modes, in this app's vocabulary.
    private static let siriModes: [String: Mode] = [
        "rail": .train,
        "bus": .bus,
        "tram": .tram,
        "metro": .metro,
        "ferry": .boat,
        "water": .boat,
        "funicular": .cable,
        "telecabin": .cable,
        "coach": .bus,
    ]

    public static func siriMode(of raw: String?) -> Mode {
        guard let raw else { return .other }
        return siriModes[raw] ?? .other
    }
}
