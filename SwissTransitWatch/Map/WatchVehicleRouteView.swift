import MapKit
import Observation
import SwiftUI

struct WatchVehicleRouteView: View {
    let vehicle: WatchTransitVehicle
    @Bindable var model: WatchTransitModel
    @State private var camera: MapCameraPosition
    @State private var railLines: [WatchRailOverlayLine] = []
    @State private var railRequestRevision = 0
    @State private var routeGeometry: WatchVehicleRouteGeometry?

    init(vehicle: WatchTransitVehicle, model: WatchTransitModel) {
        self.vehicle = vehicle
        self.model = model
        _camera = State(
            initialValue: .region(
                Self.region(for: vehicle, including: model.userLocation)
            )
        )
    }

    private var routeStops: [(stop: WatchTransitStop, coordinate: CLLocationCoordinate2D)] {
        vehicle.stops.compactMap { stop in
            guard let coordinate = stop.coordinate, coordinate.isValid else { return nil }
            return (
                stop,
                CLLocationCoordinate2D(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
            )
        }
    }

    private func routeParts(at now: Date) -> (
        travelled: [CLLocationCoordinate2D], ahead: [CLLocationCoordinate2D]
    ) {
        let legCount = max(0, vehicle.stops.count - 1)
        guard legCount > 0 else { return ([], routeStops.map(\.coordinate)) }

        let firstEvent = vehicle.stops[0].departure ?? vehicle.stops[0].eventTime
        if let firstEvent, now <= firstEvent {
            return (
                vehicle.stops[0].coordinate.map { [$0.mapCoordinate] } ?? [],
                joinedLegs(0 ..< legCount)
            )
        }

        for index in 0 ..< legCount {
            let current = vehicle.stops[index]
            let next = vehicle.stops[index + 1]
            let leaves = current.departure ?? current.eventTime
            let arrives = next.arrival ?? next.eventTime

            // Still standing at this stop: the seam belongs exactly on its
            // marker, not a few metres along the following mapped path.
            if let leaves, now <= leaves {
                return (
                    index == 0
                        ? current.coordinate.map { [$0.mapCoordinate] } ?? []
                        : joinedLegs(0 ..< index),
                    joinedLegs(index ..< legCount)
                )
            }

            if let leaves, let arrives, now < arrives {
                let duration = max(1, arrives.timeIntervalSince(leaves))
                let progress = min(1, max(0, now.timeIntervalSince(leaves) / duration))
                let split = split(legPath(index), progress: progress)
                return (
                    appending(joinedLegs(0 ..< index), split.before),
                    appending(split.after, joinedLegs((index + 1) ..< legCount))
                )
            }
        }

        let full = joinedLegs(0 ..< legCount)
        return (full, full.last.map { [$0] } ?? [])
    }

    private func legPath(_ index: Int) -> [CLLocationCoordinate2D] {
        guard index >= 0, index + 1 < vehicle.stops.count,
              let from = vehicle.stops[index].coordinate,
              let to = vehicle.stops[index + 1].coordinate
        else { return [] }
        if let route = routeGeometry?.legs[safe: index] ?? nil,
           route.count >= 2 {
            return route.map(\.mapCoordinate)
        }
        return [from.mapCoordinate, to.mapCoordinate]
    }

    private func joinedLegs(_ range: Range<Int>) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for index in range {
            result = appending(result, legPath(index))
        }
        return result
    }

    private func appending(
        _ lhs: [CLLocationCoordinate2D],
        _ rhs: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        guard let left = lhs.last, let right = rhs.first else { return lhs + rhs }
        let same = abs(left.latitude - right.latitude) < 0.000_001
            && abs(left.longitude - right.longitude) < 0.000_001
        return lhs + (same ? Array(rhs.dropFirst()) : rhs)
    }

    private func split(
        _ path: [CLLocationCoordinate2D],
        progress: Double
    ) -> (before: [CLLocationCoordinate2D], after: [CLLocationCoordinate2D]) {
        guard path.count >= 2 else { return (path, path) }
        var cumulative = [Double](repeating: 0, count: path.count)
        for index in 1 ..< path.count {
            cumulative[index] = cumulative[index - 1]
                + MKMapPoint(path[index - 1]).distance(to: MKMapPoint(path[index]))
        }
        guard let total = cumulative.last, total > 0 else { return (path, path) }
        let target = min(1, max(0, progress)) * total
        var index = 1
        while index < cumulative.count, cumulative[index] < target { index += 1 }
        index = min(index, path.count - 1)
        let length = max(0.001, cumulative[index] - cumulative[index - 1])
        let fraction = min(1, max(0, (target - cumulative[index - 1]) / length))
        let seam = CLLocationCoordinate2D(
            latitude: path[index - 1].latitude
                + (path[index].latitude - path[index - 1].latitude) * fraction,
            longitude: path[index - 1].longitude
                + (path[index].longitude - path[index - 1].longitude) * fraction
        )
        return (
            Array(path[0 ..< index]) + [seam],
            [seam] + Array(path[index...])
        )
    }

    var body: some View {
        TimelineView(
            .periodic(from: .now, by: WatchTransitPolicy.mapPositionInterval)
        ) { timeline in
            routeMap(at: timeline.date)
        }
    }

