import Foundation

/// The stationboard mirror, for what the national feed does not carry.
///
/// SIRI-ET is the estimated timetable for trains, trams and buses, and it is
/// the app's whole fleet. It is not everything that runs. Funiculars and cable
/// cars are largely absent — Bern's Marzilibahn appears nowhere in a national
/// snapshot, though the bus stop outside it does — and so are a few small
/// operators. For those stops the live fleet is simply empty, and an empty
/// board is indistinguishable from a stop with no service left today.
///
/// transport.opendata.ch does carry them. It is asked for one stop, only when
/// the board would otherwise be empty, and only for as long as it takes to
/// answer — about twenty kilobytes against the seven megabytes a national
/// refresh costs. No token, no quota to keep.
public actor MirrorClient {
    static let base = "https://transport.opendata.ch/v1"
    static let userAgent = "swiss-live-transit-ios/1.0"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Departures from one stop, as journeys.
    ///
    /// `lookback` winds the query into the past on purpose: a stationboard lists
    /// only *future* departures, so asking for "now" returns vehicles that have
    /// not left yet and nothing actually in transit.
    public func board(
        didok: String, at moment: Timestamp, limit: Int = 40, lookback: TimeInterval = 45 * 60
    ) async -> [Journey] {
        guard let url = boardURL(didok: didok, at: moment, limit: limit, lookback: lookback) else {
            return []
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Somebody is waiting on a tap, so a slow mirror must not hold the panel
        // open indefinitely. Failing is the same as having nothing, which is
        // where this started.
        request.timeoutInterval = 8

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return MirrorBoard.journeys(from: data)
        } catch {
            return []
        }
    }

    func boardURL(didok: String, at moment: Timestamp, limit: Int, lookback: TimeInterval) -> URL? {
        var components = URLComponents(string: "\(Self.base)/stationboard")
        components?.queryItems = [
            URLQueryItem(name: "id", value: didok),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "datetime", value: Self.datetime(moment - Timestamp(lookback))),
            URLQueryItem(name: "type", value: "departure"),
        ]
        return components?.url
    }

    /// The API's own format: local wall-clock, `YYYY-MM-DD hh:mm`.
    static func datetime(_ moment: Timestamp) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich") ?? .current
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: Date(timeIntervalSince1970: TimeInterval(moment))
        )
        func pad(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return "\(parts.year ?? 1970)-\(pad(parts.month))-\(pad(parts.day)) \(pad(parts.hour)):\(pad(parts.minute))"
    }
}

/// One stationboard response, turned into journeys.
enum MirrorBoard {
    static func journeys(from data: Data) -> [Journey] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let station = root["station"] as? [String: Any]
        let entries = root["stationboard"] as? [[String: Any]] ?? []
        return entries.compactMap { journey(from: $0, station: station) }
    }

    /// A time from the mirror, live where it has one.
    ///
    /// `delay` is in minutes and applies to the whole call where no prognosis
    /// exists, which is how the mirror expresses a late train that has not been
    /// individually re-timed.
    private static func time(_ stop: [String: Any], _ which: String) -> Timestamp? {
        if let prognosis = stop["prognosis"] as? [String: Any],
           let text = prognosis[which] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let parsed = formatter.date(from: text) {
                return Timestamp(parsed.timeIntervalSince1970)
            }
        }
        guard let scheduled = stop["\(which)Timestamp"] as? Double else { return nil }
        let delay = (stop["delay"] as? Double).map { $0 * 60 } ?? 0
        return Timestamp(scheduled + delay)
    }

    private static func journey(from entry: [String: Any], station: [String: Any]?) -> Journey? {
        let pass = entry["passList"] as? [[String: Any]] ?? []
        guard pass.count >= 2 else { return nil }

        var stops: [Call] = []
        for (i, p) in pass.enumerated() {
            // The feed threads route waypoints through the passList —
            // "Bahn-2000-Strecke", "Gotthard-Basistunnel" — to record which way
            // a train went. They are not stations: no scheduled time at all,
            // only a prognosis reading the same for every train that hour. Taken
            // for stops they cost a phantom call in the panel and a junk time
            // dragging the journey's own times about.
            if p["arrivalTimestamp"] == nil && p["departureTimestamp"] == nil { continue }

            let where_ = p["station"] as? [String: Any]
            var name = where_?["name"] as? String
            let coordinate = where_?["coordinate"] as? [String: Any]
            var lat = coordinate?["x"] as? Double
            var lon = coordinate?["y"] as? Double
            // The first passList entry repeats the board's own station but often
            // carries a platform-level id with null coordinates.
            if lat == nil || lon == nil, i == 0, let station {
                let own = station["coordinate"] as? [String: Any]
                lat = own?["x"] as? Double
                lon = own?["y"] as? Double
                name = name ?? station["name"] as? String
            }
            guard let lat, let lon else { continue }

            let arrival = time(p, "arrival")
            let departure = time(p, "departure")
            guard arrival != nil || departure != nil else { continue }

            let platform = (p["platform"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            stops.append(Call(
                key: "\(name ?? "—")|\(i)",
                ref: nil,
                name: name ?? "—",
                lat: lat, lon: lon,
                platform: platform,
                precise: false,
                // A terminus has no departure and an origin no arrival; fill
                // both so the interpolator never has to special-case the ends.
                arr: arrival ?? departure!,
                dep: departure ?? arrival!,
                delay: (p["delay"] as? Double).map { Int($0) },
                observed: false,
                sched: (p["departureTimestamp"] as? Double).map { Timestamp($0) }
                    ?? (p["arrivalTimestamp"] as? Double).map { Timestamp($0) }
            ))
        }
        guard stops.count >= 2 else { return nil }

        // Times must be non-decreasing or the interpolation can run backwards.
        for i in 1..<stops.count {
            if stops[i].arr < stops[i - 1].dep { stops[i].arr = stops[i - 1].dep }
            if stops[i].dep < stops[i].arr { stops[i].dep = stops[i].arr }
        }

        let category = entry["category"] as? String
        let number = entry["number"] as? String
        let line = category == number
            ? (category ?? "?")
            : "\((category ?? ""))\((number ?? ""))"
        let operatorName = entry["operator"] as? String
        let to = entry["to"] as? String

        // `name` is the operational trip number: stable for one vehicle's whole
        // run, so the same journey seen from two boards collapses to one entry.
        // Trip numbers are unique only within an operator, hence the pair; and
        // the destination is part of it because Swiss trains split.
        let trip = entry["name"] as? String
        let id = "mirror|" + (trip.map { "\(operatorName ?? "?")|\($0)|\(to ?? line)" }
            ?? "\(operatorName ?? "?")|\(line)|\(stops[0].dep)")

        return Journey(
            id: id,
            mode: Categories.mode(of: category),
            category: category,
            line: line.trimmingCharacters(in: .whitespaces).isEmpty ? (trip ?? "?") : line,
            number: number,
            operatorName: operatorName,
            operatorFull: nil,
            to: to,
            from: stops[0].name,
            delay: ((entry["stop"] as? [String: Any])?["delay"] as? Double).map { Int($0) },
            start: stops[0].dep,
            end: stops[stops.count - 1].arr,
            complete: true,
            monitored: false,
            cancelled: false,
            // Marked, so nothing downstream mistakes a mirror sighting for the
            // national feed's own view of the fleet.
            source: "mirror",
            stops: stops
        )
    }
}
