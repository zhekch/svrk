# SwissTransit power and CPU optimization plan

**Status:** implemented 2026-09-04 (WP1–WP10 in tree). Device re-measure of the three-phase Instruments script is still outstanding.
**Date of diagnosis:** 2026-09-03 / 2026-09-04.
**If context compacted:** read this file first. Do not re-open `perf.trace` unless the user captures a new one. The numbers below are the accepted baseline.

This is the working instruction set for reducing CPU, GPU, display-refresh, and radio cost. Follow it in the order of the work packages. Each package is independently shippable. Do not mix a “make following smoother” change into an idle-power change.

---

## 1. How to read this later

The app is a Mapbox map of the Swiss timetable. A model tick queries the national fleet for the current viewport, builds vehicle footprints, and uploads GeoJSON. A separate Mapbox display link presents frames. Energy is dominated by **how often those two loops run**, not by a single hot function.

Primary files:

| Area | File |
|---|---|
| Tick rate, power throttle, fleet query | `SwissTransit/App/AppModel.swift` |
| Display-link cap, camera idle, GeoJSON upload, 3D, elevation | `SwissTransit/Map/TransitMap.swift` |
| Fleet bbox query, active-minute index | `Packages/TransitCore/Sources/TransitCore/Fleet.swift` |
| Vehicle feature construction | `SwissTransit/Map/VehicleShapes.swift`, `VehicleModels.swift` |
| Terrain on/off | `SwissTransit/Map/Terrain3D.swift` |
| Location accuracy | `SwissTransit/Map/TransitMap.swift` (`applyLocationPolicy`) |
| In-app CPU/thermal readout | `SwissTransit/App/Diagnostics.swift` (`DeviceLoad`) |

Baseline Instruments capture: `perf.trace` in the repo root (1.3 GB, iPhone 16, 120 s). Phases the user performed:

- **0–40 s:** dragging the camera in 2D
- **40–80 s:** camera at rest over Genève, still 2D
- **80–120 s:** camera still at rest, **3D terrain on**

Do not treat “idle” as one number. 2D idle and 3D idle are different problems.

---

## 2. Measured baseline (do not re-litigate)

Device: iPhone 16, iOS 27, SwissTransit pid 1068, screen 43% brightness, thermal Nominal for this short run. Earlier Energy-only capture (longer 3D/drag) was thermal Fair and Energy Impact **Very High** (CPU 48%, GPU 19%, Network 10%, Display 10%, Location 7%).

| | 2D drag 0–40s | 2D idle Genève 40–80s | 3D idle 80–120s |
|---|---|---|---|
| Power Profiler CPU impact | 28.5 | **2.9** | **26.0** |
| Instructions / s | 19.4B | 3.0B | 16.7B |
| Cores busy (QoS on-core / wall) | **1.66** | **0.57** | **1.60** |
| Main thread (User Interactive) | 16% of wall | 20% | **67%** |
| Utility threads (Mapbox workers) | 28% | 19% | **64%** |
| User Initiated (Fleet + decode) | 121% | 17% | 28% |
| GPU device util | 33% | 10% | **34%** |
| GPU tiler util | 17% | 5% | 19% |
| Core Animation FPS | 41 avg | **15** once settled (60 for first ~8s) | **30–60, never 15** |
| Tiled scene bytes | 4.7 MB | 1.1 MB (constant) | **5.2 MB** |
| GPU memory in use | 417 MB | 452 MB | **554 MB** |
| Wi‑Fi received | 11.9 MB | 0.06 MB | **6.1 MB** (DEM tiles) |

Interpretation that all later work must respect:

1. **2D idle already drops CPU ~10×** within a second of the finger lifting. The 15 Hz floor is the remaining 2D bill (0.57 cores, 10% GPU, full GeoJSON rewrite every tick).
2. **3D idle is as expensive as dragging.** It never returns to the 15 Hz cap. That is a frame-rate-policy bug, not “terrain is just heavier per frame.” Heavier-per-frame is real (5× scene bytes, +100 MB GPU) but the FPS trace proves the cap is off.
3. The original Energy “Very High” gauge is the 3D / drag regime, not settled 2D.
4. Time Profiler call trees were **not** inverted (CPU-narrative backtraces empty; Thread Activity XML was 2.1 GB). QoS + FPS + GPU driver + power split is the evidence. If a new trace is captured, Time Profiler + Thread Activity + CA FPS + Power Profiler is enough; skip CPU Counters.

### 2.1 What the 2D-idle 0.57 cores actually is

Split roughly evenly:

- **User Interactive ~0.17 cores:** main thread `draw()` + Mapbox `updateGeoJSONSource` submit.
- **Utility ~0.19 cores:** Mapbox serial GeoJSON parse / tessellate / tile workers.
- **User Initiated ~0.17 cores:** `Fleet.vehicles` on the fleet actor.

