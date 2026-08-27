import Foundation
import Observation
import MapboxMaps
import TransitCore

/// A named piece of Switzerland the user can keep on the device.
struct Region: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let bbox: BBox

    /// The polygon the tile store wants. A rectangle is enough: these are
    /// administrative conveniences, not shapes anybody will look at.
    var polygon: Polygon {
        Polygon([[
            CLLocationCoordinate2D(latitude: bbox.south, longitude: bbox.west),
            CLLocationCoordinate2D(latitude: bbox.south, longitude: bbox.east),
            CLLocationCoordinate2D(latitude: bbox.north, longitude: bbox.east),
            CLLocationCoordinate2D(latitude: bbox.north, longitude: bbox.west),
            CLLocationCoordinate2D(latitude: bbox.south, longitude: bbox.west),
        ]])
    }

    /// The regions on offer.
    ///
    /// Deliberately coarse and few. A picker with twenty-six cantons in it is a
    /// worse answer than eight areas somebody can actually point at, and the
    /// tile packs overlap at the edges anyway.
    static let all: [Region] = [
        Region(id: "ch", name: "All of Switzerland", detail: "The whole country",
               bbox: BBox(west: 5.9, south: 45.8, east: 10.5, north: 47.9)),
        Region(id: "bern", name: "Bern & Oberland", detail: "Bern, Thun, Interlaken",
               bbox: BBox(west: 7.0, south: 46.4, east: 8.2, north: 47.2)),
        Region(id: "zurich", name: "Zürich & north-east", detail: "Zürich, Winterthur, St. Gallen",
               bbox: BBox(west: 8.2, south: 47.1, east: 9.7, north: 47.8)),
        Region(id: "geneva", name: "Lake Geneva", detail: "Genève, Lausanne, Montreux",
               bbox: BBox(west: 5.9, south: 46.1, east: 7.2, north: 46.8)),
        Region(id: "basel", name: "Basel & Aargau", detail: "Basel, Olten, Aarau",
               bbox: BBox(west: 7.3, south: 47.2, east: 8.5, north: 47.7)),
        Region(id: "ticino", name: "Ticino", detail: "Lugano, Bellinzona, Locarno",
               bbox: BBox(west: 8.4, south: 45.8, east: 9.3, north: 46.6)),
        Region(id: "valais", name: "Valais", detail: "Sion, Zermatt, Brig",
               bbox: BBox(west: 6.7, south: 45.9, east: 8.5, north: 46.5)),
        Region(id: "graubunden", name: "Graubünden", detail: "Chur, Davos, St. Moritz",
               bbox: BBox(west: 8.6, south: 46.2, east: 10.5, north: 47.1)),
    ]
}

/// What is stored for a region right now.
struct RegionState: Equatable {
    var progress: Double = 0
    var isDownloading = false
    var isStored = false
    var bytes: Int = 0
    /// What it will cost, asked before it is spent. See `estimate`.
    var estimatedBytes: Int?
    var isEstimating = false
    var error: String?
}

/// Per-region offline map storage.
///
/// The transit data — every stop, all 7,860 route relations, the whole railway
/// graph — ships with the app and is already on the device, so what is actually
/// downloadable is the *basemap*: the vector tiles Mapbox renders. That is the
/// large, per-area, optional part, and it is what this manages.
///
/// The other half of working offline is the fleet itself, and that is handled
/// where it is produced: every refresh writes the response straight to disk as
/// it streams (see `SnapshotWriter`), so the last snapshot is always there to
/// replay with no network at all.
@MainActor
@Observable
final class RegionStore {
    private let tileStore = TileStore.default
    private let offlineManager = OfflineManager()

    private(set) var states: [String: RegionState] = [:]
    private(set) var stylePackReady = false
    private(set) var totalBytes = 0

    /// Zoom 11 nationwide, 13 for a single area.
    ///
    /// Tile count grows fourfold per level, and the difference is not
    /// theoretical: Bern & Oberland to zoom 14 is 197 MB, and to 13 it is about
    /// a quarter of that. 13 still resolves individual streets, which is as much
    /// as a map of moving vehicles needs; 14 buys building outlines.
    private func zoomRange(for region: Region) -> ClosedRange<UInt8> {
        region.id == "ch" ? 0...11 : 0...13
    }

