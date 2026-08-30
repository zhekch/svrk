import Foundation

/// Which service the phone is *inside*, worked out from where it has been.
///
/// Switzerland publishes no vehicle positions, so there is nothing to compare a
/// phone against directly — but a journey is a timed polyline and the phone is
/// a stream of timed points, and two timed lines either lie on top of one
/// another or they do not. That is the whole method: take the last minute or so
/// of fixes, ask each running journey where it was at each of those moments,
/// and keep the one that was in the same place every time.
///
/// **The lag is the difficult part.** A drawn position comes from the timetable
/// with whatever delay the feed states applied to it, and the residual — the
/// minute the train has lost since the last poll, the thirty seconds it is
/// standing over — is not in the data at all. At line speed a minute is two
/// kilometres, so comparing instants would reject the train you are sitting on
/// and accept nothing else. So the fit is taken over a *shift* as well: the
/// phone's clock is slid against the timetable's until the two lines agree
/// best, and how far it had to slide is reported rather than hidden.
///
/// **It is a trajectory match, not a proximity match.** A single point near a
/// train means nothing — a level crossing puts a car within ten metres of an
/// intercity. A minute of points that stay with it, through a curve and a
/// station stop, means one thing only.
public struct RideFix: Sendable, Equatable {
    public var coord: Coord
    /// Unix seconds, on the same clock the fleet is asked about.
    public var at: Double
    /// Metres per second, or nil where the fix does not say.
    public var speed: Double?
    /// Course over ground in degrees, or nil where the fix does not say.
    ///
    /// Deliberately not a heading: which way the phone is *pointing* is the
    /// passenger's business and says nothing at all about the train it is on.
    public var course: Double?
    /// The published horizontal accuracy, in metres.
    public var accuracy: Double

    public init(
        coord: Coord, at: Double, speed: Double? = nil,
        course: Double? = nil, accuracy: Double = 0
    ) {
        self.coord = coord
        self.at = at
        self.speed = speed
        self.course = course
        self.accuracy = accuracy
    }
}

/// How well one journey explains a run of fixes.
public struct RideFit: Sendable, Equatable {
    /// Seconds added to the phone's clock to line the timetable up with it.
    ///
    /// Positive means the drawn vehicle is *behind* where the phone actually
    /// is — the service is running ahead of the times in hand. Negative means
    /// the map is drawing it further along the line than it has got.
    public var shift: Double
    /// The mean separation at that shift, in metres. The score.
    public var mean: Double
    /// The separation nine tenths of the fixes are inside.
    ///
    /// What this rejects is a fit that is good in the middle of the window and
    /// wrong at both ends — two lines crossing rather than two lines
    /// coinciding, which the mean alone can be talked into accepting.
    ///
    /// A high-water mark rather than *the* high-water mark, and measured that
    /// way after the plain maximum was found to veto perfectly good fits on the
    /// strength of one artefact of the drawing. The model dwells at a platform
    /// for the timetable's dwell; a real train that stands for thirty seconds
    /// where the timetable says sixty is three hundred metres from its drawn
    /// position for as long as the difference lasts, and is still obviously the
    /// train you are on. Two lines that genuinely cross are wrong in most of
    /// the window, not a tenth of it.
    public var stray: Double
    /// How many fixes were compared.
    public var samples: Int

    public init(shift: Double, mean: Double, stray: Double, samples: Int) {
        self.shift = shift
        self.mean = mean
        self.stray = stray
        self.samples = samples
    }
}

public enum RideMatching {
    /// How long a trail of fixes is kept and matched against.
    ///
    /// Long enough to contain a curve or a station stop — the features that
    /// tell two parallel lines apart — and no longer, which is the part that
    /// had to be measured rather than guessed.
    ///
    /// A shift slides the timetable against the phone; it cannot *stretch* it.
    /// So where a train's rate differs from the one the timetable implies —
    /// running late out of a station and recovering it by the next, which is
    /// the commonest thing a delayed train does — the residual grows with the
    /// span of the trail rather than averaging out. Measured on a twenty
    /// kilometre leg against a train recovering two minutes: 23 m of mean error
    /// over twelve seconds of trail, 60 m over thirty-five, and 168 m over a
    /// hundred, which is past every threshold here. A longer trail was buying
    /// discrimination up to `settledSpan` and buying error after it.
    public static let window: Double = 50

