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

        let group = Self.stationGroup(for: stop, register: stops)
        guard !group.stations.isEmpty else { return [] }
        let nowStamp = Int(now.timeIntervalSince1970)
        let journeys = timetable.journeys(
            callingAt: group.stations,
            key: group.stations.sorted().joined(separator: "|"),
            from: nowStamp - 2 * 60,
            to: nowStamp + 6 * 60 * 60,
            limit: 120,
            place: { ref in stops.lookup(ref) }
        )

        return journeys.compactMap { journey in
            guard let call = journey.stops.first(where: {
                guard let ref = $0.ref else { return false }
                return group.stations.contains(TimetableStore.station(ofSlotRef: ref))
                    && $0.dep >= nowStamp - 2 * 60
            }) else { return nil }
            let line = journey.line.trimmingCharacters(in: .whitespacesAndNewlines)
            return WatchStationDeparture(
                id: "\(journey.id)|\(call.dep)|\(call.ref ?? call.name)",
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

    func station(near coordinate: WatchCoordinate) throws -> WatchTransitStop? {
        if timetable == nil || stops == nil {
            guard try installedInfo() != nil else {
                throw WatchNationalArchiveFiles.ArchiveError.notInstalled
            }
        }
        guard let stops, coordinate.isValid else { return nil }
        let nearby = stops.near(
            lon: coordinate.longitude,
            lat: coordinate.latitude,
            metres: 160
        )
        guard let station = nearby.min(by: { lhs, rhs in
            Self.metres(
                from: coordinate,
                to: WatchCoordinate(latitude: lhs.lat, longitude: lhs.lon)
            ) < Self.metres(
                from: coordinate,
                to: WatchCoordinate(latitude: rhs.lat, longitude: rhs.lon)
            )
        }) else { return nil }
        return WatchTransitStop(
            id: "offline-station|\(station.id)",
            stationID: station.id,
            name: station.name,
            platform: nil,
            arrival: nil,
            departure: nil,
            delayMinutes: nil,
            coordinate: WatchCoordinate(latitude: station.lat, longitude: station.lon)
        )
    }

    /// Resolve a tapped platform, vehicle call or Apple Maps POI to the whole
    /// interchange. Nearby child names such as "Frutigen, Bahnhof" are folded
    /// into "Frutigen", while unrelated city stops remain separate.
    private static func stationGroup(
        for stop: WatchTransitStop,
        register: StopRegister
    ) -> (name: String, stations: Set<String>) {
        var stations = Set<String>()
        if let reference = stop.stationID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !reference.isEmpty {
            stations.insert(TimetableStore.station(ofSlotRef: reference))
        }

        guard let coordinate = stop.coordinate, coordinate.isValid else {
            return (stop.name, Set(stations.filter { !$0.isEmpty }))
        }

        let nearby = register.near(
            lon: coordinate.longitude,
            lat: coordinate.latitude,
            metres: 250
        )
        let parent = nearby.filter {
            partOfStation(stop.name, $0.name)
        }.min { lhs, rhs in
            if lhs.name.count != rhs.name.count { return lhs.name.count < rhs.name.count }
            return metres(
                from: coordinate,
                to: WatchCoordinate(latitude: lhs.lat, longitude: lhs.lon)
            ) < metres(
                from: coordinate,
                to: WatchCoordinate(latitude: rhs.lat, longitude: rhs.lon)
            )
        }
        let name = parent?.name ?? stop.name
        for registered in nearby where partOfStation(registered.name, name) {
            stations.insert(TimetableStore.station(ofSlotRef: registered.id))
        }
        return (name, Set(stations.filter { !$0.isEmpty }))
    }

    private static func sameStop(_ lhs: String, _ rhs: String) -> Bool {
        squash(lhs) == squash(rhs)
    }

    private static func squash(_ name: String) -> String {
        name.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US")
        ).filter { $0.isLetter || $0.isNumber }
    }

    private static func partOfStation(_ name: String, _ stationName: String) -> Bool {
        sameStop(name, stationName)
            || name.range(
                of: "\(stationName), ",
                options: [.anchored, .caseInsensitive]
            ) != nil
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
