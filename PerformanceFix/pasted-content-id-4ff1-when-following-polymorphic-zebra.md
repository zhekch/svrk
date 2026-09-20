# Making the followed train butter smooth

## Context

Following a train judders — the train reads blurry and repeatedly "lags back",
on an iPhone 16, where drawing one train should be trivial. You asked three
things: how the 3D is rendered and whether it is the fastest option; whether the
30 tps tick and missing interpolation are the cause; and what would fix it.

Short answers, then the mechanism.

**The renderer is fine.** Mapbox Maps SDK v11.26.0 (`Vendor/mapbox-maps-ios`,
vendored and buildable from source), Metal-backed, drawing baked glTF wagons
through `ModelLayer` with true GPU instancing — the mesh crosses once via
`addStyleModel`, and per frame only a point, a rotation, a scale and an opacity
cross per wagon (`SwissTransit/Map/VehicleModels.swift:238-345`). A sixteen-coach
IC is five distinct meshes and eleven repeats. That is already the efficient
shape, and the GPU is not the bottleneck — swapping to SceneKit, RealityKit or a
hand-written Metal `CustomLayerHost` would cost a large rewrite and lose terrain
occlusion, depth sorting against buildings and `queryRenderedFeatures` hit
testing, to fix something that is not slow.

**The tick rate is not the cause either, and interpolation already exists** —
seven layers of it. There is a trapezoidal speed profile, a sub-second fraction,
a retime glide, a continuity drift, a follow extrapolator clamped to 120 ms, a
critically damped catch-up spring and a bearing spring. The follow lane already
runs its own `CADisplayLink` at display rate and already slides the train's body
with synchronous `fill-translate` rather than re-tessellating it
(`TransitMap.swift:1257-1279`, `:1482-1630`, `:1643-1713`).

**The actual cause is a latency split.** Within one follow frame, some of the
train moves synchronously and some of it moves through an asynchronous serial
queue — so the parts of the train arrive on different frames.

---

## Root cause

Mapbox splits its write paths, and the app straddles the split:

| Write | Path | Lands |
|---|---|---|
| `setCamera` | direct | next rendered frame |
| `setLayerProperty` (`fill-translate`, `line-translate`) | direct, synchronous (`Style/StyleManager.swift:890`) | next rendered frame |
| `setSourceProperties` | direct, synchronous (`StyleSourceManager.swift:267`) | next rendered frame |
| **`updateGeoJSONSource` / `updateGeoJSONSourceFeatures`** | **`backgroundQueue.async`** (`StyleSourceManager.swift:110-190`) | **whenever the queue drains, then a re-tile** |

That background queue is created once per map as
`DispatchQueue(label: "GeoJSON parsing queue", qos: .userInitiated)` —
**no `.concurrent` attribute, so it is serial**, and it is shared by *every*
source on the map (`StyleSourceManager.swift:47`).

Two consequences, and together they explain every symptom:

### 1. The followed train's dot and line number are re-tiled 60 times a second — against the whole fleet source

`followFrame` rewrites the followed vehicle's own point feature into the shared
`ID.vehicles` source on every display refresh
(`TransitMap.swift:1617-1622`), and the comment there says so outright: *"This
lane rewrites the followed vehicle's own feature at the display's rate — sixty
times a second against the model's thirty."*

`ID.vehicles` holds **every** vehicle. So each of those 60 single-feature patches
enqueues a job on the serial queue that re-tiles the entire fleet source. Behind
them, the 30 Hz tick is enqueueing *whole-collection* rewrites of the same source
(`TransitMap.swift:4785-4787`) and of `transit-vehicle-shapes`
(`:5219-5229`). The small per-frame patches queue up behind the large parses.

The camera and the body arrive on time; the dot and the number arrive late and
irregularly. A line number drawn a few points behind the train it labels,
re-landing on an uneven cadence, is exactly "blurry" and "lags back" — **and it
happens with the map flat, which is why tilt makes no difference.**

### 2. Tilted, the 3D body itself is on the late path too

`followTranslateLayers` (`TransitMap.swift:1776-1796`) slides the fill, casing,
ghost, outline, xray, the fill-extrusion fallback and both lamp layers
synchronously. It does **not** include `VehicleModels.followModels`,
`followBuried`, or the tunnel fade bands. Those are point features, which a
`fill-translate` cannot move, so they are patched through the async path instead
(`TransitMap.swift:1706-1711`).