    private func routeMap(at now: Date) -> some View {
        let parts = routeParts(at: now)
        let liveCoordinate = vehicle.mapPosition(at: now, geometry: routeGeometry)
            ?? WatchCoordinate(latitude: vehicle.latitude, longitude: vehicle.longitude)
        return Map(position: $camera, interactionModes: [.pan, .zoom]) {
            ForEach(railLines) { line in
                MapPolyline(coordinates: line.coordinates.map(\.mapCoordinate))
                    .stroke(
                        line.style.color.opacity(0.72),
                        lineWidth: line.isDetailed ? 1.35 : 1
                    )
            }

            if parts.travelled.count >= 2 {
                MapPolyline(coordinates: parts.travelled)
                    .stroke(
                        Color.white.opacity(0.58),
                        style: StrokeStyle(
                            lineWidth: 3,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: [1, 5]
                        )
                    )
            }

            if parts.ahead.count >= 2 {
                MapPolyline(coordinates: parts.ahead)
                    .stroke(
                        Color.white.opacity(0.92),
                        style: StrokeStyle(
                            lineWidth: 3,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
            }

            ForEach(Array(vehicle.stops.enumerated()), id: \.element.id) { index, stop in
                if let coordinate = stop.coordinate, coordinate.isValid {
                    Annotation(
                        "",
                        coordinate: CLLocationCoordinate2D(
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude
                        ),
                        anchor: .center
                    ) {
                        NavigationLink(
                            value: WatchRoute.station(stop)
                        ) {
                            Circle()
                                .fill(index == 0 || index == vehicle.stops.count - 1 ? .white : .secondary)
                                .overlay { Circle().stroke(.black.opacity(0.65), lineWidth: 1) }
                                .frame(
                                    width: index == 0 || index == vehicle.stops.count - 1 ? 7 : 5,
                                    height: index == 0 || index == vehicle.stops.count - 1 ? 7 : 5
                                )
                                .frame(width: 32, height: 32)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(stop.name)
                    }
                }
            }

            if let location = model.userLocation, location.isValid {
                Annotation(
                    "",
                    coordinate: location.mapCoordinate,
                    anchor: .center
                ) {
                    Circle()
                        .fill(.blue)
                        .overlay { Circle().stroke(.white, lineWidth: 2) }
                        .frame(width: 11, height: 11)
                        .accessibilityLabel("My location")
                }
            }

            Annotation(
                "",
                coordinate: liveCoordinate.mapCoordinate,
                anchor: .center
            ) {
                WatchVehicleDot(mode: vehicle.mode, diameter: 10)
                    .overlay { Circle().stroke(.white, lineWidth: 1.5) }
                    .accessibilityLabel(vehicle.accessibilityName)
            }
        }
        .mapStyle(WatchMapStyle.transit)
        .task(id: vehicle.id) {
            guard !WatchPreviewRuntime.isRunning else { return }
            // Usually the foreground one-shot fix is already available. If
            // the route opens before it completes, request exactly one fix so
            // this screen does not remain permanently without the blue dot.
            if model.userLocation == nil { model.locate() }
            refreshRailOverlay(
                Self.region(for: vehicle, including: model.userLocation)
            )
            routeGeometry = await WatchRouteGeometryStore.shared.geometry(for: vehicle)
        }
        .onChange(of: model.userLocation) { _, location in
            guard let location, location.isValid else { return }
            camera = .region(Self.region(for: vehicle, including: location))
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            refreshRailOverlay(context.region)
        }
        .navigationTitle(vehicle.displayLine)
    }

    private func refreshRailOverlay(_ region: MKCoordinateRegion) {
        railRequestRevision &+= 1
        let revision = railRequestRevision
        let viewport = WatchViewport(mapRegion: region)
        Task {
            let loaded = await WatchRailOverlayStore.shared.lines(in: viewport)
            guard revision == railRequestRevision else { return }
            railLines = loaded
        }
    }

    private static func region(
        for vehicle: WatchTransitVehicle,
        including userLocation: WatchCoordinate?
    ) -> MKCoordinateRegion {
        var coordinates = vehicle.stops.compactMap(\.coordinate).filter(\.isValid)
        if let userLocation, userLocation.isValid {
            coordinates.append(userLocation)
        }
        guard let first = coordinates.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: vehicle.latitude,
                    longitude: vehicle.longitude
                ),
                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            )
        }

        var lowLatitude = first.latitude
        var highLatitude = first.latitude
        var lowLongitude = first.longitude
        var highLongitude = first.longitude
        for coordinate in coordinates.dropFirst() {
            lowLatitude = min(lowLatitude, coordinate.latitude)
            highLatitude = max(highLatitude, coordinate.latitude)
            lowLongitude = min(lowLongitude, coordinate.longitude)
            highLongitude = max(highLongitude, coordinate.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (lowLatitude + highLatitude) / 2,
                longitude: (lowLongitude + highLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.012, (highLatitude - lowLatitude) * 1.35),
                longitudeDelta: max(0.012, (highLongitude - lowLongitude) * 1.35)
            )
        )
    }
}

#if DEBUG
#Preview("Train Route") {
    WatchVehicleRouteView(
        vehicle: WatchPreviewData.train,
        model: WatchPreviewData.model()
    )
}
#endif
