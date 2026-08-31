import Observation
import SwiftUI

struct WatchMenuView: View {
    @Bindable var model: WatchTransitModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                destination(.fleet, title: "Vehicles", symbol: "circle.grid.2x2.fill", tint: .cyan)
                destination(.status, title: "Status", symbol: "gauge.with.dots.needle.50percent", tint: .green)
                destination(.about, title: "About", symbol: "info.circle.fill", tint: .blue)

                WatchGlassCard {
                    VStack(spacing: 0) {
                        Button {
                            model.locate()
                        } label: {
                            WatchMenuActionRow(
                                title: model.isLocating ? "Locating…" : "My location",
                                symbol: "location.fill",
                                tint: .blue,
                                isBusy: model.isLocating
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isLocating)

                        Divider().opacity(0.4)

                        Button {
                            model.refresh()
                        } label: {
                            WatchMenuActionRow(
                                title: model.isRefreshing ? "Refreshing…" : "Refresh now",
                                symbol: "arrow.clockwise",
                                tint: .cyan,
                                isBusy: model.isRefreshing
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isRefreshing)
                    }
                }

                WatchGlassCard {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Full offline", systemImage: "square.and.arrow.down.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(model.fullTimetableStatus)
                            .font(.caption.weight(.semibold))
                        if let validity = model.fullTimetableValidity {
                            Text("Valid to \(validity)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("About 124 MB · all Switzerland")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            model.downloadFullTimetable()
                        } label: {
                            WatchGlassActionLabel(
                                title: model.nationalTimetableInfo == nil
                                    ? "Download everything"
                                    : "Update download",
                                systemName: "arrow.down.circle",
                                tint: .blue
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isDownloadingFullTimetable)
                    }
                }

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
                        WatchStatusRow(title: "Vehicles", value: "\(model.vehicleCount)")
                        Divider().opacity(0.4)
                        WatchStatusRow(
                            title: "Data",
                            value: model.nationalTimetableInfo == nil
                                ? "Direct on watch"
                                : "Full offline"
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

                if model.hasSnapshot {
                    WatchGlassCard {
                        VStack(spacing: 7) {
                            WatchStatusRow(
                                title: "Saved",
                                value: model.snapshot.generatedAt.formatted(
                                    date: .omitted,
                                    time: .shortened
                                )
                            )
                            if let sourceDate = model.snapshot.sourceUpdatedAt {
                                Divider().opacity(0.4)
                                WatchStatusRow(
                                    title: "Source",
                                    value: sourceDate.formatted(
                                        date: .omitted,
                                        time: .shortened
                                    )
                                )
                            }
                        }
                    }
                }

                Button {
                    model.locate()
                } label: {
                    WatchGlassActionLabel(
                        title: model.isLocating ? "Locating…" : "My location",
                        systemName: "location.fill",
                        tint: .blue
                    )
                }
                .buttonStyle(.plain)
                .disabled(model.isLocating)

                Button {
                    model.refresh()
                } label: {
                    WatchGlassActionLabel(
                        title: model.isRefreshing ? "Refreshing…" : "Refresh",
                        systemName: "arrow.clockwise",
                        tint: .cyan
                    )
                }
                .buttonStyle(.plain)
                .disabled(model.isRefreshing)

                if let error = model.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
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
