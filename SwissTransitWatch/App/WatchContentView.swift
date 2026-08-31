import Observation
import SwiftUI

enum WatchRoute: Hashable {
    case menu
    case fleet
    case status
    case about
    case vehicle(String)
    case vehicleRoute(String)
    case station(vehicleID: String, stopID: String)
}

struct WatchContentView: View {
    @Bindable var model: WatchTransitModel

    var body: some View {
        NavigationStack {
            WatchHomeView(model: model)
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
        case .fleet:
            WatchFleetView(model: model)
        case .status:
            WatchStatusView(model: model)
        case .about:
            WatchAboutView()
        case let .vehicle(id):
            WatchVehicleDestination(id: id, model: model)
        case let .vehicleRoute(id):
            WatchVehicleRouteDestination(id: id, model: model)
        case let .station(vehicleID, stopID):
            WatchStopDestination(vehicleID: vehicleID, stopID: stopID, model: model)
        }
    }
}

private struct WatchStopDestination: View {
    let vehicleID: String
    let stopID: String
    @Bindable var model: WatchTransitModel

    var body: some View {
        if let vehicle = model.snapshot.vehicles.first(where: { $0.id == vehicleID }),
           let stop = vehicle.stops.first(where: { $0.id == stopID }) {
            WatchStopBoardView(stop: stop, model: model)
        } else {
            WatchVehicleUnavailableView()
        }
    }
}

private struct WatchVehicleRouteDestination: View {
    let id: String
    @Bindable var model: WatchTransitModel

    var body: some View {
        if let vehicle = model.snapshot.vehicles.first(where: { $0.id == id }) {
            WatchVehicleRouteView(vehicle: vehicle)
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
                snapshotDate: model.snapshot.generatedAt
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
