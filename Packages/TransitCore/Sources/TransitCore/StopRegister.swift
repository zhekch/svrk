import Foundation

/// A resolved place: where a call actually is.
public struct Place: Sendable, Equatable {
    public var lon: Double
    public var lat: Double
    public var name: String
    public var platform: String?
    /// The coordinate is this platform's, not the station's, so a vehicle
    /// standing here may be drawn on it.
    public var precise: Bool
    /// The letter this map assigned, if the stop has no code of its own.
    public var assigned: String?
    /// True when the coordinate came from the OpenStreetMap `uic_ref`
    /// supplement rather than the official register.
    ///
    /// The supplement is a weaker source and it is wrong in a specific,
    /// checkable way: Austria runs two UIC numbering schemes and the feed and
    /// OSM are on different ones, so `8101223` is Langen am Arlberg to the feed
    /// and Lambach Markt — 320 km away — to OpenStreetMap. The id join succeeds
    /// and returns the wrong station, which is worse than returning nothing.
    /// Callers use this to know which placements are worth sanity-checking.
    public var fromSupplement: Bool = false
}

/// One drawable stop: a platform, or a kerbside pole.
public struct RegisteredStop: Sendable, Equatable {
    public var id: String
    public var lon: Double
    public var lat: Double
    public var name: String
    public var platform: String?
    /// Ours, not signage. See `assignLetters`.
    public var assigned: String?
}

/// The stop register: SLOID → coordinate.
///
/// SIRI-ET identifies every call by a SLOID like `ch:1:sloid:90118:0:2` —
/// stop 90118, platform 2 — and carries no coordinates of its own. The official
/// GTFS `stops.txt` keys on exactly the same identifier, so the join is by id
/// rather than by name. That distinction is worth more than it looks: SIRI
/// abbreviates its display names ("E'brücke Bahnhof" for Emmenbrücke), so
/// matching by name leaves a sixth of the network unplaced, while matching by
/// id leaves almost none. It also resolves to the *platform* rather than the
/// station, which is where a vehicle physically stands.
public final class StopRegister: @unchecked Sendable {
    struct Row {
        var lon: Double
        var lat: Double
        var name: String
        var platform: String?
    }

    private var table: [String: Row] = [:]
    /// The same rows as a flat array, for viewport queries. Platform-level
    /// entries only: a station is already drawn by the station layer, and what
    /// is wanted here is the pole a vehicle actually stops at.
    private var index: [RegisteredStop] = []
    private var byId: [String: Int] = [:]
    /// station SLOID → normalised platform code → the register row for it.
    private var byStationCode: [String: [String: Int]] = [:]

    /// UIC → row, for stations the Swiss register does not carry.
    ///
    /// Kept apart from `table` on purpose. That one is the official Swiss
    /// register and this is OpenStreetMap's `uic_ref` — the same identifier
    /// from a different source — so the register always answers first and this
    /// only fills what it has nothing to say about.
    private var foreign: [String: Row] = [:]
    /// The same supplement by name, for the stations whose numbers disagree.
    ///
    /// Austria runs two numbering schemes and the feed and OSM are on different
    /// ones: Landeck-Zams is `8101212` to the feed and `8100063` to OSM. A name
    /// match is weaker evidence than an identifier and is used only where the
    /// identifier has already failed, only for a foreign station, and only when
    /// the name belongs to **one** station in the whole index. A name shared by
    /// two is not a tie to be broken — it is an answer we do not have.
    private var foreignByName: [String: String] = [:]

    /// A coarse grid over `index`, so `near` and `within` are not full scans.
    ///
    /// The original scans all 80,000 rows for each query, which is fine on a
    /// server answering one viewport at a time and is not fine on a phone
    /// redrawing platform plates as the map moves under a finger.
    private var grid: [GridKey: [Int]] = [:]
    private static let gridDegrees = 0.05

    struct GridKey: Hashable { var x: Int32; var y: Int32 }

