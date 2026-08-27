import Foundation
import Observation
import TransitCore

/// Whether the phone is inside one of the vehicles on the map, and which.
///
/// The matching itself is `RideMatching` and `Fleet.rideCandidates`, which are
/// in the domain module and testable on the host. This is everything around it
/// that only makes sense on a device: the trail of fixes, how often it is worth
/// asking, and — the part that decides whether the feature is pleasant or
/// maddening — when an answer is settled enough to say out loud.
///
/// **Nothing contested is claimed on one agreement.** A fit is a measurement
/// over noisy input and the fleet moves underneath it; a badge that named a
/// different train every two seconds through Bern would be worse than no badge.
/// So a candidate with company has to win several asks in a row before it is
/// offered, and has to lose several in a row before it is taken away. The
/// asymmetry is deliberate: appearing is a claim and disappearing is only the
/// absence of one, so the first is made slowly and the second is not made in a
/// tunnel.
///
/// **A candidate with no company is claimed at once.** Repeating the ask is a
/// guard against picking the wrong train out of a crowd, and where the fleet
/// has offered exactly one journey going the same way at the same time there is
/// no crowd to pick out of. Making that case wait is a badge that arrives a
/// second and a half after the passenger already knew the answer, for no
/// evidence anybody gained. See `settle`.
@MainActor
@Observable
final class RideWatch {

    /// The service the phone appears to be on.
    struct Ride: Equatable, Identifiable {
        var id: String
        var line: String
        var mode: Mode
        var to: String?
        /// How far the timetable had to be slid to fit, in seconds. Not shown —
        /// it is evidence about the answer rather than part of it — but carried
        /// so the readout can print it.
        var shift: Double
        /// The mean separation of the winning fit, in metres. Likewise.
        var metres: Double
    }

    /// What the phone is on, once it has been said the same way several times.
    private(set) var ride: Ride?

    /// What to actually put on screen: the ride, unless this one has been
    /// swiped away.
    ///
    /// Opening it is deliberately *not* an answer to it. The bar is where the
    /// sheet stands while the panel is closed — pull it up for the panel, push
    /// it back down to the bar — and a ride that stopped being offered the
    /// moment it was taken left the sheet with no floor to come back down to,
    /// so closing the panel took the whole thing off the screen and the only
    /// way back to the train you were sitting on was to find it on the map.
    /// Refusing it is the one thing that ends it. See `dismiss`.
    var offering: Ride? {
        guard let ride, !silenced.contains(ride.id) else { return nil }
        return ride
    }

    /// Which journey is being offered, for the things that only need to know
    /// *whether the answer changed*.
    ///
    /// `Ride` carries the fit's shift and separation, and those are re-measured
    /// every ask — so the struct is unequal to itself a second and a half later
    /// while naming the same train. Anything driving an animation or a sheet
    /// off `offering` would be restarted by every one of those.
    var offeringID: String? { offering?.id }

    /// Whether the trail currently looks like the trail of something running.
    /// Read by the readout; the pill only ever sees `offering`.
    private(set) var moving = false

    /// Whether the badge is currently standing on the last fit made rather than
    /// on anything the phone is saying now. True in a tunnel.
    private(set) var holding = false

    /// Off means no asking and nothing offered. On by default: it costs one
    /// fleet walk every couple of seconds and only while the phone is actually
    /// travelling.
    var enabled = Settings.bool("rides.enabled", or: true) {
        didSet {
            guard enabled != oldValue else { return }
            Settings.set(enabled, "rides.enabled")
            if !enabled { forget() }
        }
    }

    /// Match against the clock the map is drawn to rather than only against
    /// real time. Set by `-rideDemo`, and by nothing else: a *real* trail says
    /// nothing about a virtual hour, which is why the guard is there at all.
    var ignoresClock = false

    // MARK: - The trail

    private var fixes: [RideFix] = []
    /// Journeys the passenger has said are not theirs, by swiping the bar away.
    private var silenced: Set<String> = []
    private var leader: String?
    private var agreements = 0
    private var misses = 0
    private var askedAt = Date.distantPast
    private var asking = false
    /// When the trail stopped looking like something running, or nil while it
    /// still does.
    private var stillSince: Date?
    /// When the fixes stopped arriving, or nil while they are.
    private var holdingSince: Date?
    private var holdCheckedAt = Date.distantPast

