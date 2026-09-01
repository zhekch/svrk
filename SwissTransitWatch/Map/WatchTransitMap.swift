import MapKit
import Observation
import SwiftUI

struct WatchHomeView: View {
    @Bindable var model: WatchTransitModel

    var body: some View {
        ZStack {
            WatchTransitMap(model: model)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                HStack {
                    Button {
                        model.locate()
                    } label: {
                        WatchGlassIcon(
                            systemName: "location.fill",
                            tint: .blue,
                            isBusy: model.isLocating
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isLocating)
                    .accessibilityLabel("Show my location")

                    Spacer()
                    NavigationLink(value: WatchRoute.menu) {
                        WatchGlassIcon(systemName: "line.3.horizontal")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open menu")
                }
            }
            .padding(6)
        }
    }
}

/// Native MapKit with a flat, transit-focused base map and one tiny circle per vehicle.
/// Only dots in the visible camera are recomputed, at a watch-friendly 0.2 Hz.
/// The blue marker still comes from one foreground location fix, not tracking.
struct WatchTransitMap: View {
    @Bindable var model: WatchTransitModel
    @State private var position: MapCameraPosition = .region(
        WatchViewport.switzerland.mapRegion
    )
    @State private var positionedFromSnapshot = false
    @State private var railLines: [WatchRailOverlayLine] = []
    @State private var railRequestRevision = 0
    @State private var currentViewport = WatchViewport.switzerland
    @State private var selectedNativeStation: WatchTransitStop?
    @State private var isMapVisible = false

    private var mapStops: [WatchMapStopTarget] {
        let width = abs(currentViewport.east - currentViewport.west)
        let height = abs(currentViewport.north - currentViewport.south)
        let span = max(width, height)
        guard span <= 0.85 else { return [] }

        // Bus kerbs are far denser than rail/tram platforms. Keep them off the
        // default view and reveal them only once the user is looking locally.
        let showsBusPlatforms = span <= 0.08

        var unique: [String: WatchMapStopTarget] = [:]
        for vehicle in model.snapshot.vehicles {
            if vehicle.mode.lowercased() == "bus", !showsBusPlatforms { continue }
            for stop in vehicle.stops {
                guard let coordinate = stop.coordinate,
                      coordinate.isValid,
                      currentViewport.contains(coordinate)
                else { continue }

                // One target per stop place, never one per platform or
                // vehicle. Offline calls often carry a platform-level SLOID;
                // fold it back to the owning station before deduplicating.
                let reference = stop.stationID?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let key: String
                if let reference, !reference.isEmpty {
                    key = TimetableStore.station(ofSlotRef: reference)
                } else {
                    // A name is the best stop-place identity available in the
                    // compact online payload. Platform and coordinate are
                    // deliberately absent so sibling platforms collapse.
                    key = stop.name.folding(
                        options: [.diacriticInsensitive, .caseInsensitive],
                        locale: Locale(identifier: "en_US")
                    ).filter { $0.isLetter || $0.isNumber }
                }
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
                                    WatchModeStyle.color(for: target.mode),
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
                    Task {
                        selectedNativeStation = await model.station(near: point)
                    }
                }
            )
            .navigationDestination(item: $selectedNativeStation) { stop in
                WatchStopBoardView(stop: stop, model: model)
            }
            .onAppear {
                isMapVisible = true
                adoptSnapshotViewportIfNeeded()
                refreshRailOverlay(
                    model.hasSnapshot ? model.snapshot.viewport : .switzerland
                )
            }
            .onDisappear {
                isMapVisible = false
            }
            .onChange(of: model.snapshot.generatedAt) { _, _ in
                adoptSnapshotViewportIfNeeded()
                refreshRailOverlay(currentViewport)
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
                model.updateViewport(viewport)
                refreshRailOverlay(viewport)
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                let viewport = WatchViewport(mapRegion: context.region)
                currentViewport = viewport
                model.updateViewport(viewport)
                refreshRailOverlay(viewport)
            }
        }
    }

    private func visibleVehicles(at date: Date) -> [WatchTransitVehicle] {
        let visibleArea = currentViewport.padded(by: 0.12)
        return model.snapshot.vehicles.compactMap { vehicle in
            // Reject routes whose stop bounds cannot touch the camera before
            // doing even the tiny time interpolation.
            guard route(vehicle, mayIntersect: visibleArea),
                  let positioned = vehicle.positioned(at: date),
                  visibleArea.contains(WatchCoordinate(
                    latitude: positioned.latitude,
                    longitude: positioned.longitude
                  ))
            else { return nil }
            return positioned
        }
    }

    private func route(
        _ vehicle: WatchTransitVehicle,
        mayIntersect viewport: WatchViewport
    ) -> Bool {
        let coordinates = vehicle.stops.compactMap(\.coordinate).filter(\.isValid)
        guard let first = coordinates.first else {
            return viewport.contains(WatchCoordinate(
                latitude: vehicle.latitude,
                longitude: vehicle.longitude
            ))
        }

        var west = first.longitude
        var east = first.longitude
        var south = first.latitude
        var north = first.latitude
        for coordinate in coordinates.dropFirst() {
            west = min(west, coordinate.longitude)
            east = max(east, coordinate.longitude)
            south = min(south, coordinate.latitude)
            north = max(north, coordinate.latitude)
        }
        return east >= min(viewport.west, viewport.east)
            && west <= max(viewport.west, viewport.east)
            && north >= min(viewport.south, viewport.north)
            && south <= max(viewport.south, viewport.north)
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
        case "boat": return .blue
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

    static func priority(for mode: String) -> Int {
        switch mode.lowercased() {
        case "train", "metro": return 3
        case "tram", "boat", "cable": return 2
        case "bus": return 1
        default: return 0
        }
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