    func refreshStoredState() {
        tileStore.allTileRegions { [weak self] result in
            Task { @MainActor in
                guard let self, case let .success(regions) = result else { return }
                var total = 0
                for region in regions {
                    let bytes = Int(region.completedResourceSize)
                    total += bytes
                    var state = self.states[region.id] ?? RegionState()
                    state.isStored = region.completedResourceCount > 0
                    state.bytes = bytes
                    state.progress = state.isStored ? 1 : state.progress
                    self.states[region.id] = state
                }
                self.totalBytes = total
            }
        }
        offlineManager.allStylePacks { [weak self] result in
            Task { @MainActor in
                if case let .success(packs) = result { self?.stylePackReady = !packs.isEmpty }
            }
        }
    }

    /// The style itself — sprites, glyphs, the layer definitions — which every
    /// region needs and only needs once.
    func ensureStylePack(for basemap: Basemap) {
        let options = StylePackLoadOptions(
            glyphsRasterizationMode: .ideographsRasterizedLocally,
            metadata: ["basemap": basemap.rawValue],
            acceptExpired: true
        )
        guard let options else { return }
        offlineManager.loadStylePack(for: basemap.styleURI, loadOptions: options) { [weak self] result in
            Task { @MainActor in
                if case .success = result { self?.stylePackReady = true }
            }
        }
    }

    /// What a region would cost, without spending it.
    ///
    /// A download measured in hundreds of megabytes should be a decision, not a
    /// surprise, and the tile store can answer the question directly rather than
    /// leaving the app to guess from the area.
    func estimate(_ region: Region, basemap: Basemap) {
        guard states[region.id]?.estimatedBytes == nil,
              states[region.id]?.isEstimating != true,
              states[region.id]?.isStored != true
        else { return }

        var state = states[region.id] ?? RegionState()
        state.isEstimating = true
        states[region.id] = state

        guard let loadOptions = loadOptions(for: region, basemap: basemap) else {
            states[region.id]?.isEstimating = false
            return
        }

        tileStore.estimateTileRegion(forId: region.id, loadOptions: loadOptions) { _ in
        } completion: { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.states[region.id]?.isEstimating = false
                if case let .success(estimate) = result {
                    self.states[region.id]?.estimatedBytes = Int(estimate.storageSize)
                }
            }
        }
    }

    private func loadOptions(for region: Region, basemap: Basemap) -> TileRegionLoadOptions? {
        let descriptorOptions = TilesetDescriptorOptions(
            styleURI: basemap.styleURI,
            zoomRange: zoomRange(for: region),
            tilesets: nil
        )
        let descriptor = offlineManager.createTilesetDescriptor(for: descriptorOptions)
        return TileRegionLoadOptions(
            geometry: .polygon(region.polygon),
            descriptors: [descriptor],
            metadata: ["name": region.name],
            acceptExpired: true,
            // Offline packs are meant to survive a bad connection, not to be
            // refetched by one.
            networkRestriction: .none
        )
    }

    func download(_ region: Region, basemap: Basemap) {
        var state = states[region.id] ?? RegionState()
        state.isDownloading = true
        state.error = nil
        state.progress = 0
        states[region.id] = state

        ensureStylePack(for: basemap)

        guard let loadOptions = loadOptions(for: region, basemap: basemap) else {
            states[region.id]?.error = "could not describe the region"
            states[region.id]?.isDownloading = false
            return
        }

        tileStore.loadTileRegion(forId: region.id, loadOptions: loadOptions) { [weak self] progress in
            Task { @MainActor in
                let required = max(1, progress.requiredResourceCount)
                self?.states[region.id]?.progress =
                    Double(progress.completedResourceCount) / Double(required)
            }
        } completion: { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                var state = self.states[region.id] ?? RegionState()
                state.isDownloading = false
                switch result {
                case let .success(stored):
                    state.isStored = true
                    state.progress = 1
                    state.bytes = Int(stored.completedResourceSize)
                case let .failure(error):
                    state.error = String(describing: error)
                    state.progress = 0
                }
                self.states[region.id] = state
                self.refreshStoredState()
            }
        }
    }

    func remove(_ region: Region) {
        tileStore.removeRegion(forId: region.id) { [weak self] _ in
            Task { @MainActor in
                self?.states[region.id] = RegionState()
                self?.refreshStoredState()
            }
        }
    }
}