    /// How often the fleet is asked.
    ///
    /// Not per frame. The ask walks the national fleet and fits a few dozen
    /// journeys against the trail; the trail itself only grows a point a second,
    /// so asking thirty times a second would answer the same question thirty
    /// times with the same data.
    private static let interval: TimeInterval = 1.5
    /// Asks a candidate must win in a row before it is offered.
    ///
    /// Two rather than three, because the third was buying the wrong thing.
    /// What makes an early claim safe is the grading in `RideMatching` — a
    /// short trail has to fit tighter and beat the runner-up — and a repeat of
    /// the same ask a second and a half later adds a second and a half of
    /// trail, not a second opinion. One repeat still throws out a one-off.
    private static let agreementsWanted = 2
    /// And asks it must lose in a row before it is withdrawn.
    ///
    /// Ten, at a second and a half each: fifteen seconds of a good, fresh trail
    /// consistently failing to fit. Far more generous than the two agreements
    /// that put it there, and deliberately so — appearing is a claim and
    /// disappearing is only the absence of one. A cutting, a station throat or
    /// a run of poor fixes is over well inside it.
    private static let missesAllowed = 10

    /// A fix worse than this is not evidence of anything.
    private static let accurateEnough: Double = 70
    /// Fixes closer together in time than this are the same reading twice.
    private static let apart: Double = 0.7
    /// A break longer than this starts the trail again.
    ///
    /// A trail is a *trajectory*, and one built across a gap is not one: join a
    /// fix from before the Weinbergtunnel to a fix from after it and the phone
    /// appears to have crossed Zürich instantly, which fits nothing and would
    /// unseat a badge that is perfectly correct. So the trail restarts at the
    /// far end rather than spanning the gap. What it does *not* do is give up
    /// the answer — see `hold`.
    private static let gap: Double = 12
    /// A trail this stale is not describing where the phone is now.
    private static let stale: Double = 20
    /// How long the phone may be stationary before the claim is given up.
    ///
    /// Longer than any station stop and shorter than a walk to the tram: a
    /// train standing at a terminus for three minutes is still the train you
    /// are on, and a phone that has not moved for four is not on a train.
    ///
    /// Applied only to a phone that is *saying* it has not moved. No fixes at
    /// all is a different state and is not stillness — which it used to be
    /// treated as, so four minutes into the Gotthard the badge went out.
    private static let stillFor: TimeInterval = 240

    /// How long the badge is held on the last fit, with nothing arriving.
    ///
    /// The Gotthard base tunnel is twenty minutes at line speed and the
    /// Lötschberg is nine, so anything shorter than this would be a badge that
    /// works everywhere except on the routes it is most wanted. It is not a
    /// free pass: the journey has to still be running, checked against the
    /// fleet every ten seconds, and any fix that arrives is matched as usual.
    private static let holdFor: TimeInterval = 25 * 60
    private static let holdCheck: TimeInterval = 10

    /// A reading from the location provider.
    ///
    /// Everything Mapbox hands over is optional or sentinel-valued, so this is
    /// where the conversions happen and the rest of the class can assume the
    /// numbers mean what they say.
    func received(_ fix: RideFix) {
        guard enabled else { return }
        guard fix.coord.lat.isFinite, fix.coord.lon.isFinite, fix.at.isFinite else { return }
        // A negative accuracy is CoreLocation for "this is not a fix".
        guard fix.accuracy >= 0, fix.accuracy <= Self.accurateEnough else { return }
        if let last = fixes.last {
            guard fix.at > last.at + Self.apart else { return }
            // Out the far side of a gap, this fix and the one before it are not
            // two points of one path. Start again from here rather than draw a
            // line across the tunnel.
            if fix.at - last.at > Self.gap { fixes.removeAll(keepingCapacity: true) }
        }
        fixes.append(fix)

        // Pruned against the newest fix rather than against the wall clock, so
        // a replayed or synthesised trail behaves the same as a live one.
        let cutoff = fix.at - RideMatching.window
        if let oldest = fixes.first, oldest.at < cutoff {
            fixes.removeAll { $0.at < cutoff }
        }
        moving = RideMatching.isRiding(fixes)
    }

