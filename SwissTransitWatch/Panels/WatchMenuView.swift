import Observation
import SwiftUI

struct WatchMenuView: View {
    @Bindable var model: WatchTransitModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                destination(.status, title: "Status", symbol: "gauge.with.dots.needle.50percent", tint: .green)



                WatchGlassCard {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Timetable", systemImage: "square.and.arrow.down.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(model.fullTimetableStatus)
                            .font(.caption.weight(.semibold))
                        if let validity = model.fullTimetableValidity {
                            Text("Valid until \(validity)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("~124 MB")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            model.downloadFullTimetable()
                        } label: {
                            WatchGlassActionLabel(
                                title: model.nationalTimetableInfo == nil
                                    ? "Download"
                                    : "Update",
                                systemName: "arrow.down.circle",
                                tint: .blue
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isDownloadingFullTimetable)
                    }
                }
                destination(.about, title: "About", symbol: "info.circle.fill", tint: .blue)

                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
        .watchGlassScreen()
        .navigationTitle("Menu")
    }

    private func destination(
        _ route: WatchRoute,
        title: String,
        symbol: String,
        tint: Color
    ) -> some View {
        NavigationLink(value: route) {
            WatchGlassCard(interactive: true) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 24)
                    Text(title)
                        .font(.headline)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct WatchMenuActionRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 22)
            Text(title)
                .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

struct WatchStatusView: View {
    @Bindable var model: WatchTransitModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                WatchGlassCard {
                    VStack(spacing: 7) {
                        WatchStatusRow(
                            title: "Snapshot",
                            value: model.hasSnapshot
                                ? (model.isSnapshotStale ? "Needs refresh" : "Ready")
                                : "No cache"
                        )

                        Divider().opacity(0.4)
                        WatchStatusRow(title: "Location", value: model.locationStatusText)
                        Divider().opacity(0.4)
                        WatchStatusRow(title: "Timetable", value: model.fullTimetableStatus)
                    }
                }

                if let validity = model.fullTimetableValidity {
                    WatchGlassCard {
                        WatchStatusRow(title: "Valid to", value: validity)
                    }
                }

            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
        .watchGlassScreen()
        .navigationTitle("Status")
    }
}

private struct WatchStatusRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}

