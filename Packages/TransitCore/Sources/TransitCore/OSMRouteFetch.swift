import Foundation

/// Overpass JSON → relations the matcher can ingest.
///
/// Kept free of the network so a canned response is a unit, not a live query.
public enum OSMRouteParser {
    public static func parse(_ data: Data) throws -> [OSMFetchedRoute] {
        let decoded = try JSONDecoder().decode(OverpassFile.self, from: data)
        var nodes: [Int64: (coord: Coord, name: String?)] = [:]
        var ways: [Int64: [Coord]] = [:]
        var relations: [OverpassFile.Element] = []
        nodes.reserveCapacity(decoded.elements.count)
        for element in decoded.elements {
            switch element.type {
            case "node":
                if let lat = element.lat, let lon = element.lon {
                    let coord = Coord(lon: lon, lat: lat)
                    guard coord.isPlaced else { continue }
                    nodes[element.id] = (coord, element.tags?["name"])
                }
            case "way":
                if let geom = element.geometry {
                    let coords = geom.map { Coord(lon: $0.lon, lat: $0.lat) }.filter(\.isPlaced)
                    if coords.count >= 2 { ways[element.id] = coords }
                } else {
                    let coords = (element.nodes ?? []).compactMap { nodes[$0]?.coord }.filter(\.isPlaced)
                    if coords.count >= 2 { ways[element.id] = coords }
                }
            case "relation":
                relations.append(element)
            default:
                break
            }
        }

        var out: [OSMFetchedRoute] = []
        out.reserveCapacity(relations.count)
        for relation in relations {
            let tags = relation.tags ?? [:]
            let kind = tags["route"] ?? ""
            guard RelationStore.modeRoutes.values.contains(where: { $0.contains(kind) })
            else { continue }

            var wayCoords: [[Coord]] = []
            var wayIds: [Int64] = []
            var stopCoords: [Coord] = []
            var stopNames: [String?] = []
            for member in relation.members ?? [] {
                if member.type == "way" {
                    let coords: [Coord]
                    if let geom = member.geometry {
                        let parsed = geom.map { Coord(lon: $0.lon, lat: $0.lat) }.filter(\.isPlaced)
                        guard parsed.count >= 2 else { continue }
                        coords = parsed
                    } else if let known = ways[member.ref], known.count >= 2 {
                        coords = known
                    } else {
                        continue
                    }
                    wayCoords.append(coords)
                    wayIds.append(member.ref)
                } else if member.type == "node", isStopRole(member.role) {
                    if let node = nodes[member.ref], node.coord.isPlaced {
                        stopCoords.append(node.coord)
                        stopNames.append(node.name)
                    } else if let lat = member.lat, let lon = member.lon {
                        let coord = Coord(lon: lon, lat: lat)
                        guard coord.isPlaced else { continue }
                        stopCoords.append(coord)
                        stopNames.append(nil)
                    }
                }
            }
            let path = Geo.withoutUnplaced(stitch(wayCoords))
            guard path.count >= 2, !Geo.hasJump(path), let osmId = Int32(exactly: relation.id) else { continue }
            out.append(OSMFetchedRoute(
                id: osmId,
                route: kind,
                ref: tags["ref"],
                name: tags["name"],
                operatorName: tags["operator"],
                from: tags["from"],
                to: tags["to"],
                stops: stopCoords,
                stopNames: stopNames,
                path: path,
                ways: wayIds
            ))
        }
        return out
    }

    /// Roles OSM uses for a vehicle's calls, not for infrastructure.
    static func isStopRole(_ role: String?) -> Bool {
        guard let role, !role.isEmpty else { return false }
        if role == "stop" || role == "platform" { return true }
        return role.hasPrefix("stop") || role.hasPrefix("platform")
    }

    /// How close two way ends may sit and still be the same node.
    ///
    /// Exact equality misses Overpass coordinates that differ in the last
    /// digit. Much wider than this starts joining parallel tracks at a throat.
    public static let joinMetres = 15.0

    /// Join member ways end to end, flipping a way whose ends meet the path
    /// backwards. A gap starts a new run rather than a chord across country,
    /// and a way that would reverse the path is left as its own run: those two
    /// concatenations are what drew every variant of a line at once.
    public static func stitch(_ ways: [[Coord]]) -> [Coord] {
        let runs = stitchRuns(ways)
        guard let longest = runs.max(by: { Geo.length(of: $0) < Geo.length(of: $1) }) else {
            return []
        }
        return Geo.withoutSpurs(longest)
    }

