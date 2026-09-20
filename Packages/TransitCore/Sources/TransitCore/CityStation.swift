import Foundation

/// Resolves a town label to its principal railway station, not a nearby bus stop.
public enum CityStation {
    public static let maximumZoom = 10.0
    public static let searchRadius = 8_000.0

    public static func isEnabled(at zoom: Double) -> Bool {
        zoom.isFinite && zoom <= maximumZoom
    }

    public static func resolve(named name: String, near centre: Coord, among places: [StopPlace],
                               isRailway: (StopPlace) -> Bool = { $0.rail }) -> StopPlace? {
        let names = variants(name)
        guard !names.isEmpty, centre.lon.isFinite, centre.lat.isFinite else { return nil }
        let ranked = places.compactMap { place -> (place: StopPlace, rank: Int, distance: Double)? in
            guard place.lon.isFinite, place.lat.isFinite else { return nil }
            let distance = Geo.flatMetres(centre.lon, centre.lat, place.lon, place.lat)
            guard distance <= searchRadius else { return nil }
            var rank = 0
            for station in variants(place.name) {
                for city in names {
                    if station == city { rank = max(rank, 2) }
                    guard station.hasPrefix(city + " ") else { continue }
                    let suffix = String(station.dropFirst(city.count + 1))
                    if ["hb", "hbf", "hauptbahnhof", "sbb", "central", "centrale"].contains(suffix) {
                        rank = max(rank, 3)
                    } else if ["bahnhof", "gare", "stazione"].contains(suffix) {
                        rank = max(rank, 1)
                    }
                }
            }
            guard rank > 0, isRailway(place) else { return nil }
            return (place, rank, distance)
        }
        return ranked.sorted {
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.place.id < $1.place.id
        }.first?.place
    }

    private static func variants(_ name: String) -> [String] {
        name.split(separator: "/").map {
            StopPlaceStore.fold(String($0))
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }.filter { !$0.isEmpty }
    }
}
