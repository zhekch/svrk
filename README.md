# Swiss Live Transit — iOS

The same app, natively. No web view, no Node server, no `localhost`: the phone
fetches the national feed itself, parses it, matches every journey to its
OpenStreetMap route, routes what it cannot match over the railway graph, and
draws the result with the Mapbox Maps SDK.

```
node scripts/fetch-mapbox-sdk.mjs    # ~330 MB, once
node scripts/pack-ios-data.mjs       # 114 MB of JSON -> 59 MB of binary
node scripts/make-ios-secrets.mjs    # tokens, from .env
node scripts/update-timetable.mjs    # the GTFS year -> timetable.bin, 124 MB
open ios/SwissTransit.xcodeproj
```

All four scripts live in the repository root's `scripts/`, and all four are
idempotent.

### Keeping the timetable current

`update-timetable.mjs` is the one with a deadline on it. The archive the map
draws from covers one timetable year, and the Swiss timetable turns over on the
second Sunday of December — the bundled file runs 2025-12-14 to 2026-12-12 — so
a build shipped without a refreshed archive falls back to the live feed on
2026-12-13 and stays there. Nothing in the app renews it: `timetable.bin` is a
bundle resource, so a new year arrives only in a new build.

The script does the whole errand. It works out which year is wanted from the
turnover date, resolves that year's permalink on opentransportdata.swiss,
fetches the zip — resumably, since it is 235 MB — checks it is a zip before
spending anything on it, packs it in a scratch directory, reads the result back,
and only then moves it into place. A crash partway through leaves the working
archive alone.

```
node scripts/update-timetable.mjs --dry-run   # what would be fetched
node scripts/update-timetable.mjs             # do it
node scripts/check-update-timetable.mjs       # the turnover arithmetic
```

One trap it steers around: next year's feed appears months early but *part
filed*. On 2026-08-24 the 2027 slug already resolved, at 59.4 MB against the
2026 feed's 235.1 MB, because operators submit into it over the following
months. Taking the newest published year would swap a complete timetable for a
fifth of one, so the year comes from the calendar and the site is only asked to
confirm the file is there. The script says so out loud when it sees a year that
looks part filed.

## What moved, and what did not

Everything in `lib/` is now `ios/Packages/TransitCore` — a plain Swift module
with no UIKit, no Mapbox and no simulator in it, so it builds and tests on the
host in a couple of seconds. That is the point: the port is checkable against
the same 81,756 stops and 7,860 relations the JavaScript was measured on.

| Node | Swift |
|---|---|
| `lib/siri.js` | `SiriParser.swift`, `ByteScan.swift` |
| `lib/stops.js` | `StopRegister.swift` |
| `lib/routes.js` | `RouteRelations.swift`, `RelationProjection.swift` |
| `lib/railnet.js` | `RailNet.swift` |
| `lib/journeys.js` | `GeometryBuilder.swift` |
| `lib/chains.js` | `Chains.swift` |
| `lib/fleet.js` | `Fleet.swift` |
| `lib/otd.js` | `OTDClient.swift` |
| `public/js/interpolate.js` | `GeometryBuilder.swift` (`Positioning`) |
| — | `FleetCache.swift` (the packed snapshot; the server has no need of one) |
| `public/js/clock.js` | `Clock.swift` |
| `server.js` | *gone* — there is no server |

`swift test` runs 46 tests against the real packed data, including the
mapped-route coverage table the README quotes.

## The data

The server reads 114 MB of JSON at startup and thinks nothing of it. A phone
cannot: `JSONSerialization` over the 78 MB relation store alone costs tens of
seconds and several hundred megabytes of peak memory.

So `scripts/pack-ios-data.mjs` rewrites all of it into files that are
memory-mapped and read in place — coordinates as `Int32` micro-degrees (11 cm
quantum, exact under equality, half the size of a `Double`), strings in one
shared blob addressed by index. The relation store is never materialised at all:
a path is a `CoordView` decoding pairs on subscript, so 3.7 million coordinates
cost address space rather than heap.

| file | size | what |
|---|---|---|
| `routes.bin` | 32.1 MB | 7,860 OSM route relations |
| `railnet.bin` | 17.4 MB | 573,025-node railway graph |
| `stops.bin` | 4.5 MB | the stop register |
| `stop-places.bin` | 2.0 MB | the 33,518 stops the map draws |
| `platforms.bin` | 2.0 MB | OSM platform → SLOID |
| the rest | 0.9 MB | operators, foreign stations, poll lattice |
| `leg-cache.json` | 0.2 MB | railway legs the server has already routed |

Cold load is about half a second for all of it.

