import MapKit
import Observation
import SwiftUI

struct WatchHomeView: View {
    @Bindable var model: WatchTransitModel
    @Binding var navigationPath: NavigationPath
    @State private var isLocationFocused = false

    var body: some View {
        ZStack {
            WatchTransitMap(
                model: model,
                navigationPath: $navigationPath,
                isLocationFocused: $isLocationFocused
            )

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                HStack {
                    Button {
                        model.locate()
                    } label: {
                        WatchGlassIcon(
                            systemName: "location.fill",
                            tint: isLocationFocused ? .blue : nil,
                            isBusy: model.isLocating
                        )
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isLocating)
                    .accessibilityLabel("Show my location")

                    Spacer()
                    NavigationLink(value: WatchRoute.menu) {
                        WatchGlassIcon(systemName: "line.3.horizontal")
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open menu")
                }
            }
            // Match the native watch navigation inset: the visible 34-point
            // circles sit 13 points from both edges (eight points outside the
            // 44-point tap target plus five inside it). Keep this layer above
            // MapKit's attribution/help controls.
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .zIndex(100)
        }
        .ignoresSafeArea()
    }
}

/// Native MapKit with a flat, transit-focused base map and one tiny circle per vehicle.
/// Only dots in the visible camera are recomputed, at a watch-friendly 0.2 Hz.
/// The blue marker still comes from one foreground location fix, not tracking.
struct WatchTransitMap: View {
    @Bindable var model: WatchTransitModel
    @Binding var navigationPath: NavigationPath
    @Binding var isLocationFocused: Bool
    @State private var position: MapCameraPosition = .region(
        WatchViewport.switzerland.mapRegion
    )
    @State private var positionedFromSnapshot = false
    @State private var railLines: [WatchRailOverlayLine] = []
    @State private var railRequestRevision = 0
    @State private var routeGeometries: [String: WatchVehicleRouteGeometry] = [:]
    @State private var routeRequestRevision = 0
    @State private var registeredStops: [WatchTransitStop] = []
    @State private var registeredStopRequestRevision = 0
    @State private var registeredStopLookup: Task<Void, Never>?
    @State private var currentViewport = WatchViewport.switzerland
    @State private var nativeStationLookup: Task<Void, Never>?
    @State private var isMapVisible = false

    private var mapStops: [WatchMapStopTarget] {
        let width = abs(currentViewport.east - currentViewport.west)
        let height = abs(currentViewport.north - currentViewport.south)
        let span = max(width, height)
        guard span <= 0.85 else { return [] }

        // Rail stations appear from city scale onward. Bus kerbs and ferry
        // berths remain closer-only because they are considerably denser.
        let showsRailStops = span <= 0.14
        let showsLocalStops = span <= 0.035

        var unique: [String: WatchMapStopTarget] = [:]
        var knownModes: [String: String] = [:]
        for vehicle in model.snapshot.vehicles {
            for stop in vehicle.stops {
                let key = WatchStopPlaceIdentity.mapKey(for: stop.name)
                guard !key.isEmpty else { continue }
                if let held = knownModes[key] {
                    if WatchModeStyle.priority(for: vehicle.mode)
                        > WatchModeStyle.priority(for: held) {
                        knownModes[key] = vehicle.mode
                    }
                } else {
                    knownModes[key] = vehicle.mode
                }
            }
        }

        if showsLocalStops {
            for stop in registeredStops {
                guard let coordinate = stop.coordinate,
                      coordinate.isValid,
                      currentViewport.contains(coordinate)
                else { continue }
                let key = WatchStopPlaceIdentity.mapKey(for: stop.name)
                guard !key.isEmpty else { continue }
                unique[key] = WatchMapStopTarget(
                    id: key,
                    stop: stop,
                    coordinate: coordinate,
                    mode: knownModes[key] ?? "other"
                )
            }
        }

        for vehicle in model.snapshot.vehicles {
            if ["train", "metro"].contains(vehicle.mode.lowercased()),
               !showsRailStops {
                continue
            }
            if ["bus", "boat", "tram"].contains(vehicle.mode.lowercased()),
               !showsLocalStops {
                continue
            }
            for stop in vehicle.stops {
                guard let coordinate = stop.coordinate,
                      coordinate.isValid,
                      currentViewport.contains(coordinate)
                else { continue }

                // One target per passenger-facing stop place, never one per
                // platform, feed identifier or vehicle. Generic forecourts
                // such as "Bern, Bahnhof" share the railway parent's key;
                // "Bern, Obergericht" deliberately does not.
                let key = WatchStopPlaceIdentity.mapKey(for: stop.name)
                guard !key.isEmpty else { continue }
                let candidate = WatchMapStopTarget(
                    id: key,
                    stop: stop,
                    coordinate: coordinate,
                    mode: vehicle.mode
                )
                if let held = unique[key] {
                    if WatchModeStyle.priority(for: candidate.mode)
                        > WatchModeStyle.priority(for: held.mode) {
                        unique[key] = candidate
                    }
                } else {
                    unique[key] = candidate
                }
            }
        }

        let center = currentViewport.center
        return unique.values.sorted { lhs, rhs in
            lhs.coordinate.distanceSquared(to: center)
                < rhs.coordinate.distanceSquared(to: center)
        }
        .prefix(64)
        .map { $0 }
    }

