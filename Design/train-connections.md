# Train connections: RE1 and S44 investigation

Verified against the bundled timetable and the formation API on 5 September 2026.

## How the app connects services

**The feed says which numbered workings are one vehicle, and that is what is
used.** GTFS files a through-service as `transfers.txt` with
`transfer_type=4` — an in-seat transfer, meaning the passenger stays on board.
Measured on `gtfs_fp2026_20260916.zip`:

- 270,487 type-4 rows, every one naming both `from_trip_id` and `to_trip_id`,
  and every one naming a trip that exists.
- Every row carries a `service_id`, which is what makes it usable. Unscoped a
  trip appears to fan out to as many as 56 successors — those are its successors
  across different days. Scoped to one operating day the graph is 18,785 links,
  of which 99.1% are a plain 1:1 continuation, 173 are splits and 306 are joins.
- `trips.txt` carries `original_trip_id`, the Swiss Journey ID, on 92.6% of
  trips, so a link reaches a live vehicle with no matching step.

`build-through-services.mjs` reads and reports it; `pack-timetable.mjs` writes
it into `timetable.bin` as format 4, twelve bytes a link (two trip rows and the
calendar), 3.2 MB for the year. `TimetableStore.throughServices(on:)` resolves
one operating day. Earlier formats are not read: the graph is how chaining
works now rather than an optional extra, so an archive without it would quietly
fall back to guessing. A device holding an older download re-fetches.

`block_id` is **not** used: it is present on 441,534 of 2,236,815 trips and
means "same vehicle at some point today" rather than "runs through here".
`transfer_type` 1 and 2 are passenger connections between two vehicles, which is
the opposite of what is wanted.

The formation service feeds the *same* graph rather than a second mechanism.
`TrainFormation.throughLinks(ownedBy:)` turns its `F` continuations, `T`
separations and `Z` joins into `ThroughLink`s; `W` turnarounds are excluded,
because a train that continues back the way it came drawn as one vehicle runs
out and back. This is the only source that knows about a working put together
this morning.

**The inference is now the fallback, not the mechanism.** `Chains.build` takes
what the feed says first. Where the feed mentions a working *at all* — in either
direction, including naming a successor that is simply outside the drawn window
— its word is taken whole and nothing is guessed. `Chains.candidateScore` runs
only for workings the feed never mentions: runs added in the last hour, foreign
operators, the 7.4% of trips carrying no journey reference. Its rules are
unchanged.

That ordering is what fixed the duplicates. Guessing *alongside* stated fact is
what drew two dots on one platform:

- **At a split**, the inference chained the arriving RE1 to one of its two
  halves, and the other half — not held by anything, because its predecessor no
  longer terminated at the junction — appeared beside it at its own scheduled
  departure.
- **At a join**, 4268 and 6820 both continue as 4168. The inference chained
  4268 through and left 6820 running as a vehicle of its own, so one departure
  was drawn twice. `Stated.principal(into:)` now picks one predecessor
  deterministically — furthest-run first, then lower id, so a rebuild does not
  swap them and flicker — and holds the other on the platform until the coupled
  train goes.

A published link is sanity-checked but not re-scored: the successor must start
at the station the predecessor ends at, within an hour. That rejects a journey
retained from another day resolving by name, without second-guessing a border
stop that genuinely stands for forty minutes.

The panel takes the same route. `Fleet.boardNeighbour` consults the published
graph before its scoring, and where the feed has spoken the scoring is not
consulted at all — not as a tie-break and not as a fallback. A split or a join
yields no single neighbour and the panel is given none, rather than an arbitrary
half of a train still standing there coupled.

## RE1: Brig–Spiez–Bern

The reported train is 4268 (Brig 11:36, Spiez arrival 12:44), continuing as 4168
(Spiez departure 12:50, Bern arrival 13:22). The published formations contain six
coaches for 4268 and twelve for 4168, including at Spiez.

Previously, the panel requested only the current working's formation. Opening
it before Spiez therefore showed the arriving six coaches at Spiez; opening it
after Spiez offered only the four stops in working 4168.

The panel now requests every constituent working and joins their answers by
station and leg coverage. At the shared station, the outgoing formation wins,
while the arrival time is preserved from the incoming working. The coach lists
are never concatenated: the outgoing response already contains the coupled
train. Requests and learned layouts remain keyed by individual working.

Continuation requests already retrieved OJP timing, but their occupancy was
ignored. The loader now merges those forecasts too, replacing the junction's
forecast with the outgoing working's even if its platform reference differs.
Missing forecasts remain missing rather than being inferred from coach counts.
OJP was also queried for both reported workings: 4168 publishes
`manySeatsAvailable` in both classes departing Spiez, Thun, and Münsingen.
The absent Spiez–Bern indicators were therefore a client-side omission.

