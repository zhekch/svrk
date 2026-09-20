import Foundation

public extension TrainFormation.Split {
    /// Passenger destinations, even when the incoming working terminates at
    /// the junction. Resolved children can run beyond a coach goal (Brig →
    /// Domodossola), so their advertised endpoints supersede those goals.
    func destinations(continuingTo _: String? = nil, resolved: [Int: String] = [:]) -> [String] {
        // Keep a portion that terminates at the junction — coaches 8–14 to Brig
        // on an EC that also continues to Milano. Filtering out the split
        // station hid that half, after which the Swiss working's last border
        // stop (Domodossola) was advertised as if it were a destination.
        var unique: [String] = []
        for name in portions.compactMap({ resolved[$0.fromPosition] ?? $0.destination })
        where !unique.contains(where: { Fleet.sameStop($0, name) }) {
            unique.append(name)
        }
        return unique
    }

    func isUpcoming(for vehicle: VehicleSnapshot, at now: Timestamp) -> Bool {
        let station = StopRegister.sloid(forDidok: String(stopUIC))
        guard let index = vehicle.stops.firstIndex(where: {
            (station != nil && StopRegister.stationOf($0.ref) == station)
                || Fleet.sameStop($0.name, stopName)
        }) else {
            return moment.map { now < Timestamp($0.timeIntervalSince1970) } ?? false
        }
        // A departing portion whose route starts here has already separated.
        guard index > 0 else { return false }
        return vehicle.index < index || (vehicle.index == index && !vehicle.moving)
    }
}

extension Chains {
    /// The published graph, resolved against the fleet in hand.
    ///
    /// Resolution is the whole of the work here, and it is mostly about being
    /// careful with two things.
    ///
    /// **A working can be named two ways.** The packed timetable files a
    /// journey under its GTFS `trip_id` and SIRI files the same run under its
    /// Swiss Journey ID, so both are tried. `id` is unique and is preferred;
    /// a journey reference is *not* unique — it is duplicated across some runs
    /// — so it resolves only where exactly one journey carries it.
    ///
    /// **A declared successor that is not on screen is still an answer.** The
    /// map draws ninety minutes and the country is bigger than that, so a link
    /// routinely names a working that has not been expanded. The feed has still
    /// said what this train does, and inferring something else instead is how a
    /// split becomes one branch folded into the parent with the other drawn
    /// beside it. So `declared` counts what the feed said and `present` counts
    /// what can be drawn, and they are used for different questions.
    struct Stated {
        /// How many distinct successors the feed named, on screen or not.
        private var declared: [Int: Int] = [:]
        /// The ones that resolved to a journey this fleet actually holds.
        private(set) var successors: [Int: [Int]] = [:]
        private var predecessors: [Int: [Int]] = [:]
        private var named = Set<Int>()

        /// Whether the feed said anything about this working — in which case
        /// the inference must keep its hands off it, in both directions.
        func mentions(_ index: Int) -> Bool { named.contains(index) }

        /// Whether this working parts rather than continues.
        func parts(_ index: Int) -> Bool { (declared[index] ?? 0) > 1 }

        /// Of the workings that join into `index`, the one that carries the
        /// number onward. The others terminate and are held on the platform.
        ///
        /// Two trains coupling is one train leaving, and chaining both into it
        /// would draw the departure twice — the second half of the Spiez
        /// duplicate. The choice is arbitrary in principle and so is made
        /// deterministic in practice: the working that has run furthest, then
        /// the lower id, so a rebuild does not swap them and flicker.
        func principal(into index: Int) -> Int? { predecessors[index]?.first }