    var body: some View {
        TimelineView(
            .periodic(from: .now, by: WatchTransitPolicy.mapPositionInterval)
        ) { timeline in
            map(at: timeline.date)
        }
    }

    private func map(at date: Date) -> some View {
        let visibleVehicles = visibleVehicles(at: date)
        return MapReader { proxy in
            Map(position: $position, interactionModes: [.pan, .zoom]) {
            ForEach(railLines) { line in
                MapPolyline(coordinates: line.coordinates.map(\.mapCoordinate))
                    .stroke(
                        line.style.color.opacity(0.72),
                        lineWidth: line.isDetailed ? 1.35 : 1
                    )
            }

            ForEach(mapStops) { target in
                Annotation("", coordinate: target.coordinate.mapCoordinate, anchor: .center) {
                    NavigationLink(value: WatchRoute.station(target.stop)) {
                        Circle()
                            .fill(.black.opacity(0.8))
                            .overlay {
                                Circle().stroke(
                                    WatchModeStyle.stopColor(for: target.mode),
                                    lineWidth: 1.5
                                )
                            }
                            .frame(width: 7, height: 7)
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(target.stop.name) departures")
                }
            }

            if let location = model.userLocation {
                Annotation(
                    "",
                    coordinate: CLLocationCoordinate2D(
                        latitude: location.latitude,
                        longitude: location.longitude
                    ),
                    anchor: .center
                ) {
                    Circle()
                        .fill(.blue)
                        .overlay {
                            Circle().stroke(.white, lineWidth: 2)
                        }
                        .frame(width: 11, height: 11)
                        .accessibilityLabel("My location")
                }
            }

            ForEach(visibleVehicles) { vehicle in
                Annotation(
                    "",
                    coordinate: CLLocationCoordinate2D(
                        latitude: vehicle.latitude,
                        longitude: vehicle.longitude
                    ),
                    anchor: .center
                ) {
                    NavigationLink(value: WatchRoute.vehicle(vehicle.id)) {
                        WatchVehicleDot(mode: vehicle.mode, diameter: 7)
                            .frame(width: 24, height: 24)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(vehicle.accessibilityName)
                }
            }
            }
            .mapStyle(WatchMapStyle.transit)
            .simultaneousGesture(
                SpatialTapGesture().onEnded { tap in
                    // Leave our own NavigationLink annotations alone. A tap on
                    // the native basemap instead resolves the nearest transit
                    // stop from the tapped coordinate.
                    guard !hitsCustomAnnotation(
                            tap.location,
                            proxy: proxy,
                            vehicles: visibleVehicles
                          ),
                          max(
                            abs(currentViewport.east - currentViewport.west),
                            abs(currentViewport.north - currentViewport.south)
                          ) <= 0.30,
                          let coordinate = proxy.convert(tap.location, from: .local)
                    else { return }
                    let point = WatchCoordinate(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    )
                    guard point.isValid else { return }
                    nativeStationLookup?.cancel()
                    nativeStationLookup = Task {
                        guard let stop = await model.station(near: point),
                              !Task.isCancelled,
                              isMapVisible
                        else { return }
                        // Native-map stops and all value-based links must use
                        // one path. Mixing navigationDestination(item:) with
                        // NavigationLink(value:) could re-push the station over
                        // the vehicle or Times screen selected by the user.
                        navigationPath.append(WatchRoute.station(stop))
                    }
                }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 4).onChanged { _ in
                    // Clear immediately when the wearer moves the camera. A
                    // zoom around the location can remain focused; the final
                    // camera callback below verifies the actual centre.
                    if isLocationFocused { isLocationFocused = false }
                }
            )
            .onAppear {
                isMapVisible = true
                adoptSnapshotViewportIfNeeded()
                isLocationFocused = locationIsCentered(in: currentViewport)
                refreshRailOverlay(
                    model.hasSnapshot ? model.snapshot.viewport : .switzerland
                )
                refreshVehicleRoutes(currentViewport)
                refreshRegisteredStops(currentViewport)
            }
            .onDisappear {
                isMapVisible = false
                nativeStationLookup?.cancel()
                nativeStationLookup = nil
                registeredStopLookup?.cancel()
                registeredStopLookup = nil
                registeredStopRequestRevision &+= 1
            }
            .onChange(of: model.snapshot.generatedAt) { _, _ in
                adoptSnapshotViewportIfNeeded()
                refreshRailOverlay(currentViewport)
                refreshVehicleRoutes(currentViewport)
                refreshRegisteredStops(currentViewport)
            }
            .onChange(of: date, initial: true) { _, date in
                guard isMapVisible else { return }
                model.refreshVisibleMapIfNeeded(at: date)
            }
            .onChange(of: model.locationFocusRevision) { _, _ in
                guard let viewport = model.locationViewport else { return }
                positionedFromSnapshot = true
                currentViewport = viewport
                position = .region(viewport.mapRegion)
                isLocationFocused = true
                model.updateViewport(viewport)
                refreshRailOverlay(viewport)
                refreshVehicleRoutes(viewport)
                refreshRegisteredStops(viewport)
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                let viewport = WatchViewport(mapRegion: context.region)
                currentViewport = viewport
                isLocationFocused = locationIsCentered(in: viewport)
                model.updateViewport(viewport)
                refreshRailOverlay(viewport)
                refreshVehicleRoutes(viewport)
                refreshRegisteredStops(viewport)
            }
        }
    }

    private func locationIsCentered(in viewport: WatchViewport) -> Bool {
        guard let location = model.userLocation else { return false }
        let latitudeSpan = max(0.000_001, abs(viewport.north - viewport.south))
        let longitudeSpan = max(0.000_001, abs(viewport.east - viewport.west))
        let center = viewport.center

        // A marker within the central tenth of the screen still reads as
        // centred. Moving beyond it turns the tint off without treating a
        // location-centred zoom as a pan-away.
        return abs(center.latitude - location.latitude) <= latitudeSpan * 0.05
            && abs(center.longitude - location.longitude) <= longitudeSpan * 0.05
    }

    private func visibleVehicles(at date: Date) -> [WatchTransitVehicle] {
        let visibleArea = currentViewport
        let span = max(
            abs(currentViewport.east - currentViewport.west),
            abs(currentViewport.north - currentViewport.south)
        )
        let usesDetailedRoutes = span < 0.35
        let positioned = model.snapshot.vehicles.compactMap {
            vehicle -> WatchTransitVehicle? in
            guard let fallback = vehicle.positioned(at: date) else { return nil }

            let fallbackCoordinate = WatchCoordinate(
                latitude: fallback.latitude,
                longitude: fallback.longitude
            )
            let fallbackIsVisible = visibleArea.contains(fallbackCoordinate)

            guard usesDetailedRoutes,
                  let geometry = routeGeometries[vehicle.id],
                  let routed = vehicle.positioned(at: date, geometry: geometry)
            else { return fallbackIsVisible ? fallback : nil }

            let routedCoordinate = WatchCoordinate(
                latitude: routed.latitude,
                longitude: routed.longitude
            )
            let routedIsVisible = visibleArea.contains(routedCoordinate)
            // Loading detailed OSM geometry must not make a dot that was
            // already on-screen disappear. Relation archives can briefly be
            // stale while the camera changes, and an imperfect relation match
            // can put the routed point just outside a tight viewport. Prefer
            // the route whenever it remains visible; otherwise retain the
            // stop-to-stop timetable interpolation for this frame.
            if routedIsVisible { return routed }
            return fallbackIsVisible ? fallback : nil
        }
        return thinningOverlaps(positioned, in: visibleArea)
    }

    /// A 7-point dot cannot be distinguished or tapped separately from another
    /// dot only a few points away. Keep one representative per tiny visual cell
    /// before MapKit creates annotation views; this is both clearer and cheaper
    /// in dense station throats.
    private func thinningOverlaps(
        _ vehicles: [WatchTransitVehicle],
        in viewport: WatchViewport
    ) -> [WatchTransitVehicle] {
        struct Cell: Hashable { var column: Int; var row: Int }

        let west = min(viewport.west, viewport.east)
        let south = min(viewport.south, viewport.north)
        let width = max(0.000_001, abs(viewport.east - viewport.west))
        let height = max(0.000_001, abs(viewport.north - viewport.south))
        let span = max(width, height)
        // Thin much more aggressively at regional zoom. Individual tracks and
        // vehicles cannot be distinguished there, and a few dozen MapKit
        // annotation views are considerably cheaper than the full service set.
        let density: (columns: Double, rows: Double, limit: Int)
        switch span {
        case 1.0...:
            density = (7, 8, 40)
        case 0.35 ..< 1.0:
            density = (10, 12, 64)
        case 0.12 ..< 0.35:
            density = (14, 16, 88)
        default:
            // Roughly 9–11 points per cell on current watch displays: smaller
            // than the tap target, but enough to remove true overlaps.
            density = (22, 26, 112)
        }
        var held: [Cell: WatchTransitVehicle] = [:]

        for vehicle in vehicles {
            let cell = Cell(
                column: Int(
                    ((vehicle.longitude - west) / width * density.columns).rounded(.down)
                ),
                row: Int(
                    ((vehicle.latitude - south) / height * density.rows).rounded(.down)
                )
            )
            if let existing = held[cell] {
                let candidatePriority = WatchModeStyle.priority(for: vehicle.mode)
                let existingPriority = WatchModeStyle.priority(for: existing.mode)
                if candidatePriority > existingPriority
                    || (candidatePriority == existingPriority && vehicle.id < existing.id) {
                    held[cell] = vehicle
                }
            } else {
                held[cell] = vehicle
            }
        }
        // Apply the global cap after sorting, otherwise the service's input
        // order can fill the budget with buses before trains are considered.
        let center = viewport.center
        let selected = held.values.sorted { lhs, rhs in
            let lhsPriority = WatchModeStyle.priority(for: lhs.mode)
            let rhsPriority = WatchModeStyle.priority(for: rhs.mode)
            if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
            let lhsDistance = WatchCoordinate(
                latitude: lhs.latitude,
                longitude: lhs.longitude
            ).distanceSquared(to: center)
            let rhsDistance = WatchCoordinate(
                latitude: rhs.latitude,
                longitude: rhs.longitude
            ).distanceSquared(to: center)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.id < rhs.id
        }
        .prefix(density.limit)
        .map { $0 }

        // Budget selection above is train-first. Drawing is deliberately the
        // reverse: MapKit paints later annotations over earlier ones, so buses
        // go down first and trains remain visible wherever tap targets overlap.
        return selected.sorted { lhs, rhs in
            let lhsPriority = WatchModeStyle.priority(for: lhs.mode)
            let rhsPriority = WatchModeStyle.priority(for: rhs.mode)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            let lhsDistance = WatchCoordinate(
                latitude: lhs.latitude,
                longitude: lhs.longitude
            ).distanceSquared(to: center)
            let rhsDistance = WatchCoordinate(
                latitude: rhs.latitude,
                longitude: rhs.longitude
            ).distanceSquared(to: center)
            if lhsDistance != rhsDistance { return lhsDistance > rhsDistance }
            return lhs.id > rhs.id
        }
    }

    private func hitsCustomAnnotation(
        _ point: CGPoint,
        proxy: MapProxy,
        vehicles: [WatchTransitVehicle]
    ) -> Bool {
        for stop in mapStops {
            if let target = proxy.convert(stop.coordinate.mapCoordinate, to: .local),
               hypot(target.x - point.x, target.y - point.y) <= 18 {
                return true
            }
        }
        for vehicle in vehicles {
            let coordinate = CLLocationCoordinate2D(
                latitude: vehicle.latitude,
                longitude: vehicle.longitude
            )
            if let target = proxy.convert(coordinate, to: .local),
               hypot(target.x - point.x, target.y - point.y) <= 15 {
                return true
            }
        }
        return false
    }

    private func adoptSnapshotViewportIfNeeded() {
        guard !positionedFromSnapshot, model.hasSnapshot else { return }
        positionedFromSnapshot = true
        currentViewport = model.snapshot.viewport
        position = .region(model.snapshot.viewport.mapRegion)
        model.updateViewport(model.snapshot.viewport)
    }

    private func refreshRailOverlay(_ viewport: WatchViewport) {
        railRequestRevision &+= 1
        let revision = railRequestRevision
        Task {
            let loaded = await WatchRailOverlayStore.shared.lines(in: viewport)
            guard revision == railRequestRevision else { return }
            railLines = loaded
        }
    }

    private func refreshVehicleRoutes(_ viewport: WatchViewport) {
        routeRequestRevision &+= 1
        let revision = routeRequestRevision
        let span = max(
            abs(viewport.east - viewport.west),
            abs(viewport.north - viewport.south)
        )
        // At regional scale, following a detailed OSM path is sub-pixel work.
        // Avoid route archive searches and polyline interpolation until the
        // user zooms close enough to see the difference. Keep already loaded
        // geometry in memory, though, so zooming back in cannot make a vehicle
        // jump to its chord while the archive is queried again.
        guard span < 0.35 else {
            return
        }
        let area = viewport.padded(by: 0.2)
        let now = Date()
        let positioned = model.snapshot.vehicles.compactMap { vehicle -> WatchTransitVehicle? in
            let fallback = vehicle.positioned(at: now)
            let routed = routeGeometries[vehicle.id].flatMap {
                vehicle.positioned(at: now, geometry: $0)
            }
            if let routed,
               area.contains(WatchCoordinate(
                latitude: routed.latitude,
                longitude: routed.longitude
               )) {
                return routed
            }
            if let fallback,
               area.contains(WatchCoordinate(
                latitude: fallback.latitude,
                longitude: fallback.longitude
               )) {
                return fallback
            }
            return nil
        }
        let center = area.center
        let candidateIDs = Set(positioned.sorted { lhs, rhs in
            let lhsPriority = WatchModeStyle.priority(for: lhs.mode)
            let rhsPriority = WatchModeStyle.priority(for: rhs.mode)
            if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
            let lhsDistance = WatchCoordinate(
                latitude: lhs.latitude,
                longitude: lhs.longitude
            ).distanceSquared(to: center)
            let rhsDistance = WatchCoordinate(
                latitude: rhs.latitude,
                longitude: rhs.longitude
            ).distanceSquared(to: center)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.id < rhs.id
        }.prefix(48).map(\.id))
        let candidates = model.snapshot.vehicles.filter {
            candidateIDs.contains($0.id)
        }
        let vehiclesByID = Dictionary(
            uniqueKeysWithValues: model.snapshot.vehicles.map { ($0.id, $0) }
        )
        let protectedGeometries = routeGeometries.filter { id, geometry in
            guard let vehicle = vehiclesByID[id],
                  let routed = vehicle.mapPosition(at: now, geometry: geometry)
            else { return false }
            return area.contains(routed)
        }
        Task {
            let loaded = await WatchRouteGeometryStore.shared.geometries(
                for: Array(candidates)
            )
            guard revision == routeRequestRevision else { return }
            // Never evict geometry that is positioning an on-screen vehicle.
            // It may not be among the 48 new archive candidates after the
            // viewport grid changes, but losing it would move the dot back to
            // its chord and make it appear to vanish during this gesture.
            routeGeometries = loaded.merging(protectedGeometries) {
                loaded, _ in loaded
            }
        }
    }

    private func refreshRegisteredStops(_ viewport: WatchViewport) {
        registeredStopLookup?.cancel()
        registeredStopLookup = nil
        registeredStopRequestRevision &+= 1
        let revision = registeredStopRequestRevision
        let span = max(
            abs(viewport.east - viewport.west),
            abs(viewport.north - viewport.south)
        )
        guard span <= 0.035 else {
            registeredStops = []
            return
        }

        registeredStopLookup = Task {
            // Camera-end already limits this work to settled gestures. A tiny
            // debounce also collapses the snapshot/camera callbacks that can
            // arrive together after a refresh.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let loaded = await model.mapStops(in: viewport)
            guard !Task.isCancelled,
                  revision == registeredStopRequestRevision
            else { return }
            registeredStops = loaded
            registeredStopLookup = nil
        }
    }
}

enum WatchMapStyle {
    /// MapKit does not expose the Maps app's Transit mode. Showing only public
    /// transport POIs gives the watch its closest native, lightweight equivalent.
    static var transit: MapStyle {
        .standard(
            elevation: .flat,
            emphasis: .automatic,
            pointsOfInterest: .including(.publicTransport),
            showsTraffic: false
        )
    }
}

struct WatchVehicleDot: View {
    let mode: String
    var diameter: CGFloat = 8