    private static func cell(_ lon: Double, _ lat: Double) -> GridKey {
        GridKey(x: Int32(floor(lon / gridDegrees)), y: Int32(floor(lat / gridDegrees)))
    }

    public private(set) var isReady = false

    public init() {}

    // MARK: - Loading

    public func load(stopsFile: URL, foreignFile: URL?) throws {
        var reader = BinaryReader(try MappedFile(url: stopsFile))
        try reader.expect(magic: "SVSTOPS_", version: 1)
        let strings = try reader.readStringTable()
        try reader.align(to: 4)

        let count = Int(try reader.readUInt32())
        var newTable = [String: Row](minimumCapacity: count)
        for _ in 0..<count {
            let id = strings[Int(try reader.readUInt32())]
            let name = strings[Int(try reader.readUInt32())]
            let platformIndex = try reader.readUInt32()
            let lon = BinaryFormat.decode(try reader.readInt32())
            let lat = BinaryFormat.decode(try reader.readInt32())
            newTable[id] = Row(
                lon: lon, lat: lat, name: name,
                platform: platformIndex == BinaryFormat.noString ? nil : strings[Int(platformIndex)]
            )
        }
        table = newTable
        buildIndex()

        if let foreignFile {
            try? loadForeign(foreignFile)
        }
        isReady = true
    }

    private func loadForeign(_ url: URL) throws {
        var reader = BinaryReader(try MappedFile(url: url))
        try reader.expect(magic: "SVFOREIG", version: 1)
        let strings = try reader.readStringTable()
        try reader.align(to: 4)

        let count = Int(try reader.readUInt32())
        var rows = [String: Row](minimumCapacity: count)
        for _ in 0..<count {
            let code = strings[Int(try reader.readUInt32())]
            let name = strings[Int(try reader.readUInt32())]
            let lon = BinaryFormat.decode(try reader.readInt32())
            let lat = BinaryFormat.decode(try reader.readInt32())
            rows[code] = Row(lon: lon, lat: lat, name: name, platform: nil)
        }
        foreign = rows

        // Second sighting poisons the entry rather than overwriting it: the
        // point is to answer only where there is nothing to choose between.
        var seen: [String: String?] = [:]
        for (code, row) in rows {
            guard let key = Self.normaliseName(row.name) else { continue }
            seen[key] = seen[key] == nil ? code : String?.none
        }
        foreignByName = seen.compactMapValues { $0 }
    }

    // MARK: - Index

    /// Flatten the register once, so a viewport query is a scan of platforms
    /// rather than a walk over eighty thousand keys on every request.
    private func buildIndex() {
        index = []
        byId = [:]
        grid = [:]

        for (id, row) in table {
            // `ch:1:sloid:7000` is the station; `ch:1:sloid:7000:1:21` is
            // platform 1.
            let parts = id.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count > 4 else { continue }

            // Drop the phantoms.
            //
            // The register carries rows that are not places you can stand:
            // Bern's Luisenstrasse has its two real platforms and then `:0:2371`
            // and `:0:2372` sitting on top of each other at the station's own
            // coordinate, with no platform code between them. Drawn, they are
            // unlabelled markers stacked on the station dot.
            //
            // The test needs both halves: 257 stops nationwide are a single
            // platform recorded at the station point, and those carry a code and
            // are perfectly real.
            if row.platform == nil {
                let stationId = parts[0..<4].joined(separator: ":")
                if let station = table[stationId], station.lon == row.lon, station.lat == row.lat {
                    continue
                }
            }

            index.append(RegisteredStop(
                id: id, lon: row.lon, lat: row.lat, name: row.name,
                platform: row.platform, assigned: nil
            ))
        }

        // A stable order, so the letters assigned below do not depend on
        // dictionary iteration. The original gets this for free from JSON key
        // order; a Swift dictionary has none, and a letter that means the
        // northbound side today and the southbound side tomorrow is worse than
        // no letter at all.
        index.sort { $0.id < $1.id }

        for (i, stop) in index.enumerated() {
            byId[stop.id] = i
            grid[Self.cell(stop.lon, stop.lat), default: []].append(i)
        }

        buildCodeIndex()
        assignLetters()
    }