    /// How far the phone's clock may be slid against the timetable.
    ///
    /// Two and a half minutes. Beyond that the search costs more and admits
    /// more: at line speed six kilometres of track come into range, which is
    /// long enough to reach a genuinely different train.
    public static let maxShift: Double = 150
    /// The sweep is coarse first and then fine around the winner. The
    /// separation-against-shift curve is a shallow V — a train pulling away
    /// from you at its own speed — so a coarse minimum is always in the right
    /// basin, and the fine pass only has to find the bottom of it.
    public static let coarseStep: Double = 15
    public static let fineStep: Double = 1.5

    /// A coarse fit worse than this is not refined. Purely a saving: the fine
    /// pass is twenty more evaluations of a candidate that is kilometres out.
    public static let coarseCutoff: Double = 500

    /// The mean separation at which a journey is plausible.
    ///
    /// Generous on purpose. A GPS fix inside a metal tube is worth tens of
    /// metres on a good day, the drawn position is a point on a route relation
    /// rather than on the rail actually under the train, and both ends of a
    /// four-hundred-metre intercity are the same journey.
    public static let nearEnough: Double = 130
    /// And nine tenths of the fixes have to be inside this, however good the
    /// average. See `RideFit.stray`.
    public static let strayAllowed: Double = 300
    /// Which tenth is allowed to be outside it.
    public static let strayShare: Double = 0.9

    /// The shape a trail has to have before it is worth matching at all.
    ///
    /// Twelve seconds and a hundred and eighty metres, which at line speed is
    /// six seconds of running and is reached about as soon as a train has
    /// finished pulling out. The gates used to be twenty and three hundred,
    /// which cost half a minute for evidence that was not doing the work: what
    /// tells two trains apart is not how *long* the trail is but how much of it
    /// disagrees, and that is measured below, per fit, rather than assumed here.
    public static let minimumFixes = 4
    public static let minimumSpan: Double = 12
    /// Metres a second: about 23 km/h. Below this you are walking, cycling or
    /// stuck in traffic, and none of those is a service this app can name.
    public static let movingAt: Double = 6.5
    /// And the trail has to go somewhere. A phone sitting on a platform reads a
    /// few metres a second of noise; a phone on a train covers a kilometre.
    public static let minimumTravel: Double = 180

    /// The span at which a trail has shown enough of itself to be taken at face
    /// value.
    ///
    /// Between `minimumSpan` and here, what is claimed is graded by what has
    /// been seen. A twelve-second trail is a straight line — every train on
    /// every parallel track fits a straight line — so a fit made on one has to
    /// be *better*, and has to beat the runner-up by a clear margin, before it
    /// is worth saying out loud. By thirty-five seconds there is a curve or a
    /// station stop in it and the ordinary thresholds do.
    ///
    /// This is what buys the shorter gates above without buying a badge that
    /// names the intercity overtaking you.
    public static let settledSpan: Double = 35
    /// What a fit must be worth on the shortest trail there is.
    public static let tightEnough: Double = 70
    /// And how far the runner-up must be behind it on one.
    public static let widestMargin: Double = 45

    /// How close a fit has to be to be claimed, given how much trail is behind
    /// it: `tightEnough` at `minimumSpan`, easing to `nearEnough` by
    /// `settledSpan`.
    public static func closeEnough(over span: Double) -> Double {
        tightEnough + (nearEnough - tightEnough) * settled(span)
    }

    /// How far behind the runner-up must be, on the same scale — nothing at all
    /// once the trail has settled, because two candidates that both fit a
    /// thirty-five-second trail are two portions of one train far more often
    /// than they are two trains.
    public static func margin(over span: Double) -> Double {
        widestMargin * (1 - settled(span))
    }

    private static func settled(_ span: Double) -> Double {
        guard settledSpan > minimumSpan else { return 1 }
        return min(1, max(0, (span - minimumSpan) / (settledSpan - minimumSpan)))
    }

    /// The span of a trail, in seconds.
    public static func span(of fixes: [RideFix]) -> Double {
        guard let first = fixes.first, let last = fixes.last else { return 0 }
        return last.at - first.at
    }

