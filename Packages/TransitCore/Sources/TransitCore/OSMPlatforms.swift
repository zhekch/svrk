import Foundation

/// What a clicked OpenRailwayMap shape actually is.
public struct PlatformShape: Sendable, Equatable {
    public var sloids: [String]
    public var codes: [String]
    public var name: String
    /// True where the timetable does not split this station into platforms, so
    /// the departures shown are the whole station's. Said plainly in the panel
    /// rather than passed off as a platform board.
    public var stationOnly: Bool
}

/// OpenStreetMap platform id → the SLOIDs that stop there.
///
/// This is what makes a drawn platform clickable *correctly*. A rendered shape
/// carries an OSM id and the station's name and nothing else — so it knows
/// where it is but not which track it is. The answer lives on the OSM element,
/// in `ref` ("1;2" for an island platform) and `local_ref` ("K1" for a bus
/// bay), which match the register's platform codes exactly.
///
/// Resolving it by proximity was the old approach and it was wrong in a way
/// worth recording: at Bern every platform is registered near 7.4372E while the
/// drawn footprints run out to 7.4384E, so the nearest register point to a
/// click on platform 7 is frequently platform 8, or a bus kerb across the
/// forecourt. Distance is not the relationship; the code is.
public final class OSMPlatformIndex: @unchecked Sendable {
    private var table: [String: PlatformShape] = [:]
    /// `node-2916071197` → the UIC id of the station its blob covers.
    private var stations: [String: String] = [:]
    private var coveredCache: Set<String>?

    public init() {}

    public var isReady: Bool { !table.isEmpty }
    public var shapeCount: Int { table.count }
    public var stationCount: Int { stations.count }

    public func load(_ url: URL) throws {
        var reader = BinaryReader(try MappedFile(url: url))
        try reader.expect(magic: "SVPLATFM", version: 1)
        let strings = try reader.readStringTable()
        try reader.align(to: 4)

        let shapeCount = Int(try reader.readUInt32())
        var shapes = [String: PlatformShape](minimumCapacity: shapeCount)
        for _ in 0..<shapeCount {
            let key = strings[Int(try reader.readUInt32())]
            let name = strings[Int(try reader.readUInt32())]
            let stationOnly = try reader.readUInt32() == 1
            let pairs = Int(try reader.readUInt32())
            var sloids: [String] = []
            var codes: [String] = []
            sloids.reserveCapacity(pairs)
            codes.reserveCapacity(pairs)
            for _ in 0..<pairs {
                sloids.append(strings[Int(try reader.readUInt32())])
                let code = try reader.readUInt32()
                codes.append(code == BinaryFormat.noString ? "" : strings[Int(code)])
            }
            shapes[key] = PlatformShape(sloids: sloids, codes: codes, name: name, stationOnly: stationOnly)
        }
        table = shapes

        let stationRows = Int(try reader.readUInt32())
        var byElement = [String: String](minimumCapacity: stationRows)
        for _ in 0..<stationRows {
            let element = strings[Int(try reader.readUInt32())]
            let uic = strings[Int(try reader.readUInt32())]
            byElement[element] = uic
        }
        stations = byElement
        coveredCache = nil
    }

    /// Resolve a clicked shape.
    ///
    /// The platform layer writes its id prefixed (`way-421636561`); the
    /// platform-edge layer writes a bare integer, which is always a way, so
    /// both forms are accepted.
    public func lookup(_ id: String) -> PlatformShape? {
        guard isReady else { return nil }
        let key = id.allSatisfy(\.isNumber) ? "way-\(id)" : id
        return table[key]
    }

    /// Every track some drawn shape already covers, as `station|track`.
    ///
    /// Used to keep the two ways of showing a platform from fighting: where a
    /// footprint is drawn, that shape is the better thing to click and to look
    /// at, and a plate on top of it is just clutter. Where nothing is drawn —
    /// most kerbside bus stops are a bare node in OSM — the plate is the only
    /// marker there is, so it stays.
    ///
    /// Keyed by track rather than by SLOID so the sector entries go with it.
    /// The register lists Bern's platform 7 three times over as `7`, `7A-D` and
    /// `7E-H`; they are one platform with one footprint.
    public func coveredTracks() -> Set<String> {
        if let coveredCache { return coveredCache }
        var covered = Set<String>()
        for (key, row) in table {
            // Skip station-only bindings: those name a station, not a platform,
            // and hiding a station's plates on their strength would remove
            // markers that no shape actually replaces.
            if row.stationOnly { continue }
            // Only ways and relations count. A platform mapped as a single OSM
            // node has no footprint and is drawn by nothing — treating one as
            // "covered" would delete the plate of 801 Swiss stops and put no
            // shape in its place.
            if key.hasPrefix("node-") { continue }
            for (i, sloid) in row.sloids.enumerated() {
                let code = i < row.codes.count ? row.codes[i] : ""
                // Numbered tracks only. A lettered bay keeps its plate even
                // where the kerb is drawn, because the letter *is* how you find
                // it — "leaves from K1" is written on the ticket and on nothing
                // else on the map.
                guard !code.isEmpty, code.allSatisfy(\.isNumber) else { continue }
                covered.insert("\(StopRegister.stationOf(sloid))|\(code)")
            }
        }
        coveredCache = covered
        return covered
    }

    /// Resolve one of the rendered station blobs to a station.
    ///
    /// Their ids read `node-2916071197-tram-tram-tram_stop` — an OSM element id
    /// with rendering categories appended — so only the first two parts
    /// identify anything. Answering by nearest station instead meant a click on
    /// the Zytglogge tram stop returned Marzili.
    public func station(for id: String) -> String? {
        guard !stations.isEmpty else { return nil }

        let dashed = id.split(separator: "-").prefix(2).joined(separator: "-")
        if let hit = stations[dashed] { return hit }

        // The stop-position dots carry the same element in whatever form their
        // tile was built with. Still an identifier join: the digits are an OSM
        // element id either way, and the only question is which kind of element
        // they name. A stop position is a node essentially always.
        let digits = id.drop { !$0.isNumber }.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        for kind in ["node", "way", "relation"] {
            if let hit = stations["\(kind)-\(digits)"] { return hit }
        }
        return nil
    }
}
