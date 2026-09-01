import Foundation
import SwiftUI

enum WatchRailStyle: UInt8, Sendable {
    case other = 0
    case heavy = 1
    case narrow = 2
    case tram = 3
    case lightRail = 4
    case funicular = 5

    var color: Color {
        switch self {
        case .heavy: return Color(red: 1.0, green: 0.51, blue: 0.0)
        case .narrow: return Color(red: 0.75, green: 0.85, blue: 0.0)
        case .tram, .lightRail: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .funicular: return Color(red: 0.85, green: 0.47, blue: 0.47)
        case .other: return .secondary
        }
    }
}

struct WatchRailOverlayLine: Identifiable, Sendable {
    var id: Int
    var style: WatchRailStyle
    var coordinates: [WatchCoordinate]
    var isDetailed: Bool
}

/// A memory-mapped, watch-sized derivative of the app's OSM railway graph.
/// Only metadata is read at startup; coordinates are decoded for the current
/// viewport after camera movement stops. It has no network or timer of its own.
actor WatchRailOverlayStore {
    static let shared = WatchRailOverlayStore()

    private struct Entry: Sendable {
        var id: Int
        var style: WatchRailStyle
        var west: Int32
        var south: Int32
        var east: Int32
        var north: Int32
        var pointCount: Int
        var pointsOffset: Int

        var extent: Int64 {
            Int64(east) - Int64(west) + Int64(north) - Int64(south)
        }
    }

    private struct Archive: Sendable {
        var file: MappedFile
        var bands: [UInt8: [Entry]]
    }

    private var archive: Archive?
    private var didTryLoading = false

    func lines(in viewport: WatchViewport) -> [WatchRailOverlayLine] {
        guard let archive = loadIfNeeded() else { return [] }
        let width = abs(viewport.east - viewport.west)
        let height = abs(viewport.north - viewport.south)
        let span = max(width, height)

        // SwiftUI Map creates a separate renderer for every custom polyline.
        // Keep the watch layer deliberately sparse; Apple's basemap still
        // supplies geographic context underneath it. The 12 m corridor band
        // is only worthwhile once the camera reaches city scale.
        let policy: (
            level: UInt8,
            lineLimit: Int,
            pointLimit: Int,
            simplifyMetres: Double
        )
        switch span {
        case 1.0...:
            policy = (0, 32, 500, 150)
        case 0.35 ..< 1.0:
            policy = (0, 48, 800, 150)
        case 0.14 ..< 0.35:
            policy = (0, 72, 1_200, 150)
        case 0.05 ..< 0.14:
            policy = (1, 96, 1_800, 55)
        case 0.015 ..< 0.05:
            policy = (1, 120, 2_600, 25)
        default:
            policy = (1, 140, 3_200, 10)
        }
        let detailed = policy.level == 1
        let level = policy.level
        guard let entries = archive.bands[level] else { return [] }

        let west = BinaryFormat.encode(min(viewport.west, viewport.east))
        let south = BinaryFormat.encode(min(viewport.south, viewport.north))
        let east = BinaryFormat.encode(max(viewport.west, viewport.east))
        let north = BinaryFormat.encode(max(viewport.south, viewport.north))
        var visible = entries.filter {
            $0.west <= east && $0.east >= west
                && $0.south <= north && $0.north >= south
        }

        // A dense station throat can contain thousands of tiny OSM ways. Keep
        // meaningful transit classes and longer runs first, with both overlay
        // and vertex limits so a single complex line cannot consume the frame.
        visible.sort {
            let lhsPriority = Self.priority($0.style)
            let rhsPriority = Self.priority($1.style)
            if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
            return $0.extent > $1.extent
        }
        var selected: [Entry] = []
        selected.reserveCapacity(min(visible.count, policy.lineLimit))
        var selectedPoints = 0
        for entry in visible {
            guard selected.count < policy.lineLimit else { break }
            guard selectedPoints + entry.pointCount <= policy.pointLimit else { continue }
            selected.append(entry)
            selectedPoints += entry.pointCount
        }

        return selected.compactMap { entry in
            let pointBytes = entry.pointCount * 8
            guard entry.pointsOffset >= 0,
                  entry.pointsOffset + pointBytes <= archive.file.buffer.count
            else { return nil }
            var raw: [Coord] = []
            raw.reserveCapacity(entry.pointCount)
            for index in 0 ..< entry.pointCount {
                let offset = entry.pointsOffset + index * 8
                let lon = Int32(littleEndian: archive.file.buffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: Int32.self
                ))
                let lat = Int32(littleEndian: archive.file.buffer.loadUnaligned(
                    fromByteOffset: offset + 4,
                    as: Int32.self
                ))
                raw.append(
                    Coord(
                        lon: BinaryFormat.decode(lon),
                        lat: BinaryFormat.decode(lat)
                    )
                )
            }
            let simplified = detailed
                ? Geo.simplify(raw, toleranceMetres: policy.simplifyMetres)
                : raw
            guard simplified.count >= 2 else { return nil }
            let coordinates = simplified.map {
                WatchCoordinate(latitude: $0.lat, longitude: $0.lon)
            }
            return WatchRailOverlayLine(
                id: entry.id,
                style: entry.style,
                coordinates: coordinates,
                isDetailed: detailed
            )
        }
    }

    private func loadIfNeeded() -> Archive? {
        if let archive { return archive }
        guard !didTryLoading else { return nil }
        didTryLoading = true
        guard let url = Bundle.main.url(
            forResource: "watch-rail-overlay-v1",
            withExtension: "bin"
        ) else { return nil }

        do {
            let file = try MappedFile(url: url)
            var reader = BinaryReader(file)
            try reader.expect(magic: "SVWRAIL1", version: 1)
            let bandCount = Int(try reader.readUInt32())
            guard (1 ... 4).contains(bandCount) else { return nil }
            var bands: [UInt8: [Entry]] = [:]

            for _ in 0 ..< bandCount {
                let level = try reader.readUInt8()
                _ = try reader.skip(3)
                let count = Int(try reader.readUInt32())
                guard count <= 100_000 else { return nil }
                var entries: [Entry] = []
                entries.reserveCapacity(count)

                for index in 0 ..< count {
                    let recordBytes = Int(try reader.readUInt32())
                    let recordStart = reader.cursor
                    let rawStyle = try reader.readUInt8()
                    _ = try reader.skip(3)
                    let west = try reader.readInt32()
                    let south = try reader.readInt32()
                    let east = try reader.readInt32()
                    let north = try reader.readInt32()
                    let pointCount = Int(try reader.readUInt32())
                    guard pointCount >= 2,
                          recordBytes == 24 + pointCount * 8
                    else { return nil }
                    let pointsOffset = reader.cursor
                    _ = try reader.skip(pointCount * 8)
                    guard reader.cursor == recordStart + recordBytes else { return nil }
                    entries.append(
                        Entry(
                            id: Int(level) * 100_000 + index,
                            style: WatchRailStyle(rawValue: rawStyle) ?? .other,
                            west: west,
                            south: south,
                            east: east,
                            north: north,
                            pointCount: pointCount,
                            pointsOffset: pointsOffset
                        )
                    )
                }
                bands[level] = entries
            }
            let loaded = Archive(file: file, bands: bands)
            archive = loaded
            return loaded
        } catch {
            return nil
        }
    }

    private static func priority(_ style: WatchRailStyle) -> Int {
        switch style {
        case .tram, .lightRail, .funicular: return 3
        case .heavy, .narrow: return 2
        case .other: return 1
        }
    }
}

