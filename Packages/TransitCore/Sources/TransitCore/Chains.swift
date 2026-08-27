import Foundation

/// Link journeys that are physically the same vehicle.
///
/// A Swiss service often changes trip number partway along its run — an S1 is
/// renumbered at Gümligen, a Regio swaps numbers at Spiez — and the feed reports
/// each numbered leg as a separate journey. Drawn naively that is one dot
/// vanishing at the junction and an unrelated dot appearing beside it, when in
/// reality one train rolled through.
///
/// The feed carries no "continues as" field, so continuations are inferred. The
/// inference is deliberately cautious: a wrong link teleports a train across the
/// country, which is far worse than leaving two legs unlinked. Every candidate
/// must clear `candidateScore`, and the two journeys must each be the other's
/// best match before they are joined.
public enum Chains {
    /// A continuation departs after the arrival, but not much later.
    ///
    /// The two numbers are far apart because they describe different events. A
    /// journey continuing under the *same* line number is one service the feed
    /// happened to file in two pieces, and it may legitimately stand a while.
    /// A journey continuing under a *different* number is a renumbering, and a
    /// renumbering is a station dwell rather than a stand: the train stops, the
    /// number on it changes, it goes.
    ///
    /// Measured on a national snapshot, every plainly-correct renumbering in it
    /// dwells two minutes or less — Solothurn's RE5 becomes an S7 at Bern with
    /// no dwell at all, an IR15 becomes an S9 at Luzern in one minute. The
    /// wrong ones start at four and run to twelve: an RE48 terminating at
    /// Zürich HB was joined to an IR16 leaving for Bern eleven minutes later,
    /// which is not one train rolling onward but two trains sharing a platform.
    static let minGap = 0
    static let maxGapSameLine = 20 * 60
    static let maxGapRenumber = 3 * 60

    /// How much better the best candidate must be than the runner-up.
    ///
    /// At a junction like Olten several services leave within a few minutes of
    /// an arrival and any of them could be the continuation. When the top two
    /// are this close we have no basis to choose, so we link neither.
    static let ambiguityMargin = 5 * 60

    /// Guard against pathological chains from a bad match.
    static let maxChainLength = 5

    /// Score a possible A→B continuation, or nil if it fails a hard
    /// requirement. Lower is better.
    static func candidateScore(_ a: Journey, _ b: Journey) -> Int? {
        if a.id == b.id { return nil }
        if a.mode != b.mode { return nil }
        // Trip numbers are only unique per operator, and a handover between two
        // operators is not something we can confirm from this feed.
        if (a.operatorName ?? "") != (b.operatorName ?? "") { return nil }

        guard let end = a.stops.last, let begin = b.stops.first else { return nil }
        if end.name != begin.name { return nil }

        // Where the source identifies the exact platform, insist the
        // continuation leaves from the one the arrival came into.
        //
        // A train that rolls onward does not change platform to do it, so this
        // is both true and far stronger evidence than a matching station name —
        // at a junction where six services touch the same station within ten
        // minutes, the platform is what tells them apart.
        if let endRef = end.ref, let beginRef = begin.ref, endRef != beginRef { return nil }

        let gap = begin.dep - end.arr
        let sameLine = a.line == b.line
        if gap < minGap { return nil }

        if sameLine {
            if gap > maxGapSameLine { return nil }
            // A stated change of platform is a different train, whatever the
            // number on the front says.
            //
            // The renumbering branch below has always insisted on this; the
            // same-line branch did not, and it is the branch that runs for the
            // great majority of joins. Its only platform evidence was the SLOID
            // test above, which is skipped whenever either side names its stop
            // at station level — and at a terminus like Bern or Zürich HB that
            // is routine. So "same line, arrived within twenty minutes" was
            // enough on its own, and it is not: an IC6 into Bern platform 1 and
            // an IC6 out of Bern platform 7 are two trains that share a number,
            // not one train that rolled through.
            //
            // Only a *stated disagreement* rejects. Where the feed declines to
            // name a platform this says nothing, exactly as before — the point
            // is to stop assuming agreement, not to start demanding proof.
            if let arrived = end.platform, let leaves = begin.platform,
               !StopRegister.sameTrack(arrived, leaves) { return nil }
        } else {
            // A renumbering has to be evidenced, not merely permitted.
            //
            // The test above is skipped whenever either side names its stop at
            // station level — which is a third of these joins — so "same
            // platform" was being *assumed* exactly where the feed declined to
            // say. For a change of line number that assumption is the whole
            // link, so here the platform must actually be stated on both sides
            // and must agree. Sectors aside: an IR calls at `12A-C` where the
            // S-Bahn behind it calls at `12`, and those are one track.
            if gap > maxGapRenumber { return nil }
            guard StopRegister.sameTrack(end.platform, begin.platform) else { return nil }
        }

        // A working that heads back the way it came is a different service, not
        // this vehicle rolling onward.
        //
        // This has to hold for the *same* line above all. A tram 7 reaches
        // Ostring, waits, and leaves as a tram 7 the other way; an IR65 turns at
        // Biel. Joining those halves produced a stop list that ran out and back,
        // which showed the whole journey twice in the panel and — because route
        // matching walks stops in order — matched no relation at all.
        //
        // Comparing whole stop lists rather than just the turn is what catches
        // it: a genuine through-service carries on to new stations, while a
        // turnback revisits the ones it has just left.
        let called = Set(a.stops.dropLast().map(\.name))
        for stop in b.stops.dropFirst() where called.contains(stop.name) { return nil }

        return gap + (sameLine ? 0 : 10 * 60)
    }