`leg-cache.json` is the one file that is copied rather than packed: it is
`RailNet`'s own format, read by the same `loadCache` on both sides. Each entry
is a Dijkstra over the 573,025-node graph that the phone would otherwise run
itself, on the actor the draw loop shares. The app writes its own cache over the
top of it into Application Support as it routes more, so the seed only matters
for a first launch.

## Offline

Two halves, and only one of them is a download.

**The transit data ships with the app.** Every stop, every route relation, the
whole railway graph — 59 MB in the bundle. Route matching, rail-graph routing
and every board work with the network switched off.

**The fleet is stored as the fleet.** Each refresh writes the parsed journeys
to `fleet.bin` (`FleetCache`) — one shared string blob, micro-degree
coordinates, 20 MB — so the last national snapshot is always there to replay
and a cold launch with no signal draws a real fleet, and says so.

It used to store the *response* instead: 150 MB of XML, re-parsed on every
launch behind a curtain reading "Loading the network" over data already on the
device. That is where thirty seconds of launch went. Reading the packed fleet
costs about a tenth of a second; an XML file is still accepted, whatever it is
called, because replaying a recorded snapshot out of `archive/` is how the app
is checked against a daytime network at three in the morning.

**The basemap is the part you choose.** Eight areas, each a Mapbox tile pack,
with the size asked of the tile store *before* it is spent rather than after —
Lake Geneva is about 161 MB, and that is a decision, not a surprise.

## The railway overlay

Drawn from the routing graph rather than from tiles — the same OpenStreetMap
railway the app routes trains over, so it costs no second source, no tile
server, and works with the network off. Trams green, main line blue, opacity on
a dial in Settings.

Two things make it usable rather than merely present. Edges are joined into runs
before they are drawn: one feature per edge puts central Zürich past fourteen
thousand, and a cap reached while sweeping cells from one corner fills the south
of the screen and leaves the north empty. And detail is scaled to zoom — below
zoom 11 main line only, with runs shorter than a few hundred metres dropped,
because a station throat is dozens of crossovers that are invisible individually
and a smudge collectively. Nationwide that is 2,597 features instead of 20,000.

## Vehicles, drawn as vehicles

Zoomed out, a vehicle is a dot, which is all a dot can be. Zoomed in, it is the
thing itself: a four-hundred-metre intercity with a locomotive on the back, a
seven-car tilting unit, a three-module tram, a twelve-metre PostAuto — each at
its real length, on the track it is actually on, in the colours the company
paints its stock.

**The change is per vehicle, not per zoom.** A single threshold has to be set
for the average vehicle, and there is no average vehicle: an IC is thirty times
the length of a minibus. So each one arrives when *it* is long enough on screen
to be recognised — about twelve points, which is zoom 12.5 for an intercity,
around 14 for a tram and 16 for a bus. Nothing is ever drawn as a shape too
small to read, and nothing is held back as a dot once it is not. The dot does
not cut out underneath: it shrinks and fades as the shape draws in, so the
handover reads as one marker changing rather than two swapping.

**Length is true and width is not.** Length is the whole point — it is the fact
a dot cannot carry — so it is always at ground scale. Width cannot be: standard
gauge stock is 2.9 m against a 200 m train, and a truthful top view of an
intercity at zoom 14 is fifty points long and less than one point wide. Bodies
are therefore drawn at their real width or seven points, whichever is more, so
the exaggeration shrinks as the map zooms in and has vanished by about zoom 18.

**It moves the way a train moves.** The timetable gives two numbers, a
departure and an arrival, and everything between them is the renderer's to
invent — so the leg is run to a trapezoidal speed profile rather than at a
constant crawl: away from the platform, up to line speed, and braking into the
next stop. The area under the curve is still one whole leg, so the vehicle
arrives exactly on time and the map never disagrees with the times printed
beside it. The ramps are a fixed *number of seconds* rather than a fixed share,
or an intercity would spend ten minutes accelerating.

Two things had to change underneath for that to be visible at all. `Timestamp`
is whole seconds, so a draw loop running fifteen times a second was redrawing a
number that changed once — invisible for a dot that moves a metre in that time,
and one large jerk a second for a train drawn to scale that moves seventy
points. Positions are now computed to better than a second. And the frame rate
rises with the zoom, because that is what decides both how far a vehicle moves
on screen and how few of them are on it. Both are one switch in Settings.

**Each body is rigid.** The train is laid along its own geometry — the same
routed line the map draws — and each vehicle is a straight box between the two
points where its own ends fall on it. That is what a real coach does: it cuts
the inside of a curve, overhangs the outside, and scissors slightly at the
couplers against the one behind it. Bending each body to the alignment would
look smoother and be wrong.