So even a “cheap” idle tick is: walk the active-minute national fleet → filter to viewport → rebuild footprints → upload **every** vehicle feature as a fresh GeoJSON document → Mapbox presents at 15 Hz.

### 2.2 What 3D idle adds on top

- Display link stuck at `.default` (60/120 Hz request) because `cameraSettled` never stays true.
- Mapbox terrain mesh every frame (GPU 34%, DEM downloads).
- `style.elevation(at:)` per wagon per tick (and cableway probes), a hop into the renderer, skipped entirely when `terrain3D` is false (`rest(..., relief:)`).
- Main thread busy **two thirds of every second**.

---

## 3. How the two clocks work today

There are two loops. Confusing them is how a “save power” change makes following worse.

### 3.1 Model tick (`AppModel`)

`startTicking()` sleeps on a deadline, then `requestCadenceTick()` → `enqueueTick()` → `performTick()`.

`frameInterval` (`AppModel.swift`):

- Sheet covering the map (`mapObscured`): **1 s**
- Following a vehicle: **33 ms** (ignores zoom floor)
- Zoom `< stillZoom` (9): **1 s**
- Dots only (not `detailedVehicles`, or zoom below shape min): **66 ms**
- Detailed vehicles, zoom ≥ 14: floor **33 ms**, then `pace()` may stretch toward **150 ms** based on the fastest vehicle on screen
- Detailed vehicles, zoom 9–14: floor **50 ms**, same `pace()`
- Then `powerFactor` (Low Power Mode or thermal `.serious`/`.critical`) multiplies, floored at 1 s
- **`.fair` thermal does nothing.** That was a deliberate choice. The first Energy capture was Fair and still Very High.

`pace()` already exists to avoid rebuilding a city tram 17 times per pixel. `paceSlowest` is 150 ms (~6.7 Hz). A train at line speed in the Genève viewport still keeps the interval near the 33–66 ms floor. Idle camera ≠ idle fleet.

`performTick` always:

1. Possibly `fleet.redrawTimetableIfNeeded` (once a wall-clock second)
2. `fleet.vehicles(in:query, ...)` — walks `activeJourneys` for the current minute (national), then bbox-filters
3. `rebuildShapes` — up to `shapeLimit` (260) footprints
4. `frameVersion += 1` and `onFrame?()` which calls `MapCoordinator.draw()`

Vehicles **outside the viewport are not drawn.** They are still **visited** in the active-minute list. The 15% bbox pad (`bbox.padded(by: 0.15)` plus shape padding in metres) is the only off-screen work that is intentional (pop-in prevention, long trains straddling the edge).

### 3.2 Mapbox display link (`MapCoordinator.setRenderRate`)

`mapView.preferredFrameRateRange` and the follow `CADisplayLink` are capped to the model pace **only when `cameraSettled` is true**.

```
if !locationActive           → 1 Hz
else if !cameraSettled       → CAFrameRateRange.default   // 60/120
else if following            → followRange (up to 2× model, max 60)
else                         → pacedRange (model Hz)
```

`cameraMoved()` runs on **every** `onCameraChanged`:

```swift
cameraSettled = model.isFollowingVehicle && !gestureCameraActive
setRenderRate()
```

If the user is not following, this **forces unsettled** (uncapped fps) on any camera event, then waits for `onMapIdle` to set `cameraSettled = true`.

In 2D, idle arrives ~8 s after the pan stops → 15 Hz. In 3D, idle never arrives for the remaining 40 s → 30–60 Hz forever. Terrain DEM, terrain mesh, and per-tick GeoJSON updates keep Mapbox “busy,” so `onMapIdle` does not stick, so the cap never returns. Chicken and egg.

Tilt end (`handleTilt`) also sets `cameraSettled = model.isFollowingVehicle` (false if not following) and relies on the same idle path.

This is the single highest-leverage bug.

### 3.3 Double draw

`TransitMap.updateUIView` calls `draw()` whenever SwiftUI updates the representable. `onFrame` also calls `draw()`. Vehicle uploads are guarded by `drawnFrameVersion`. Other lanes (`drawStops`, `drawCableways`, `apply3D`, `applySolidity`, `applyHighlights`) still run and must keep their own “write only if changed” guards. Do not add a third caller of `draw()`.

---

## 4. Goals and non-goals

**Goals**

