import SwiftUI

/// What the map looks like, one tap from the map.
///
/// Everything else in Settings is about what the app *does* — how often it
/// fetches, what it draws, what it has learned. These are about what is under
/// your thumb right now, and judging them means watching the map change while
/// you move them. A sheet behind a slider control four taps away is the wrong
/// place for that, so they live on the map instead: a short sheet that leaves
/// most of the map visible, over the button that opened it.
///
/// That is also why the tilt slider is here rather than left to the gesture.
/// Everything in the third-dimension section does nothing at all on a map
/// looking straight down, and the only other way to find that out is a
/// two-finger vertical drag — which almost nobody knows and which cannot be
/// performed while a sheet is over the map.
struct MapSettingsSheet: View {
    @Bindable var model: AppModel
    @Binding var basemap: Basemap
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Basemap", selection: $basemap) {
                        ForEach(Basemap.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    // Only Standard has one. The other three are fixed palettes,
                    // and a time-of-day control that greys out on three choices
                    // out of four is worse than one that is not there at all.
                    if basemap == .standard {
                        Picker("Light", selection: Binding(
                            get: { model.lightPreset },
                            set: { model.lightPreset = $0; model.requestTick() }
                        )) {
                            ForEach(Terrain3D.LightPreset.allCases) {
                                Text($0.label).tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                } header: {
                    Text("Basemap")
                } footer: {
                    if basemap == .standard {
                        Text("""
                        Mapbox's own three-dimensional basemap: buildings with \
                        height, landmarks modelled one by one, and a sun that \
                        moves with the setting above it. Either change reloads \
                        the style, so everything this app draws over it is \
                        built for the ground it is going to be drawn on.
                        """)
                    }
                }

                Section {
                    Toggle("Terrain", isOn: Binding(
                        get: { model.terrain3D },
                        set: { model.terrain3D = $0 }
                    ))
                    // Only while there is relief to exaggerate. A dial under a
                    // switch that is off is a control for nothing.
                    if model.terrain3D {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Relief")
                                Spacer()
                                Text(String(format: "%.1f×", model.terrainExaggeration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: Binding(
                                get: { model.terrainExaggeration },
                                set: { model.terrainExaggeration = $0 }
                            ), in: 0.5...2.5)
                        }
                    }
                    // Standard brings its own and draws them better — modelled
                    // landmarks rather than extruded footprints — so offering a
                    // switch for ours there would be a switch that does nothing.
                    // Satellite is a photograph of the roofs themselves; the
                    // same translucent boxes sit over them as a grey haze.
                    if basemap.showsExtrudedBuildings {
                        Toggle("Buildings", isOn: Binding(
                            get: { model.buildings3D },
                            set: { model.buildings3D = $0 }
                        ))
                    }
                    Toggle("Solid vehicles", isOn: Binding(
                        get: { model.solidVehicles },
                        set: { model.solidVehicles = $0 }
                    ))
                    .disabled(!model.detailedVehicles)
                    if model.detailedVehicles, model.solidVehicles {
                        Toggle("Tunnels", isOn: Binding(
                            get: { model.ghostTunnels },
                            set: { model.ghostTunnels = $0 }
                        ))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Tilt")
                            Spacer()
                            Text("\(Int(model.pitch.rounded()))°")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { model.pitch },
                            // Straight at the camera rather than into the model.
                            // The map owns the pitch and reports it back, so
                            // writing it here as well would give the slider two
                            // sources and a fight between them.
                            set: { model.tilt(to: $0) }
                        ), in: 0...70)
                    }
                } header: {
                    Text("Three dimensions")
                } footer: {
                    Text("""
                    Tilt the map and the vehicles stand up: the same outlines, \
                    sliced into a solid — a chassis under an overhanging body, \
                    a window band, a roof drawn in, a cab that rakes back as it \
                    rises. It happens close in, where the height is worth more \
                    than a pixel, and it fades rather than switches, so a train \
                    lifts out of its own footprint instead of being swapped for \
                    a model of one. Terrain needs a connection. The buildings, \
                    the vehicles and the tilt do not. Tunnels, on, fade a \
                    wagon as it goes under; off, the body ignores the bore \
                    and stays solid.
                    """)
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Railway network")
                            Spacer()
                            Text(model.trackOpacity < 0.02
                                 ? "off"
                                 : "\(Int(model.trackOpacity * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { model.trackOpacity },
                            set: { model.trackOpacity = $0; model.requestTick() }
                        ), in: 0...1)
                    }
                    Toggle("High contrast", isOn: Binding(
                        get: { model.highContrastTracks },
                        set: { model.highContrastTracks = $0 }
                    ))
                } header: {
                    Text("Track overlay")
                } footer: {
                    // One footer for both states rather than one each: the
                    // toggle is right above it, and a paragraph that changes
                    // length as you press it moves everything under it.
                    Text("""
                    Off, the network is the app's own — drawn from the routing \
                    graph on the device, and there with no signal. On, it is \
                    OpenRailwayMap's own colours from their tiles: orange main \
                    lines, yellow branches, olive narrow gauge, pink trams. \
                    Those need a connection, and without one the plainer \
                    network comes back.
                    """)
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct MapSettingsPreview: View {
    @State private var model = AppModel()
    @State private var basemap: Basemap = .dark

    var body: some View {
        MapSettingsSheet(model: model, basemap: $basemap)
            .preferredColorScheme(.dark)
    }
}

#Preview("Map settings") {
    MapSettingsPreview()
}