**The tick rate is not the frame rate.** Mapbox renders on its own thread from
data already uploaded, so a finger drags the map at the display's rate whatever
this app is doing. What the model controls is how often positions are recomputed
and new geometry pushed — which decides whether a vehicle glides or steps, and
nothing else. The readout shows both, because one number for both reads as a
claim about the screen when it is a claim about the model. Getting the tick rate
up to what it asks for took two things: a loop that sleeps to a *deadline*
rather than for an interval (sleeping for the interval after the work makes the
period `work + interval`, so asking for 30 gave 17), and a hint in
`Positioning.position` so a journey's call list is not scanned from the
beginning fifteen thousand times a frame — each step of which copied a `Call`,
six reference-counted strings and all.

**Trains that share an alignment are fanned across it.** Nothing in any feed
says which track a train is on between stations, so every service matched to the
same route relation is drawn on the same line — six of them stacked on the
approach to Bern. They are ranked by their booked platform where the feed states
one, which is real evidence and does not change during the approach, and fanned
about the alignment at track spacing. It is a drawing decision and it errs the
right way: the trains really are on parallel tracks, so a fan is closer to the
truth than a stack; which one is on which track is the guess. Eased rather than
applied, or the whole fan would jump sideways each time a train joined it.

**A drawn vehicle is bigger than its marker, and the map has to allow for it.**
A vehicle is anchored at its head and the viewport query keeps whatever falls
inside the box — right for a dot, and wrong for a train. Zoom in on the fourth
coach of an intercity, or pan a little sideways, and the head leaves the box
while most of the train is still on the screen, so the whole train is dropped.
The query is grown by more than the longest thing that can be drawn.

**The map is flat and the country is not.** At Bern the buses stand on the
Bahnhofplatz deck and the trains are in the station underneath, so the drawings
cross — and in an arbitrary order that reads as a collision rather than as a
bridge. Road vehicles are drawn last, over a soft dark casing, because a road
crosses over a railway far more often than under one. What it cannot do is
separate two trains sharing one alignment: which of two S-Bahnen is on which
track through a station throat is not in any feed this app reads.

## The third dimension

Off by default and one tap away, under *Map* on the map itself.

**The basemap.** A fourth choice beside Dark, Light and Satellite: Mapbox
Standard, which is not a colour scheme but a whole style imported into ours —
buildings with height, landmarks modelled one by one, and a sun that moves with
a time-of-day setting. Because that setting decides whether the ground is light
or dark, and every halo, casing and overlay palette this app installs is chosen
from that, changing it reloads the style rather than adjusting it. Its layers are not ours to
order, so everything this app draws is assigned a slot in it: the tracks and the
station areas to `middle`, behind the buildings that stand on them, and every
marker to `top`. Without that they landed above the entire imported style, and a
station's worth of platforms was painted across the Bahnhofplatz like a decal.
Standard also lights its scene, and at `night` that light is dim and blue — so
the overlay emits its own colour at full strength and reads the same at midnight
as at noon, while the solid vehicles take the scene light, because they are the
one thing here that really is standing in it. The other
three basemaps get extruded building footprints out of their own vector tiles
instead — deliberately translucent, because they are the context and the thing
being looked at is on the ground between them.

**The terrain.** Mapbox's global elevation tiles, with a relief dial from 0.5x
to 2.5x. It is the one part of the map that genuinely needs a network — the
elevation is not packed onto the device — and it is also the single thing that
most changes what the map is. Half of why the Swiss network runs where it runs
is a question about slopes, and a slope is invisible from directly above. The
dial exists for the same reason the track overlay has one: at 1x the Alps are
correct and the Mittelland is flat, which is true and throws away the only cue
that the line through Olten is climbing at all.

**The vehicles.** Tilt the map and they stand up. Not different models — the
*same* outlines, sliced. Each unit's plan outline is rebuilt at four or five
heights, narrowing and shortening as it rises, and each slice is extruded
between its own two heights: a chassis under an overhanging body, the operator's
colour up to the waist rail, a window band, the turn of the shoulder, a roof
drawn in. Cabs rake because the levels above the floor are held further off the
nose than the ones below; double-deckers get two window bands with a belt
between them, which is how one is recognised from the side; a low-floor tram's
glass starts at knee height and a locomotive has none at all.

Slicing the flat outline rather than shipping a mesh per family is the whole
design. The silhouette of the solid seen from directly above is the flat drawing
exactly, which is what makes the change read as one vehicle being tilted instead
of two vehicles being swapped — and there is no second source of truth for a
livery to drift out of. The cost is faceting, which at the size a train occupies
on a phone is the look rather than the price.