    /// The best shift for these fixes against one journey's positions, or nil
    /// where the journey cannot answer for the whole window.
    ///
    /// `sample` is asked for a coordinate at an arbitrary instant and returns
    /// nil outside the journey's own life, which is what keeps a service that
    /// terminated thirty seconds ago from matching the last third of a trail.
    public static func fit(_ fixes: [RideFix], to sample: (Double) -> Coord?) -> RideFit? {
        guard fixes.count >= minimumFixes else { return nil }

        // The coarse pass runs on four fixes rather than on all of them. It is
        // twenty-one evaluations per candidate and its only job is to find the
        // basin; the ends and a couple of points between them locate that just
        // as well as a dozen do, at a third of the cost.
        let sketch = thinned(fixes)
        var best: (shift: Double, mean: Double)?
        var shift = -maxShift
        while shift <= maxShift + 0.001 {
            if let mean = meanSeparation(sketch, shifted: shift, sample),
               mean < best?.mean ?? .infinity {
                best = (shift, mean)
            }
            shift += coarseStep
        }
        guard let coarse = best, coarse.mean <= coarseCutoff else { return nil }

        // The fine pass minimises the mean, which is the only thing the search
        // is steering by. The stray is measured once, at the winner: it is a
        // sort, and doing one per shift per candidate would be the most
        // expensive thing in the ask for a number nothing chooses on.
        var found: (shift: Double, mean: Double, samples: Int)?
        var fine = coarse.shift - coarseStep
        let last = coarse.shift + coarseStep
        while fine <= last + 0.001 {
            if let scored = score(fixes, shifted: fine, sample),
               scored.mean < found?.mean ?? .infinity {
                found = scored
            }
            fine += fineStep
        }
        guard let best = found, let stray = stray(fixes, shifted: best.shift, sample)
        else { return nil }
        return RideFit(
            shift: best.shift, mean: best.mean, stray: stray, samples: best.samples
        )
    }

    /// Whether this fit is worth carrying back to the caller at all.
    ///
    /// Deliberately the loose test. Whether it is worth *claiming* depends on
    /// how much trail is behind it and on what else fitted, and neither of
    /// those is a question about one fit — see `closeEnough` and `margin`,
    /// which `RideWatch` applies to the field this returns.
    public static func isRide(_ fit: RideFit) -> Bool {
        fit.mean <= nearEnough && fit.stray <= strayAllowed && fit.samples >= minimumFixes
    }

    /// Ground covered by the trail, in metres.
    public static func travelled(_ fixes: [RideFix]) -> Double {
        guard fixes.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<fixes.count {
            total += Geo.flatMetres(
                fixes[i - 1].coord.lon, fixes[i - 1].coord.lat,
                fixes[i].coord.lon, fixes[i].coord.lat
            )
        }
        return total
    }

    /// Whether the trail is the trail of something running rather than of
    /// somebody standing still.
    ///
    /// Both halves are needed. Speed alone accepts the noise a stationary phone
    /// reads at a platform edge, and distance alone accepts a walk to the far
    /// end of a station; a phone that is both fast *and* getting somewhere is
    /// on board something.
    public static func isRiding(_ fixes: [RideFix]) -> Bool {
        guard fixes.count >= minimumFixes, let first = fixes.first, let last = fixes.last,
              last.at - first.at >= minimumSpan
        else { return false }
        guard travelled(fixes) >= minimumTravel else { return false }
        // The fix's own speed where it has one, and the trail's where it does
        // not — a simulator's replayed track has no speeds at all.
        let stated = fixes.compactMap { $0.speed }.filter { $0 >= 0 }
        let pace = stated.isEmpty
            ? travelled(fixes) / max(1, last.at - first.at)
            : stated.reduce(0, +) / Double(stated.count)
        return pace >= movingAt
    }

