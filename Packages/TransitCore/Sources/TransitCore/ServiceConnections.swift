import Foundation

/// A numbered working's coverage within the passenger's through-service.
public struct FormationLeg: Sendable, Equatable {
    public var key: FormationKey
    public var stops: ClosedRange<Int>
}

public extension FormationAtStop {
    var measuredLength: Double? {
        guard !coaches.isEmpty, coaches.allSatisfy({ ($0.length ?? 0) > 0 }) else { return nil }
        return coaches.reduce(0) { $0 + ($1.length ?? 0) }
    }

    var measuredSeats: Int? {
        let passenger = coaches.filter { $0.kind.carriesPassengers }
        guard !passenger.isEmpty,
              passenger.allSatisfy({ $0.seatsFirst != nil || $0.seatsSecond != nil }) else { return nil }
        return passenger.reduce(0) { $0 + ($1.seatsFirst ?? 0) + ($1.seatsSecond ?? 0) }
    }
}

public extension VehicleSnapshot {
    var formationLegs: [FormationLeg] {
        guard !stops.isEmpty else { return [] }
        if let parts, !parts.isEmpty {
            return parts.compactMap { part in
                guard stops.indices.contains(part.start), stops.indices.contains(part.end),
                      part.start <= part.end,
                      let key = FormationKey(
                        journeyID: formationReference(leg: part),
                        operationDate: FormationKey.operationDate(of: stops[part.start].sched ?? stops[part.start].dep)
                      ) else { return nil }
                return FormationLeg(key: key, stops: part.start...part.end)
            }.sorted { $0.stops.lowerBound < $1.stops.lowerBound }
        }
        guard let key = FormationKey(
            journeyID: formationReference(leg: nil),
            operationDate: FormationKey.operationDate(of: stops[0].sched ?? stops[0].dep)
        ) else { return [] }
        return [FormationLeg(key: key, stops: 0...(stops.count - 1))]
    }
}

public extension TrainFormation {
    /// Use each working only on its own stops. At a join, the outgoing
    /// working describes the assembled train; adding both lists would count
    /// the arriving coaches twice.
    static func combining(
        _ legs: [(leg: FormationLeg, formation: TrainFormation)], calls: [Call]
    ) -> TrainFormation? {
        let ordered = legs.sorted { $0.leg.stops.lowerBound < $1.leg.stops.lowerBound }
        guard var result = ordered.first?.formation else { return nil }
        var byIndex: [Int: FormationAtStop] = [:]
        var relationships: [Relationship] = []
        for entry in ordered {
            for relation in entry.formation.relationships where !relationships.contains(relation) {
                relationships.append(relation)
            }
            for index in entry.leg.stops where calls.indices.contains(index) {
                let call = calls[index]
                let matches = entry.formation.stops.filter { stop in
                    if let ref = call.ref, ref == String(stop.uic) { return true }
                    if let ref = call.ref,
                       let station = StopRegister.sloid(forDidok: String(stop.uic)) {
                        return StopRegister.stationOf(ref) == station
                    }
                    return Fleet.sameStop(call.name, stop.stopName)
                }
                guard var stop = matches.min(by: {
                    $0.distance(from: Date(timeIntervalSince1970: Double(call.arr)))
                        < $1.distance(from: Date(timeIntervalSince1970: Double(call.arr)))
                }), !stop.isEmpty else { continue }
                if let arriving = byIndex[index] {
                    stop.arrival = arriving.arrival ?? stop.arrival
                }
                byIndex[index] = stop
            }
        }
        result.stops = byIndex.keys.sorted().compactMap { byIndex[$0] }
        if let last = result.stops.last, let source = ordered.last?.formation,
           let index = source.stops.lastIndex(where: {
               $0.uic == last.uic || Fleet.sameListedStop($0.stopName, last.stopName)
           }), index + 1 < source.stops.count {
            result.stops.append(contentsOf: source.stops[(index + 1)...])
        }
        result.relationships = relationships
        if ordered.count > 1 {
            // These totals describe one working, not the assembled journey.
            result.totalLength = nil
            result.totalSeats = nil
            result.vehicleCount = nil
            result.axleCount = nil
        }
        return result.stops.isEmpty ? nil : result
    }
}

public extension JourneyLoad {
    /// A junction's outgoing forecast supersedes its arriving forecast, even
    /// if the platform reference changed between the two workings.
    func merging(_ onward: JourneyLoad) -> JourneyLoad {
        var result = self
        let stations = Set(onward.byStop.keys.map { StopRegister.stationOf($0) })
        result.byStop = result.byStop.filter { !stations.contains(StopRegister.stationOf($0.key)) }
        result.byStop.merge(onward.byStop) { _, new in new }
        return result
    }
}