Not every cue runs along the vehicle, and the first pass made that mistake: five
coloured bands stacked up the side and nothing anywhere to say where one body
stopped and the next began, so a sixteen-coach train and a single railcar were
the same striped extrusion at two lengths. Bogies fixed it — two dark blocks
under the ends with daylight between them — and doors finished it, one slab a
side at the places the flat drawing already ticks them. Both are gated on how
big a body actually is on screen, so a bus that is eight points long gets
neither.

The paint is the real stock rather than one colour a company. Nearly every
modern Swiss fleet is a pale body under a strong band above the windows — SBB's
red on silver-white with red doors, Zürich's white over blue, Basel's cream over
green — and from directly above that band is a hairline along the very edge of
the body, which is why the flat drawing has never needed it and the solid cannot
do without it.

A tilted map after dark gets lights: two white ahead, two red behind, a soft
halo and a hard core, emitting their own colour so the basemap's night cannot
dim them. Dark *and* tilted, because a lamp on a plan view is a dot beside a dot
— there is no third dimension for it to stand in front of. They are the only
thing on the map that says which way a vehicle is *facing* rather than which way
it is pointing: a train standing at a terminus with its tail lamps toward you
has not turned round, and a bearing cannot say that.

The lamps are part of the mesh. A wagon that carries the front of the train has
two warm white blocks set into its nose and the one on the back has two red
ones, at the height that family actually carries them — 1.4 m on a Re 460, 1.1
on a Cobra tram, 1.0 on a PostAuto, 2.2 on a lake steamer — with a self-lit
material so a basemap's midnight cannot dim them. Being geometry, they are
hidden by the vehicle carrying them, which is what stops a train wearing its own
tail lights on its face, and they cannot drift from the nose because they *are*
the nose.

Over each one is a soft halo, and that is a separate feature because a glow is
not a surface. It is placed from the same anchor the mesh uses, and carries its
height as distance: on a map tilted by θ, a lamp *h* off the ground is drawn
where the ground `h · tanθ` further from the camera is drawn. Given no height at
all — which is what a circle layer has, because a circle is painted on the
ground — four lamps that belong on a nose land several metres in front of it and
below it, which is exactly what they used to do.

It happens close in and only when tilted: below about 22 degrees the height buys
nothing, and further out than zoom 15 a three-metre body is under a pixel tall.
Between those it fades rather than switches — the solids rise as the footprints
under them go, so a train lifts out of its own drawing. The fade is driven off
the camera at the display's rate rather than off the model's tick, because it
has to keep up with a two-finger drag.

**A wagon is one baked model, and that is the whole of why it holds together.**
The slabs above are not what is drawn: they are sliced into a mesh, written as a
binary glTF, handed to the renderer once and thereafter referred to by name. All
that crosses per frame is a point, a heading, a tilt and a scale — about sixty
bytes for a wagon that cost two kilobytes of polygons before. Nothing inside a
wagon can move relative to the rest of it, because nothing inside it is being
sent for anything to come apart from; and the same change buys the tilt, since a
model can be rotated into a gradient and an extruded prism is vertical by
definition.

It is generated rather than modelled, and that is not thrift. The silhouette of
the solid from above has to be exactly the flat drawing or the change from one
to the other stops reading as one object standing up — generating the mesh from
the same `outline` keeps that by construction, and gets every livery of every
operator without an asset pipeline. A sixteen-coach intercity resolves to five
distinct meshes and eleven repeats, at 20–45 kB each.

`Design/vehicles/solid/` holds every solid the app can build, rendered from the
slabs without a map; `Design/vehicles/model/` holds the same wagons read back
out of the `.glb` files themselves and placed the way the map places them, which
is the check that the bake, the container, the change of axes and the placement
all still agree.

**A train in a tunnel stays on the rails and vanishes.** The routing graph
marks tunnel edges and those runs are stitched back together at underground
junctions, so a wagon is underground when it is *on those rails* — not merely
near them. It keeps the track's lat/lon and the track's elevation, and over
about a coach and a half past the arch its body fades to nothing, coach by
coach. A 3D model cannot punch through terrain, and a ghost of one on the
mountain is a train that has left the rails. What is left to follow is the
line number, drawn through the hill (`text-occlusion-opacity`).

## What a train is made of

Two halves, and only one of them ships.

**`LayoutLibrary` is what each line normally runs.** IC1 is a double-deck unit,
IC5 is an ICN, IR16 is a KISS, a Zürich S-Bahn is a four-car DTZ and a Basel one
is a FLIRT — with the real classes' real dimensions, so a metre-gauge RhB train
is visibly narrower and shorter-bodied than an SBB one. It resolves by line,
then by what that operator runs locally, then by category, then by mode, and the
last one always answers: there is no vehicle the map cannot draw.