    /// The same register rows again, reachable by station *and printed code*.
    ///
    /// SIRI-ET names two thirds of its calls by a platform SLOID, which carries
    /// the coordinate of the platform itself. The remaining third names the
    /// station — `ch:1:sloid:7000`, Bern — and states the platform separately,
    /// as the string printed on the departure board: `12A-C`. Read as a
    /// coordinate that call is the middle of Bern, and Bern's middle is ninety
    /// metres from platform 12 and right on top of platform 4.
    ///
    /// Nothing here is matched by position: the code printed on the board and
    /// the code in the register are the same string, and where they are not, no
    /// coordinate is claimed.
    private func buildCodeIndex() {
        byStationCode = [:]
        for (i, stop) in index.enumerated() {
            guard let platform = stop.platform else { continue }
            let station = Self.stationOf(stop.id)
            let key = Self.normaliseCode(platform)
            // First writer wins. Where a station registers one code twice — a
            // through platform recorded once per direction — the rows sit
            // within a few metres of each other, so which one answers does not
            // matter; that it is stable between requests does.
            if byStationCode[station]?[key] == nil {
                byStationCode[station, default: [:]][key] = i
            }
        }
    }

    /// Letter the kerbs nobody has numbered.
    ///
    /// Only 28% of Swiss platforms carry a code. The rest are not an omission
    /// in our data — Gümligen, Seidenberg is unnumbered in the register,
    /// unnumbered in the feed, and its two platform ways in OSM carry neither
    /// `ref` nor `local_ref`. There is no number to find. But the stop still
    /// has two sides going opposite ways, and a map that draws two identical
    /// unlabelled kerbs cannot say which is which.
    ///
    /// The letters are **ours**, not signage, and they are kept in their own
    /// field for that reason: `platform` stays nil, so nothing that matches a
    /// journey's reported platform against the register can ever match against
    /// a letter we invented.
    private func assignLetters() {
        var byStation: [String: [Int]] = [:]
        var codesInUse: [String: Set<String>] = [:]

        for (i, stop) in index.enumerated() {
            let station = Self.stationOf(stop.id)
            if let platform = stop.platform {
                // Bays a stop *is* signed for. Thun, Bahnhof has A to Z on its
                // forecourt and a handful of unsigned kerbs besides, so
                // lettering the unsigned ones from A gave that stop two
                // different bays both labelled A. A letter that collides with a
                // real one is worse than no letter: it looks like signage and
                // points at the wrong kerb.
                codesInUse[station, default: []].insert(platform.uppercased())
                continue
            }
            byStation[station, default: []].append(i)
        }

        for (station, kerbs) in byStation {
            guard kerbs.count >= 2 else { continue }
            // `ch:1:sloid:7251:0:11` sorts before `:0:4` as text; the tail is a
            // number. The register's own numbering is stable and published,
            // unlike anything we could compute from what each kerb serves now.
            let ordered = kerbs.sorted {
                let a = Self.tail(index[$0].id), b = Self.tail(index[$1].id)
                return a == b ? index[$0].id < index[$1].id : a < b
            }
            let taken = codesInUse[station] ?? []
            var next = 0
            for kerb in ordered {
                while taken.contains(Self.letter(next)) { next += 1 }
                index[kerb].assigned = Self.letter(next)
                next += 1
            }
        }
    }

    private static func tail(_ id: String) -> Int {
        guard let last = id.split(separator: ":").last, let n = Int(last) else { return Int.max }
        return n
    }

    /// 0 → A, 25 → Z, 26 → AA. Bern's forecourt does not need the second case.
    static func letter(_ i: Int) -> String {
        var out = ""
        var n = i
        while true {
            out = String(UnicodeScalar(UInt8(65 + n % 26))) + out
            if n < 26 { return out }
            n = n / 26 - 1
        }
    }

    // MARK: - Codes

