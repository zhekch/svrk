import MapKit
import SwiftUI

struct WatchVehicleRouteView: View {
    let vehicle: WatchTransitVehicle
    @State private var camera: MapCameraPosition

    init(vehicle: WatchTransitVehicle) {
        self.vehicle = vehicle
        _camera = State(initialValue: .region(Self.region(for: vehicle)))
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

    private var routeParts: (
        travelled: [CLLocationCoordinate2D], ahead: [CLLocationCoordinate2D]
    ) {
        let stops = routeStops
        guard stops.count >= 2 else { return ([], stops.map(\.coordinate)) }

        let now = Date()
        let vehicleCoordinate = CLLocationCoordinate2D(
            latitude: vehicle.latitude,
            longitude: vehicle.longitude
        )
        let firstEvent = stops[0].stop.departure ?? stops[0].stop.eventTime
        if let firstEvent, now <= firstEvent {
            return ([stops[0].coordinate], stops.map(\.coordinate))
        }

        for index in 0 ..< stops.count - 1 {
            let leaves = stops[index].stop.departure ?? stops[index].stop.eventTime
            let arrives = stops[index + 1].stop.arrival ?? stops[index + 1].stop.eventTime

            // Still standing at this stop: the seam belongs exactly on its
            // marker, not a few metres along the following chord.
            if let leaves, now <= leaves {
                return (
                    stops[0 ... index].map(\.coordinate),
                    stops[index...].map(\.coordinate)
                )
            }

            // Between calls, the watch service places the vehicle on this same
            // straight segment. Use that displayed point as the shared end of
            // the dotted past and start of the solid future.
            if let arrives, now < arrives {
                return (
                    stops[0 ... index].map(\.coordinate) + [vehicleCoordinate],
                    [vehicleCoordinate] + stops[(index + 1)...].map(\.coordinate)
                )
            }
        }

        return (stops.map(\.coordinate), [stops[stops.count - 1].coordinate])
    }

    var body: some View {
        let parts = routeParts
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            if parts.travelled.count >= 2 {
                MapPolyline(coordinates: parts.travelled)
                    .stroke(
                        WatchModeStyle.color(for: vehicle.mode).opacity(0.72),
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
                        WatchModeStyle.color(for: vehicle.mode).opacity(0.9),
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
                            value: WatchRoute.station(
                                vehicleID: vehicle.id,
                                stopID: stop.id
                            )
                        ) {
                            Circle()
                                .fill(index == 0 || index == vehicle.stops.count - 1 ? .white : .secondary)
                                .overlay { Circle().stroke(.black.opacity(0.65), lineWidth: 1) }
                                .frame(
                                    width: index == 0 || index == vehicle.stops.count - 1 ? 7 : 5,
                                    height: index == 0 || index == vehicle.stops.count - 1 ? 7 : 5
                                )
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(stop.name)
                    }
                }
            }

            Annotation(
                "",
                coordinate: CLLocationCoordinate2D(
                    latitude: vehicle.latitude,
                    longitude: vehicle.longitude
                ),
                anchor: .center
            ) {
                WatchVehicleDot(mode: vehicle.mode, diameter: 10)
                    .overlay { Circle().stroke(.white, lineWidth: 1.5) }
                    .accessibilityLabel(vehicle.accessibilityName)
            }
        }
        .mapStyle(
            .standard(
                elevation: .flat,
                emphasis: .muted,
                pointsOfInterest: .excludingAll,
                showsTraffic: false
            )
        )
        .navigationTitle(vehicle.displayLine)
    }

    private static func region(for vehicle: WatchTransitVehicle) -> MKCoordinateRegion {
        let coordinates = vehicle.stops.compactMap(\.coordinate).filter(\.isValid)
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
