import Observation
import SwiftUI

enum WatchRoute: Hashable {
    case menu
    case status
    case about
    case vehicle(String)
    case vehicleRoute(String)
    case stationVehicle(WatchTransitVehicle)
    case stationVehicleRoute(WatchTransitVehicle)
    case stationTimes(WatchDepartureGroup)
    /// A station is navigated to by its own value rather than through the
    /// vehicle it was tapped from. The originating run may disappear on the
    /// next refresh, while the station and its complete board remain valid.
    case station(WatchTransitStop)
}

struct WatchContentView: View {
    @Bindable var model: WatchTransitModel
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            WatchHomeView(model: model, navigationPath: $navigationPath)
                .navigationDestination(for: WatchRoute.self) { route in
                    destination(for: route)
                }
        }
    }

    @ViewBuilder
    private func destination(for route: WatchRoute) -> some View {
        switch route {
        case .menu:
            WatchMenuView(model: model)
        case .status:
            WatchStatusView(model: model)
        case .about:
            WatchAboutView()
        case let .vehicle(id):
            WatchVehicleDestination(id: id, model: model)
        case let .vehicleRoute(id):
            WatchVehicleRouteDestination(id: id, model: model)
        case let .stationVehicle(vehicle):
            WatchVehicleDetailView(
                vehicle: vehicle,
                routeValue: .stationVehicleRoute(vehicle)
            )
        case let .stationVehicleRoute(vehicle):
            WatchVehicleRouteView(vehicle: vehicle, model: model)
        case let .stationTimes(group):
            WatchDepartureTimesView(group: group)
        case let .station(stop):
            WatchStopBoardView(stop: stop, model: model)
        }
    }
}

private struct WatchVehicleRouteDestination: View {
    let id: String
    @Bindable var model: WatchTransitModel

    var body: some View {
        if let vehicle = model.snapshot.vehicles.first(where: { $0.id == id }) {
            WatchVehicleRouteView(vehicle: vehicle, model: model)
        } else {
            WatchVehicleUnavailableView()
        }
    }
}

private struct WatchVehicleDestination: View {
    let id: String
    @Bindable var model: WatchTransitModel

    var body: some View {
        if let vehicle = model.snapshot.vehicles.first(where: { $0.id == id }) {
            WatchVehicleDetailView(
                vehicle: vehicle,
                routeValue: .vehicleRoute(vehicle.id)
            )
        } else {
            WatchVehicleUnavailableView()
        }
    }
}

private struct WatchVehicleUnavailableView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tram.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Vehicle unavailable")
                .font(.headline)
            Text("Refresh the nearby vehicle list and try again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .watchGlassScreen()
        .navigationTitle("Vehicle")
    }
}