    /// The connected pieces `stitch` chooses among, longest first in spirit
    /// but not sorted — tests look at count and contents.
    public static func stitchRuns(_ ways: [[Coord]]) -> [[Coord]] {
        var runs: [[Coord]] = []
        for way in ways {
            guard way.count >= 2 else { continue }
            if attach(way, to: &runs) { continue }
            runs.append(way)
        }
        // Not `Geo.join`. That treats a unique neighbour as the continuation
        // even through a 180° reverse, which is right for a rail corridor and
        // wrong here: the return track is often the only leftover piece.
        return runs
    }

    /// Grow an existing run by `way` if an end meets. Prefers the run just
    /// grown, which is member order, the mapper's path.
    static func attach(_ way: [Coord], to runs: inout [[Coord]]) -> Bool {
        guard way.count >= 2 else { return false }
        for i in runs.indices.reversed() {
            if append(way, onto: &runs[i]) { return true }
            if append(way.reversed(), onto: &runs[i]) { return true }
            if prepend(way, onto: &runs[i]) { return true }
            if prepend(Array(way.reversed()), onto: &runs[i]) { return true }
        }
        return false
    }

    static func append(_ extra: [Coord], onto run: inout [Coord]) -> Bool {
        guard extra.count >= 2, let end = run.last, near(end, extra[0]) else { return false }
        if foldsBack(run, extra) { return false }
        run.append(contentsOf: extra.dropFirst())
        return true
    }

    static func prepend(_ extra: [Coord], onto run: inout [Coord]) -> Bool {
        guard extra.count >= 2, let start = run.first,
              near(start, extra[extra.count - 1]) else { return false }
        if foldsBack(extra, run) { return false }
        run.insert(contentsOf: extra.dropLast(), at: 0)
        return true
    }

    /// The join is a reversal, not a continuation — both tracks of a
    /// double-track line meeting at a terminus, or the return working listed
    /// after the outbound one.
    static func foldsBack(_ incoming: [Coord], _ outgoing: [Coord]) -> Bool {
        guard incoming.count >= 2, outgoing.count >= 2 else { return false }
        return Geo.turnDegrees(
            incoming[incoming.count - 2], incoming[incoming.count - 1], outgoing[1]
        ) > Geo.foldAngle
    }

    static func near(_ a: Coord, _ b: Coord) -> Bool {
        a == b || Geo.flatMetres(a.lon, a.lat, b.lon, b.lat) <= joinMetres
    }

    fileprivate struct OverpassFile: Decodable {
        var elements: [Element]
        struct Element: Decodable {
            var type: String
            var id: Int64
            var lat: Double?
            var lon: Double?
            var nodes: [Int64]?
            var members: [Member]?
            var tags: [String: String]?
            var geometry: [LatLon]?
        }
        struct Member: Decodable {
            var type: String
            var ref: Int64
            var role: String?
            var lat: Double?
            var lon: Double?
            var geometry: [LatLon]?
        }
        struct LatLon: Decodable {
            var lat: Double
            var lon: Double
        }
    }
}

