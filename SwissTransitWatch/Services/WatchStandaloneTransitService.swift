import Foundation

/// Small online fallback used until the full national archive is installed.
actor WatchStandaloneTransitService {
    private let baseURL = URL(string: "https://transport.opendata.ch/v1")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func stationBoard(
        for stop: WatchTransitStop,
        at now: Date = Date()
    ) async throws -> [WatchStationDeparture] {
        let coordinate = stop.coordinate ?? WatchCoordinate(latitude: 0, longitude: 0)
        let station = NearbyStation(
            id: stop.stationID ?? "",
            name: stop.name,
            coordinate: coordinate,
            distance: 0,
            icon: nil
        )
        let services = try await vehicles(at: station, now: now, includeUpcoming: true)
        return services.compactMap { vehicle in
            let call = vehicle.stops.first {
                if let wanted = stop.stationID, let found = $0.stationID {
                    return wanted == found
                }
                return Self.sameStop($0.name, stop.name)
            }
            guard let call,
                  let departure = call.departure ?? call.arrival,
                  departure >= now.addingTimeInterval(-2 * 60)
            else { return nil }
            return WatchStationDeparture(
                id: vehicle.id,
                mode: vehicle.mode,
                line: vehicle.line,
                destination: vehicle.displayDestination,
                departure: departure,
                platform: call.displayPlatform,
                delayMinutes: call.delayMinutes ?? vehicle.delayMinutes
            )
        }
        .sorted { $0.departure < $1.departure }
    }

    func snapshot(
        near coordinate: WatchCoordinate,
        viewport: WatchViewport,
        at now: Date = Date()
    ) async throws -> WatchTransitSnapshot {
        try Task.checkCancellation()
        let stations = try await nearestStations(to: coordinate)
        let vehicles = await withTaskGroup(of: [WatchTransitVehicle].self) { group in
            for station in stations {
                group.addTask { [self] in
                    (try? await vehicles(at: station, now: now)) ?? []
                }
            }

            var combined: [WatchTransitVehicle] = []
            for await stationVehicles in group {
                combined.append(contentsOf: stationVehicles)
            }
            return combined
        }

        try Task.checkCancellation()
        var unique: [String: WatchTransitVehicle] = [:]
        for vehicle in vehicles where unique[vehicle.id] == nil {
            unique[vehicle.id] = vehicle
        }

        let dots = unique.values.sorted { lhs, rhs in
            if lhs.mode != rhs.mode { return lhs.mode < rhs.mode }
            if lhs.line != rhs.line {
                return lhs.line.localizedStandardCompare(rhs.line) == .orderedAscending
            }
            return lhs.id < rhs.id
        }.prefix(120)

        return WatchTransitSnapshot(
            generatedAt: now,
            sourceUpdatedAt: now,
            viewport: viewport,
            vehicles: Array(dots)
        )
    }

    private func nearestStations(to coordinate: WatchCoordinate) async throws -> [NearbyStation] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("locations"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "x", value: String(coordinate.latitude)),
            URLQueryItem(name: "y", value: String(coordinate.longitude)),
            URLQueryItem(name: "type", value: "station"),
        ]

        let response: LocationsResponse = try await get(components)
        let candidates = response.stations.compactMap { station -> NearbyStation? in
            guard let id = station.id, !id.isEmpty,
                  let point = station.coordinate?.watchCoordinate,
                  point.isValid
            else { return nil }
            return NearbyStation(
                id: id,
                name: station.name ?? "Nearby stop",
                coordinate: point,
                distance: station.distance ?? .greatestFiniteMagnitude,
                icon: station.icon?.lowercased()
            )
        }.sorted { $0.distance < $1.distance }

        guard !candidates.isEmpty else { throw ServiceError.noNearbyStations }

        var selected: [NearbyStation] = []
        var selectedIDs = Set<String>()
        var icons = Set<String>()
        for station in candidates {
            let icon = station.icon ?? "unknown"
            guard !icons.contains(icon) else { continue }
            selected.append(station)
            selectedIDs.insert(station.id)
            icons.insert(icon)
            if selected.count == 3 { return selected }
        }
        for station in candidates where !selectedIDs.contains(station.id) {
            selected.append(station)
            if selected.count == 3 { break }
        }
        return selected
    }

    private func vehicles(
        at station: NearbyStation,
        now: Date,
        includeUpcoming: Bool = false
    ) async throws -> [WatchTransitVehicle] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("stationboard"),
            resolvingAgainstBaseURL: false
        )!
        var queryItems = [
            URLQueryItem(
                name: station.id.isEmpty ? "station" : "id",
                value: station.id.isEmpty ? station.name : station.id
            ),
            URLQueryItem(name: "limit", value: "24"),
            URLQueryItem(name: "datetime", value: Self.queryDate(now.addingTimeInterval(-45 * 60))),
            URLQueryItem(name: "type", value: "departure"),
        ]
        for field in [
            "stationboard/name",
            "stationboard/category",
            "stationboard/number",
            "stationboard/operator",
            "stationboard/to",
            "stationboard/passList/station",
            "stationboard/passList/arrivalTimestamp",
            "stationboard/passList/departureTimestamp",
            "stationboard/passList/delay",
            "stationboard/passList/platform",
            "stationboard/passList/prognosis/platform",
        ] {
            queryItems.append(URLQueryItem(name: "fields[]", value: field))
        }
        components.queryItems = queryItems

        let response: StationboardResponse = try await get(components)
        return response.stationboard.compactMap {
            vehicle(
                from: $0,
                queriedStation: station,
                now: now,
                includeUpcoming: includeUpcoming
            )
        }
    }

    private func vehicle(
        from journey: Journey,
        queriedStation: NearbyStation,
        now: Date,
        includeUpcoming: Bool = false
    ) -> WatchTransitVehicle? {
        let calls = journey.passList.compactMap { call -> TimedCall? in
            let fallback = call.station.id == queriedStation.id
                || call.station.name == queriedStation.name
            guard let coordinate = call.station.coordinate?.watchCoordinate
                    ?? (fallback ? queriedStation.coordinate : nil),
                  coordinate.isValid,
                  let scheduledArrival = call.arrivalTimestamp ?? call.departureTimestamp,
                  let scheduledDeparture = call.departureTimestamp ?? call.arrivalTimestamp
            else { return nil }
            let delay = TimeInterval((call.delay ?? 0) * 60)
            return TimedCall(
                id: call.station.id,
                name: call.station.name ?? queriedStation.name,
                coordinate: coordinate,
                arrival: TimeInterval(scheduledArrival) + delay,
                departure: TimeInterval(scheduledDeparture) + delay,
                delayMinutes: call.delay,
                platform: call.prognosis?.platform ?? call.platform
            )
        }

        guard calls.count >= 2 else { return nil }
        let position = Self.position(in: calls, at: now.timeIntervalSince1970)
            ?? (includeUpcoming
                ? calls.first.map {
                    Position(coordinate: $0.coordinate, delayMinutes: $0.delayMinutes)
                }
                : nil)
        guard let position else { return nil }

        let category = (journey.category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let number = (journey.number ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (journey.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let line = number.isEmpty ? (name.isEmpty ? category : name) : number
        let firstTime = Int(calls[0].departure)
        let identity = [journey.operatorName, name, journey.to, String(firstTime)]
            .compactMap { $0 }
            .joined(separator: "|")
        let stops = calls.enumerated().map { index, call in
            WatchTransitStop(
                id: [call.id, String(index), String(Int(call.departure))]
                    .compactMap { $0 }
                    .joined(separator: "|"),
                stationID: call.id,
                name: call.name,
                platform: call.platform,
                arrival: Date(timeIntervalSince1970: call.arrival),
                departure: Date(timeIntervalSince1970: call.departure),
                delayMinutes: call.delayMinutes,
                coordinate: call.coordinate
            )
        }

        return WatchTransitVehicle(
            id: identity.isEmpty ? "\(queriedStation.id)|\(firstTime)" : identity,
            mode: Self.mode(for: category),
            line: line,
            destination: journey.to,
            origin: calls[0].name,
            operatorName: journey.operatorName,
            delayMinutes: position.delayMinutes,
            latitude: position.coordinate.latitude,
            longitude: position.coordinate.longitude,
            stops: stops
        )
    }

    private func get<Response: Decodable>(_ components: URLComponents) async throws -> Response {
        guard let url = components.url else { throw ServiceError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SwissTransit-watchOS/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200 ... 299).contains(http.statusCode)
        else { throw ServiceError.invalidResponse }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private static func position(in calls: [TimedCall], at timestamp: TimeInterval) -> Position? {
        guard let first = calls.first, let last = calls.last,
              timestamp >= first.arrival - 5 * 60,
              timestamp <= last.departure + 2 * 60
        else { return nil }

        if timestamp <= first.departure {
            return Position(coordinate: first.coordinate, delayMinutes: first.delayMinutes)
        }
        for index in 0 ..< calls.count - 1 {
            let current = calls[index]
            let next = calls[index + 1]
            if timestamp <= current.departure {
                return Position(coordinate: current.coordinate, delayMinutes: current.delayMinutes)
            }
            if timestamp <= next.arrival {
                let duration = max(1, next.arrival - current.departure)
                let progress = min(1, max(0, (timestamp - current.departure) / duration))
                return Position(
                    coordinate: WatchCoordinate(
                        latitude: current.coordinate.latitude
                            + (next.coordinate.latitude - current.coordinate.latitude) * progress,
                        longitude: current.coordinate.longitude
                            + (next.coordinate.longitude - current.coordinate.longitude) * progress
                    ),
                    delayMinutes: current.delayMinutes ?? next.delayMinutes
                )
            }
        }
        return Position(coordinate: last.coordinate, delayMinutes: last.delayMinutes)
    }

    private static func mode(for category: String) -> String {
        switch category.uppercased() {
        case "B", "BUS", "N": return "bus"
        case "T", "TRAM": return "tram"
        case "M", "METRO": return "metro"
        case "BAT", "BAV", "SHIP": return "boat"
        case "FUN", "PB", "GB", "CC", "CABLE": return "cable"
        case "", "WALK": return "other"
        default: return "train"
        }
    }

    private static func queryDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Zurich")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func sameStop(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.lowercased()
                .split { $0 == "," || $0 == "." || $0.isWhitespace }
                .joined(separator: " ")
        }
        return normalized(lhs) == normalized(rhs)
    }
}

private extension WatchStandaloneTransitService {
    enum ServiceError: LocalizedError {
        case invalidResponse
        case noNearbyStations

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Transit data is temporarily unavailable."
            case .noNearbyStations: return "No nearby Swiss transit stops were found."
            }
        }
    }

    struct LocationsResponse: Decodable { var stations: [Station] }
    struct StationboardResponse: Decodable { var stationboard: [Journey] }

    struct Station: Decodable {
        var id: String?
        var name: String?
        var coordinate: APICoordinate?
        var distance: Double?
        var icon: String?
    }

    struct APICoordinate: Decodable {
        var x: Double?
        var y: Double?

        var watchCoordinate: WatchCoordinate? {
            guard let x, let y else { return nil }
            return WatchCoordinate(latitude: x, longitude: y)
        }
    }

    struct Journey: Decodable {
        var name: String?
        var category: String?
        var number: String?
        var operatorName: String?
        var to: String?
        var passList: [Call]

        enum CodingKeys: String, CodingKey {
            case name, category, number, to, passList
            case operatorName = "operator"
        }
    }

    struct Call: Decodable {
        var station: Station
        var arrivalTimestamp: Int?
        var departureTimestamp: Int?
        var delay: Int?
        var platform: String?
        var prognosis: Prognosis?
    }

    struct Prognosis: Decodable {
        var platform: String?
    }

    struct NearbyStation: Sendable {
        var id: String
        var name: String
        var coordinate: WatchCoordinate
        var distance: Double
        var icon: String?
    }

    struct TimedCall: Sendable {
        var id: String?
        var name: String
        var coordinate: WatchCoordinate
        var arrival: TimeInterval
        var departure: TimeInterval
        var delayMinutes: Int?
        var platform: String?
    }

    struct Position: Sendable {
        var coordinate: WatchCoordinate
        var delayMinutes: Int?
    }
}