- 3D idle should cost in the same *order of magnitude* as 2D idle, not as 2D dragging. Target after WP1+WP2: 3D idle CPU impact ≤ ~8, FPS ≤ model pace (15 or `pace()`), GPU util well below the 34% idle figure.
- 2D idle should drop below 0.57 cores without making live vehicles stutter at city zoom. Target: skip GeoJSON when nothing moved a pixel; stretch tick when the camera has been still; do not walk the whole country every 66 ms.
- Dragging may stay expensive. Smooth pan is allowed to use `.default` fps. It must **return** to the cap.
- Following must remain smooth. Do not cap the follow display link to the model rate (see comments on `followRange`). Do not sample `elevation(at:)` on the follow display link (`rest(..., measure: !follow)` already avoids that — do not regress it).

**Non-goals**

- Micro-optimizing Swift at the instruction level. CPU Counters are not needed.
- Turning 3D off as the “fix.” 3D may stay; it must idle.
- Breaking vehicle gliding so that trains jump once a second at zoom 16.
- Rewriting Mapbox.

**Hard constraints already encoded in comments — obey them**

- One GeoJSON source for flat + solid + lamps of a vehicle. Splitting them again desyncs lamps from noses.
- Followed vehicle has its own source so the display-rate lane does not rebuild hundreds of others.
- `updateGeoJSONSource` is a serial parse queue inside Mapbox. Full-document rewrite is expensive; feature-level `updateGeoJSONSourceFeatures` replaces only what you pass (omitted features disappear).
- Do not call `tick()` directly; go through `enqueueTick()`.
- Do not write `@Observable` viewport/zoom on every camera event (already guarded). Do not put `fastestDrawn` / `mapObscured` / `powerFactor` / `frameVersion` into observation.
- `elevation(at:)` is a renderer hop. Once per model tick per wagon is the intended price. Per display refresh is forbidden.

---

## 5. Work packages (do in this order)

Each package: problem, change, files, tests, verify. Stop after WP1 and re-measure if possible; it should move the Energy gauge by itself.

---

### WP1 — Stop 3D from holding the display at 60 Hz

**Priority:** P0. Largest measured idle win. CPU 26 → hopefully ~8–12, GPU 34% → much lower, Display slice down, main thread 67% → nearer 20%.

**Problem.** `cameraMoved()` sets `cameraSettled = isFollowing && !gesture`. Any `onCameraChanged` that is not a follow write uncapped the renderer. 3D terrain / DEM / source updates keep firing camera-changed or prevent `onMapIdle`, so the cap never returns.

**Change.**

1. **Only a finger or an app-started camera ease may clear `cameraSettled`.** Mapbox-internal camera events, terrain tile arrival, and GeoJSON-driven invalidation must not.

   Suggested state:

   - `gestureCameraActive` already exists (`gestureCameraCount > 0 || customTiltActive`).
   - Add `easeCameraActive` if programmatic eases (focus, frame route, debug start) currently rely on the same idle path — they should set a flag around `beginGesture`/`endGesture` or the ease completion.
   - `cameraMoved()` should **not** assign `cameraSettled` at all, *or* should only set it false when `gestureCameraActive || easeCameraActive`.
   - `onMapIdle` still sets `cameraSettled = true` (and can stay as the “gesture ended and coast finished” signal).
   - Tilt `.ended`: set `cameraSettled = true` immediately if no other gesture is down, or call `setRenderRate()` toward pacedRange without waiting for Mapbox idle. Do not leave it false until idle.

2. **Decouple render-rate from Mapbox idle.** If no gesture/ease has been active for e.g. 150–300 ms, force `cameraSettled = true` with a short `Task.sleep` watchdog. Idle is a nice extra, not the only path back to the cap. This breaks the chicken-and-egg in 3D.

3. **Turning terrain on must not leave the link at `.default`.** `apply3D` already no-ops when the tuple is unchanged. After a terrain toggle, call `setRenderRate()` with the current pace. A few seconds of higher fps while DEM streams in is acceptable; 40 s is not.

4. **Do not treat pitch > 0 as “camera busy.”** Tilted 2D/3D looking at a still viewport is idle.

**Files:** `SwissTransit/Map/TransitMap.swift` (`cameraMoved`, `setRenderRate`, `handleTilt`, `onMapIdle` observers, `apply3D`).

**Do not:** cap during an actual pan/pinch/tilt. That was tried in comments and makes gestures stutter.

**Verify:**

- Repeat the 2D-drag / 2D-idle / 3D-idle script. 3D idle FPS must fall to the model pace (about 15, or `pace()`), not stay 30–60.
- 2D idle must still drop to ~15 after a pan (should get *faster* than the current 8 s delay if the watchdog is in).
- Following a train must still interpolate between ticks (follow link at `followRange`, not `pacedRange`).
- Diagnostics `DeviceLoad.cpuPercent` in 3D idle should be in the same band as 2D idle, not drag.

---

### WP2 — Do not re-upload GeoJSON that has not moved

**Priority:** P0/P1. This is most of the 2D-idle Utility + a chunk of User Interactive. Every tick currently does:

