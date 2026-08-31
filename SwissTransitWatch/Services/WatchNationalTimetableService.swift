import Foundation

struct WatchNationalTimetableInfo: Equatable, Sendable {
    var installedAt: Date
    var validFrom: Date
    var validUntil: Date
    var byteCount: Int64
}

/// Owns the optional full-country archive. Both files are memory-mapped/read in
/// place; the watch never expands the year's timetable into an object graph.
actor WatchNationalTimetableService {
    static let approximateDownloadBytes: Int64 = 124 * 1_024 * 1_024
    private var timetable: TimetableStore?
    private var stops: StopRegister?
    private var info: WatchNationalTimetableInfo?

    func installedInfo() throws -> WatchNationalTimetableInfo? {
        if let info { return info }
        guard WatchNationalArchiveFiles.fileManager.fileExists(
            atPath: WatchNationalArchiveFiles.timetableURL.path
        ), WatchNationalArchiveFiles.fileManager.fileExists(
            atPath: WatchNationalArchiveFiles.stopsURL.path
        )
        else { return nil }
        return try loadInstalledArchive()
    }

    func downloadAndInstall() async throws {
        try await WatchTimetableDownloadCoordinator.shared.startAndWait()
        timetable = nil
        stops = nil
        info = nil
    }

    static func handleBackgroundSessionEvents() async {
        await WatchTimetableDownloadCoordinator.shared.waitForBackgroundEvents()
    }

    func downloadIsActive() async -> Bool {
        await WatchTimetableDownloadCoordinator.shared.isActive()
    }

    func removeInstalledArchive() throws {
        timetable = nil
        stops = nil
        info = nil
        let files = WatchNationalArchiveFiles.self
        if files.fileManager.fileExists(atPath: files.timetableURL.path) {
            try files.fileManager.removeItem(at: files.timetableURL)
        }
        if files.fileManager.fileExists(atPath: files.stopsURL.path) {
            try files.fileManager.removeItem(at: files.stopsURL)
        }
    }

    func snapshot(
        viewport: WatchViewport,
        at now: Date = Date()
    ) throws -> WatchTransitSnapshot {
        if timetable == nil || stops == nil {
            guard try installedInfo() != nil else {
                throw WatchNationalArchiveFiles.ArchiveError.notInstalled
            }
        }
        guard let timetable, let stops else {
            throw WatchNationalArchiveFiles.ArchiveError.notInstalled
        }

        let moment = Int(now.timeIntervalSince1970)
        let region = BBox(
            west: min(viewport.west, viewport.east),
            south: min(viewport.south, viewport.north),
            east: max(viewport.west, viewport.east),
            north: max(viewport.south, viewport.north)
        )
        let journeys = timetable.journeys(
            from: moment,
            to: moment,
            limit: 4_000,
            in: region,
            place: { ref in stops.lookup(ref) }
        )
        let visibleRegion = region.padded(by: 0.25)
        let vehicles = journeys.compactMap { Self.vehicle(from: $0, at: moment) }
            .filter {
                visibleRegion.contains(lon: $0.longitude, lat: $0.latitude)
            }
            .sorted { lhs, rhs in
                if lhs.mode != rhs.mode { return lhs.mode < rhs.mode }
                if lhs.line != rhs.line {
                    return lhs.line.localizedStandardCompare(rhs.line) == .orderedAscending
                }
                return lhs.id < rhs.id
            }
            .prefix(160)

        return WatchTransitSnapshot(
            generatedAt: now,
            sourceUpdatedAt: info?.installedAt,
            viewport: viewport,
            vehicles: Array(vehicles)
        )
    }

    func stationBoard(
        for stop: WatchTransitStop,
        at now: Date = Date()
    ) throws -> [WatchStationDeparture] {
        if timetable == nil || stops == nil {
            guard try installedInfo() != nil else {
                throw WatchNationalArchiveFiles.ArchiveError.notInstalled
            }
        }
        guard let timetable, let stops else {
            throw WatchNationalArchiveFiles.ArchiveError.notInstalled
        }

        let station = stop.stationID.map(TimetableStore.station(ofSlotRef:))
        guard let station, !station.isEmpty else { return [] }
        let nowStamp = Int(now.timeIntervalSince1970)
        let journeys = timetable.journeys(
            callingAt: [station],
            key: station,
            from: nowStamp - 2 * 60,
            to: nowStamp + 6 * 60 * 60,
            limit: 80,
            place: { ref in stops.lookup(ref) }
        )

        return journeys.compactMap { journey in
            guard let call = journey.stops.first(where: {
                guard let ref = $0.ref else { return false }
                return TimetableStore.station(ofSlotRef: ref) == station
                    && $0.dep >= nowStamp - 2 * 60
            }) else { return nil }
            let line = journey.line.trimmingCharacters(in: .whitespacesAndNewlines)
            return WatchStationDeparture(
                id: journey.id,
                mode: journey.mode.rawValue,
                line: line.isEmpty ? (journey.number ?? journey.mode.rawValue.capitalized) : line,
                destination: journey.to ?? "—",
                departure: Date(timeIntervalSince1970: TimeInterval(call.dep)),
                platform: call.platform ?? call.assigned,
                delayMinutes: call.delay
            )
        }
        .sorted { $0.departure < $1.departure }
        .prefix(30)
        .map { $0 }
    }

    private func loadInstalledArchive() throws -> WatchNationalTimetableInfo {
        try WatchNationalArchiveFiles.validateInstalledArchive()

        let loadedStops = StopRegister()
        try loadedStops.load(
            stopsFile: WatchNationalArchiveFiles.stopsURL,
            foreignFile: nil
        )
        let loadedTimetable = try TimetableStore(
            url: WatchNationalArchiveFiles.timetableURL
        )
        guard let span = loadedTimetable.span() else {
            throw WatchNationalArchiveFiles.ArchiveError.invalidArchive
        }

        let timetableSize = try WatchNationalArchiveFiles.fileSize(
            WatchNationalArchiveFiles.timetableURL
        )
        let stopsSize = try WatchNationalArchiveFiles.fileSize(
            WatchNationalArchiveFiles.stopsURL
        )
        let attributes = try WatchNationalArchiveFiles.fileManager.attributesOfItem(
            atPath: WatchNationalArchiveFiles.timetableURL.path
        )
        let installedAt = attributes[.modificationDate] as? Date ?? Date()
        let loadedInfo = WatchNationalTimetableInfo(
            installedAt: installedAt,
            validFrom: Date(timeIntervalSince1970: TimeInterval(span.lowerBound)),
            validUntil: Date(timeIntervalSince1970: TimeInterval(span.upperBound)),
            byteCount: timetableSize + stopsSize
        )

        stops = loadedStops
        timetable = loadedTimetable
        info = loadedInfo
        return loadedInfo
    }

    private static func vehicle(from journey: Journey, at now: Int) -> WatchTransitVehicle? {
        let calls = journey.stops.filter {
            ($0.lat != 0 || $0.lon != 0)
                && $0.lat.isFinite && $0.lon.isFinite
                && (-90 ... 90).contains($0.lat)
                && (-180 ... 180).contains($0.lon)
        }
        guard calls.count >= 2,
              now >= calls[0].arr - 5 * 60,
              now <= calls[calls.count - 1].dep + 2 * 60
        else { return nil }

        let position: (lat: Double, lon: Double, delay: Int?)
        if now <= calls[0].dep {
            position = (calls[0].lat, calls[0].lon, calls[0].delay)
        } else if let found = positionBetweenCalls(calls, at: now) {
            position = found
        } else if let last = calls.last {
            position = (last.lat, last.lon, last.delay)
        } else {
            return nil
        }

        let line = journey.line.trimmingCharacters(in: .whitespacesAndNewlines)
        let stops = calls.map { call in
            WatchTransitStop(
                id: call.key,
                stationID: call.ref,
                name: call.name,
                platform: call.platform ?? call.assigned,
                arrival: Date(timeIntervalSince1970: TimeInterval(call.arr)),
                departure: Date(timeIntervalSince1970: TimeInterval(call.dep)),
                delayMinutes: call.delay,
                coordinate: WatchCoordinate(latitude: call.lat, longitude: call.lon)
            )
        }
        return WatchTransitVehicle(
            id: journey.id,
            mode: journey.mode.rawValue,
            line: line.isEmpty ? (journey.number ?? journey.mode.rawValue.capitalized) : line,
            destination: journey.to,
            origin: journey.from,
            operatorName: journey.operatorName,
            delayMinutes: position.delay,
            latitude: position.lat,
            longitude: position.lon,
            stops: stops
        )
    }

    private static func positionBetweenCalls(
        _ calls: [Call],
        at now: Int
    ) -> (lat: Double, lon: Double, delay: Int?)? {
        for index in 0 ..< calls.count - 1 {
            let current = calls[index]
            let next = calls[index + 1]
            if now <= current.dep {
                return (current.lat, current.lon, current.delay)
            }
            if now <= next.arr {
                let duration = max(1, next.arr - current.dep)
                let progress = min(1, max(0, Double(now - current.dep) / Double(duration)))
                return (
                    current.lat + (next.lat - current.lat) * progress,
                    current.lon + (next.lon - current.lon) * progress,
                    current.delay ?? next.delay
                )
            }
        }
        return nil
    }
}
