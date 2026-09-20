import SwiftUI
import TransitCore

/// Transit data already on the device, and the optional map-area packs.
///
/// Pushed from Settings rather than opened from a map button: the map's
/// chrome is for looking, and this is storage.
struct OfflineView: View {
    @Bindable var model: AppModel
    var basemap: Basemap = .standard
    var onClose: (() -> Void)? = nil
    @State private var store = RegionStore()

    /// Packed stores plus the last fleet snapshot, in bytes.
    ///
    /// Measured rather than quoted: the bundled data is a directory of packed
    /// files that changes size every time it is rebuilt, and the fleet cache
    /// grows and shrinks with the time of day.
    ///
    /// Held rather than computed, which is what this comment always claimed
    /// and the code never did: as a computed property the walk ran on *every*
    /// evaluation of `body`, and the body is re-evaluated for every progress
    /// report of a running download. Asked once per appearance now, and off
    /// the main actor.
    @State private var onDeviceBytes: Int64 = 0

    private nonisolated static func measureOnDevice() -> Int64 {
        var bytes: Int64 = 0
        let files = FileManager.default
        if let data = Bundle.main.resourceURL?.appendingPathComponent("Data"),
           let walk = files.enumerator(at: data, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in walk {
                bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        let snapshot = URL.applicationSupportDirectory.appendingPathComponent("fleet.bin")
        bytes += Int64((try? snapshot.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return bytes
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Map tiles and transit data together. The footer used to report only the
    /// packs, so a device with 59 MB of timetable and no tiles said "nothing
    /// stored yet".
    private var storedSummary: String {
        let maps = Int64(store.totalBytes)
        let transit = onDeviceBytes
        switch (maps > 0, transit > 0) {
        case (true, true):
            return "Stored: \(Self.bytes(transit)+Self.bytes(maps)) of data."
        case (false, true):
            return "Stored: \(Self.bytes(transit)) of transit data. No map areas yet."
        case (true, false):
            return "Stored: \(Self.bytes(maps)) of map areas."
        case (false, false):
            return "Nothing stored yet."
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloaded content:")
                        .font(.callout.weight(.semibold))
                    // Worth stating plainly, because it is the unusual part:
                    // the transit data is not a download, it ships with the
                    // app.
                    bundledRow("Stops", "\(model.loaded?.stops ?? 0)")
                    bundledRow("Last fleet snapshot",
                               model.status.journeys > 0
                                   ? "\(model.status.journeys) journeys"
                                   : "none stored yet")
                    Divider().padding(.vertical, 2)
                    bundledRow(
                        "Transit data",
                        onDeviceBytes > 0 ? Self.bytes(onDeviceBytes) : "—"
                    )
                }
                .padding(.vertical, 2)
            }

            Section {
                ForEach(Region.all) { region in
                    RegionRow(
                        region: region,
                        state: store.states[region.id] ?? RegionState(),
                        download: { store.download(region, basemap: basemap) },
                        remove: { store.remove(region) }
                    )
                    .onAppear { store.estimate(region, basemap: basemap) }
                }
            } header: {
                Text("Map areas")
            } footer: {
                Text(storedSummary)
            }
        }
        .navigationTitle("Offline")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { onClose() } }
            }
        }
        .task {
            onDeviceBytes = await Task.detached(priority: .utility) {
                Self.measureOnDevice()
            }.value
        }
        .onAppear {
            store.refreshStoredState()
            // `-downloadRegion bern` starts one immediately, so the download
            // path can be exercised without a tap.
            if let id = UserDefaults.standard.string(forKey: "downloadRegion"),
               let region = Region.all.first(where: { $0.id == id }) {
                store.download(region, basemap: basemap)
            }
        }
    }

