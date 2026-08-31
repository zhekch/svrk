import CoreLocation
import Foundation
import Observation

/// Standalone watch runtime: one foreground location fix, then either the
/// optional memory-mapped national archive or a few compact HTTPS requests.
/// No phone session, background polling or live location tracking is kept alive.
@MainActor
@Observable
final class WatchTransitModel: NSObject {
    static let staleInterval = WatchTransitPolicy.staleInterval

    private(set) var snapshot: WatchTransitSnapshot
    private(set) var isRefreshing = false
    private(set) var isLocating = false
    private(set) var isDownloadingFullTimetable = false
    private(set) var lastError: String?
    private(set) var userLocation: WatchCoordinate?
    private(set) var locationAuthorization: CLAuthorizationStatus
    private(set) var locationFocusRevision = 0
    private(set) var nationalTimetableInfo: WatchNationalTimetableInfo?

    @ObservationIgnored private let onlineService: WatchStandaloneTransitService
    @ObservationIgnored private let nationalService: WatchNationalTimetableService
    @ObservationIgnored private let locationManager: CLLocationManager
    @ObservationIgnored private var currentViewport: WatchViewport
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private var pendingLocationFocus = false
    @ObservationIgnored private var pendingLocationRefresh = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var fullDownloadTask: Task<Void, Never>?
    @ObservationIgnored private var nationalInfoTask: Task<Void, Never>?
    @ObservationIgnored private var locationTimeoutTask: Task<Void, Never>?

    private static let cacheKey = "watch.transit.snapshot.v3"

    override init() {
        let manager = CLLocationManager()
        let cached = Self.loadCachedSnapshot() ?? .empty
        onlineService = WatchStandaloneTransitService()
        nationalService = WatchNationalTimetableService()
        locationManager = manager
        locationAuthorization = manager.authorizationStatus
        snapshot = cached
        currentViewport = cached.viewport
        super.init()

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 250
    }

    var hasSnapshot: Bool {
        snapshot.generatedAt != .distantPast
    }

    var isSnapshotStale: Bool {
        guard hasSnapshot else { return true }
        return Date().timeIntervalSince(snapshot.generatedAt) >= Self.staleInterval
    }

    var vehicleCount: Int {
        snapshot.vehicles.count
    }

    var locationViewport: WatchViewport? {
        userLocation.map(WatchViewport.near)
    }

    var locationStatusText: String {
        if isLocating { return "Locating" }
        switch locationAuthorization {
        case .authorizedAlways, .authorizedWhenInUse:
            return userLocation == nil ? "Ready" : "One-shot"
        case .notDetermined:
            return "Not requested"
        case .denied, .restricted:
            return "Off"
        @unknown default:
            return "Unavailable"
        }
    }

    var fullTimetableStatus: String {
        if isDownloadingFullTimetable { return "Downloading…" }
        guard let nationalTimetableInfo else { return "Not downloaded" }
        let megabytes = max(1, nationalTimetableInfo.byteCount / 1_000_000)
        return "Downloaded · \(megabytes) MB"
    }

    var fullTimetableValidity: String? {
        nationalTimetableInfo?.validUntil.formatted(
            date: .abbreviated,
            time: .omitted
        )
    }

    func enterForeground() {
        guard !isForeground else { return }
        isForeground = true
        loadNationalTimetableInfo()

        if let location = locationManager.location,
           location.horizontalAccuracy >= 0,
           Date().timeIntervalSince(location.timestamp) <= Self.staleInterval {
            accept(
                coordinate: WatchCoordinate(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                ),
                forceFocus: !hasSnapshot,
                forceRefresh: isSnapshotStale
            )
            return
        }

        pendingLocationFocus = !hasSnapshot
        pendingLocationRefresh = isSnapshotStale
        requestSingleLocation()
    }

    func leaveForeground() {
        isForeground = false
        refreshTask?.cancel()
        refreshTask = nil
        nationalInfoTask?.cancel()
        nationalInfoTask = nil
        locationTimeoutTask?.cancel()
        locationTimeoutTask = nil
        locationManager.stopUpdatingLocation()
        isRefreshing = false
        isDownloadingFullTimetable = false
        isLocating = false
        pendingLocationFocus = false
        pendingLocationRefresh = false
    }

