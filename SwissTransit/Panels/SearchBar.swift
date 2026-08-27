import SwiftUI
import TransitCore

/// Find a place or a service by name.
///
/// A button rather than a permanent field. The map is the document here and a
/// search field pinned across the top of it is a strip of chrome over the thing
/// you came to look at — so it stays a 34-point circle until it is asked for,
/// and then it becomes the whole header. Opening it puts the keyboard up
/// immediately: nobody taps a magnifying glass to admire the field.
struct SearchBar: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            field
            if model.isSearching, !model.searchResults.isEmpty {
                results
            }
        }
        // The keyboard is the point of the button, so it goes up on its own.
        //
        // After a beat rather than immediately: this view is created *by* the
        // change that opens it, and a `focused = true` in the same pass asks
        // UIKit to make first responder a field it has not laid out yet, which
        // it declines silently. One runloop turn is enough, and is under the
        // 220 ms the header takes to expand anyway.
        .task {
            guard model.isSearching else { return }
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Station, or IC8, or 726", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .font(.callout)
                // Return takes the top row. The keyboard offers a Search key
                // whatever this does, so leaving it inert is a button that
                // lies.
                .onSubmit { Task { await model.openTopResult() } }

            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }

            Button("Cancel") {
                withAnimation(.snappy(duration: 0.22)) { model.isSearching = false }
            }
            .font(.callout)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// What was found, stations first.
    ///
    /// Stations first because they are the answer to the shorter query: two
    /// letters is almost always the start of a place name, and a line
    /// designation is short enough that its results arrive at full strength the
    /// moment they are relevant. Each group is capped rather than interleaved —
    /// a mixed list sorted by some common score puts a bus stop between two
    /// trains and reads as noise.
    private var results: some View {
        ScrollView {
            VStack(spacing: 0) {
                let stations = model.searchResults.stations
                let vehicles = model.searchResults.vehicles

                if !stations.isEmpty {
                    groupHeading("Stops")
                    ForEach(Array(stations.enumerated()), id: \.element.id) { index, place in
                        Button {
                            Task { await model.open(station: place) }
                        } label: {
                            stationRow(place)
                        }
                        .buttonStyle(.plain)
                        // No rule under the last row of the last group: a
                        // divider with nothing beneath it reads as a row that
                        // failed to draw.
                        if index < stations.count - 1 || !vehicles.isEmpty {
                            Divider().padding(.leading, 46)
                        }
                    }
                }

                if !vehicles.isEmpty {
                    groupHeading("Services")
                    ForEach(Array(vehicles.enumerated()), id: \.element.id) { index, hit in
                        Button {
                            Task { await model.open(vehicle: hit) }
                        } label: {
                            vehicleRow(hit)
                        }
                        .buttonStyle(.plain)
                        if index < vehicles.count - 1 {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
            }
        }
        // Tall enough for about six rows. Any more and the list is covering the
        // map it is about to move.
        .frame(maxHeight: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func groupHeading(_ text: String) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    }

    private func stationRow(_ place: StopPlace) -> some View {
        HStack(spacing: 10) {
            Image(systemName: place.rail ? "tram.fill" : "bus.fill")
                .font(.system(size: 13))
                .frame(width: 36)
                .foregroundStyle(place.rail ? Color.accentColor : .secondary)
            Text(place.name)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let away = distance(to: Coord(lon: place.lon, lat: place.lat)) {
                Text(away)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private func vehicleRow(_ hit: VehicleHit) -> some View {
        HStack(spacing: 10) {
            // Wide enough for "IC8" and "RJX" without the badge scaling its
            // own text down; the badge sets narrower rather than wrapping, so a
            // tight frame is a designation nobody can read.
            LineBadge(line: hit.line, mode: hit.mode)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.to ?? hit.from)
                    .font(.callout)
                    .lineLimit(1)
                Text(subtitle(hit))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // Said rather than implied. A service that has not left yet is a
            // perfectly good answer — it is how you find the 17:04 at ten to —
            // but it is not on the map, and tapping it moves the camera to an
            // empty platform unless the row says so first.
            if !hit.running {
                Text(Format.time(hit.departure))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private func subtitle(_ hit: VehicleHit) -> String {
        var parts: [String] = []
        if let number = hit.number { parts.append("№ \(number)") }
        parts.append("from \(hit.from)")
        return parts.joined(separator: " · ")
    }

    /// How far from the middle of the map, which is what "closest" is measured
    /// against — the map, not the phone. Somebody looking at Lugano searching
    /// for "Bahnhof" means one in Lugano, wherever they happen to be sitting.
    private func distance(to coord: Coord) -> String? {
        let box = model.viewport
        let centre = Coord(lon: (box.west + box.east) / 2, lat: (box.south + box.north) / 2)
        let metres = Geo.flatMetres(coord.lon, coord.lat, centre.lon, centre.lat)
        guard metres.isFinite, metres < 400_000 else { return nil }
        if metres < 950 { return "\(Int((metres / 50).rounded()) * 50) m" }
        return "\(Int((metres / 1000).rounded())) km"
    }
}

#Preview("Search") {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack {
            SearchBar(model: AppModel())
            Spacer()
        }
        .padding(12)
    }
    .preferredColorScheme(.dark)
}