    /// `01` and `1` are one platform; `12a-c` and `12A-C` are one platform.
    ///
    /// Deliberately nothing more than case and a leading zero. Stripping the
    /// sector letters would make `12A-C` match `12`, which is usually right and
    /// sometimes not — at Bern `12A-C` and `12D-F` are the two halves of an
    /// underground platform 250 m long.
    static func normaliseCode(_ code: String) -> String {
        var text = code.trimmingCharacters(in: .whitespaces).uppercased()
        while text.count > 1, text.hasPrefix("0"), text.dropFirst().first?.isNumber == true {
            text.removeFirst()
        }
        return text
    }

    /// The track a platform code names, with any sector dropped.
    ///
    /// A long platform is lettered in sections and the feed reports the section
    /// a train stops in rather than the platform: an IC on Bern's platform 1
    /// arrives as `1A-D`, never as `1`. The register holds both forms, so
    /// comparing the strings directly meant a train in a sector matched no
    /// platform at all — Bern's 1, 3 and 4 showed an empty board while 7 and 9
    /// worked, purely because of which form the operator happened to send.
    ///
    /// Lettered stops are left alone. A bus bay is `K1` or `A`, where the
    /// letter is the identity rather than a subdivision of it.
    public static func trackOf(_ code: String?) -> String? {
        guard let code else { return nil }
        let text = code.trimmingCharacters(in: .whitespaces)
        let digits = text.prefix { $0.isNumber }
        return digits.isEmpty ? text.uppercased() : String(digits)
    }

    /// Whether two platform codes name the same track, sectors aside.
    public static func sameTrack(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return trackOf(a) == trackOf(b)
    }

    /// `ch:1:sloid:7000:1:21` → `ch:1:sloid:7000`, the station it belongs to.
    ///
    /// The register also carries 3,073 rows under a **generated** SLOID, which
    /// is how it records the lettered sections of a long platform:
    ///
    ///   `ch:1:sloid:7000_gen:ch:1:sloid:7000:4:7_pf:7A-D`
    ///
    /// Split naively on `:`, the first four parts of that are
    /// `ch:1:sloid:7000_gen`, which is not a station and matches nothing. That
    /// one character is why the `7A-D` plates came back. Cutting at `_gen`
    /// first gives the station the row actually belongs to.
    public static func stationOf(_ ref: String?) -> String {
        guard let ref else { return "" }
        let base = ref.range(of: "_gen").map { String(ref[ref.startIndex..<$0.lowerBound]) } ?? ref
        let parts = base.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count > 4 ? parts[0..<4].joined(separator: ":") : (base.isEmpty ? ref : base)
    }

    /// `8508036` → `ch:1:sloid:8036`, the station a DIDOK number names.
    ///
    /// A Swiss DIDOK number is `85` followed by the SLOID number, zero-padded to
    /// five digits — the padding is in the DIDOK number, not in the SLOID, so
    /// `8508036` is sloid 8036 and not 08036. No distance is involved, which is
    /// the point: at a forecourt the nearest register row to a stop's own
    /// coordinate is routinely a different stop.
    public static func sloid(forDidok didok: String) -> String? {
        guard didok.count == 7, didok.hasPrefix("85"), didok.allSatisfy(\.isNumber),
              let number = Int(didok.dropFirst(2))
        else { return nil }
        return "ch:1:sloid:\(number)"
    }

    /// Case and spacing only. Anything cleverer starts inventing equivalences.
    static func normaliseName(_ name: String?) -> String? {
        guard let name else { return nil }
        let squashed = name.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return squashed.isEmpty ? nil : squashed
    }

    // MARK: - Queries

    /// Where platform `code` of `station` is, or nil.
    ///
    /// Tried exactly first, then by its leading number: a feed that says
    /// `12A-C` where the register carries only `12` should still land on
    /// platform 12 rather than on the station. The reverse — `12` matching one
    /// of `12A-C`/`12D-F` — is not attempted, because there is no way to choose
    /// between the halves and they are a platform's length apart.
    public func platformPoint(station: String, code: String?) -> RegisteredStop? {
        guard isReady, !station.isEmpty, let code else { return nil }
        guard let codes = byStationCode[station] else { return nil }

        let wanted = Self.normaliseCode(code)
        if let exact = codes[wanted] { return index[exact] }

        let number = String(wanted.prefix { $0.isNumber })
        guard !number.isEmpty, number != wanted, let hit = codes[number] else { return nil }
        return index[hit]
    }

