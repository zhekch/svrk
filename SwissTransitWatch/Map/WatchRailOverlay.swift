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
        let detailed = max(width, height) <= 0.85
        let level: UInt8 = detailed ? 1 : 0
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
        // the meaningful transit classes and longer runs first so one wrist
        // view never turns into thousands of MapKit overlays.
        let limit = detailed ? 1_400 : 1_100
        if visible.count > limit {
            visible.sort {
                let lhsPriority = Self.priority($0.style)
                let rhsPriority = Self.priority($1.style)
                if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
                return $0.extent > $1.extent
            }
            visible.removeLast(visible.count - limit)
        }

        return visible.compactMap { entry in
            let pointBytes = entry.pointCount * 8
            guard entry.pointsOffset >= 0,
                  entry.pointsOffset + pointBytes <= archive.file.buffer.count
            else { return nil }
            var coordinates: [WatchCoordinate] = []
            coordinates.reserveCapacity(entry.pointCount)
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
                coordinates.append(
                    WatchCoordinate(
                        latitude: BinaryFormat.decode(lat),
                        longitude: BinaryFormat.decode(lon)
                    )
                )
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
