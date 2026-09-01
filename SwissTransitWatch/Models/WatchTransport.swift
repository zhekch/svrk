import Foundation

enum WatchTransitPolicy {
    /// Cached dots and a recent location remain useful for a short wrist check.
    static let staleInterval: TimeInterval = 15 * 60

    /// Vehicle coordinates are cheap timetable interpolation, not radio or GPS
    /// samples. Five seconds is visibly current on a watch without asking
    /// MapKit to redraw at phone-like frame rates.
    static let mapPositionInterval: TimeInterval = 5

    /// Pull new runs and prognosis changes much less often than dots move. The
    /// request is centred on the visible map and only runs while it is onscreen.
    static let viewportRefreshInterval: TimeInterval = 2 * 60
}

struct WatchCoordinate: Codable, Equatable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90 ... 90).contains(latitude)
            && (-180 ... 180).contains(longitude)
    }
}

/// The small cache format used only by the watch target. It intentionally has
/// no route geometry, formations, vehicle shapes, disruptions or engineering.
/// Stop coordinates are retained because they power both the detail screen and
/// its inexpensive stop-to-stop route preview.
struct WatchTransitSnapshot: Codable, Equatable, Sendable {
    static let protocolVersion = 3

    var version = protocolVersion
    var generatedAt: Date
    var sourceUpdatedAt: Date?
    var viewport: WatchViewport
    var vehicles: [WatchTransitVehicle]

    static let empty = WatchTransitSnapshot(
        generatedAt: .distantPast,
        sourceUpdatedAt: nil,
        viewport: .switzerland,
        vehicles: []
    )

    var isUsable: Bool { version == Self.protocolVersion }
}

struct WatchViewport: Codable, Equatable, Hashable, Sendable {
    var west: Double
    var south: Double
    var east: Double
    var north: Double

    static let switzerland = WatchViewport(
        west: 5.82, south: 45.78, east: 10.59, north: 47.90
    )

    static func near(_ coordinate: WatchCoordinate) -> WatchViewport {
        // Roughly 13 km north/south and 13 km east/west around the wearer.
        // That is enough context for nearby services without a broad query.
        let latitudeRadius = 0.06
        let cosine = max(0.3, cos(coordinate.latitude * .pi / 180))
        let longitudeRadius = latitudeRadius / cosine
        return WatchViewport(
            west: coordinate.longitude - longitudeRadius,
            south: coordinate.latitude - latitudeRadius,
            east: coordinate.longitude + longitudeRadius,
            north: coordinate.latitude + latitudeRadius
        )
    }

    var center: WatchCoordinate {
        WatchCoordinate(
            latitude: (min(south, north) + max(south, north)) / 2,
            longitude: (min(west, east) + max(west, east)) / 2
        )
    }

    func contains(_ coordinate: WatchCoordinate) -> Bool {
        (min(south, north) ... max(south, north)).contains(coordinate.latitude)
            && (min(west, east) ... max(west, east)).contains(coordinate.longitude)
    }

    func padded(by fraction: Double) -> WatchViewport {
        let fraction = max(0, fraction)
        let latitudePadding = abs(north - south) * fraction
        let longitudePadding = abs(east - west) * fraction
        return WatchViewport(
            west: min(west, east) - longitudePadding,
            south: min(south, north) - latitudePadding,
            east: max(west, east) + longitudePadding,
            north: max(south, north) + latitudePadding
        )
    }

    init(west: Double, south: Double, east: Double, north: Double) {
        self.west = west
        self.south = south
        self.east = east
        self.north = north
    }
}

struct WatchTransitStop: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var stationID: String?
    var name: String
    var platform: String?
    var arrival: Date?
    var departure: Date?
    var delayMinutes: Int?
    var coordinate: WatchCoordinate?

    var eventTime: Date? { arrival ?? departure }

    var displayPlatform: String? {
        guard let platform else { return nil }
        let cleaned = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

struct WatchStationDeparture: Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var mode: String
    var line: String
    var destination: String
    var departure: Date
    var platform: String?
    var delayMinutes: Int?
}

struct WatchTransitVehicle: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var mode: String
    var line: String
    var destination: String?
    var origin: String
    var operatorName: String?
    var delayMinutes: Int?
    var latitude: Double
    var longitude: Double
    var stops: [WatchTransitStop]

    func nextStop(at date: Date) -> WatchTransitStop? {
        // A call remains current until its departure, then immediately yields
        // to the next one. Returning the last call after the run has finished
        // is what made a 16:06 stop still read as "next" at 16:10.
        let grace = date.addingTimeInterval(-15)
        return stops.first {
            guard let leaves = $0.departure ?? $0.arrival else { return false }
            return leaves >= grace
        }
    }

    /// Recomputes the lightweight dot position from the calls already held in
    /// memory. This performs no location or network work. The online and
    /// offline snapshot builders use the same stop-to-stop interpolation.
    func mapPosition(at date: Date) -> WatchCoordinate? {
        let calls = stops.compactMap { stop -> (
            coordinate: WatchCoordinate, arrival: Date, departure: Date
        )? in
            guard let coordinate = stop.coordinate, coordinate.isValid,
                  let event = stop.arrival ?? stop.departure
            else { return nil }
            return (
                coordinate,
                stop.arrival ?? event,
                stop.departure ?? event
            )
        }

        guard let first = calls.first, let last = calls.last,
              date >= first.arrival.addingTimeInterval(-5 * 60),
              date <= last.departure.addingTimeInterval(2 * 60)
        else { return nil }

        if date <= first.departure { return first.coordinate }

        for index in 0 ..< calls.count - 1 {
            let current = calls[index]
            let next = calls[index + 1]
            if date <= current.departure { return current.coordinate }
            if date <= next.arrival {
                let duration = max(1, next.arrival.timeIntervalSince(current.departure))
                let progress = min(
                    1,
                    max(0, date.timeIntervalSince(current.departure) / duration)
                )
                return WatchCoordinate(
                    latitude: current.coordinate.latitude
                        + (next.coordinate.latitude - current.coordinate.latitude) * progress,
                    longitude: current.coordinate.longitude
                        + (next.coordinate.longitude - current.coordinate.longitude) * progress
                )
            }
        }

        return last.coordinate
    }

    func positioned(at date: Date) -> WatchTransitVehicle? {
        guard let coordinate = mapPosition(at: date) else { return nil }
        var result = self
        result.latitude = coordinate.latitude
        result.longitude = coordinate.longitude
        return result
    }
}

enum WatchTransitPayload {
    /// Keep the on-watch cache small even when unusually verbose operators or
    /// destinations are returned.
    private static let cacheBudget = 768 * 1_024

    static func encode(_ snapshot: WatchTransitSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var outgoing = snapshot
        while true {
            let data = try encoder.encode(outgoing)
            if data.count <= cacheBudget || outgoing.vehicles.isEmpty { return data }
            outgoing.vehicles.removeLast(max(1, outgoing.vehicles.count / 5))
        }
    }

    static func decode(_ data: Data) throws -> WatchTransitSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(WatchTransitSnapshot.self, from: data)
    }
}