    var body: some View {
        Circle()
            .fill(WatchModeStyle.color(for: mode))
            .overlay {
                Circle().stroke(
                    .black.opacity(0.28),
                    lineWidth: max(0.55, diameter * 0.085)
                )
            }
            .frame(width: diameter, height: diameter)
    }
}

enum WatchModeStyle {
    static func color(for mode: String) -> Color {
        switch mode.lowercased() {
        case "train": return .red
        case "tram": return Color(red: 0.20, green: 0.78, blue: 0.35)
        case "bus": return Color(red: 0.04, green: 0.52, blue: 1.00)
        case "metro": return .purple
        case "boat": return Color(red: 0.31, green: 0.78, blue: 1.00)
        case "cable": return .yellow
        default: return .white
        }
    }

    static func symbol(for mode: String) -> String {
        switch mode.lowercased() {
        case "train": return "train.side.front.car"
        case "tram": return "tram.fill"
        case "bus": return "bus.fill"
        case "metro": return "train.side.front.car"
        case "boat": return "ferry.fill"
        case "cable": return "cablecar.fill"
        default: return "circle.fill"
        }
    }

    static func stopColor(for mode: String) -> Color {
        switch mode.lowercased() {
        case "train": return .red
        case "boat": return Color(red: 0.31, green: 0.78, blue: 1.00)
        default: return .white
        }
    }