    /// Whether the newest fixes describe a phone resting in one place.
    ///
    /// This is intentionally stricter than simply being "not riding". A walk
    /// through a station and the first seconds after leaving a vehicle are both
    /// not rides, but neither is permission to announce a stop. The recent
    /// fixes must span several seconds, report walking speed or less, and fit
    /// inside the uncertainty-sized circle around the newest fix.
    public static func isStill(_ fixes: [RideFix]) -> Bool {
        guard let last = fixes.last, last.accuracy <= 35 else { return false }
        let recent = fixes.filter { last.at - $0.at <= 12 }
        guard recent.count >= 4, let first = recent.first,
              last.at - first.at >= 6
        else { return false }

        let stated = recent.compactMap { $0.speed }.filter { $0 >= 0 }
        if !stated.isEmpty,
           stated.reduce(0, +) / Double(stated.count) > 1.0 {
            return false
        }

        let span = max(1, last.at - first.at)
        let net = Geo.flatMetres(
            first.coord.lon, first.coord.lat, last.coord.lon, last.coord.lat
        )
        guard net / span <= 1.1 else { return false }

        // A good GPS fix should form a tight cluster; a less exact one gets
        // room equal to its own honest uncertainty, but never enough to cover
        // a person walking from one stop side to another.
        let widestAccuracy = recent.map(\.accuracy).max() ?? last.accuracy
        let radius = max(12, min(30, widestAccuracy))
        return recent.allSatisfy {
            Geo.flatMetres(
                $0.coord.lon, $0.coord.lat, last.coord.lon, last.coord.lat
            ) <= radius
        }
    }

    /// The smallest turn between two bearings, in degrees.
    public static func turn(_ a: Double, _ b: Double) -> Double {
        let raw = abs((a - b).truncatingRemainder(dividingBy: 360))
        return raw > 180 ? 360 - raw : raw
    }

    // MARK: - Scoring

    private static func score(
        _ fixes: [RideFix], shifted by: Double, _ sample: (Double) -> Coord?
    ) -> (shift: Double, mean: Double, samples: Int)? {
        var total = 0.0
        var samples = 0
        for fix in fixes {
            guard let at = sample(fix.at + by) else { return nil }
            total += Geo.flatMetres(at.lon, at.lat, fix.coord.lon, fix.coord.lat)
            samples += 1
        }
        guard samples >= minimumFixes else { return nil }
        return (by, total / Double(samples), samples)
    }

    /// The separation `strayShare` of the fixes are inside, at one shift.
    ///
    /// On a short trail this is the maximum and is meant to be: with thirteen
    /// fixes the ninetieth percentile *is* the twelfth of thirteen. It only
    /// begins to forgive once there are enough samples for one of them to be
    /// an artefact rather than a disagreement.
    private static func stray(
        _ fixes: [RideFix], shifted by: Double, _ sample: (Double) -> Coord?
    ) -> Double? {
        var apart: [Double] = []
        apart.reserveCapacity(fixes.count)
        for fix in fixes {
            guard let at = sample(fix.at + by) else { return nil }
            apart.append(Geo.flatMetres(at.lon, at.lat, fix.coord.lon, fix.coord.lat))
        }
        guard !apart.isEmpty else { return nil }
        apart.sort()
        let at = Int((Double(apart.count - 1) * strayShare).rounded())
        return apart[at]
    }

    private static func meanSeparation(
        _ fixes: [RideFix], shifted by: Double, _ sample: (Double) -> Coord?
    ) -> Double? {
        var total = 0.0
        for fix in fixes {
            guard let at = sample(fix.at + by) else { return nil }
            total += Geo.flatMetres(at.lon, at.lat, fix.coord.lon, fix.coord.lat)
        }
        return total / Double(fixes.count)
    }

    /// Both ends and a couple of points between them.
    static func thinned(_ fixes: [RideFix], to wanted: Int = 4) -> [RideFix] {
        guard fixes.count > wanted else { return fixes }
        let step = Double(fixes.count - 1) / Double(wanted - 1)
        return (0..<wanted).map { fixes[Int((Double($0) * step).rounded())] }
    }
}

/// A journey that could be the one the phone is inside.
public struct RideCandidate: Sendable, Equatable, Identifiable {
    public var id: String
    public var line: String
    public var mode: Mode
    public var category: String?
    public var to: String?
    public var operatorName: String?
    public var fit: RideFit

    public init(
        id: String, line: String, mode: Mode, category: String? = nil,
        to: String? = nil, operatorName: String? = nil, fit: RideFit
    ) {
        self.id = id
        self.line = line
        self.mode = mode
        self.category = category
        self.to = to
        self.operatorName = operatorName
        self.fit = fit
    }
}