    /// Group journeys into one entry per physical vehicle.
    ///
    /// Unlinked journeys come back unchanged; linked ones are flattened into a
    /// single journey carrying `parts`.
    public static func build(_ journeys: some Sequence<Journey>) -> [Journey] {
        let all = Array(journeys)
        guard !all.isEmpty else { return [] }

        // Index by the station a journey starts from, so finding the
        // continuations of a journey ending at X does not mean scanning the
        // entire fleet.
        var startingAt: [String: [Int]] = [:]
        for (i, j) in all.enumerated() {
            guard let first = j.stops.first else { continue }
            startingAt[first.name, default: []].append(i)
        }

        var bestNext: [Int: Link] = [:]
        var bestPrev: [Int: (index: Int, score: Int, runnerUp: Int)] = [:]

        for (i, a) in all.enumerated() {
            guard let last = a.stops.last else { continue }
            var winner = -1
            var winnerScore = Int.max
            var runnerUpScore = Int.max

            for j in startingAt[last.name] ?? [] {
                guard let score = candidateScore(a, all[j]) else { continue }
                if score < winnerScore {
                    runnerUpScore = winnerScore
                    winnerScore = score
                    winner = j
                } else if score < runnerUpScore {
                    runnerUpScore = score
                }
            }

            guard winner >= 0 else { continue }
            // Too close to call.
            if runnerUpScore != Int.max && runnerUpScore - winnerScore < ambiguityMargin { continue }

            bestNext[i] = Link(index: winner, score: winnerScore)
            if let held = bestPrev[winner] {
                if winnerScore < held.score {
                    bestPrev[winner] = (i, winnerScore, held.score)
                } else {
                    bestPrev[winner] = (held.index, held.score, min(held.runnerUp, winnerScore))
                }
            } else {
                bestPrev[winner] = (i, winnerScore, Int.max)
            }
        }

        // Only join where the choice is mutual and unambiguous from both sides:
        // A's best successor is B, and B has no other predecessor that fits
        // nearly as well. This is what keeps busy junctions from inventing
        // through-services.
        var next: [Int: Int] = [:]
        var hasPrev = Set<Int>()
        for (a, link) in bestNext {
            guard let prev = bestPrev[link.index], prev.index == a else { continue }
            if prev.runnerUp != Int.max && prev.runnerUp - prev.score < ambiguityMargin { continue }
            next[a] = link.index
            hasPrev.insert(link.index)
        }

        var chains: [[Int]] = []
        var used = Set<Int>()

        for head in all.indices where !hasPrev.contains(head) && !used.contains(head) {
            var chain = [head]
            used.insert(head)

            // Stations the chain has already called at, so a third leg cannot
            // double back over the first. `candidateScore` compares each link
            // against its immediate predecessor only, which is enough for a
            // pair but not for a chain: a bus running out, back, and out again
            // passed every pairwise test and arrived as one 28-stop vehicle
            // that visited Uster three times.
            var visited = Set(all[head].stops.dropLast().map(\.name))

            var link = next[head]
            while let current = link, chain.count < maxChainLength {
                if used.contains(current) { break } // a cycle would loop forever
                if all[current].stops.dropFirst().contains(where: { visited.contains($0.name) }) { break }

                chain.append(current)
                used.insert(current)
                for stop in all[current].stops.dropLast() { visited.insert(stop.name) }
                link = next[current]
            }
            chains.append(chain)
        }

        // Any journey caught in a cycle never became a head; emit it on its own
        // so it still appears on the map.
        for i in all.indices where !used.contains(i) {
            used.insert(i)
            chains.append([i])
        }

        let vehicles = chains.map { chain in
            chain.count == 1 ? all[chain[0]] : join(chain.map { all[$0] })
        }
        markLayovers(vehicles)
        return vehicles
    }

    // MARK: - Standing at the platform

    /// How long a terminating vehicle may be held on its platform.
    ///
    /// Long enough for the turnbacks the timetable is full of — of the 4,728
    /// terminations in a national snapshot that have a later departure from
    /// the same track, 83% leave again inside fifteen minutes — and short
    /// enough that a train which really did run empty to the depot is not left
    /// standing on the map all afternoon.
    static let maxLayover = 20 * 60