        init(_ graph: ThroughGraph, in all: [Journey]) {
            guard !graph.isEmpty else { return }

            // Folded once per journey, because `ThroughLink` names arrive
            // already folded — see its documentation. Doing it the other way
            // round meant re-folding every link name on every chain rebuild,
            // which is 75,000 throwaway strings each time the fleet changes.
            var byID: [String: Int] = [:]
            var byRef: [String: [Int]] = [:]
            byID.reserveCapacity(all.count)
            for (i, journey) in all.enumerated() {
                byID[journey.id.lowercased()] = i
                if let ref = journey.journeyRef, !ref.isEmpty, ref != journey.id {
                    byRef[ref.lowercased(), default: []].append(i)
                }
            }
            func resolve(_ names: [String]) -> Int? {
                for name in names { if let found = byID[name] { return found } }
                for name in names {
                    // Only where it is unambiguous. A reference shared by two
                    // occurrences names neither of them.
                    if let found = byRef[name], found.count == 1 { return found[0] }
                }
                return nil
            }

            /// One name for a working, so the same successor reaching us from
            /// the timetable and from the formation service is counted once.
            ///
            /// Without this the two sources disagree about a working's *name* —
            /// the timetable offers a `trip_id` and a journey reference, the
            /// formation service only the reference — and a continuation named
            /// by both would look like two successors, which is to say a split
            /// that does not happen.
            func canonical(_ names: [String]) -> String {
                for name in names where name.contains(":sjyid:") { return name }
                return names.joined(separator: "|")
            }

            var declaredResolved: [Int: Set<Int>] = [:]
            var declaredOffscreen: [Int: Set<String>] = [:]

            for link in graph.links {
                let from = resolve(link.from)
                let to = resolve(link.to)
                // Either end being named is enough to put it out of the
                // inference's reach, and both ends have to be marked before
                // the other is known to be here. A working whose *predecessor*
                // is off screen is the ordinary case at the edge of the drawn
                // window, and leaving it unmarked let the inference adopt it as
                // the continuation of some third train standing at the same
                // platform — which is the wrong link this is meant to end.
                if let from { named.insert(from) }
                if let to { named.insert(to) }
                guard let from else { continue }
                guard let to, to != from else {
                    // Named, but not on screen. Still an answer: it is what
                    // stops the inference offering a different one.
                    declaredOffscreen[from, default: []].insert(canonical(link.to))
                    continue
                }
                declaredResolved[from, default: []].insert(to)
                guard Self.adjacent(all[from], all[to]) else { continue }
                if !(successors[from]?.contains(to) ?? false) {
                    successors[from, default: []].append(to)
                }
                if !(predecessors[to]?.contains(from) ?? false) {
                    predecessors[to, default: []].append(from)
                }
            }

            for index in Set(declaredResolved.keys).union(declaredOffscreen.keys) {
                declared[index] = (declaredResolved[index]?.count ?? 0)
                    + (declaredOffscreen[index]?.count ?? 0)
            }

            for (to, froms) in predecessors where froms.count > 1 {
                predecessors[to] = froms.sorted {
                    let a = all[$0], b = all[$1]
                    let aStart = a.stops.first?.dep ?? a.start
                    let bStart = b.stops.first?.dep ?? b.start
                    return aStart == bStart ? a.id < b.id : aStart < bStart
                }
            }
        }

        /// How long after an arrival a published continuation may still leave.
        ///
        /// Longer than the inference's twenty minutes, because the inference is
        /// using the gap as *evidence* and this is not — the feed has already
        /// said these are one vehicle, and the only job left is to notice when
        /// the two objects in hand are plainly not the pair it meant. An hour
        /// rejects a retained journey from another day without second-guessing
        /// a border stop that genuinely stands for forty minutes.
        static let maxPublishedDwell: Timestamp = 60 * 60

        /// Whether these two objects can be the pair the feed meant.
        ///
        /// Not a scoring function and not a second opinion: a stale journey
        /// retained from an earlier day resolves by name just as well as
        /// today's, and joining it walks the vehicle across the country.
        static func adjacent(_ a: Journey, _ b: Journey) -> Bool {
            guard let end = a.stops.last, let begin = b.stops.first else { return false }
            guard stationKey(end) == stationKey(begin) else { return false }
            let gap = begin.dep - end.arr
            return gap >= -60 && gap <= maxPublishedDwell
        }