So when solids are up, the wagons lag their own footprint, lamps and camera.
Solids switch fully on at **2° of pitch and zoom 15.2**
(`Packages/TransitCore/Sources/TransitCore/VehicleMesh.swift:1474-1499`), and
following a train sets zoom 17 — so any tilt at all puts the body on the late
path.

This is a latency and serialization problem, not a throughput one. That is why a
fast phone does not help: a faster chip does not shorten a wait behind a parse
already queued ahead of you.

### A premise in the README that no longer holds

> "Mapbox renders on its own thread from data already uploaded, so a finger drags
> the map at the display's rate whatever this app is doing." — README, *The tick
> rate is not the frame rate*

In v11 on iOS this is false. `MapView.updateFromDisplayLink` calls
`metalView.draw()` **synchronously inside the main-thread `CADisplayLink`
callback** (`Vendor/mapbox-maps-ios/Sources/MapboxMaps/Foundation/MapView.swift:706-742`),
and `MetalView` is an `MTKView` whose `draw()` runs `draw(in:)` on the calling
thread (`Foundation/MetalView.swift`). Main-thread work and map rendering are on
the same thread and compete directly. Since the whole tick — `performTick`,
`rebuildShapes`, `vehicleDrawing`, `rest()`'s per-wagon `style.elevation(at:)`
probes — is `@MainActor`, every millisecond the tick spends is a millisecond the
renderer does not have. Worth correcting in the README, because several design
comments rest on it.

---

## Plan

Ordered by impact per unit of risk. Step 0 proves the diagnosis on your device
before anything is changed.

### 0. Measure — confirm the queue latency directly

The SDK already gives an exact number for "how late does a follow patch land".
Every GeoJSON write takes a `dataId`, and `MapboxMap.onSourceDataLoaded`
(`Foundation/MapboxMap.swift:1495`) reports it back.

- Stamp the `followFrame` patch at `TransitMap.swift:1620` with
  `dataId: String(displayTime)`, subscribe to `onSourceDataLoaded`, and log
  `now - dataId` p50/p95.
- Run alongside the existing `-frameProbe YES` (`App/Diagnostics.swift:228-373`)
  and the `FrameStats.TickCost` marks already surfaced by `FrameReadout`
  (`App/ContentView.swift:1592-1620`).

Expect p50 well over one frame and a long p95 tail. If it comes back inside a
frame, the diagnosis above is wrong and steps 1–2 should not be built.

### 1. Take the followed vehicle's point off the shared fleet source

The single highest-impact change, and the one that fixes the **flat** case.

Give the followed vehicle its own one-feature source and its own circle/symbol
layers, exactly as the body already has `VehicleShapes.followSource`
(`Map/VehicleShapes.swift:49`). Then:

- Exclude the followed id from the main fleet source — `vehicleFeature` already
  has the notion of holding a vehicle out (`TransitMap.swift:1578-1580`).
- Rewrite the feature **only when the tick changes it**, not per frame.
- Slide it between ticks with synchronous `circle-translate` / `text-translate` /
  `icon-translate`, reusing `setFollowShapeTranslate`
  (`TransitMap.swift:1735-1761`) and adding the new layers to
  `followTranslateLayers` (`:1776`).

This removes 60 whole-fleet re-tiles per second and puts the dot and the number
on the same frame as the camera and the body.

### 2. Put the 3D wagons on the synchronous path

Fixes the **tilted** case. The hook already exists: `model-translation` is
installed on the wagon layers (`Map/VehicleModels.swift:316`), and
`modelElevationReference` is deliberately `.sea` *because* `.ground` ignores
`model-translation` (the comment at `:296-311` records probing this).

One constraint to design around: `model-translation` is currently a data-driven
expression reading the per-wagon vertical lift
(`["array","number",3,["get","alt"]]`, values `[0, 0, lift]` at
`VehicleModels.swift:532`), and Mapbox expressions have **no array constructor**
that can combine a per-feature value with a per-frame constant. So:

- For the follow lane, write `model-translation` as a layer **constant**
  `[dxMetres, dyMetres, lift]` each display frame, and add
  `VehicleModels.followModels`, `followBuried` and the fade bands to
  `followTranslateLayers`.