It has to work this way because the formation service answers one train at a
time, fifty times a minute, for eleven companies. A map that morphed its dots by
*asking* would need a request per train per screenful — hundreds of them on a
zoom into Zürich, for none of the buses.

**It is keyed by the line as well as by the train.** The train number is the
accurate key and the wrong one to stop at: "the S42" is not a train, it is forty
trains a day, each with its own number. Keyed by number alone, a formation
learned by tapping the three o'clock working taught the map nothing about the
five o'clock one and the drawing went back to the library between them — which
reads exactly like the database forgetting what it was told. So an observation
is filed against the line too, and one tap corrects every working of it. Where a
later observation agrees with the library the line's correction is *removed*
rather than replaced: a service short-formed once should not be drawn short for
ever.

**And it survives a reinstall.** Installing from Xcode empties Application
Support, so what the app had learned went with it every build. A copy ships in
the bundle at `SwissTransit/Resources/vehicle-layouts.json` and is read first,
with the device's own file over the top of it. Settings will hand the device's
copy back as a file; drop it over that one and the next build starts out knowing
what this one learned.

**`VehicleLayoutStore` is what the app has learned.** Tapping a train already
fetches its real formation for the panel. That answer is now also turned into a
drawing and filed under the train number — not the journey id, which contains
the day; train 711 is train 711 tomorrow and is nearly always the same physical
set. Where it draws the same as the library's guess there is nothing to store
and a single flag records that the guess was *checked*, which is the only thing
distinguishing a guess that has held up from one nobody has tested. Where it
differs, the formation is kept and drawn from thereafter. The table the app
ships with is a first guess; the one on the device is what it has learned.

One thing has to be inferred either way, because the service does not carry it:
which ends have a cab. It describes what a passenger finds inside a coach, and a
cab is not something a passenger finds. The rolling-stock class answers it where
there is one — `Bt`, `ABt` and `BDt` are driving trailers by definition, `RABe`
and `ETR` are units whose end cars always have one — and where there is not, the
shape of the train does: no locomotive means a multiple unit driven from both
ends, and one locomotive means a push-pull working whose *other* end is a
driving trailer, which is how nearly every hauled passenger train in the country
runs.

Every shape the code can draw is exported to `Design/vehicles/`, from the same
geometry, by `Design/vehicles/export.swift` — one page, one scale, so the
lengths are comparable.

## Platforms and station areas

The platform you stand on, drawn as its own shape, and the block a station
covers. These come from OpenRailwayMap's vector tiles — `RailwayShapes.swift` is
the web app's ORM style ported layer for layer, so a station looks the same in
both places — and they are the one thing on this map that needs a network.

Two things are worth knowing about them.

**The tiles want a `Referer`.** ORM refuses a request without one; a browser
always sends the page it is drawing, and a native HTTP stack has no page to
name, so every tile came back `403 Forbidden`. An HTTP interceptor adds one for
that host, naming this app rather than their site, and leaves every other
request alone.

**A numbered plate stands down wherever a shape says the same thing.** The
footprint is the better object — it says where the platform is, how long it is
and which way it runs, and it is far easier to hit than a marker — so the plate
would only be a second thing to tap, thirty of them at Bern. Lettered bays keep
theirs; the letter *is* how the stop is found. And the suppression waits for
evidence that the tiles are arriving, so a platform is never left with neither a
shape nor a plate. Switch the whole layer off in Settings and every number comes
back.

**One blob per station.** A stop mapped as several OSM nodes gets several
circles — Bern's tram stop is three, all named "Bern Bahnhof" — and overlapping
fills stack into darker lenses, so one stop reads as three. Of the blobs over
the same station that actually overlap, the largest is drawn and the rest are
filtered out; a blob of the same station somewhere else, like the K bays on
Bubenbergplatz, is left alone.

Tapping one is answered by identity: the OSM id under the finger goes to the
same table that answers it on the web (`platforms.bin`), which knows the `ref`
each element carries. Position is not involved — at Bern every platform is
registered near 7.4372E while the footprints run out to 7.4384E, so the nearest
register point to a tap on platform 7 is frequently platform 8.

## The service you are on

Switzerland publishes no vehicle positions, so this app has never been able to
say where a train *is* — only where the timetable says it should be. Which means
nothing can tell it which train you are sitting in, either. It works that out
instead.

A journey is a timed polyline and a phone is a stream of timed points, and two
timed lines either lie on top of one another or they do not. So the last fifty
seconds of fixes are matched against every running journey within reach: where
was this service at each of those moments, and was it where the phone was? A
minute of points that stay with a train — through a curve, through a station
stop — means one thing. A single point beside one means nothing at all; a level
crossing puts a car within ten metres of an intercity.