```swift
style.updateGeoJSONSource(withId: ID.vehicles, geoJSON: .featureCollection(...))
```

for **all** dots, and a matching full rewrite of the shapes source, even if every vehicle moved a centimetre.

**Problem.** Mapbox’s GeoJSON path is a serial parse + tessellate. 2D idle GPU is only 10% and tiled bytes are *constant* 1.08 MB — the GPU is repeating the same scene. The CPU is rebuilding the document that describes it.

**Change.**

1. **Vehicle points (`ID.vehicles`).** Keep the last uploaded `[id: Feature]` (or a hash of id + quantized lon/lat + selected/emerged/tunnel/label). Quantize coordinates to something finer than a pixel (e.g. 1e-6 deg ≈ 10 cm, or better: metresPerPoint * 0.2). If a feature’s quantized payload is unchanged, do not include it in a write.

   Prefer **skipping the whole source write** when nothing in the viewport changed by a pixel. That is the idle case.

   If only a handful changed, `updateGeoJSONSourceFeatures` can patch those ids. **Warning:** that API *replaces* the matched features and leaves others; it does **not** delete omitted ones. Use it only for in-place moves. Vehicles that left the viewport still need a full rewrite or an explicit delete path. Simplest correct idle path: **if the id set is identical and every feature is quantized-equal, write nothing.** If the id set changed (pan, vehicle appeared/disappeared), full rewrite. If id set same but a few moved, either full rewrite (simpler) or feature patch (cheaper). Start with skip-if-identical; add patch only if profiling says so.

2. **Shapes source (`VehicleShapes.source`).** Same idea. Footprint polygons are large. Hash per vehicle id of: emergence, placements, resting grades/lifts, selected, stood. Skip the whole upload if the set of hashes is unchanged.

   Follow source already compares `drawnFollowShapeFeatures` / `drawnFollowPointFeature`. Copy that pattern; do not invent a third one.

3. **Stops, platforms, tracks, route, railway shapes.** These already have “only if changed” comments in places. Audit `drawStops`, `drawPlatforms`, `drawTracks`, `drawRoute`, `drawRailwayShapes`, `drawCableways` and confirm a settled camera writes **zero** source updates. Cableways already compare `drawnCableways` by value and retry pending terrain at 0.75 s — keep that.

4. **Do not skip** while emergence is animating, selection ring is fading, tunnel fade `dt` is in flight, or follow catchup is running. Those need frames.

**Files:** `TransitMap.swift` (`drawVehicles`, `drawVehicleShapes`, follow lane), possibly a small `struct FeatureFingerprint`.

**Verify:** 2D idle, diagnostics or a counter of `updateGeoJSONSource` calls per second → should fall from ~15 to ~0–2 when the camera is still and vehicles have not moved a pixel. A tram at 20 km/h at zoom 14 should still advance, but maybe only every few ticks if quantized to 0.2 px. A train at 140 km/h at zoom 16 must still look continuous.

**Risk:** quantization too coarse → stepping. Too fine → no savings. Tie the quantum to `metresPerPoint` (same philosophy as `paceStepPoints = 0.4`).

---

### WP3 — Stretch the tick when the camera is still

**Priority:** P1. Complementary to WP2. Even a skipped GeoJSON write still costs `Fleet.vehicles` + `rebuildShapes` if the tick runs at 15 Hz.

**Problem.** `wantedInterval` keys off zoom, follow, and fastest vehicle. It does **not** know whether the user is looking at a still picture. Genève idle still has fast trains, so `pace()` stays near the 33–66 ms floor and you pay 0.17 cores of Fleet forever.

**Change.** Introduce an explicit **still-camera** multiplier, separate from `powerFactor` and `mapObscured`.

Suggested policy (tune against a live Genève view):

| Condition | Tick interval |
|---|---|
| Gesture / ease / follow | unchanged (current rules) |
| Camera still < 2 s | unchanged |
| Camera still ≥ 2 s, live clock, detailed zoom | `max(current, 100–150 ms)` — already `paceSlowest`; *raise* `paceSlowest` for still-camera only, e.g. 250–400 ms |
| Camera still ≥ 5 s | 250–500 ms |
| Camera still ≥ 15 s and no selection | 500 ms–1 s |
| Clock paused / scrubbing held still | 1 s immediately (vehicles do not move) |
| `mapObscured` | 1 s (already) |
| Scene inactive | 1 Hz renderer (already) + paused presentation (already) |

Still-camera must **not** apply while `isFollowingVehicle` (the whole map is moving).

Wake immediately (existing `repaceIfNeeded` + `requestTick`) on: pan/pinch/tilt begin, selection change, clock play/pause, terrain toggle, follow start.

Implementation sketch:

