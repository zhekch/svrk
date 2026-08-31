import MapKit
import Observation
import SwiftUI

struct WatchHomeView: View {
    @Bindable var model: WatchTransitModel

    var body: some View {
        ZStack {
            WatchTransitMap(model: model)

            VStack(spacing: 0) {
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

                Spacer(minLength: 0)
            }
            .padding(6)
        }
    }
}

/// Native MapKit with a flat, muted base map and one tiny circle per vehicle.
/// It deliberately has no route geometry, model or animation layer. The blue
/// marker comes from a single foreground location fix, not live tracking.
struct WatchTransitMap: View {
    @Bindable var model: WatchTransitModel
    @State private var position: MapCameraPosition = .region(
        WatchViewport.switzerland.mapRegion
    )
    @State private var positionedFromSnapshot = false

    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom]) {
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

            ForEach(model.snapshot.vehicles) { vehicle in
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
        .mapStyle(
            .standard(
                elevation: .flat,
                emphasis: .muted,
                pointsOfInterest: .excludingAll,
                showsTraffic: false
            )
        )
        .onAppear {
            adoptSnapshotViewportIfNeeded()
        }
        .onChange(of: model.snapshot.generatedAt) { _, _ in
            adoptSnapshotViewportIfNeeded()
        }
        .onChange(of: model.locationFocusRevision) { _, _ in
            guard let viewport = model.locationViewport else { return }
            positionedFromSnapshot = true
            position = .region(viewport.mapRegion)
            model.updateViewport(viewport)
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            model.updateViewport(WatchViewport(mapRegion: context.region))
        }
    }

    private func adoptSnapshotViewportIfNeeded() {
        guard !positionedFromSnapshot, model.hasSnapshot else { return }
        positionedFromSnapshot = true
        position = .region(model.snapshot.viewport.mapRegion)
        model.updateViewport(model.snapshot.viewport)
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
        case "tram": return .cyan
        case "bus": return .green
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

extension WatchTransitVehicle {
    var accessibilityName: String {
        let service = line.isEmpty ? mode.capitalized : line
        if let destination, !destination.isEmpty {
            return "\(service) to \(destination)"
        }
        return service
    }
}