    private func bundledRow(_ title: String, _ detail: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
            Text(title).font(.caption)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RegionRow: View {
    let region: Region
    let state: RegionState
    let download: () -> Void
    let remove: () -> Void

    /// Once stored, what it took. Before that, what it will take — asked of the
    /// tile store rather than guessed, because these run to hundreds of
    /// megabytes and a surprise that size is not one to spring on somebody.
    private var subtitle: String {
        if state.isStored {
            return ByteCountFormatter.string(fromByteCount: Int64(state.bytes), countStyle: .file)
        }
        if state.isDownloading {
            return "\(Int(state.progress * 100))% of \(region.detail)"
        }
        if let estimate = state.estimatedBytes {
            return "\(region.detail) · ~\(ByteCountFormatter.string(fromByteCount: Int64(estimate), countStyle: .file))"
        }
        return state.isEstimating ? "\(region.detail) · sizing…" : region.detail
    }


    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(region.name).font(.callout)
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary)
                if let error = state.error {
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            if state.isDownloading {
                ProgressView(value: state.progress)
                    .progressViewStyle(.circular)
                    .frame(width: 22)
            } else if state.isStored {
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            } else {
                Button(action: download) {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

struct SettingsSheet: View {
    @Bindable var model: AppModel
    var basemap: Basemap = .standard
    /// `-openSheet offline` lands here rather than on a second sheet.
    var openOffline = false
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()

    private enum Page: Hashable {
        case offline
    }

    // The basemap and the track overlay used to head this list. They are now
    // on the map itself, behind the button above the locate arrow — see
    // `MapSettingsSheet`. Both are judged by watching the map change under
    // them, which is the one thing a full-height sheet cannot let you do.

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Picker("Data", selection: Binding(
                        get: { model.dataMode },
                        set: { model.dataMode = $0 }
                    )) {
                        ForEach(TransitDataMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                } header: {
                    Text("Live data")
                } footer: {
                    Text(model.dataMode.detail)
                }

                Section {
                    Toggle("Platforms and stations", isOn: Binding(
                        get: { model.showRailwayShapes }, set: { model.showRailwayShapes = $0 }
                    ))
                    Toggle("Detailed stops", isOn: Binding(
                        get: { model.showStops }, set: { model.showStops = $0 }
                    ))
                    Toggle("Detailed vehicles", isOn: Binding(
                        get: { model.detailedVehicles },
                        set: { model.detailedVehicles = $0 }
                    ))
                } header: {
                    Text("Visual")
                }

                Section {
                    Toggle("Vehicle and stop suggestions", isOn: Binding(
                        get: { model.rides.enabled },
                        set: { model.rides.enabled = $0 }
                    ))
                } header: {
                    Text("Behaviour")
                }

                Section {
                    NavigationLink(value: Page.offline) {
                        Label("Offline", systemImage: "arrow.down.circle")
                    }
                }
                
                Section {
                    Toggle("Debug", isOn: Binding(
                        get: { model.showDiagnostics }, set: { model.showDiagnostics = $0 }
                    ))
                    if model.showDiagnostics {
                        Toggle("Wagon hitboxes", isOn: Binding(
                            get: { model.showWagonHitboxes },
                            set: { model.showWagonHitboxes = $0 }
                        ))
                        if let file = model.exportLayouts() {
                            ShareLink(item: file) {
                                Label("Export learned formations", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }

                if model.showDiagnostics {
                    Section("Status") {
                        row("Journeys", "\(model.status.journeys)")
                        row("Vehicles after chaining", "\(model.status.vehicles)")
                        row("Unresolved calls", "\(model.status.unresolved)")
                        row("Source", model.status.source)
                        if let at = model.status.refreshedAt {
                            row("Refreshed", Format.time(Int(at.timeIntervalSince1970)))
                        }
                        row("Parse", String(format: "%.2f s", model.status.parseSeconds))
                        if model.status.refreshSeconds > 0 {
                            row("Refresh", String(format: "%.1f s", model.status.refreshSeconds))
                        }
                        if model.status.bytes > 0 {
                            row("Downloaded", ByteCountFormatter.string(
                                fromByteCount: Int64(model.status.bytes), countStyle: .file))
                        }
                        if model.status.failures > 0 {
                            row("Failed refreshes", "\(model.status.failures)")
                        }
                        if let error = model.status.lastError {
                            row("Last error", error)
                        }
                        // Collected by `Fleet.load` since the first build and, until
                        // now, shown nowhere: a store that failed to open left the
                        // feature that depends on it quietly missing, with the app
                        // reporting nothing at all.
                        ForEach(model.loaded?.problems ?? [], id: \.self) { problem in
                            row("Did not load", problem)
                        }
                    }
                }

                Section {
                    Text("Timetable and stop register: [opentransportdata.swiss](https://opentransportdata.swiss).\nRoutes and the railways: ©[OpenStreetMap](https://www.openstreetmap.org/copyright) contributors.\nBasemap: ©[Mapbox](https://www.mapbox.com/about/maps/) ©[OpenStreetMap](https://www.openstreetmap.org/copyright) contributors.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .listRowBackground(Color.clear)
                        .tint(.secondary)
                }

                // Last thing on the last screen, which is where a version
                // belongs: nobody looks for it until something is wrong, and
                // then it is the first thing they are asked for. Read off the
                // bundle rather than written here, so it cannot disagree with
                // the build it is printed in. See the README for the rule that
                // keeps it moving.
                Section {
                    Text(Self.version)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                        .textSelection(.enabled)
                }

            }
            .menuAnimation(value: model.dataMode)
            .menuAnimation(value: model.showDiagnostics)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .offline:
                    OfflineView(model: model, basemap: basemap, onClose: { dismiss() })
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task {
                if openOffline { path.append(Page.offline) }
            }
        }
    }

    /// What this build calls itself: the marketing version, and the build
    /// number after it because the first alone does not tell two builds of one
    /// version apart.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return build == short ? "Version \(short)" : "Version \(short) (\(build))"
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

private struct SettingsSheetPreview: View {
    @State private var model = AppModel()

    var body: some View {
        SettingsSheet(model: model)
            .preferredColorScheme(.dark)
    }
}

#Preview("Settings") {
    SettingsSheetPreview()
}

#Preview("Offline maps") {
    NavigationStack {
        OfflineView(model: AppModel())
    }
    .preferredColorScheme(.dark)
}