    /// Fetches around the currently visible map centre. It never starts a
    /// continuous location session.
    func refresh() {
        lastError = nil
        let target = normalizedRefreshViewport(currentViewport)
        startRefresh(near: target.center, viewport: target)
    }

    /// Requests one fresh foreground fix, recentres the map and updates the
    /// small nearby cache. Core Location is idle again after the callback.
    func locate() {
        lastError = nil
        pendingLocationFocus = true
        pendingLocationRefresh = true
        requestSingleLocation()
    }

    /// Downloads the full packed Swiss timetable and stop register. The files
    /// stay on the watch and replace network requests until their service year
    /// ends. This is always a deliberate user action because it is about 124 MB.
    func downloadFullTimetable() {
        guard isForeground, !isDownloadingFullTimetable else { return }
        lastError = nil
        let target = normalizedRefreshViewport(currentViewport)
        isDownloadingFullTimetable = true

        fullDownloadTask?.cancel()
        fullDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await nationalService.downloadAndInstall()
                try Task.checkCancellation()
                guard isForeground else {
                    isDownloadingFullTimetable = false
                    return
                }
                guard let info = try await nationalService.installedInfo() else {
                    throw WatchNationalArchiveFiles.ArchiveError.notInstalled
                }
                nationalTimetableInfo = info
                let nationalSnapshot = try await nationalService.snapshot(viewport: target)
                snapshot = Self.validated(snapshot: nationalSnapshot)
                currentViewport = target
                persist(snapshot: snapshot)
                lastError = nil
            } catch is CancellationError {
                // The partial staged file is discarded by the download service.
            } catch {
                lastError = error.localizedDescription
            }
            if !Task.isCancelled {
                isDownloadingFullTimetable = false
            }
        }
    }

    /// Panning only changes the centre used by a later manual refresh.
    func updateViewport(_ viewport: WatchViewport) {
        guard viewport.center.isValid else { return }
        currentViewport = viewport
    }

    /// Loaded only after a stop is tapped. No board polling or background work
    /// is kept alive after the full-screen station page disappears.
    func stationBoard(for stop: WatchTransitStop) async throws -> [WatchStationDeparture] {
        let now = Date()
        if let info = try? await nationalService.installedInfo(),
           (info.validFrom ... info.validUntil).contains(now),
           stop.stationID != nil {
            return try await nationalService.stationBoard(for: stop, at: now)
        }
        return try await onlineService.stationBoard(for: stop, at: now)
    }

    private func requestSingleLocation() {
        guard isForeground else { return }
        locationAuthorization = locationManager.authorizationStatus

        switch locationAuthorization {
        case .notDetermined:
            isLocating = true
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            isLocating = true
            locationManager.requestLocation()
            startLocationTimeout()
        case .denied, .restricted:
            finishLocationWithoutFix(message: "Location is off; using the map centre.")
        @unknown default:
            finishLocationWithoutFix(message: "Location is unavailable; using the map centre.")
        }
    }

    private func startLocationTimeout() {
        locationTimeoutTask?.cancel()
        locationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finishLocationWithoutFix(message: "Location timed out; using the map centre.")
        }
    }

    private func accept(
        coordinate: WatchCoordinate,
        forceFocus: Bool = false,
        forceRefresh: Bool = false
    ) {
        guard coordinate.isValid else {
            finishLocationWithoutFix(message: "Location was invalid; using the map centre.")
            return
        }

        locationTimeoutTask?.cancel()
        locationTimeoutTask = nil
        let isOutsideCache = !hasSnapshot || !snapshot.viewport.contains(coordinate)
        let shouldFocus = forceFocus || pendingLocationFocus || isOutsideCache
        let shouldRefresh = forceRefresh || pendingLocationRefresh
            || isSnapshotStale || isOutsideCache

        userLocation = coordinate
        isLocating = false
        pendingLocationFocus = false
        pendingLocationRefresh = false

        let viewport = WatchViewport.near(coordinate)
        if shouldFocus {
            currentViewport = viewport
            locationFocusRevision &+= 1
        }
        if shouldRefresh {
            startRefresh(near: coordinate, viewport: viewport)
        }
    }

    private func finishLocationWithoutFix(message: String) {
        locationTimeoutTask?.cancel()
        locationTimeoutTask = nil
        isLocating = false
        let shouldRefresh = pendingLocationRefresh || isSnapshotStale
        let shouldFocus = pendingLocationFocus && !hasSnapshot
        pendingLocationFocus = false
        pendingLocationRefresh = false

        if shouldRefresh {
            let target = normalizedRefreshViewport(currentViewport, focus: shouldFocus)
            startRefresh(near: target.center, viewport: target)
        } else {
            lastError = message
        }
    }

    private func normalizedRefreshViewport(
        _ viewport: WatchViewport,
        focus: Bool = false
    ) -> WatchViewport {
        let latitudeSpan = abs(viewport.north - viewport.south)
        let longitudeSpan = abs(viewport.east - viewport.west)
        guard latitudeSpan > 1 || longitudeSpan > 1 else { return viewport }

        let nearby = WatchViewport.near(viewport.center)
        currentViewport = nearby
        if focus || !hasSnapshot {
            locationFocusRevision &+= 1
        }
        return nearby
    }

    private func startRefresh(near coordinate: WatchCoordinate, viewport: WatchViewport) {
        guard isForeground, coordinate.isValid else { return }
        refreshTask?.cancel()
        isRefreshing = true
        lastError = nil

        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let now = Date()
                let archiveInfo = try? await nationalService.installedInfo()
                let incoming: WatchTransitSnapshot
                if let archiveInfo,
                   (archiveInfo.validFrom ... archiveInfo.validUntil).contains(now) {
                    nationalTimetableInfo = archiveInfo
                    incoming = try await nationalService.snapshot(viewport: viewport, at: now)
                } else {
                    incoming = try await onlineService.snapshot(
                        near: coordinate,
                        viewport: viewport,
                        at: now
                    )
                }
                try Task.checkCancellation()
                snapshot = Self.validated(snapshot: incoming)
                currentViewport = incoming.viewport
                persist(snapshot: snapshot)
                lastError = nil
            } catch is CancellationError {
                // Wrist-down cancels radio and parsing work without surfacing an error.
            } catch {
                lastError = error.localizedDescription
            }
            if !Task.isCancelled {
                isRefreshing = false
            }
        }
    }

    private func persist(snapshot: WatchTransitSnapshot) {
        guard let data = try? WatchTransitPayload.encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    private static func loadCachedSnapshot() -> WatchTransitSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? WatchTransitPayload.decode(data),
              decoded.isUsable
        else { return nil }
        return validated(snapshot: decoded)
    }

    private func loadNationalTimetableInfo() {
        nationalInfoTask?.cancel()
        nationalInfoTask = Task { [weak self] in
            guard let self else { return }
            isDownloadingFullTimetable = await nationalService.downloadIsActive()
            nationalTimetableInfo = try? await nationalService.installedInfo()
        }
    }

    private static func validated(snapshot: WatchTransitSnapshot) -> WatchTransitSnapshot {
        var snapshot = snapshot
        snapshot.vehicles = Array(snapshot.vehicles.lazy.filter {
            WatchCoordinate(latitude: $0.latitude, longitude: $0.longitude).isValid
        }.prefix(160))
        return snapshot
    }
}

extension WatchTransitModel: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            locationAuthorization = status
            guard isForeground else { return }
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                requestSingleLocation()
            case .denied, .restricted:
                finishLocationWithoutFix(message: "Location is off; using the map centre.")
            case .notDetermined:
                break
            @unknown default:
                finishLocationWithoutFix(message: "Location is unavailable; using the map centre.")
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        let coordinate = WatchCoordinate(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        Task { @MainActor [weak self] in
            self?.accept(coordinate: coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message: String
        if let coreLocationError = error as? CLError,
           coreLocationError.code == .denied {
            message = "Location is off; using the map centre."
        } else {
            message = "Could not get a location; using the map centre."
        }
        Task { @MainActor [weak self] in
            self?.finishLocationWithoutFix(message: message)
        }
    }
}