    static func priority(for mode: String) -> Int {
        WatchModeRenderPriority.value(for: mode)
    }
}

extension WatchViewport {
    var mapRegion: MKCoordinateRegion {
        let lowLatitude = min(south, north)
        let highLatitude = max(south, north)
        let lowLongitude = min(west, east)
        let highLongitude = max(west, east)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (lowLatitude + highLatitude) / 2,
                longitude: (lowLongitude + highLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: min(180, max(0.01, highLatitude - lowLatitude)),
                longitudeDelta: min(360, max(0.01, highLongitude - lowLongitude))
            )
        )
    }

    init(mapRegion region: MKCoordinateRegion) {
        let halfLatitude = region.span.latitudeDelta / 2
        let halfLongitude = region.span.longitudeDelta / 2
        self.init(
            west: region.center.longitude - halfLongitude,
            south: region.center.latitude - halfLatitude,
            east: region.center.longitude + halfLongitude,
            north: region.center.latitude + halfLatitude
        )
    }
}

extension WatchCoordinate {
    var mapCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }


    func distanceSquared(to other: WatchCoordinate) -> Double {
        let latitudeDistance = latitude - other.latitude
        let longitudeDistance = longitude - other.longitude
        return latitudeDistance * latitudeDistance + longitudeDistance * longitudeDistance
    }
}

private struct WatchMapStopTarget: Identifiable {
    var id: String
    var stop: WatchTransitStop
    var coordinate: WatchCoordinate
    var mode: String
}

extension WatchTransitVehicle {
    var accessibilityName: String {
        let service = line.isEmpty ? mode.capitalized : line
        if let destination, !destination.isEmpty {
            return "\(service) to \(destination)"
        }
        return service
    }
}