    /// Note, for each vehicle that terminates, how long it is still standing
    /// where it terminated.
    ///
    /// The reasoning is platform occupancy, which is a fact about the world
    /// rather than a guess about this train: a platform holds one vehicle at a
    /// time, so whatever leaves that track next is the bound on how long this
    /// one can still be on it. Where that next departure is the same operator
    /// running the same mode, the honest reading is that it *is* this train
    /// under another number, and it is held until then. Where it is not —
    /// another operator's working takes the track — this train must already
    /// have gone, and nothing is held.
    ///
    /// The platform has to be stated on both sides. It is the whole of the
    /// evidence here, exactly as it is for a renumbering in `candidateScore`,
    /// and a station name on its own would hold a train at Zürich HB because
    /// something else leaves Zürich HB.
    static func markLayovers(_ vehicles: [Journey]) {
        var startingAt: [String: [Journey]] = [:]
        for vehicle in vehicles {
            guard let first = vehicle.stops.first, first.platform != nil else { continue }
            startingAt[first.name, default: []].append(vehicle)
        }

        for vehicle in vehicles {
            vehicle.layover = nil
            vehicle.heldUntil = nil
        }

        for vehicle in vehicles {
            guard let end = vehicle.stops.last, end.platform != nil else { continue }

            var next: Journey?
            var nextDep = Timestamp.max
            for candidate in startingAt[end.name] ?? [] where candidate !== vehicle {
                guard let begin = candidate.stops.first,
                      begin.dep > end.arr,
                      begin.dep - end.arr <= maxLayover,
                      begin.dep < nextDep,
                      StopRegister.sameTrack(end.platform, begin.platform)
                else { continue }
                next = candidate
                nextDep = begin.dep
            }

            guard let next,
                  next.mode == vehicle.mode,
                  (next.operatorName ?? "") == (vehicle.operatorName ?? "")
            else { continue }

            // One second short of the departure, so the platform never holds
            // two vehicles: this one goes as the next appears.
            vehicle.layover = Layover(
                until: nextDep - 1, line: next.line, to: next.to, id: next.id
            )
            // The other half of the same fact, written where the departure can
            // read it: this train is already on the map until then, so the
            // working it becomes must not draw a second dot beside it.
            next.heldUntil = nextDep - 1
        }
    }

    /// A chosen continuation and how good the choice was.
    struct Link { var index: Int; var score: Int }

    /// Flatten a chain into one journey covering the whole physical run.
    static func join(_ chain: [Journey]) -> Journey {
        let head = chain[0]
        var stops = head.stops
        // Where each numbered leg sits in the joined stop list. Geometry is
        // matched per leg — no single relation covers a service that changes
        // number partway, so matching the joined run as a whole finds nothing.
        var ranges: [(start: Int, end: Int)] = [(0, stops.count - 1)]

        for part in chain.dropFirst() {
            guard let begin = part.stops.first else { continue }
            // The junction station is the previous leg's terminus and this
            // leg's origin; keep one entry, using the arrival we already have
            // and the departure of the leg about to run.
            let junctionIndex = stops.count - 1
            stops[junctionIndex].dep = begin.dep
            if stops[junctionIndex].platform == nil { stops[junctionIndex].platform = begin.platform }
            stops.append(contentsOf: part.stops.dropFirst())
            ranges.append((junctionIndex, stops.count - 1))
        }

        let terminus = chain[chain.count - 1]
        let joined = Journey(
            id: head.id, mode: head.mode, category: head.category, line: head.line,
            number: head.number, operatorName: head.operatorName, operatorFull: head.operatorFull,
            to: terminus.to, from: stops[0].name,
            delay: head.delay, start: stops[0].dep, end: stops[stops.count - 1].arr,
            complete: head.complete, monitored: head.monitored, cancelled: head.cancelled,
            source: head.source, stops: stops,
            // Shown in the detail panel so a renumbering is visible rather than
            // hidden, and used to match each leg to its own route relation.
            parts: chain.enumerated().map { i, p in
                JourneyPart(
                    id: p.id, line: p.line, number: p.number, category: p.category,
                    operatorName: p.operatorName, mode: p.mode, to: p.to,
                    from: p.stops.first?.name ?? "—",
                    start: ranges[i].start, end: ranges[i].end,
                    journeyRef: p.journeyRef
                )
            },
            // Taken from the head, as `complete`, `monitored` and `cancelled`
            // are: a chained run is filed under the working it starts as, and
            // each leg's own identity survives in `parts` regardless.
            extra: head.extra
        )
        // A correction in flight belongs to the vehicle, not to the object
        // chaining happens to have built for it. Without this, a re-time that
        // lands on a joined run is rebuilt into a fresh `Journey` with nothing
        // to walk off, and the glide that was meant to hide the jump becomes
        // the jump. Expiry is by wall clock, so copying a spent one is inert.
        joined.settle = head.settle
        return joined
    }
}
