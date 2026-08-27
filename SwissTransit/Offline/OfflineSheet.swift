import SwiftUI
import TransitCore

struct OfflineSheet: View {
    @Bindable var model: AppModel
    @State private var store = RegionStore()
    @State private var basemap: Basemap = .dark
    @Environment(\.dismiss) private var dismiss

    /// What the packed stores and the stored snapshot actually occupy.
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
    @State private var onDeviceSize = "—"

    private nonisolated static func measureOnDevice() -> String {
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
        guard bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Downloaded content:")
                            .font(.callout.weight(.semibold))
                        // Worth stating plainly, because it is the unusual part:
                        // the transit data is not a download, it ships with the
                        // app.
                        bundledRow("Stops", "\(model.loaded?.stops ?? 0)")
                        bundledRow("Route relations", "\(model.loaded?.relations ?? 0)")
                        bundledRow("Railway graph", "\(model.loaded?.railnetNodes ?? 0)")
                        bundledRow("Last fleet snapshot",
                                   model.status.journeys > 0
                                       ? "\(model.status.journeys) journeys"
                                       : "none stored yet")
                        Divider().padding(.vertical, 2)
                        bundledRow("Space used", onDeviceSize)
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
                    Text(store.totalBytes > 0
                         ? "Stored: \(ByteCountFormatter.string(fromByteCount: Int64(store.totalBytes), countStyle: .file))"
                         : "Nothing stored yet.")
                }
            }
            .navigationTitle("Offline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task {
                onDeviceSize = await Task.detached(priority: .utility) {
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
    @Environment(\.dismiss) private var dismiss

    // The basemap and the track overlay used to head this list. They are now
    // on the map itself, behind the button above the locate arrow — see
    // `MapSettingsSheet`. Both are judged by watching the map change under
    // them, which is the one thing a full-height sheet cannot let you do.

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Refresh", selection: Binding(
                        get: { model.cadence },
                        set: { model.cadence = $0 }
                    )) {
                        ForEach(RefreshCadence.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Button {
                        Task { await model.refreshNow() }
                    } label: {
                        Label(model.isRefreshing ? "Refreshing…" : "Refresh now",
                              systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshing)

                    Toggle("Engineering works", isOn: Binding(
                        get: { model.includesPlannedWorks },
                        set: { model.includesPlannedWorks = $0 }
                    ))
                } header: {
                    Text("Live data")
                } footer: {
                    Text(model.includesPlannedWorks
                         ? "Planned possessions add 4.3 MB every six hours — about 17 MB a day."
                         : "Disruptions happening now are always fetched. "
                           + "Planned possessions weeks out are not, saving about 17 MB a day.")
                }

                // Three sections where there was one. "Show" had grown to hold
                // everything that happened to be a toggle: what is drawn, how
                // it is drawn, and what the app does while you use it. Only the
                // first of those answers the question the header asks.
                Section {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        Toggle(isOn: Binding(
                            get: { !model.hiddenModes.contains(mode) },
                            set: { on in
                                if on { model.hiddenModes.remove(mode) } else { model.hiddenModes.insert(mode) }
                                model.requestTick()
                            }
                        )) {
                            HStack {
                                Circle().fill(mode.color).frame(width: 9, height: 9)
                                Text(mode.label)
                            }
                        }
                    }
                    Toggle("Bus stops", isOn: Binding(
                        get: { model.showStops }, set: { model.showStops = $0 }
                    ))
                    Toggle("Platforms and stations", isOn: Binding(
                        get: { model.showRailwayShapes }, set: { model.showRailwayShapes = $0 }
                    ))
                } header: {
                    Text("Show")
                } footer: {
                    Text("""
                    What is on the map at all. The railway network and the \
                    basemap are on the map itself, behind the map button above \
                    the locate arrow.
                    """)
                }

                Section {
                    Toggle("Vehicles to scale", isOn: Binding(
                        get: { model.showVehicleShapes }, set: { model.showVehicleShapes = $0 }
                    ))
                    Toggle("Spread parallel vehicles", isOn: Binding(
                        get: { model.spreadVehicles }, set: { model.spreadVehicles = $0 }
                    ))
                    Toggle("Smooth movement", isOn: Binding(
                        get: { model.smoothMotion }, set: { model.smoothMotion = $0 }
                    ))
                } header: {
                    Text("How vehicles are drawn")
                } footer: {
                    Text("""
                    To scale, a train is as long as it really is; otherwise \
                    every vehicle is a dot. Spreading pulls apart the ones \
                    sharing a track, so the one you meant is the one you tap.
                    """)
                }

                Section {
                    Toggle("Ask when several things are under a tap", isOn: Binding(
                        get: { model.askWhenSeveral }, set: { model.askWhenSeveral = $0 }
                    ))
                    Toggle("Follow the vehicle you open", isOn: Binding(
                        get: { model.followSelectedVehicle },
                        set: { model.followSelectedVehicle = $0 }
                    ))
                    Toggle("Notice the service you are on", isOn: Binding(
                        get: { model.rides.enabled },
                        set: { model.rides.enabled = $0 }
                    ))
                } header: {
                    Text("Behaviour")
                }

                // The toggle that learns them now sits with the count of what
                // it has learned and the button that hands them over, rather
                // than a screen away from both under a different header.
                Section {
                    Toggle("Learn train formations", isOn: Binding(
                        get: { model.learnFormations }, set: { model.learnFormations = $0 }
                    ))
                    LabeledContent("Formations learned") {
                        Text("\(model.layouts.count) trains, \(model.layouts.patternCount) lines")
                            .font(.caption.monospacedDigit())
                    }
                    if let file = model.exportLayouts() {
                        ShareLink(item: file) {
                            Label("Export learned formations", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: {
                    Text("Train formations")
                } footer: {
                    Text("""
                    Exporting hands over the learned formations as JSON — drop \
                    it into the project as \
                    SwissTransit/Resources/vehicle-layouts.json and the next \
                    build starts out knowing them.
                    """)
                }

                Section {
                    Toggle("Frame readout", isOn: Binding(
                        get: { model.showDiagnostics }, set: { model.showDiagnostics = $0 }
                    ))
                    Toggle("Wagon hitboxes", isOn: Binding(
                        get: { model.showWagonHitboxes },
                        set: { model.showWagonHitboxes = $0 }
                    ))
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("""
                    The readout shows what each frame draws. Hitboxes draw each \
                    wagon's outline and the heading, grade and euler the \
                    renderer was given for it.
                    """)
                }

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
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
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
    OfflineSheet(model: AppModel())
        .preferredColorScheme(.dark)
}
