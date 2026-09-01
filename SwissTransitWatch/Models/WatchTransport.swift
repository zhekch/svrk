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

/// Shared ordering for every watch-side vehicle budget. Higher values are
/// admitted first; the map reverses this only at paint time so high-priority
/// dots are visually on top of lower-priority ones.
enum WatchModeRenderPriority {
    static func value(for mode: String) -> Int {
        switch mode.lowercased() {
        case "train", "metro": return 3
        case "tram", "boat", "cable": return 2
        case "bus": return 1
        default: return 0
        }
    }
}

/// Stable stop-place identity for the watch map and station boards.
/// Platform identifiers vary between the online and packed feeds, while the
/// passenger-facing name is consistent enough to collapse those identifiers.
/// Only generic forecourt names ("…, Bahnhof", "…, Gare", etc.) fold into a
/// railway parent; another nearby city stop remains its own place.
enum WatchStopPlaceIdentity {
    private static let genericStationSuffixes = Set([
        "bahnhof", "gare", "station", "stazione", "staziun",
    ])

    static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        squash(lhs) == squash(rhs)
    }

    static func isGenericChild(_ child: String, of parent: String) -> Bool {
        let child = folded(child)
        let parent = folded(parent)
        guard child.hasPrefix("\(parent),") else { return false }
        let suffix = child.dropFirst(parent.count + 1)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return genericStationSuffixes.contains(suffix)
    }

    static func belongsToInterchange(_ name: String, parent: String) -> Bool {
        sameName(name, parent) || isGenericChild(name, of: parent)
    }

    static func mapKey(for name: String) -> String {
        let value = folded(name)
        if let comma = value.firstIndex(of: ",") {
            let suffix = value[value.index(after: comma)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if genericStationSuffixes.contains(suffix) {
                return squash(String(value[..<comma]))
            }
        }
        return squash(value)
    }

    private static func folded(_ name: String) -> String {
        name.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "de_CH")
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func squash(_ name: String) -> String {
        folded(name).filter { $0.isLetter || $0.isNumber }
    }
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

enum WatchBoardShowing: String, Equatable, Hashable, Sendable {
    case departure
    case arrival
}

struct WatchStationDeparture: Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var mode: String
    var line: String
    var destination: String
    var origin: String
    var arrival: Date
    var departure: Date
    var platform: String?
    var delayMinutes: Int?
    var vehicle: WatchTransitVehicle?
    var originates: Bool
    var terminates: Bool
    /// Dominant daytime headway from the packed national timetable. Nil means
    /// the service is irregular or the online fallback lacks enough evidence.
    var typicalIntervalMinutes: Int? = nil

    func eventTime(showing: WatchBoardShowing) -> Date {
        showing == .departure ? departure : arrival
    }

    func place(showing: WatchBoardShowing) -> String {
        showing == .departure ? destination : origin
    }
}