**The lag is the hard part, and it is the whole design.** A drawn position comes
from the timetable with whatever delay the feed states applied to it, and the
residual — the minute lost since the last poll, the thirty seconds a train is
standing over — is not in the data anywhere. At line speed a minute is two
kilometres, which is enough to reject the train you are on and accept nothing
else. So the fit is taken over a *shift* as well: the phone's clock is slid
against the timetable's until the two lines agree, coarsely and then finely, and
how far it had to slide is reported rather than hidden. Two and a half minutes
either way, because past that the search reaches a genuinely different train.

**What it says is one line.** A red dot, the word Live, and the service — `Live
· RE1 to Brig` — across the bottom of the map. The app has worked out something
the person holding it already knows: they can see the train they are sitting in.
What it knows and they do not is where it goes, how late it is and what it is
made of, and all of that is one pull away — the badge carries the sheet's own
grab handle, and pulling it up snaps the camera to the train and opens the panel
a tap on the marker would have opened. Pushing it back down declines it, which
matters: the one case a fit cannot settle on its own is the train on the next
track.

**What it takes to claim depends on what has been seen.** Asking at all needs a
trail that is going somewhere — twelve seconds, a hundred and eighty metres and
above 23 km/h, which is a train and is not a walk to the platform — and that is
reached about as soon as a train has finished pulling out. But twelve seconds is
a *straight line*, and every train on every parallel track fits a straight line
equally well. So the threshold is graded by the evidence: on the shortest trail
a fit has to be within 70 m and has to beat the runner-up by 45, and by
thirty-five seconds — long enough to contain a curve or a station stop — the
ordinary 130 m applies and the margin is gone. Fast when the answer is obvious,
patient when it is not.

On top of that a candidate has to win two asks in a row, which throws out a
one-off. Losing takes ten, which is fifteen seconds of good fixes consistently
failing to fit: appearing is a claim and disappearing is only the absence of
one, so the first is made carefully and the second is not made in a cutting.
That puts the badge up about **fourteen seconds** after a train reaches line
speed, and about **twenty-five** from a standing start.

**And it survives the tunnel.** Losing the fixes is not evidence that you got
off — a train cannot change identity between Erstfeld and Bodio — so the trail
and the answer are two different things and only the trail is thrown away. The
badge coasts on the last fit it made for up to twenty-five minutes, which covers
the Gotthard base tunnel with room to spare, on one condition checked against
the fleet every ten seconds: the service it names has not terminated. Coming out
the far side, the trail restarts rather than drawing a line across the mountain
— joining a fix from Erstfeld to a fix from Bodio would describe a teleport that
fits nothing — and because keeping a badge is easier than claiming one, the
short new trail confirms what is already on screen instead of having to earn it
again.

**It is matched against this app's own drawing, which is not a constant speed.**
The map runs each leg to a trapezoidal profile with a 55-second ramp at either
end and dwells at every call, so the thing the fit compares against already
accelerates and stands still — which is the right shape, and is also where the
one free parameter runs out. A shift *slides* the timetable against the phone;
it cannot stretch it. Measured on a 20 km leg against a train given an
acceleration the model does not have, that costs 5–40 m of mean error, which the
shift buys back by pretending the train is a few seconds ahead of itself. What
it cannot buy back is a *rate* difference — two minutes late out of a station
and on time into the next is a leg run eight per cent quick — and there the
residual grows with the trail rather than averaging out: 23 m of error over
twelve seconds, 60 over thirty-five, 168 over a hundred. That last one is past
every threshold here, which is why the window is fifty seconds and not the
hundred it started at. A longer trail was buying discrimination up to
thirty-five seconds and buying error after it.

The same measurement changed the second gate. A fit used to be refused if any
single fix was more than 300 m out, and a real train that stands thirty seconds
where the timetable books sixty puts the drawn position that far away for as
long as the difference lasts — one artefact of the drawing, and the badge went
out over it. The gate is a ninetieth-percentile stray instead: two lines that
genuinely cross are wrong in most of the window, not a tenth of it. On a short
trail the percentile *is* the maximum, so nothing is given away where there is
nothing to spare.

`RideMatching` is in `TransitCore` and is tested on the host against trails
whose answer is known — including the two that decide whether any of this is
worth having: a service running the other way that is briefly right beside you,
and the same line twenty minutes ahead on the same rails. `RideProfileTests`
covers the other half: the matcher against `Positioning`'s own trapezoid, so a
change to `Motion.rampSeconds` says whether it can still find the train.

## Time, and what the feed can answer for

Positions are computed from each journey's own call list rather than observed,
so the clock is free: hand the renderer a different number and it draws a
different hour. The *snapshot* is not free. SIRI-ET is an estimated timetable —
it carries what has been filed, drops a journey once it has run, and files
trains hours before buses.