- `lift` is per-wagon and "nearly always nothing" (a wagon spanning a dip). Take
  the followed train's single lift value on the fast path, and fall back to
  today's async patch on the rare frames where its wagons' lifts actually differ.
- Note `model-translation` is in **metres, map-anchored**, not viewport points —
  so it needs no pixel reprojection and is *stabler* than `fill-translate` under
  a rotating camera.

Heading staleness is not worth chasing: at 200 km/h on a 500 m curve a train
turns ~0.2° per 33 ms tick.

### 3. Stop whole-collection rewrites competing on the same serial queue

Reduces queue occupancy so anything still async lands sooner, and cuts main-thread
tick cost (which, per the correction above, is render time).

- `drawVehicles` rebuilds a `Feature` for every vehicle and pushes one
  whole-collection `updateGeoJSONSource` per tick, with no diffing
  (`TransitMap.swift:4766-4787`). `drawFlatVehicleShapes` already does proper
  incremental `add`/`update`/`removeGeoJSONSourceFeatures` keyed on stable ids
  (`:5113-5169`) — apply that same pattern here.
- The 3D lane likewise rewrites `transit-vehicle-shapes` whole every tick
  (`:5219-5229`) while the 2D lane diffs. Make it incremental too.
- `rest()` does a `style.elevation(at:)` round-trip per wagon nose/middle/tail
  every tick when solids are up (`:5626-5640`) — cache per wagon and re-probe
  only on meaningful movement.

### 4. Only if still not smooth — move the followed train to a `ModelSource`

The clean end-state, and how Mapbox renders its own 3D puck
(`Location/Puck/Puck3DRenderer.swift:33-75`): a `ModelSource` holding one `Model`
per wagon (`position: [lon, lat]`, `orientation: [x, y, z]`), updated through
**`setSourceProperties`, which is synchronous** (`StyleSourceManager.swift:267`),
with `ModelLayer.modelType = .locationIndicator`.

That gives exact per-wagon position *and* heading every display frame with zero
queue latency and no translation approximation. It is a larger change and needs
the tunnel-fade opacity story rechecked (per-model `featureProperties` driving
`model-opacity` instead of stacked layers), so it is worth doing only if steps
1–3 leave visible judder.

### 5. Minor

- `prefersHighFrameRate` pins the renderer to 120 Hz whenever the follow pill is
  visible (`TransitMap.swift:355-357`) — that is the normal follow state. Moot on
  your iPhone 16 (60 Hz panel), but on a Pro it asks for an 8.3 ms budget the main
  thread cannot hold while a 30 Hz tick shares it, producing more missed frames
  rather than smoother motion. Worth gating on measured headroom.
- `probeRest` (`TransitMap.swift:5432`) is marked `// TEMPORARY — Remove before
  finishing.` and still runs per frame behind a `UserDefaults` flag.
- There is no `os_signpost` instrumentation anywhere; adding signposts around the
  tick phases and the follow frame would make main-thread occupancy attributable
  in Instruments.

---

## Verification

1. **Queue latency** — the step 0 `dataId` round-trip p50/p95 should fall to
   under one frame after step 1, for the followed point.
2. **On device, flat** — `-startZoom 17 -selectVehicle 1`, follow a fast train,
   watch the line number against the train body. It should be welded to it. This
   is the flat-case regression that step 1 fixes.
3. **On device, tilted** — `-startPitch 60 -solidVehicles 1`, same follow. The
   wagons should not drift against their own footprint and lamps. Step 2.
4. **Frame pacing** — `-frameProbe YES`, read `missed` refreshes and main-thread
   p95 over a 60 s follow. `missed` should approach zero.
5. **Regression suite** — the existing follow/motion tests must stay green:
   `Packages/TransitCore/RegressionTests/MapMotionTests.swift`,
   `RotationHoldTests.swift`, `ZoomStallTests.swift`, `BackwardsOnZoomTests.swift`,
   plus `TickLatencyTests.swift` and `TickStallTests.swift`.
6. Bump `MARKETING_VERSION` patch and `CURRENT_PROJECT_VERSION` in both places,
   per the README's standing rule.

## Note on the working tree

`git status` shows ~80 modified files and a large uncommitted body of work —
`drawFollowShape`, `followTranslateLayers`, `drawFlatVehicleShapes` and
`prefersHighFrameRate` exist only in the working tree, not at `HEAD`. Everything
above is written against the working tree. Worth committing before starting so
this work is separable.