    /// Ask, if it is time to and there is anything worth asking about.
    ///
    /// Fire and forget: the answer comes back on the main actor and settles
    /// itself. Called from the draw loop, which must not wait on a walk of the
    /// fleet — a frame is 33 ms and this is 10.
    func consider(fleet: Fleet, clock: Clock) {
        guard enabled, !asking else { return }
        let moment = Date()

        // A trail that has stopped arriving is not evidence about now, so it is
        // dropped — but dropping the *evidence* is not the same as dropping the
        // *answer*, and conflating the two is what put the badge out in every
        // tunnel in the country. A train cannot change identity between
        // Erstfeld and Bodio. See `hold`.
        let fresh = fixes.last.map { moment.timeIntervalSince1970 - $0.at <= Self.stale } ?? false
        guard fresh else {
            if !fixes.isEmpty { fixes.removeAll(keepingCapacity: true) }
            if moving { moving = false }
            stillSince = nil
            hold(fleet: fleet, clock: clock, at: moment)
            return
        }
        holdingSince = nil
        if holding { holding = false }

        // Standing still for long enough is how a ride ends: you got off, and
        // the train the badge names is a train you can see leaving. Given a
        // clean slate rather than only forgotten, so the next thing boarded is
        // offered even if this one was pushed away.
        //
        // Reached only with fixes in hand, which is the whole correction: this
        // is a phone reporting that it is not moving, not a phone reporting
        // nothing at all.
        if moving {
            stillSince = nil
        } else {
            let since = stillSince ?? moment
            stillSince = since
            if ride != nil, moment.timeIntervalSince(since) >= Self.stillFor {
                forget()
                silenced.removeAll()
            }
        }

        // Only against real time. The clock is a dial on this map — hand it a
        // different number and it draws a different hour — and "which of these
        // is the phone inside" is a question only about now.
        guard clock.isLive || ignoresClock, moving else { return }
        guard moment.timeIntervalSince(askedAt) >= Self.interval else { return }
        askedAt = moment
        asking = true

        // The fixes are stamped in real time and the fleet is asked in the
        // clock's, which are the same thing while `isLive` holds and are still
        // allowed to differ by a minute or two inside it. Carrying the offset
        // rather than assuming it keeps that minute out of the shift search,
        // where it would be mistaken for a late train.
        let offset = clock.offset()
        let trail = fixes.map {
            RideFix(
                coord: $0.coord, at: $0.at + offset, speed: $0.speed,
                course: $0.course, accuracy: $0.accuracy
            )
        }
        let now = clock.nowSeconds()
        Task { [weak self] in
            let found = await fleet.rideCandidates(from: trail, at: now)
            self?.settle(found)
        }
    }

    /// Keep the badge through a stretch with nothing arriving.
    ///
    /// Everything the fit knew is still true — you were on that train fifteen
    /// seconds ago and there is no way off between here and the far portal —
    /// so the honest thing is to go on saying it, and the only claim that can
    /// go stale is that the service is still running at all. That one is
    /// checked, against the fleet, every ten seconds. It is what makes the
    /// difference between coasting and guessing.
    ///
    /// Bounded anyway. Twenty-five minutes covers the longest tunnel in the
    /// country with room to spare, and past it the phone has more likely been
    /// in a pocket since Bern than under the Alps.
    private func hold(fleet: Fleet, clock: Clock, at moment: Date) {
        guard let ride else {
            holdingSince = nil
            if holding { holding = false }
            return
        }
        let since = holdingSince ?? moment
        holdingSince = since
        if !holding { holding = true }

        guard moment.timeIntervalSince(since) < Self.holdFor else {
            forget()
            return
        }
        guard moment.timeIntervalSince(holdCheckedAt) >= Self.holdCheck else { return }
        holdCheckedAt = moment
        asking = true
        let id = ride.id
        let now = clock.nowSeconds()
        Task { [weak self] in
            let running = await fleet.isRunning(id: id, at: now)
            self?.settleHold(id, running: running)
        }
    }

    private func settleHold(_ id: String, running: Bool) {
        asking = false
        // The answer may have moved on while the ask was in flight.
        guard let ride, ride.id == id, !running else { return }
        forget()
    }

    /// Pushed off the bottom of the screen from the bar's own height: this is
    /// not my train, or I know, stop telling me.
    ///
    /// The only way a ride is put away. Pushing the panel back *down* to the
    /// bar is not this — that is the sheet returning to its floor, and the
    /// floor is still the train you are on.
    func dismiss() {
        guard let ride else { return }
        silenced.insert(ride.id)
    }

    /// Forget the answer without forgetting the trail.
    func forget() {
        ride = nil
        leader = nil
        agreements = 0
        misses = 0
        holdingSince = nil
        if holding { holding = false }
    }