/// Asks Overpass for the OSM route relations a selected vehicle might be on.
///
/// One query per line and bounding box, coalesced so two taps on the same TER
/// do not fire two downloads. Failures stay silent: the chord is already on
/// the map, and a missing relation is not worse than the straight line we had.
public actor OSMRouteClient {
    public static let shared = OSMRouteClient()

    public static let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
    ]

    private let session: URLSession
    private var inFlight: [String: Task<[OSMFetchedRoute], Never>] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(
        line: String, mode: Mode, stops: [Call], extraTokens: [String] = []
    ) async -> [OSMFetchedRoute] {
        let ref = RelationStore.normaliseRef(line)
        guard stops.count >= 2, let bbox = Self.bbox(of: stops) else { return [] }
        let key = "\(mode.rawValue)|\(ref)|\(Self.cacheCell(bbox))|\(extraTokens.joined(separator: ","))"
        if let existing = inFlight[key] { return await existing.value }
        let task = Task {
            await self.download(
                ref: line, normalised: ref, mode: mode, stops: stops, extraTokens: extraTokens
            )
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// The full worldwide relation, by OSM id.
    ///
    /// Packed `routes.bin` is a Swiss extract, so ICE 60 arrives as two named
    /// stops on this side of the Rhine. Asking Overpass for the same id returns
    /// the unclipped member list, names included.
    public func fetch(relationId: Int32) async -> [OSMFetchedRoute] {
        let key = "id:\(relationId)"
        if let existing = inFlight[key] { return await existing.value }
        let task = Task { await self.download(relationId: relationId) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func download(
        ref: String, normalised: String, mode: Mode, stops: [Call], extraTokens: [String]
    ) async -> [OSMFetchedRoute] {
        let queries = [
            Self.connectingQuery(mode: mode, stops: stops, extraTokens: extraTokens),
            Self.refQuery(ref: ref, normalised: normalised, mode: mode, stops: stops),
        ]
        NetworkMeter.shared.began("overpass")
        var lastPayload = 0
        for query in queries where !query.isEmpty {
            if let parsed = await post(query, lastPayload: &lastPayload), !parsed.isEmpty {
                NetworkMeter.shared.received("overpass", wire: lastPayload, payload: lastPayload)
                return parsed
            }
        }
        NetworkMeter.shared.received("overpass", wire: lastPayload, payload: lastPayload)
        return []
    }

    /// Both mirrors at once; the first 200 that parses wins. Sequential tries
    /// paid the slow server's full timeout before the other was asked.
    private func post(_ query: String, lastPayload: inout Int) async -> [OSMFetchedRoute]? {
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "data", value: query)]
        guard let body = comps.percentEncodedQuery?.data(using: .utf8) else { return nil }

        struct Answer: Sendable {
            var data: Data
            var routes: [OSMFetchedRoute]
        }
        let session = self.session
        let endpoints = Self.endpoints
        let answer: Answer? = await withTaskGroup(of: Answer?.self) { group in
            for endpoint in endpoints {
                group.addTask {
                    var request = URLRequest(url: endpoint, timeoutInterval: 25)
                    request.httpMethod = "POST"
                    request.setValue(
                        "application/x-www-form-urlencoded; charset=utf-8",
                        forHTTPHeaderField: "Content-Type"
                    )
                    request.setValue(OTDClient.userAgent, forHTTPHeaderField: "User-Agent")
                    request.httpBody = body
                    do {
                        let (data, response) = try await session.data(for: request)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        guard (200..<300).contains(status) else { return nil }
                        let routes = try OSMRouteParser.parse(data)
                        return Answer(data: data, routes: routes)
                    } catch {
                        return nil
                    }
                }
            }
            var empty: Answer?
            for await result in group {
                guard let result else { continue }
                if !result.routes.isEmpty {
                    group.cancelAll()
                    return result
                }
                empty = result
            }
            return empty
        }
        if let answer {
            lastPayload = answer.data.count
            return answer.routes
        }
        return nil
    }

    private func download(relationId: Int32) async -> [OSMFetchedRoute] {
        let query = """
        [out:json][timeout:40];
        relation(\(relationId));
        (._;>>;);
        out body;
        """
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "data", value: query)]
        guard let body = comps.percentEncodedQuery?.data(using: .utf8) else { return [] }

        NetworkMeter.shared.began("overpass")
        var lastPayload = 0
        for endpoint in Self.endpoints {
            var request = URLRequest(url: endpoint, timeoutInterval: 45)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue(OTDClient.userAgent, forHTTPHeaderField: "User-Agent")
            request.httpBody = body
            do {
                let (data, response) = try await session.data(for: request)
                lastPayload = data.count
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else { continue }
                let parsed = try OSMRouteParser.parse(data)
                NetworkMeter.shared.received("overpass", wire: data.count, payload: data.count)
                return parsed
            } catch {
                continue
            }
        }
        NetworkMeter.shared.received("overpass", wire: lastPayload, payload: lastPayload)
        return []
    }

    /// The OSM `route` values this mode can honestly be.
    nonisolated static func routeRegex(for mode: Mode) -> String {
        let kinds = RelationStore.modeRoutes[mode] ?? ["train", "bus", "tram"]
        return kinds.joined(separator: "|")
    }

    /// Relations that actually serve this run, not merely those tagged with the
    /// GTFS number. Swiss IC 3 from Frankfurt to Interlaken is ICE 43 to Basel
    /// plus IC 61 onwards — OSM never writes `ref=IC3` on that geometry.
    nonisolated static func connectingQuery(
        mode: Mode, stops: [Call], extraTokens: [String]
    ) -> String {
        guard let first = stops.first, let last = stops.last else { return "" }
        let kinds = routeRegex(for: mode)
        let samples = Self.sampleStops(stops)
        var preamble: [String] = []
        var union: [String] = []

        // Pairwise: a relation that calls at two of the sampled stops. IC 61
        // at Olten and Interlaken, without pulling every ICE in Germany.
        if samples.count >= 2 {
            for (i, stop) in samples.enumerated() {
                preamble.append(
                    "rel[\"type\"=\"route\"][\"route\"~\"^\(kinds)$\"](around:\(Self.stationRadius),\(Self.coord(stop.lat)),\(Self.coord(stop.lon)))->.s\(i);"
                )
            }
            for i in 0..<samples.count {
                for j in (i + 1)..<samples.count {
                    union.append("rel.s\(i).s\(j);")
                }
            }
        }

        // At each end, relations whose from/to/name mentions the *other* end —
        // or a station the packed Swiss match already named (Basel on IC 61,
        // which the feed's three calls skip). Tokens from *this* stop are
        // omitted so Frankfurt does not download every ICE that terminates there.
        let mids = samples.dropFirst().dropLast()
        for (k, stop) in [first, last].enumerated() {
            let other = k == 0 ? last : first
            var tokens = Set(Self.searchTokens(in: other.name))
            for mid in mids { tokens.formUnion(Self.searchTokens(in: mid.name)) }
            for extra in extraTokens { tokens.formUnion(Self.searchTokens(in: extra)) }
            let pattern = tokens.sorted().joined(separator: "|")
            guard !pattern.isEmpty else { continue }
            preamble.append(
                "rel[\"type\"=\"route\"][\"route\"~\"^\(kinds)$\"](around:\(Self.stationRadius),\(Self.coord(stop.lat)),\(Self.coord(stop.lon)))->.n\(k);"
            )
            union.append("rel.n\(k)[\"to\"~\"\(pattern)\",i];")
            union.append("rel.n\(k)[\"from\"~\"\(pattern)\",i];")
            union.append("rel.n\(k)[\"name\"~\"\(pattern)\",i];")
            union.append("rel.n\(k)[\"via\"~\"\(pattern)\",i];")
        }

        guard !union.isEmpty else { return "" }
        return """
        [out:json][timeout:50][maxsize:67108864];
        \(preamble.joined(separator: "\n"))
        (
        \(union.joined(separator: "\n"))
        );
        out geom;
        """
    }

    nonisolated static func refQuery(
        ref: String, normalised: String, mode: Mode, stops: [Call]
    ) -> String {
        let kinds = routeRegex(for: mode)
        let escaped = normalised.replacingOccurrences(of: "\"", with: "")
        let raw = ref.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "")
        var refs = [escaped].filter { !$0.isEmpty }
        if raw != escaped, !raw.isEmpty { refs.append(raw) }
        guard !refs.isEmpty else { return "" }
        let samples = Self.sampleStops(stops)
        let clauses = samples.flatMap { stop in
            refs.map {
                "rel[\"type\"=\"route\"][\"route\"~\"^\(kinds)$\"][\"ref\"=\"\($0)\"](around:35000,\(Self.coord(stop.lat)),\(Self.coord(stop.lon)));"
            }
        }.joined(separator: "\n")
        return """
        [out:json][timeout:40];
        (
        \(clauses)
        );
        out geom;
        """
    }

    nonisolated static func query(
        ref: String, normalised: String, mode: Mode, stops: [Call]
    ) -> String {
        connectingQuery(mode: mode, stops: stops, extraTokens: [])
    }

    /// Words worth putting in an Overpass regex: four+ letters, no punctuation.
    nonisolated static func searchTokens(in name: String) -> [String] {
        name.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en"))
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) } }
    }

    nonisolated static let stationRadius = 1_200

    nonisolated static func coord(_ value: Double) -> String {
        String(format: "%.5f", value)
    }

    /// Ends plus a few in the middle, so a long run is covered without one
    /// around-filter per call.
    nonisolated static func sampleStops(_ stops: [Call]) -> [Call] {
        let placed = stops.filter(\.isPlaced)
        let source = placed.isEmpty ? stops : placed
        guard source.count > 6 else { return source }
        var out = [source[0], source[source.count / 2], source[source.count - 1]]
        out.insert(source[1], at: 1)
        out.insert(source[source.count - 2], at: out.count - 1)
        return out
    }

    nonisolated public static func bbox(of stops: [Call], pad: Double = 0.15) -> BBox? {
        let placed = stops.filter(\.isPlaced)
        guard let first = placed.first else { return nil }
        var west = first.lon, east = first.lon, south = first.lat, north = first.lat
        for stop in placed.dropFirst() {
            west = min(west, stop.lon)
            east = max(east, stop.lon)
            south = min(south, stop.lat)
            north = max(north, stop.lat)
        }
        return BBox(
            west: west - pad, south: south - pad,
            east: east + pad, north: north + pad
        )
    }

    /// Coarse enough that two trains on the same line share a download, fine
    /// enough that a Swiss RE1 and a French one do not.
    nonisolated public static func cacheCell(_ bbox: BBox) -> String {
        func q(_ value: Double) -> Int { Int((value * 5).rounded()) }
        return "\(q(bbox.west)),\(q(bbox.south)),\(q(bbox.east)),\(q(bbox.north))"
    }
}