Measured on a recorded national snapshot (18,196 journeys, taken at 17:31):

| offset | vehicles | share | rail |
|---|---|---|---|
| −60 min | 55 | 1% | 7% |
| −15 min | 379 | 7% | 19% |
| **now** | **5,348** | **100%** | **100%** |
| +30 min | 5,000 | 93% | 100% |
| +1 h | 3,162 | 59% | 100% |
| +2 h | 1,831 | 34% | 100% |
| +3 h | 849 | 16% | 89% |
| +4 h | 140 | 3% | 21% |

Two things follow, and the time control used to get both wrong.

**The range was read off the extremes.** `min(start)…max(end)` over the whole
snapshot is the span of one night service filed thirty hours out and one that
started yesterday evening — on the table above, −542 to +1801 minutes. So the
control offered nine hours back and twelve forward, the map quietly emptied as
the clock moved, and an empty map reads as a claim about Switzerland rather than
about the data in hand. The answer at the time was to measure: `FleetCoverage`
counted the fleet minute by minute, offered the span where it stayed above a
fifth of what was running — about −15 to +170 on this snapshot — and drew the
whole curve as a strip of bars under the clock, so the thinning was something
you could see coming.

**The archive removed the question.** `timetable.bin` is a year of service days
and answers for any minute in it straight off the file, so what the control may
offer is a fact about the packed feed — 2025-12-14 to 2026-12-13 on the current
one — rather than a curve to apologise for. `TimetableStore.span()` is that
bound and `Fleet.drawableSpan()` hands it up; the picker takes a date as well as
a time, and next Tuesday morning costs what this afternoon does.

The archive expires, and nothing in the app renews it. `timetable.bin` is a
bundle resource packed by `scripts/pack-timetable.mjs` and read in place; there
is no downloader and no writable copy, so a new year arrives only in a new
build. The Swiss timetable turns over on the second Sunday of December — the
current file covers 2025-12-14 to 2026-12-12 — and past its last service day it
still opens, still reads, and answers for nothing anybody is asking about. So
`Fleet.drawableSpan(at:)` offers it only while it covers the present, and a
stale one falls back to the feed: the map is exactly what it was before the
archive existed, ±2 h around now, rather than a control bounded entirely in last
spring with no "now" to step from.

The strip went with it, and by then it was actively lying. Once the map draws
from the timetable, the fleet in hand is whatever window was last expanded
around the clock — half an hour behind, an hour ahead — so the bars were drawing
the shape of the *expansion window*, normalised against a "now" the clock had
already been dragged away from. Scrub an hour or two and every bar read zero,
which disabled every step button. `FleetCoverage` is gone; the falloff it
measured is still true about SIRI-ET, which is why the table above stays, and it
is no longer what bounds the clock.

**The past was being thrown away.** Every journey arrives with its complete call
list, so any of them can be positioned at any moment it covers — but `apply`
replaced the store wholesale on each refresh, so a journey that finished was
gone. That is why stepping backwards emptied the map at fifteen minutes while
stepping forward reached hours. `Fleet` now keeps what the feed has let go of
for ninety minutes (`Fleet.retention`), geometry dropped, capped at 14,000. They
are chained in with the live ones, which is what makes a train that arrived ten
minutes ago and leaves again in five appear on its platform — see
`RetentionTests` for the invariant that holds: nothing already drawn may move or
disappear.

## Things that are different on a phone

- **There is a search, because there is a keyboard.** The map is the document,
  so it stays a 34-point circle until asked for and then takes the header.
  Stations come from the 33,518-stop register by word-prefix over folded names —
  `Zürich` and `zurich` are one string, and "bern bahn" is a filter rather than a
  phrase — ranked by how the query matches and then by distance from the middle
  of the map, which is what "closest" means when you are looking at Lugano from
  Bern. Services match either way a person names one: the line as it is
  published (`IC8`, typed with or without the space) or the service number
  (`726`), which the national feed mostly does not send as a field and which is
  read out of the journey reference instead — the same two fields `FormationKey`
  already reads for the formation service.
- **The feed is 7 MB a request, always.** SIRI-ET has no regional filter: one
  call returns the whole country. At the server's once-a-minute cadence that is
  420 MB an hour, which is fine on a desk and not on a cellular plan. So the
  cadence is a setting — live, every five minutes, or manual — and the app says
  which one costs what.
- **Positions are recomputed 15 times a second**, not 60. A vehicle covers a
  metre or two in that time, well under a pixel; sixty would spend four times
  the energy to move nothing visible.
- **Geometry is attached only when the map is zoomed in enough to show it.**
  Matching a relation and routing a leg over a 573,000-node graph is not work to
  do for a dot two cantons away.