extension Fleet {
    /// How far from the phone a journey's drawn position may be and still be
    /// worth fitting.
    ///
    /// Set by the shift rather than by taste: two and a half minutes at the
    /// fastest thing on these rails is a little over six kilometres, and a
    /// journey further off than that cannot be brought onto the trail by any
    /// shift the search is allowed to try.
    static let rideReach: Double = 6_500

    /// How many of the nearest are actually fitted.
    ///
    /// The fit is the expensive half — forty evaluations of a journey's
    /// position each — so the field is cut by distance first. Forty-eight is
    /// past what a Zürich throat holds within reach at rush hour.
    static let rideField = 48

    /// A cone around the phone's course. A service running the other way is not
    /// the one you are on, and this rejects it for the price of a subtraction
    /// rather than for the price of a fit.
    static let rideCone: Double = 55

    /// How long may be spent building geometry for candidates, per ask.
    ///
    /// A chord cuts every corner, so a journey with no path yet can sit two
    /// hundred metres off its own rails through a curve — which is the
    /// difference between a match and a miss. Budgeted like the draw loop's own
    /// geometry pass, and memoised, so this costs something once and nothing
    /// after that.
    static let rideGeometryBudget: TimeInterval = 0.012

    /// The journeys whose recent path the phone's own could be.
    ///
    /// Ordered best first. An empty answer means nothing fitted, which is the
    /// normal state of a phone in a pocket on a pavement.
    public func rideCandidates(
        from fixes: [RideFix], at now: Timestamp, limit: Int = 3
    ) -> [RideCandidate] {
        guard RideMatching.isRiding(fixes), let latest = fixes.last else { return [] }

        // Who is near enough, and going the same way. One walk of the fleet,
        // the same one the draw loop makes, and a subtraction per journey.
        let moment = Double(now)
        let course = (latest.course).flatMap { $0 >= 0 ? $0 : nil }
        var near: [(journey: Journey, metres: Double)] = []
        for journey in fleetVehicles() {
            guard let position = Positioning.position(of: journey, at: moment) else { continue }
            let metres = Geo.flatMetres(
                position.lon, position.lat, latest.coord.lon, latest.coord.lat
            )
            guard metres <= Self.rideReach else { continue }
            if let course, position.moving,
               RideMatching.turn(course, position.bearing) > Self.rideCone { continue }
            near.append((journey, metres))
        }
        guard !near.isEmpty else { return [] }
        near.sort { $0.metres < $1.metres }
        if near.count > Self.rideField { near.removeLast(near.count - Self.rideField) }

        var spent: TimeInterval = 0
        for entry in near where entry.journey.geometry == nil {
            let started = Date()
            attachGeometry(to: entry.journey)
            spent += Date().timeIntervalSince(started)
            if spent >= Self.rideGeometryBudget { break }
        }

        var out: [RideCandidate] = []
        for entry in near {
            let journey = entry.journey
            // `position` moves the journey's own search hint, and the draw loop
            // reads it fifteen times a second expecting it to point at roughly
            // now. Asking about a minute either side of that would leave every
            // candidate's hint pointing somewhere the next frame has to walk
            // back from, so it is put back.
            let hint = journey.searchHint
            let fitted = RideMatching.fit(fixes) { at in
                Positioning.position(of: journey, at: at).map { Coord(lon: $0.lon, lat: $0.lat) }
            }
            journey.searchHint = hint
            guard let fitted, RideMatching.isRide(fitted) else { continue }
            out.append(RideCandidate(
                id: journey.id, line: journey.line, mode: journey.mode,
                category: journey.category, to: journey.to,
                operatorName: journey.operatorName, fit: fitted
            ))
        }

        // Best fit first, and where two are as good as each other the one that
        // needed less fudging of the clock. Two candidates this close are
        // nearly always one train filed as two coupled portions, so the tie is
        // between two right answers rather than between a right and a wrong.
        out.sort { a, b in
            a.fit.mean == b.fit.mean
                ? abs(a.fit.shift) < abs(b.fit.shift)
                : a.fit.mean < b.fit.mean
        }
        return Array(out.prefix(limit))
    }
}