- `MapCoordinator` already has `cameraSettled`. Publish a **non-observed** `model.cameraSettledAt: CFTimeInterval?` or a bool `model.cameraIsSettled` written only on true/false edges (so it does not invalidate SwiftUI).
- `wantedInterval` reads that + `clock.isPlaying`.
- Do not put a Timer in SwiftUI. Fold into `frameInterval`.

**Off-screen / far vehicles:** they are already not in `vehicles`. The win here is running the national walk less often, not skipping more vehicles.

**Files:** `AppModel.wantedInterval` / `frameInterval`; `TransitMap.cameraMoved` / idle watchdog from WP1.

**Verify:** 2D idle cores should fall from 0.57 toward ~0.2–0.3. Vehicles on a still city map may hitch slightly at 4 Hz; that is acceptable if a pan instantly restores 15 Hz. Following must be unchanged.

**Do not** drop below 1 Hz while foreground-visible and live; the comment on `throttleFloor` is right — a dead-looking map makes people prod it.

---

### WP4 — Do not walk the national fleet every tick

**Priority:** P1. This is the User Initiated 0.17 cores in 2D idle and much of the 1.2 cores during drag.

**Problem.** `Fleet.vehicles` (Fleet.swift ~2122):

```
candidates = activeJourneys(in: fleet, at: moment)  // all journeys alive this minute
for journey in candidates {
    if hidden mode: continue
    if not extraId: clock gate; if drawnWithin() disjoint padded bbox: continue
    position(...)
    if not in padded bbox: continue
}
```

`activeJourneys` is cached per minute — good. The **per-tick loop still visits every active journey in the country** to ask `drawnWithin()` / clock. At zoom 8 that is the point (everything is in view) and `stillZoom` already slows to 1 s. At Genève zoom most journeys fail the box test, but they still pay the iteration and the `drawnWithin()` build.

**Change.**

1. **Spatial index of active journeys.** Grid by `drawnWithin()` (or a cheap centroid + radius). `vehicles(in:bbox)` only walks cells overlapping `padded`. Rebuild the grid when `activeMinute` / `chainedRevision` / `timingRevision` changes, not every tick.

   `drawnWithin()` is described as exact and possibly built on first ask — that is the cost to stop paying nationally.

2. **Keep `including extraId`** as an explicit exception (already): a selected vehicle that just jumped out of the box must still return.

3. **Do not change inclusion semantics.** Tests in `Packages/TransitCore/Tests` around fleet queries / thinning / extraId must stay green. Add a test: vehicles in a small Genève bbox do not invoke positioning on a journey whose `drawnWithin` is in Zürich.

4. Optional later: store last position per journey and skip `Positioning.position` if the journey was outside last tick and the box has not moved. Riskier; do spatial index first.

**Files:** `Packages/TransitCore/Sources/TransitCore/Fleet.swift` (`vehicles`, `activeJourneys`, new grid). Tests under `Packages/TransitCore/Tests`.

**Verify:** TransitCore tests. Instruments: User Initiated in 2D idle should drop. Drag at country zoom (zoom < 9) should be similar — that path is already 1 Hz.

---

### WP5 — Freeze or crawl anything not on screen

**Priority:** P1/P2. The user asked for this explicitly. Drawing is already viewport-culled. Remaining off-screen work:

| Work | Today | Desired |
|---|---|---|
| Vehicle snapshots outside bbox | Not returned (except `extraId`) | Keep. Pad 15% is enough; do not shrink it or long trains pop. |
| Active-minute walk of the country | Every tick | WP4 grid |
| Geometry attach (`withGeometry: detailed` when zoom ≥ 10) | For vehicles in the (padded) query box | Keep for in-view. Do not attach geometry for the 15% pad if they are only dots — optional micro-saving. |
| `keepRefining` / `keepTimingsLive` / `startLearning` | Background, already cancelled when `powerFactor > 1` | Also pause while camera still ≥ 5 s **or** always rate-limit harder. They are speculative. |
| `coverViewportIfNeeded` / opening geometry warm | After resume | Keep. |
| Stops / platforms / railway overlay | Viewport queries | Confirm they do not rebuild on a still camera (WP2 audit). |
| Cableway terrain walk | Retries every 0.75 s while pending | Keep; already gated. When terrain off, `ground` returns 0 and should not hit `elevation(at:)`. |
| Follow interpolation of vehicles not followed | N/A (only followId) | Keep. |
| Timetable window `redrawTimetableIfNeeded` | ≤ 1 Hz | Keep. |

Concrete extra freeze rules worth adding:

1. **Selection-only high rate.** If a vehicle is selected but not followed, only that vehicle needs 15–30 Hz interpolation for the panel clock / formation. The rest of the map can sit on the still-camera interval (WP3). Today one tick rebuilds everyone.

   Implementation: `performTick` still queries the viewport set (needed for the map), but WP2 will skip uploads for the ones that did not move a pixel. Optionally: query full viewport at the slow interval, and query `including: selectedID` at the fast interval as a cheap one-vehicle tick. That is a second code path — only do it if WP2+WP3 are not enough.