- **Routed legs are memoised and now survive a launch.** `RailNet.loadCache` /
  `saveCache` existed from the first version and nothing on the phone called
  them, so every launch re-ran a graph search for legs it had already solved —
  inside the fleet actor, which also answers the draw loop and every map tap.
  One cold journey stalled the lot, which is the pause on the first vehicle
  opened after a launch and on no later one. The cache is now seeded from the
  bundle, written to Application Support on background, and the per-draw
  geometry work is capped at 8 ms so a screenful of cold vehicles cannot block a
  frame either.
- **A tap on a train is answered against the whole train.** A dot is a point and
  the finger is aiming at the point. A two-hundred-metre train is a long object
  and the finger is aiming at whichever part of it is underneath — so distance
  is measured to the drawn body rather than to the head, and the eighth coach of
  an IC is no longer two hundred metres away and losing to the bus stop it is
  passing.
- **Tapping the vehicle you already have open spends the tap on the camera.**
  The panel is already showing that train, so a second tap asks the only
  question left about it: how closely to hold it. Round the three states —
  loose, centred, turning with it — and back to the start, so nothing needs a
  second control and nothing is a dead end. From far out the first of those taps
  buys the approach instead: a vehicle selected at a country zoom is a dot in
  the middle of the screen, and "turn the map to its heading" says nothing about
  a marker too small to have a visible one. So that tap closes to the zoom the
  vehicle is actually recognisable at — 18 for a bus or a tram, 17 for a train,
  which is two hundred metres and would be longer than the screen at 18 — and
  the tap after it finds the map close enough for the heading lock to mean what
  it says.
- **A tap on the track is answered from the relations, not from tiles.** The web
  app reads OpenRailwayMap's vector tiles for the OSM way under the cursor and
  matches those ids. There are no tiles here and there need not be: the
  relations carry the geometry, so the question is answered directly — exactly,
  and offline.

## Development

The map is driven from the model's own tick rather than SwiftUI's update cycle
(`AppModel.onFrame`). `UIViewRepresentable.updateUIView` runs only for state
read while evaluating a `body`, and this map's state is read inside the
coordinator — so nothing ever told SwiftUI to call it again.

Debug launch arguments, because Switzerland's network is asleep between one and
five in the morning:

```
-startOffsetMinutes 195     # open the map three hours ahead
-startLat 47.3779 -startLon 8.5403 -startZoom 13
-selectNearest 1            # tap the middle of the screen on arrival
-selectVehicle 1            # open the nearest vehicle's panel instead
-expandSheet 1              # open the sheet at full height
-startBearing 135 -startPitch 60   # a rotated or tilted map, for the viewport
-terrain3D 1 -terrainRelief 180   # open with the relief on, at 1.8x
-solidVehicles 0                  # hold the vehicles flat on a tilted map
-openSheet offline          # open straight into a sheet
-downloadRegion bern        # start a region download
-rideDemo 20                # ride a real train, reporting twenty seconds late
```

`-rideDemo` is the only way to see the ride badge from a desk: it takes a
vehicle the map is already drawing, wobbles its positions by a few metres and
feeds them to the matcher *stamped late*, so the fit has to find the same number
of seconds back again. The frame readout prints what it found.

### The version, and moving it

The bottom of the Settings sheet prints what the build calls itself —
`Version 1.0.5 (6)`, read off the bundle rather than typed into a view.

**Every working session that changes the app moves it**, at the end, as part of
the work. The patch component of `MARKETING_VERSION` goes up by one and
`CURRENT_PROJECT_VERSION` — the build number — goes up by one with it, in *both*
places they are written:

```
make-project.py                     # TARGET_SETTINGS, which regenerates the project
SwissTransit.xcodeproj/project.pbxproj   # twice: Debug and Release
```

Both, because `make-project.py` writes the project file and anyone who runs it
after editing only the project would put the old number back. A session that
touched nothing that ships — a note, a README paragraph — leaves it alone.

The point is a screenshot: somebody reporting that the trains are floating
again should not have to be asked which build they are looking at.

## Why the SDK is vendored

Mapbox ships `MapboxCoreMaps`, `MapboxCommon` and `Turf` as binary targets
hosted on `api.mapbox.com`, which SwiftPM can only authenticate against through
a `~/.netrc` entry holding a secret download token. That is a machine setting
rather than a project one.

`scripts/fetch-mapbox-sdk.mjs` fetches the same artifacts, checks them against
the SHA-256s Mapbox publishes in its own manifests, and points the package
graph at local paths. Resolution then needs no credentials and no network. It
is the same bytes by a different route, not a mirror to be trusted.