    /// Platforms inside a bounding box, most identifiable first.
    ///
    /// Capped, because a city centre holds hundreds and the map only needs
    /// enough to draw. Entries carrying a platform code are preferred when the
    /// cap bites — "Bern, platform K1" is worth drawing over an unlabelled pole.
    public func within(_ bbox: BBox, limit: Int = 400) -> [RegisteredStop] {
        var out: [RegisteredStop] = []
        let x0 = Int32(floor(bbox.west / Self.gridDegrees))
        let x1 = Int32(floor(bbox.east / Self.gridDegrees))
        let y0 = Int32(floor(bbox.south / Self.gridDegrees))
        let y1 = Int32(floor(bbox.north / Self.gridDegrees))

        guard x0 <= x1, y0 <= y1 else { return [] }
        for x in x0...x1 {
            for y in y0...y1 {
                for i in grid[GridKey(x: x, y: y)] ?? [] {
                    let stop = index[i]
                    if bbox.contains(lon: stop.lon, lat: stop.lat) { out.append(stop) }
                }
            }
        }

        if out.count <= limit { return out }
        out.sort { ($0.platform != nil ? 1 : 0) > ($1.platform != nil ? 1 : 0) }
        return Array(out.prefix(limit))
    }

    /// Every stop within `metres` of a point.
    ///
    /// Used to treat a station as the place it is rather than the point the
    /// index records: the platforms, the forecourt tram stops and the bus kerbs
    /// around a station carry different names and different SLOIDs, and only
    /// proximity ties them together.
    public func near(lon: Double, lat: Double, metres: Double) -> [RegisteredStop] {
        let dLat = metres / Geo.metresPerDegree
        let dLon = dLat / max(0.2, cos(Geo.toRad(lat)))
        let box = BBox(west: lon - dLon, south: lat - dLat, east: lon + dLon, north: lat + dLat)

        var out: [RegisteredStop] = []
        for stop in within(box, limit: .max) {
            if Geo.flatMetres(stop.lon, stop.lat, lon, lat) <= metres { out.append(stop) }
        }
        return out
    }

    public func stop(id: String) -> RegisteredStop? {
        byId[id].map { index[$0] }
    }

    /// The name the register holds for a UIC number.
    ///
    /// Four spellings of the same identifier, tried in the order they are
    /// trustworthy. A Swiss number is `85` plus a SLOID, and the register keys
    /// the station by the SLOID; a foreign one is filed under the bare number,
    /// under `missingSLOID_…` where the packer had a coordinate and no SLOID,
    /// or in the OpenStreetMap supplement. Domodossola — which the formation
    /// service names only as `8301003` — is the first kind of foreign row.
    public func name(uic: Int) -> String? {
        guard isReady else { return nil }
        let code = String(uic)
        if let sloid = Self.sloid(forDidok: code), let row = table[sloid] { return row.name }
        if let row = table[code] { return row.name }
        if let row = table["missingSLOID_\(code)"] { return row.name }
        return foreign[code]?.name
    }