struct WatchVehicleRouteGeometry: Sendable {
    /// One optional OSM path for every pair of consecutive timetable calls.
    /// Nil means that particular leg still uses its inexpensive chord fallback.
    var legs: [[WatchCoordinate]?]
}

/// Matches only the vehicles the current camera can see against a simplified,
/// memory-mapped copy of the same OSM route relations used by the iOS app.
/// The archive includes rail, road and ferry services but no way-id index, so
/// it is about a quarter of the full relation store and pages in on demand.
actor WatchRouteGeometryStore {
    static let shared = WatchRouteGeometryStore()

    private var relations: RelationStore?
    private var didTryLoading = false
    private var cache: [String: WatchVehicleRouteGeometry] = [:]
    private var misses = Set<String>()
    private var cacheOrder: [String] = []

    func geometries(
        for vehicles: [WatchTransitVehicle]
    ) -> [String: WatchVehicleRouteGeometry] {
        guard loadIfNeeded() != nil else { return [:] }
        var result: [String: WatchVehicleRouteGeometry] = [:]
        for vehicle in vehicles {
            if let geometry = geometry(for: vehicle) {
                result[vehicle.id] = geometry
            }
        }
        return result
    }

    func geometry(
        for vehicle: WatchTransitVehicle
    ) -> WatchVehicleRouteGeometry? {
        guard let relations = loadIfNeeded(), vehicle.stops.count >= 2,
              let mode = Mode(rawValue: vehicle.mode.lowercased())
        else { return nil }

        let key = cacheKey(for: vehicle)
        if let cached = cache[key] { return cached }
        if misses.contains(key) { return nil }

        let calls = vehicle.stops.compactMap { stop -> Call? in
            guard let coordinate = stop.coordinate, coordinate.isValid else { return nil }
            let arrival = Int((stop.arrival ?? stop.departure ?? .distantPast).timeIntervalSince1970)
            let departure = Int((stop.departure ?? stop.arrival ?? .distantPast).timeIntervalSince1970)
            return Call(
                key: stop.id,
                ref: stop.stationID,
                name: stop.name,
                lat: coordinate.latitude,
                lon: coordinate.longitude,
                platform: stop.platform,
                arr: arrival,
                dep: departure,
                delay: stop.delayMinutes
            )
        }
        guard calls.count == vehicle.stops.count,
              let matched = relations.legPaths(RelationStore.MatchProbe(
                mode: mode,
                line: vehicle.line,
                number: vehicle.line,
                category: nil,
                stops: calls
              ))
        else {
            misses.insert(key)
            trimCacheIfNeeded()
            return nil
        }

        let geometry = WatchVehicleRouteGeometry(
            legs: matched.legs.map { leg in
                leg.map { path in
                    // Relation member order can contain a short trip to the
                    // end of an OSM way and back. Clean each matched leg once
                    // while filling the cache; map frames only interpolate the
                    // already-clean coordinates.
                    var cleaned = Geo.withoutSpurs(path)
                    cleaned = Geo.withoutFolds(cleaned)
                    cleaned = Geo.withoutEndStubs(cleaned)
                    return cleaned.map {
                        WatchCoordinate(latitude: $0.lat, longitude: $0.lon)
                    }
                }
            }
        )
        cache[key] = geometry
        cacheOrder.append(key)
        trimCacheIfNeeded()
        return geometry
    }

    private func loadIfNeeded() -> RelationStore? {
        if let relations { return relations }
        guard !didTryLoading else { return nil }
        didTryLoading = true
        guard let url = Bundle.main.url(
            forResource: "watch-route-relations-v1",
            withExtension: "bin"
        ) else { return nil }

        let loaded = RelationStore()
        guard (try? loaded.load(url)) != nil else { return nil }
        relations = loaded
        return loaded
    }

    private func cacheKey(for vehicle: WatchTransitVehicle) -> String {
        let stops = vehicle.stops.map { stop in
            if let stationID = stop.stationID, !stationID.isEmpty { return stationID }
            return stop.name.folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: Locale(identifier: "en_US")
            )
        }.joined(separator: ">")
        return "\(vehicle.mode)|\(vehicle.line)|\(stops)"
    }

    private func trimCacheIfNeeded() {
        let limit = 96
        while cacheOrder.count > limit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        if misses.count > limit { misses.removeAll(keepingCapacity: true) }
    }
}