2. **Hidden modes** already drop before positioning. Keep that first.

3. **Dot spacing / thinning** (`thinTheHidden`) already drops stacked vehicles. Do not draw 40 buses as 40 meshes in one depot; that is already the intent of `noCloserThan`. Check `dotSpacing(at:zoom:)` is aggressive enough at city zoom.

4. **`shapeLimit = 260`.** Already a cap. If city centres still build 260 full footprints every tick, consider: only the nearest N or the largest on screen get shapes; the rest stay dots until selected. That is a product change — ask before doing it.

**Files:** `AppModel.performTick`, `Fleet.vehicles`, refine/timing loops around `keepRefining` / `keepTimingsLive` (~4280+ in AppModel).

---

### WP6 — 3D CPU after the frame rate is fixed

**Priority:** P2, **after WP1**. If 3D idle is still expensive at 15 Hz, then per-frame 3D work is the remainder.

**Work:**

1. **`rest(..., relief: terrain3D, measure: !follow)`** — already skips elevation when terrain is off, and skips new samples on the follow display link. After WP1 the main tick is 15 Hz; 2 samples/wagon × ~30 wagons = ~60 renderer hops/tick. Cache last sample per wagon id and only resample if the wagon moved more than ~2 m or the camera exaggeration changed. The comment in `rest` already says the ground does not change slope over a metre.

2. **Cableway `ground(_:)`** — same cache. Pending retry 0.75 s stays.

3. **DEM network.** 6.1 MB in 40 s of 3D idle. `Terrain3D.installSource` uses Mapbox DEM, `maxzoom = 14`. After the viewport is still, Mapbox should stop fetching. If it does not, it is because WP1 left the camera “moving.” Recheck Wi‑Fi after WP1 before adding a DEM pause.

4. **Buildings 3D** (`buildings3D` / Standard config). Extruded buildings are GPU. If 3D idle GPU stays high at 15 Hz, offer / default buildings off when terrain is on, or fade buildings above a pitch/zoom. Product decision.

5. **Do not call `setTerrain` every tick.** `apply3D` is already gated on `drawn3D` tuple. Keep it that way. Adding a write here re-tiles DEM (comment at `draw` / `apply3D`).

6. **Wagon meshes.** `VehicleModelStore.names` bakes a few per tick. Fine. Do not bake off-screen; it already takes `shapes.flatMap(\.placements)` from in-view footprints.

**Files:** `TransitMap.rest`, `drawCableways`, `Terrain3D.swift`, `VehicleModelStore.swift`.

**Verify:** 3D idle with WP1 in, then compare GPU util and User Interactive with terrain on vs off at the same 15 Hz. The delta is the true 3D tax.

---

### WP7 — Location, heading, radio

**Priority:** P2. First Energy capture had Location 7%, Network 10%. The 120 s power-profiler run showed 2D idle network ≈ 0; 3D idle 6 MB DEM; drag 12 MB tiles.

**Already good (do not regress):**

- Custom `AppleLocationProvider` instead of Mapbox default `kCLLocationAccuracyBest`.
- Coarse: 25 m filter, hundred-metres accuracy, unless locate-follow / ride / recent motion / nearby offer.
- Heading subscription **removed** when the puck is off screen (`headingIsVisible`).
- `disconnectLocation` on scene inactive.
- Station probe throttled (45 s class interval — see `stationProbeAfter`).
- Ride detection does not hold GNSS at full duty all session.

**Possible extras:**

1. If locate mode is `.unfocused` and the puck is off screen, you can stop updating location entirely except for the rare nearby-transit probe. Today a coarse stream still runs when `locationActive`.
2. GTFS-RT refresh is 300 s even in `.all` (`TransitDataMode.refreshInterval`). Fine. OJP/formation on-demand is already the cheaper mode. Do not poll formations for every in-view train while idle; that is what `.onDemand` is for. Defaulting to on-demand is a product choice.
3. After WP1, 3D idle should not keep pulling DEM. If it does, file it as Mapbox camera-not-idle, not as a new downloader.

**Files:** `TransitMap.applyLocationPolicy`, `AppModel` data mode / refresh loops.

---

### WP8 — SwiftUI and main-thread interference

**Priority:** P2. Historical bug (fixed): unguarded `model.viewport =` every camera event invalidated the whole chrome at tick rate. Do not reintroduce.

**Audit:**