/// Consecutive calls of the same advertised service are collapsed into one
/// station-board card. The full set remains available from its Times action.
struct WatchDepartureGroup: Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var departures: [WatchStationDeparture]
    var showing: WatchBoardShowing

    var primary: WatchStationDeparture { departures[0] }

    var mapVehicle: WatchTransitVehicle? {
        departures.lazy.compactMap(\.vehicle).first
    }

    var frequencyDescription: String {
        if showing == .departure,
           let minutes = departures.compactMap(\.typicalIntervalMinutes).first {
            return Self.intervalDescription(minutes, prefix: "Usually every")
        }

        let sorted = departures.map { $0.eventTime(showing: showing) }.sorted()
        guard sorted.count >= 2 else {
            return showing == .departure
                ? "One upcoming departure"
                : "One upcoming arrival"
        }
        let intervals = zip(sorted, sorted.dropFirst()).compactMap { earlier, later in
            let minutes = Int((later.timeIntervalSince(earlier) / 60).rounded())
            return minutes > 0 ? minutes : nil
        }
        // Two future calls supply only one interval: at the evening transition
        // that is exactly the misleading 91-minute gap. Do not call it a
        // frequency unless at least two intervals agree within five minutes.
        guard intervals.count >= 2 else { return "Irregular service" }
        var buckets: [Int: Int] = [:]
        for interval in intervals where interval <= 180 {
            let rounded = max(5, Int((Double(interval) / 5).rounded()) * 5)
            buckets[rounded, default: 0] += 1
        }
        guard let winner = buckets.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }), winner.value >= 2, winner.value * 2 >= intervals.count
        else { return "Irregular service" }
        return Self.intervalDescription(winner.key, prefix: "Every")
    }

    private static func intervalDescription(_ minutes: Int, prefix: String) -> String {
        if (55 ... 65).contains(minutes) { return "\(prefix) hour" }
        if minutes > 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            if remainder == 0 {
                return hours == 1 ? "\(prefix) hour" : "\(prefix) \(hours) hours"
            }
            return "\(prefix) \(hours) hr \(remainder) min"
        }
        return "\(prefix) \(minutes) min"
    }
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
    func mapPosition(
        at date: Date,
        geometry: WatchVehicleRouteGeometry? = nil
    ) -> WatchCoordinate? {
        let calls = stops.enumerated().compactMap { index, stop -> (
            index: Int, coordinate: WatchCoordinate, arrival: Date, departure: Date
        )? in
            guard let coordinate = stop.coordinate, coordinate.isValid,
                  let event = stop.arrival ?? stop.departure
            else { return nil }
            return (
                index,
                coordinate,
                stop.arrival ?? event,
                stop.departure ?? event
            )
        }

        guard let first = calls.first, let last = calls.last,
              date >= first.arrival.addingTimeInterval(-5 * 60),
              date <= last.departure.addingTimeInterval(2 * 60)
        else { return nil }

        if date <= first.departure {
            if let firstLeg = geometry?.legs.first ?? nil,
               let routeStart = firstLeg.first {
                return routeStart
            }
            return first.coordinate
        }

        for index in 0 ..< calls.count - 1 {
            let current = calls[index]
            let next = calls[index + 1]
            if date <= current.departure {
                let routeLeg: [WatchCoordinate]? = geometry?.legs[safe: current.index] ?? nil
                return routeLeg?.first ?? current.coordinate
            }
            if date <= next.arrival {
                let duration = max(1, next.arrival.timeIntervalSince(current.departure))
                let progress = min(
                    1,
                    max(0, date.timeIntervalSince(current.departure) / duration)
                )
                if next.index == current.index + 1,
                   let path = geometry?.legs[safe: current.index] ?? nil,
                   let routed = Self.position(along: path, progress: progress) {
                    return routed
                }
                return WatchCoordinate(
                    latitude: current.coordinate.latitude
                        + (next.coordinate.latitude - current.coordinate.latitude) * progress,
                    longitude: current.coordinate.longitude
                        + (next.coordinate.longitude - current.coordinate.longitude) * progress
                )
            }
        }

        if let lastLeg = geometry?.legs.last ?? nil,
           let routeEnd = lastLeg.last {
            return routeEnd
        }
        return last.coordinate
    }

    func positioned(
        at date: Date,
        geometry: WatchVehicleRouteGeometry? = nil
    ) -> WatchTransitVehicle? {
        guard let coordinate = mapPosition(at: date, geometry: geometry) else { return nil }
        var result = self
        result.latitude = coordinate.latitude
        result.longitude = coordinate.longitude
        return result
    }

    private static func position(
        along path: [WatchCoordinate],
        progress: Double
    ) -> WatchCoordinate? {
        guard let first = path.first, path.count >= 2 else { return path.first }
        var lengths = [Double](repeating: 0, count: path.count)
        for index in 1 ..< path.count {
            lengths[index] = lengths[index - 1]
                + metres(from: path[index - 1], to: path[index])
        }
        guard let total = lengths.last, total > 0 else { return first }
        let target = min(1, max(0, progress)) * total
        var index = 1
        while index < lengths.count, lengths[index] < target { index += 1 }
        index = min(index, path.count - 1)
        let segment = max(0.001, lengths[index] - lengths[index - 1])
        let fraction = min(1, max(0, (target - lengths[index - 1]) / segment))
        return WatchCoordinate(
            latitude: path[index - 1].latitude
                + (path[index].latitude - path[index - 1].latitude) * fraction,
            longitude: path[index - 1].longitude
                + (path[index].longitude - path[index - 1].longitude) * fraction
        )
    }

    private static func metres(
        from lhs: WatchCoordinate,
        to rhs: WatchCoordinate
    ) -> Double {
        let latitude = (lhs.latitude + rhs.latitude) * 0.5 * .pi / 180
        let north = (rhs.latitude - lhs.latitude) * 111_320
        let east = (rhs.longitude - lhs.longitude) * 111_320 * cos(latitude)
        return hypot(north, east)
    }
}

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
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