    /// One line of evidence for the frame readout.
    var summary: String {
        guard enabled else { return "off" }
        if let ride, holding {
            let held = holdingSince.map { Int(Date().timeIntervalSince($0).rounded()) } ?? 0
            return "\(ride.line) · held \(held)s"
        }
        guard moving else { return fixes.isEmpty ? "no fix" : "still" }
        guard let ride else {
            return leader == nil
                ? "looking · \(Int(RideMatching.span(of: fixes).rounded()))s"
                : "maybe · \(agreements)/\(Self.agreementsWanted)"
        }
        return "\(ride.line) · \(Int(ride.metres.rounded()))m · \(Int(ride.shift.rounded()))s"
    }

    // MARK: - Settling

    private func settle(_ candidates: [RideCandidate]) {
        asking = false
        guard enabled else { return }
        let span = RideMatching.span(of: fixes)

        // **Keeping is easier than claiming.** Once a train has been named, any
        // plausible fit for it goes on naming it. The grading below is about
        // what it takes to *start*, and a trail that has just restarted at the
        // far end of a tunnel is short by definition — applying the strict test
        // to a badge that is already up would put it out at exactly the moment
        // it had just survived the tunnel intact.
        //
        // Unless something else fits clearly better, which is the one way a
        // wrong answer gets corrected rather than defended.
        if let standing = ride, let again = candidates.first(where: { $0.id == standing.id }) {
            let overtaken = candidates.first.map {
                $0.id != standing.id && again.fit.mean - $0.fit.mean >= RideMatching.widestMargin
            } ?? false
            if !overtaken {
                misses = 0
                leader = standing.id
                agreements = max(agreements, Self.agreementsWanted)
                let refreshed = Ride(
                    id: again.id, line: again.line, mode: again.mode, to: again.to,
                    shift: again.fit.shift, metres: again.fit.mean
                )
                if ride != refreshed { ride = refreshed }
                return
            }
        }

        // **Alone in the field is the whole answer.** The strict grading below
        // exists to tell one train from the trains beside it; where the fleet
        // has offered exactly one journey there is nothing to tell it apart
        // *from*. `rideCandidates` has already thrown out everything running
        // the other way, everything out of reach, and everything the shift
        // search could not slide onto the trail at any delay — so a field of
        // one is not "the best of a bad set", it is the only service in the
        // country whose path this phone could have been taking.
        //
        // Waiting a second and a half to say so again would buy nothing: the
        // repeat is not a second opinion, it is the same question asked of the
        // same fleet with one more fix in hand. So it is claimed on the spot,
        // against the ordinary threshold rather than the short-trail one,
        // which is the one place that tightening was only ever guarding
        // against a runner-up that does not exist here.
        let alone = candidates.count == 1

        // With company, what is worth saying out loud depends on how much trail
        // is behind it and on what else fitted: a twelve-second straight line
        // has to fit tighter, and has to beat the runner-up by a clear margin,
        // because every train on every parallel track fits a straight line
        // equally well.
        let claimable: RideCandidate? = candidates.first.flatMap { best in
            guard alone || best.fit.mean <= RideMatching.closeEnough(over: span)
            else { return nil }
            let clear = candidates.dropFirst().first.map {
                $0.fit.mean - best.fit.mean >= RideMatching.margin(over: span)
            } ?? true
            return clear ? best : nil
        }

        guard let best = claimable else {
            misses += 1
            agreements = 0
            if misses >= Self.missesAllowed {
                leader = nil
                // Only the answer is dropped. The trail is still good and the
                // very next ask may find the same train again.
                ride = nil
            }
            return
        }

        misses = 0
        if best.id == leader {
            agreements += 1
        } else {
            leader = best.id
            agreements = 1
        }
        // One candidate, no argument: the agreement count is what stands in for
        // a second opinion, and an uncontested fit has already had one.
        if alone { agreements = max(agreements, Self.agreementsWanted) }
        guard agreements >= Self.agreementsWanted else { return }

        let found = Ride(
            id: best.id, line: best.line, mode: best.mode, to: best.to,
            shift: best.fit.shift, metres: best.fit.mean
        )
        // A different train is a different question, so whatever was said about
        // the last one no longer applies to this one.
        if let ride, ride.id != found.id { silenced.remove(ride.id) }
        if ride != found { ride = found }
    }
}