    /// Resolve a SIRI `StopPointRef`, trying each form in order of precision.
    ///
    /// The exact platform is what we want. Failing that, the same platform
    /// written without its leading zero — SIRI sends `:0:03` where GTFS holds
    /// `:0:3`, and that one difference accounted for most of what was left
    /// unresolved. Failing that, the station the platform belongs to, which is
    /// a hundred metres out at worst and much better than dropping the call.
    public func lookup(_ ref: String, statedPlatform: String? = nil, name: String? = nil) -> Place? {
        guard isReady, !ref.isEmpty else { return nil }

        var fromSupplement = false
        var row = table[ref]
        // True when the coordinate is a platform's rather than a station's —
        // which is what decides whether the map may stand a vehicle on it.
        var precise = row != nil && Self.stationOf(ref) != ref

        if row == nil {
            let unpadded = Self.unpad(ref)
            if unpadded != ref {
                row = table[unpadded]
                precise = row != nil
            }
        }
        if row == nil {
            let parts = ref.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count > 4 { row = table[parts[0..<4].joined(separator: ":")] }
        }
        if row == nil || !precise {
            // The call names the station and prints the platform beside it.
            // That code is an identifier the register also holds, so it
            // resolves the rest of the way — Bern platform 12, not the middle
            // of Bern. Two thirds of calls arrive already platform-specific;
            // this is most of the other third.
            if let here = platformPoint(station: Self.stationOf(ref), code: statedPlatform) {
                row = table[here.id] ?? row
                precise = true
            }
        }
        if row == nil {
            let found = lookupForeign(ref: ref, name: name)
            row = found.row
            fromSupplement = found.fromSupplement
        }
        guard let row else { return nil }

        return Place(
            lon: row.lon, lat: row.lat, name: row.name, platform: row.platform,
            precise: precise, assigned: byId[ref].map { index[$0].assigned } ?? nil,
            fromSupplement: fromSupplement
        )
    }

    /// `ch:1:sloid:90118:0:03` → `…:0:3`.
    private static func unpad(_ ref: String) -> String {
        guard let colon = ref.lastIndex(of: ":") else { return ref }
        let tail = ref[ref.index(after: colon)...]
        guard tail.count > 1, tail.hasPrefix("0"), tail.allSatisfy(\.isNumber) else { return ref }
        let trimmed = String(Int(tail) ?? 0)
        return ref[ref.startIndex...colon] + trimmed
    }

    /// `ch:1:ScheduledStopPoint:8301003` → `8301003`.
    ///
    /// SIRI-ET names a stop by SLOID wherever there is one, and by a plain
    /// scheduled stop point where there is not — which in practice means
    /// foreign stations. That number is the UIC code, and the register keys
    /// those stations by exactly that, so this is the same
    /// identifier-to-identifier join the SLOID path is, on the other identifier.
    private func lookupForeign(ref: String, name: String?) -> (row: Row?, fromSupplement: Bool) {
        guard let code = Self.scheduledStopPointCode(ref) else { return (nil, false) }

        // The register keeps first refusal.
        if let row = table[code] { return (row, false) }
        if let n = Int(code), let row = table[String(n)] { return (row, false) }
        // `missingSLOID_8400058` is the third spelling of the same fact: the
        // register mints that key for a stop it has a coordinate for and no
        // SLOID to hang it on. Without this Amsterdam Centraal sat in the
        // register, correctly placed, and was dropped from every night train
        // that calls there.
        if let row = table["missingSLOID_\(code)"] { return (row, false) }

        // A station outside the register altogether. Almost every one of these
        // is German or Austrian, and OpenStreetMap tags them with the very
        // number the feed just sent.
        if let row = foreign[code] { return (row, true) }
        if let n = Int(code), let row = foreign[String(n)] { return (row, true) }

        // The number itself disagrees. See `foreignByName`.
        if let key = Self.normaliseName(name), let code = foreignByName[key] {
            return (foreign[code], true)
        }
        return (nil, false)
    }

    static func scheduledStopPointCode(_ ref: String) -> String? {
        guard let range = ref.range(of: "ScheduledStopPoint:", options: .caseInsensitive) else { return nil }
        let digits = ref[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    // MARK: - Stats

    public struct Stats: Sendable {
        public var stops: Int
        public var foreignStations: Int
        public var platforms: Int
        public var coded: Int
        public var lettered: Int
    }

    public var stats: Stats {
        Stats(
            stops: table.count,
            foreignStations: foreign.count,
            platforms: index.count,
            coded: index.count { $0.platform != nil },
            lettered: index.count { $0.assigned != nil }
        )
    }
}