struct WatchAboutView: View {
    var body: some View {
        ScrollView {
            WatchGlassCard {
                VStack(spacing: 9) {
                    Image(systemName: "applewatch")
                        .font(.title)
                        .foregroundStyle(.cyan)
                    Text("SwissTransit")
                        .font(.headline)
                    Text("A lightweight standalone map of nearby Swiss transit dots.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Works without an iPhone. Location is requested once in the foreground, never tracked continuously.")
                        .font(.caption2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("The optional full-country offline timetable is a manual download of about 124 MB.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
        .watchGlassScreen()
        .navigationTitle("About")
    }
}

#if DEBUG
@MainActor
enum WatchPreviewData {
    static let zurichHB = WatchTransitStop(
        id: "8503000",
        stationID: "8503000",
        name: "Zürich HB",
        platform: "9",
        arrival: nil,
        departure: nil,
        delayMinutes: nil,
        coordinate: WatchCoordinate(latitude: 47.37818, longitude: 8.54019)
    )

    static var train: WatchTransitVehicle {
        return WatchTransitVehicle(
            id: "preview-ic5",
            mode: "train",
            line: "IC 5",
            destination: "St. Gallen",
            origin: "Lausanne",
            operatorName: "SBB CFF FFS",
            delayMinutes: 3,
            latitude: 47.4300,
            longitude: 8.5510,
            stops: [
                timedStop(
                    id: "8503000",
                    name: "Zürich HB",
                    platform: "9",
                    minutes: -4,
                    latitude: 47.37818,
                    longitude: 8.54019,
                    delay: 3
                ),
                timedStop(
                    id: "8503006",
                    name: "Zürich Oerlikon",
                    platform: "4",
                    minutes: 4,
                    latitude: 47.41153,
                    longitude: 8.54414,
                    delay: 3
                ),
                timedStop(
                    id: "8503016",
                    name: "Zürich Flughafen",
                    platform: "2",
                    minutes: 12,
                    latitude: 47.45042,
                    longitude: 8.56242,
                    delay: 3
                ),
                timedStop(
                    id: "8506000",
                    name: "Winterthur",
                    platform: "3",
                    minutes: 25,
                    latitude: 47.50012,
                    longitude: 8.72414,
                    delay: 3
                ),
            ]
        )
    }

    static var stationDepartures: [WatchStationDeparture] {
        let now = Date()
        let previewTrain = train
        return [
            WatchStationDeparture(
                id: "preview-ic5-board",
                mode: "train",
                line: "IC 5",
                destination: "St. Gallen",
                origin: "Lausanne",
                arrival: now.addingTimeInterval(3 * 60),
                departure: now.addingTimeInterval(4 * 60),
                platform: "9A-C",
                delayMinutes: 3,
                vehicle: previewTrain,
                originates: false,
                terminates: false,
                typicalIntervalMinutes: 60
            ),
            WatchStationDeparture(
                id: "preview-s11-1",
                mode: "train",
                line: "S 11",
                destination: "Seuzach",
                origin: "Aarau",
                arrival: now.addingTimeInterval(7 * 60),
                departure: now.addingTimeInterval(8 * 60),
                platform: "41/42",
                delayMinutes: nil,
                vehicle: nil,
                originates: false,
                terminates: false,
                typicalIntervalMinutes: 30
            ),
            WatchStationDeparture(
                id: "preview-ir75",
                mode: "train",
                line: "IR 75",
                destination: "Konstanz",
                origin: "Luzern",
                arrival: now.addingTimeInterval(15 * 60),
                departure: now.addingTimeInterval(16 * 60),
                platform: "11",
                delayMinutes: nil,
                vehicle: nil,
                originates: false,
                terminates: false,
                typicalIntervalMinutes: 60
            ),
            WatchStationDeparture(
                id: "preview-s11-2",
                mode: "train",
                line: "S 11",
                destination: "Seuzach",
                origin: "Aarau",
                arrival: now.addingTimeInterval(37 * 60),
                departure: now.addingTimeInterval(38 * 60),
                platform: "41/42",
                delayMinutes: nil,
                vehicle: nil,
                originates: false,
                terminates: false,
                typicalIntervalMinutes: 30
            ),
            WatchStationDeparture(
                id: "preview-s11-3",
                mode: "train",
                line: "S 11",
                destination: "Seuzach",
                origin: "Aarau",
                arrival: now.addingTimeInterval(67 * 60),
                departure: now.addingTimeInterval(68 * 60),
                platform: "41/42",
                delayMinutes: nil,
                vehicle: nil,
                originates: false,
                terminates: false,
                typicalIntervalMinutes: 30
            ),
        ]
    }

    static var departureGroup: WatchDepartureGroup {
        WatchDepartureGroup(
            id: "preview-s11-group",
            departures: stationDepartures.filter { $0.line == "S 11" },
            showing: .departure
        )
    }

    static var snapshot: WatchTransitSnapshot {
        let previewTrain = train
        return WatchTransitSnapshot(
            generatedAt: Date().addingTimeInterval(-2 * 60),
            sourceUpdatedAt: Date().addingTimeInterval(-3 * 60),
            viewport: .near(
                WatchCoordinate(latitude: previewTrain.latitude, longitude: previewTrain.longitude)
            ),
            vehicles: [previewTrain]
        )
    }

    static func model() -> WatchTransitModel {
        let model = WatchTransitModel()
        model.installPreview(snapshot: snapshot)
        return model
    }

    private static func timedStop(
        id: String,
        name: String,
        platform: String,
        minutes: Int,
        latitude: Double,
        longitude: Double,
        delay: Int
    ) -> WatchTransitStop {
        let event = Date().addingTimeInterval(TimeInterval(minutes * 60))
        return WatchTransitStop(
            id: id,
            stationID: id,
            name: name,
            platform: platform,
            arrival: event.addingTimeInterval(-45),
            departure: event,
            delayMinutes: delay,
            coordinate: WatchCoordinate(latitude: latitude, longitude: longitude)
        )
    }
}

/// Canvas-only host for the watch menu. The model deliberately never enters
/// foreground, so previewing its rows cannot request location or the network.
@MainActor
private struct WatchMenuPreviewHost: View {
    @State private var model = WatchPreviewData.model()

    var body: some View {
        WatchMenuView(model: model)
    }
}

#Preview("Menu") {
    WatchMenuPreviewHost()
}
#endif