- `updateUIView` → `draw()` on every representable update. Vehicle path is version-guarded; ensure `apply(basemap:)` and `setLocationActive` are no-ops when unchanged (location path already guards).
- Diagnostics overlay: `recordFrame` is 4 Hz and only when `showDiagnostics`. Keep it that way. `DeviceLoad.sample` is 1 Hz. Do not sample `task_threads` every frame (comment in Diagnostics.swift).
- `RidePill` pulse already respects Reduce Motion and Low Power Mode.
- Avoid `@Observable` writes from the tick except `vehicles` / `vehicleShapes` / `frameVersion` (frameVersion is already `@ObservationIgnored`). If WP2 skips uploads, also skip assigning `vehicles` when the snapshots are quantized-equal, or SwiftUI panels still dirty 15 Hz. **Important:** the map does not need Observation to draw (it uses `onFrame`). The panels do. A still camera with a live selected vehicle still needs the panel clock; the rest of the list can lag.

**Files:** `AppModel` observation surface, `ContentView.swift`, `TransitMap.updateUIView`.

---

### WP9 — Thermal `.fair` and Low Power

**Priority:** P2. Product/policy.

Today: Low Power or `.serious` → `powerFactor = 2`; `.critical` → 4; `.fair` → 1.

The first Energy capture was **Fair** and Very High. `.fair` is “a warm day,” and the comment says not to halve the common case. Options:

- Still-camera backoff (WP3) will cut the common case without waiting for thermal.
- Optional: if `.fair` **and** 3D on **and** camera still, apply factor 2. Narrower than a global Fair throttle.
- When `.serious`, also force `cameraSettled` path (WP1) and skip DEM exaggeration > 1.

Do not pause the live clock in thermal throttle.

---

### WP10 — Watch app

**Priority:** P3. Not in `perf.trace` (iPhone). Same philosophy: no 15 Hz national walk on a watch. `WatchTransitMap` / `WatchTransitModel` should tick at 1 Hz or on significant position change. If someone profiles the watch later, start there. Do not block iPhone WPs on this.

---

## 6. Implementation order and how to land it

Do **not** implement everything in one PR. Suggested stack:

1. **WP1** frame-rate idle (TransitMap only). Highest confidence, highest idle win, smallest blast radius if follow is tested.
2. **WP2** skip identical GeoJSON. Idle CPU on Utility + main.
3. **WP3** still-camera tick stretch. Needs WP1’s reliable `cameraSettled`.
4. **WP4** spatial index in TransitCore. Test-heavy, independent of UI.
5. **WP6** elevation cache, only if 3D idle still hurts after 1–3.
6. **WP5** refine-loop pause / selected-vehicle fast path, only if 2–4 are not enough.
7. **WP7–WP9** polish.
8. **WP10** watch, later.

Each PR: one concern, Instruments before/after on the same three-phase script (2D drag 30s, 2D idle 30s, 3D idle 30s). Record CPU impact, cores, FPS, GPU%. Put numbers in the PR.

---

## 7. How to re-verify (do not skip)

Same package as the diagnosis, no more:

- Time Profiler
- Thread Activity
- Core Animation FPS
- Power Profiler

Release, physical iPhone, 30–60 s. Script:

1. 2D, pan around 20–30 s
2. Hands off, 2D, 30 s
3. Turn terrain on, hands off, 30 s

Pass criteria for “idle is fixed”:

- 2D idle FPS ~ model pace (≤ 15, not 60 after the first 300 ms)
- 3D idle FPS ~ same cap (not 30–60 for tens of seconds)
- 3D idle CPU impact no longer ≈ drag (26 vs 28). Aim for < 10.
- 2D idle cores < 0.57, ideally < 0.3 after WP2+WP3
- Following a train still looks continuous (spot-check, not just idle)

In-app: enable the diagnostics readout (`DeviceLoad`). 3D idle `cpuPercent` should not sit in the drag band.

---

## 8. Pitfalls (read before editing)

- **Follow link vs model tick.** Follow must stay faster than the model. `followRange` is 2× model, max 60. `rest(measure: !follow)` must stay false on the display link.
- **`onCameraChanged` is not “the user moved the map.”** In 3D it fires for internal reasons. WP1 is specifically about not believing it.
- **`updateGeoJSONSourceFeatures` deletes nothing.** Using it as a “diff upload” without a leave-viewport path will ghost trains.
- **One source per vehicle’s drawings.** Do not split lamps again.
- **`enqueueTick` only.** Direct `performTick` / `tick()` reintroduces the drag backlog (239 ticks) described above `requestTick`.
- **Do not observe `frameVersion`.** SwiftUI would then `updateUIView` → `draw` in lockstep with the tick (the double-draw bug).
- **`pace()` floor vs still-camera.** Fast trains in a still viewport still want high tick *if you rebuild everyone*. WP2 (skip upload) is what makes a slower tick look acceptable; WP3 without WP2 just makes jumps.
- **Pad 15%.** Removing it to “freeze off screen” will pop trains at the edge. Spatial-index them instead of dropping them.
- **`.fair` is not `.serious`.** Do not globally halve fps on Fair.
- **Background/inactive paths already exist** (`pausePresentation`, `suspend`, 1 Hz renderer). Idle-foreground is the gap, not background.

