import SwiftUI

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

                    // Satellite imagery has no adjustable lighting.
                    if basemap == .standard {
                        Picker("Light", selection: Binding(
                            get: { model.lightPreset },
                            set: { model.lightPreset = $0 }
                        )) {
                            ForEach(Terrain3D.LightPreset.controlCases) {
                                Image(systemName: $0.symbol)
                                    .accessibilityLabel($0.label)
                                    .tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("mapLighting")
                    }
                } header: {
                    Text("Basemap")
                } footer: {
                    if basemap == .standard, model.lightPreset == .auto {
                        Text("Follows the real.")
                    }
                }

                Section {
                    Toggle("Terrain", isOn: Binding(
                        get: { model.terrain3D },
                        set: { model.terrain3D = $0 }
                    ))
                    if model.detailedVehicles {
                        Toggle("Tunnels", isOn: Binding(
                            get: { model.ghostTunnels },
                            set: { model.ghostTunnels = $0 }
                        ))
                    }

                } header: {
                    Text("3D")
                }

                Section {
                    Picker("Overlay", selection: Binding(
                        get: { model.highContrastTracks },
                        set: { model.highContrastTracks = $0 }
                    )) {
                        Text("Simple").tag(false)
                        Text("ORM").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: {
                    Text("Track overlay")
                } footer: {
                    Text("Simple only available in Switzerland")
                }
            }
            .menuAnimation(value: basemap)
            .menuAnimation(value: model.lightPreset)
            .menuAnimation(value: model.detailedVehicles)
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
    @State private var basemap: Basemap = .standard

    var body: some View {
        MapSettingsSheet(model: model, basemap: $basemap)
            .preferredColorScheme(.dark)
    }
}

#Preview("Map settings") {
    MapSettingsPreview()
}