        /// Hold the platform where a train parts or two trains couple.
        ///
        /// Both are the same fact seen from two sides: for a while there is one
        /// vehicle standing on one track, and whatever it becomes must not be
        /// drawn beside it until it actually goes.
        func markHandovers(in vehicles: [Journey], of all: [Journey]) {
            guard !named.isEmpty else { return }

            var byPart: [String: Journey] = [:]
            for vehicle in vehicles {
                byPart[vehicle.id] = vehicle
                for part in vehicle.parts ?? [] { byPart[part.id] = vehicle }
            }

            // --- a train that parts ---
            for (from, children) in successors where parts(from) {
                guard let source = byPart[all[from].id], let end = source.stops.last else { continue }
                let halves = children.compactMap { byPart[all[$0].id] }
                guard let first = halves.min(by: { $0.stops[0].dep < $1.stops[0].dep })
                else { continue }
                // Keep the coupled train through the dwell, then hand over every
                // portion together when the first of them departs.
                let handover = max(end.arr + 1, first.stops[0].dep)
                // There is no single outgoing identity for the panel to switch
                // to, so the layover names none.
                source.layover = Layover(until: handover - 1)
                source.splitContinuations = halves.map(\.id)
                for child in halves {
                    child.heldUntil = handover - 1
                    child.splitAppearance = handover
                }
            }

            // --- two trains that couple ---
            for (to, froms) in predecessors where froms.count > 1 {
                guard let onward = byPart[all[to].id], let begin = onward.stops.first
                else { continue }
                let principal = froms.first
                for from in froms where from != principal {
                    guard let spare = byPart[all[from].id], spare !== onward else { continue }
                    // It is standing on the platform until the coupled train
                    // goes, and then it has gone — as that train, under the
                    // number the principal half carries.
                    spare.layover = Layover(
                        until: begin.dep - 1, line: onward.line, to: onward.to, id: onward.id
                    )
                }
            }
        }
    }

    /// Follow the requested portion, or the unique continuation of the same
    /// advertised line. An ambiguous split never silently chooses a branch.
    static func continuation(
        of source: Journey, among children: [Journey], preferredID: String?, at now: Timestamp
    ) -> Journey? {
        guard let handover = source.layover?.until, now > handover else { return nil }
        // The incoming working has to have actually arrived. A split that
        // happened hours ago must not retarget a train that is still running
        // — that is the Domodossola→Bern / Bern→Domodossola flicker.
        guard let end = source.stops.last, now >= end.arr else { return nil }
        let outgoing = children.filter { source.splitContinuations.contains($0.id) && !$0.cancelled }
        if let preferredID { return outgoing.first { $0.id == preferredID } }
        let sameDestination = outgoing.filter { $0.to == source.to }
        if sameDestination.count == 1 { return sameDestination[0] }
        let sameLine = outgoing.filter { $0.line == source.line }
        return sameLine.count == 1 ? sameLine[0] : nil
    }
}

// The formation service's own through-services live here rather than beside
// `ThroughLink` because they need `TrainFormation`, and the watch compiles a
// hand-picked subset of this module that has the link types but no formation
// service at all. Keeping `ThroughServices.swift` free of that dependency is
// what lets the watch read the packed graph.

public extension TrainFormation {
    /// The formation service's own through-service links, in the shared shape.
    ///
    /// The realtime formation feed answers the same question the timetable
    /// does, for the trains it covers, and it is the only source that knows
    /// about a working put together this morning. `T` is a separation and names
    /// both halves; `F` is a continuation and `Z` a join, each naming one other
    /// working, with `direction` saying which side of this train it is on.
    ///
    /// `W` (a turnaround) is deliberately not here. The train does continue, but
    /// it continues *back the way it came*, and joining those halves draws both
    /// directions of a line as one vehicle running out and back.
    func throughLinks(ownedBy mine: [String]) -> [ThroughLink] {
        var out: [ThroughLink] = []
        let me = mine.filter { !$0.isEmpty }.map { $0.lowercased() }
        guard !me.isEmpty else { return [] }

        for relation in relationships {
            let others = relation.others.compactMap { working -> [String]? in
                let names = [working.journeyID].compactMap { $0 }
                    .filter { !$0.isEmpty }.map { $0.lowercased() }
                return names.isEmpty ? nil : names
            }
            guard !others.isEmpty else { continue }

            switch relation.kind {
            case .separation:
                // Both halves, and only where both are named: half a split is
                // not a split, it is a continuation that hides the other
                // branch. `direction` is `N` when they follow this working.
                guard relation.direction == .after, others.count >= 2 else { continue }
                for other in others { out.append(ThroughLink(from: me, to: other)) }
            case .continuation, .merge:
                guard let other = others.first else { continue }
                switch relation.direction {
                case .after: out.append(ThroughLink(from: me, to: other))
                case .before: out.append(ThroughLink(from: other, to: me))
                case nil: continue
                }
            case .turnaround, .relief, .substitute, .rerouting:
                continue
            }
        }
        return out
    }
}