---

## 9. Suggested first code change (WP1, concrete)

In `MapCoordinator.cameraMoved()` (TransitMap.swift ~364):

**Remove:**

```swift
cameraSettled = model.isFollowingVehicle && !gestureCameraActive
setRenderRate()
```

**Replace with:**

- If `gestureCameraActive` (or a new `easeCameraActive`): `cameraSettled = false`; `setRenderRate()`; arm/reset a 200 ms settle watchdog.
- Else: do not touch `cameraSettled`. Still `reportViewport()` as today (follow coalesced).
- Watchdog fire: `cameraSettled = true`; `setRenderRate()`.
- `onMapIdle`: `cameraSettled = true`; `setRenderRate()`; cancel watchdog.
- `handleTilt` `.ended`: do not set `cameraSettled = isFollowingVehicle`. Set true (or let watchdog do it). Call `setRenderRate()`.
- Follow writes must not go through the “user moved” path — they already avoid it for viewport coalescing; they must also not clear settled. Today `cameraSettled = isFollowing && !gesture` is **true** while following, which *keeps the cap in the follow range*. After the change, while following, `setRenderRate` still uses `followRange` because `model.isFollowingVehicle && followLink` is the branch, independent of `cameraSettled`. Confirm that path still runs at the end of `startFollowLink` / `wakeFollowLink`.

Write a comment at the assignment site: **Mapbox camera-changed is not a user gesture; treating it as one holds ProMotion at 60 Hz for the lifetime of 3D.**

---

## 10. Open product questions (do not guess in code)

Ask the user before:

- Defaulting terrain off, or auto-disabling buildings when terrain is on.
- Default data mode `.onDemand`.
- Capping city-centre detailed shapes below 260.
- Making a still live map crawl at 2 Hz (visible hitching vs battery).
- Treating thermal `.fair` as a throttle when 3D is on.

Until then: WP1–WP4 are mechanical and justified by the trace.

---

## 11. Progress log

- 2026-09-04: Plan written from `perf.trace` analysis. Implementation not started.
- 2026-09-04: Implemented WP1–WP10 in the app (not yet re-measured on device).
  - **WP1** `TransitMap.cameraMoved` no longer treats Mapbox camera-changed as a gesture. 200 ms settle watchdog; tilt end settles immediately; programmatic eases use a generation flag; `apply3D` re-asserts the paced display-link range.
  - **WP2** Vehicle-point and shape GeoJSON uploads skip when quantized fingerprints match (0.2 px, same idea as `paceStepPoints`). Stops/platforms/tracks/route/cableways already gated.
  - **WP3** Still-camera tick stretch: 250 ms after 2 s, 400 ms after 5 s, 750 ms after 15 s with no selection; paused clock is 1 s immediately. Wakes on pan, selection, play/pause, terrain, follow.
  - **WP4** `Fleet` spatial grid of `drawnWithin` at 0.2° cells, rebuilt with the active-minute index. `including:` still returns an out-of-box vehicle. Test: `testAGeneveViewportDoesNotPositionZurichLocalJourneys` (skipped without the SIRI snapshot).
  - **WP5** Refine / live-timing / formation-learning loops sleep while the camera has been still ≥ 5 s; a pan restarts them.
  - **WP6** Reverted. Quantized elevation samples made coaches along a rake sit at different grades (jittery wagons). Model tick samples `elevation(at:)` again; follow display link still reuses last rest. Still-camera tick stretch does not apply when zoom ≥ shape min and something on screen is moving — that case stays at `pace()` (33 ms / 30 fps close up).
  - **WP7** Left the coarse location stream running while the scene is active. Disconnecting when the puck was “off screen” ran before the first fix, so the puck never appeared and the locate button was a no-op (`latestLocation == nil`). Heading still drops when the puck is off screen.
  - **WP8** Skip `vehicles` / `rebuildShapes` when the fleet has not moved a pixel and selection/follow/emergence are unchanged.
  - **WP9** `.serious`/`.critical` cap DEM exaggeration at 1. Did **not** globally throttle `.fair` (open product question). Still-camera backoff covers the common case.
  - **WP10** Watch map already interpolates at 5 s and refreshes the viewport at 2 min — slower than the 1 Hz ceiling. Comment only.
  - Verify on device with the three-phase Instruments script in §7 when a phone is available. Before/after CPU impact and FPS not yet recorded.
- When a WP lands, append: date, PR/commit, before/after CPU impact and FPS for the three phases.