“Runs as” now uses actual leg endpoints and shows operational train numbers.
Formation picker selection uses station identity so loading preceding legs
cannot move an existing selection to a different station. Coach totals use the
selected stop's measured coaches where available.

## S44: Burgdorf branches

Working 16449 leaves Thun at 13:08 and reaches Burgdorf at 14:08. Its formation
assigns coaches 1–4 to Solothurn and 5–8 to Sumiswald-Grünen. Both onward workings
are present in the packed timetable:

| Working | Departure | Destination | Arrival |
| --- | --- | --- | --- |
| 16549 | Burgdorf 14:11, 4C | Sumiswald-Grünen | 14:38 |
| 16649 | Burgdorf 14:15, 4AB | Solothurn | 14:42 |

Two issues hid them. The branch search inspected only the currently expanded map
fleet, and the timetable's station index misread generated sector references.
For example, `ch:1:sloid:8005_gen:ch:1:sloid:8005:3:4_pf:4AB` was indexed under
`ch:1:sloid:8005_gen` rather than Burgdorf's `ch:1:sloid:8005`.

The index now removes the generated suffix before extracting the station.
Branch lookup queries the timetable at the split independently of the map's
viewport/time window. It prioritizes published journey references/train numbers;
without those, it requires matching operator, line, origin, destination, and a
short departure window, rejecting ambiguous matches. UIC/SLOID station identity
handles differing spellings and platform sectors. Branch stops appear before
asynchronous route geometry finishes loading.

## RE1/R11: Spiez split at 14:12

The later screenshots show working 4173 arriving at Spiez at 14:10 with twelve
coaches. Unlike the earlier northbound example, this response explicitly
publishes a `T` separation, direction `N`, naming RE1 4273 and R11 6825. Both
depart at 14:12, with six coaches each. R11 also names incoming 4173 with an
`F` relationship; its later `W` relationship is a turnaround, not a continuation
of the passenger journey.

At Spiez, both outgoing short strings include twelve physical coaches on the
platform, but only six are inside `[...]`. The other six are outside the train
boundary and marked closed. The parser previously ignored that boundary and
counted all twelve as belonging to each departing working. The map then froze
that incorrect formation for the journey, drawing the detached half as extra
grey coaches. Subsequent stops correctly list only six.

The parser now preserves the other working as platform context, gives only the
train's own coaches positions and vehicle metadata, and excludes the other half
from both the formation strip and map layout. Closed coaches *inside* the
boundary still belong to the train. Where the stop-based response lacks stock
names, learned layouts use the same library silhouette fallback as restored
layouts, retaining the actual coach count and published classes.

The map previously delayed only one of two simultaneous outgoing markers,
depending on dictionary order. It now delays both through the incoming train's
dwell. Published separations prevent the heuristic from flattening one branch
into the parent and control a common handover at the first departure, including
updated departure times. Incomplete or ambiguous identities do not suppress
vehicles. A split has no single outgoing identity, so the panel does not switch
to an arbitrary half while the coupled train is standing there. Outgoing
formations are no longer learned under an incoming train's key.

Saved observations carry a parser revision so existing installations recheck
old formations as trains enter view. Corrected per-working coach lists outrank
line averages after restart on the observed operating day, avoiding a twelve-car
line pattern replacing a known six-car departing working. Later days retain the
line fallback; the bundled database remains readable.

## Verification

### 20 September: RE1 4269 loses its Bern origin

The 12:17 map selection reproduced a separate passenger-route regression:
4169 (Bern–Spiez) qualified as the predecessor of 4269 (Spiez–Domodossola),
but `boardNeighbour` ranked both the map copy and the freshly expanded timetable
copy. The duplicate became the runner-up with the same score, so the ambiguity
check rejected the connection and the panel began at Spiez.

Neighbour lookup now resolves live aliases and deduplicates operating occurrences
before ranking them. The booked calls and train identities distinguish copies
from genuinely different trains; the existing ambiguity margin remains in force.
`RE1StitchingTests` covers the exact 4169/4269 map selection in both directions,
a delayed live predecessor alias, and distinct numbered predecessors that must
remain ambiguous.

Regression coverage uses recorded formation responses and the bundled timetable
for the exact reported RE1 and S44 workings. It checks all 14 RE1 formation stops,
the six-to-twelve-coach change at Spiez, both S44 destinations and departure
times, generated station references, missing formation coverage, occupancy
replacement across platform changes, and formation/layout keys at the junction.
The follow-up Spiez fixtures also check bracket membership, six-car map layouts
at and after the split, closed coaches belonging to the train, deterministic
handover, delayed and staggered departures, incomplete identities, same-day
restart persistence, later-day fallback, and legacy-cache rechecking.
The final focused suite passed all 155 tests. The iOS simulator and embedded
watchOS app build succeeded. Tests were run with a fresh build directory to avoid
Finder metadata in an existing test bundle interfering with code signing.
