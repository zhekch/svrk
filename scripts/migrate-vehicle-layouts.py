#!/usr/bin/env python3
"""Lift a learned-layout file to the current version.

Version 3 stopped storing a ``livery``. Paint is a fact about the company, not
about the train, and every layout read back out of the store has always been
repainted from the operator on the way out — so the colour strings on disk were
written, read, and discarded unused. Worse than wasted: a fleet repainted
between two builds left every record asserting a colour that was no longer true,
in a field nothing would ever consult.

Its units gained a ``type``: the rolling-stock register's own name for the
vehicle, ``RABe511``, ``Bt``, ``A(2E)``. That is the evidence every other field
on a unit is read *from*, and version 2 threw it away after reading it — so the
database remembered the conclusions and forgot their source.

Version 4 stopped writing down fields that hold their default. A unit spelled
out in full is about 185 bytes, and nearly all of it says what a coach already
is: 2.9 m wide, two doors, no pantograph, coupled to the one in front, no cab,
single-deck, no class band. Six and a half thousand of those is most of a
megabyte and a half of the file saying nothing. Omitting them costs no
information — an absent field is one that was ordinary — and takes the median
unit from twelve fields to four.

What no version of this can repair is the class names, which version 2 never
stored; migrated units come across without a type and acquire one the next time
that train is observed. Nothing is lost by that: every dimension the drawing
needs was already baked into the unit, so a migrated formation draws exactly as
it did. The type is what makes *future* readings improvable.

    python3 scripts/migrate-vehicle-layouts.py SwissTransit/Resources/vehicle-layouts.json
    python3 scripts/migrate-vehicle-layouts.py in.json -o out.json
    python3 scripts/migrate-vehicle-layouts.py in.json --dry-run

Idempotent: a file already at the current version is reported and left alone.
"""

import argparse
import json
import os
import sys
import tempfile

TARGET_VERSION = 5
MIGRATABLE = {2, 3, 4}

# `ClassBand` and `UnitKind` as an older file spelled them, mapped back to the
# formation service's own code — which is what version 5 keeps, because it says
# in one field what is a locomotive, what is a luggage van and what class a
# coach carries. Read off the class name instead, a rake whose every vehicle
# shares one name loses its engine.
BAND_TO_KIND = {
    "first": "1",
    "second": "2",
    "mixed": "12",
    "dining": "WR",
}


def wagon(unit):
    """One stored unit reduced to what version 5 keeps: the name, and the kind.

    Everything else in a version 2-4 unit — length, width, cabs, doors,
    pantographs, deck, joint, nose, stripe — was deduced from the class name and
    the vehicle's place in the train when the formation arrived, and is deduced
    again now at drawing time by `WagonCatalogue.units`. Carrying it was
    carrying the same deduction several thousand times over.
    """
    out = {}
    name = unit.get("type")
    if name:
        out["t"] = name
    # The body kind is the stronger signal and comes first: a unit filed as a
    # locomotive is a locomotive whatever class band it was given.
    kind = unit.get("kind")
    if kind == "locomotive":
        out["k"] = "LK"
    elif kind == "van":
        out["k"] = "D"
    else:
        code = BAND_TO_KIND.get(unit.get("band"))
        if code:
            out["k"] = code
    return out


def record(old):
    """A version 2-4 record as a version 5 one."""
    if not isinstance(old, dict):
        return None
    layout = old.get("layout")
    units = layout.get("units") if isinstance(layout, dict) else None
    return {
        "w": [wagon(u) for u in (units or [])],
        "s": old.get("seen", 0),
        "c": old.get("count", 1),
    }


def migrate(file):
    """Rewrite one decoded file in place, returning a count of what changed."""
    counts = {"entries": 0, "patterns": 0, "wagons": 0, "named": 0}

    def convert(holder, key):
        old = holder.get(key)
        if not isinstance(old, dict):
            return
        new = record(old)
        counts["wagons"] += len(new["w"])
        counts["named"] += sum(1 for w in new["w"] if "t" in w)
        holder[key] = new

    for entry in file.get("entries") or []:
        convert(entry, "record")
        counts["entries"] += 1

    for pattern in file.get("patterns") or []:
        convert(pattern, "record")
        # The losing formation is a stored layout too.
        if pattern.get("challenger") is not None:
            convert(pattern, "challenger")
        counts["patterns"] += 1

    for slot in file.get("slots") or []:
        convert(slot, "record")
        if slot.get("challenger") is not None:
            convert(slot, "challenger")

    file.setdefault("slots", [])
    file["version"] = TARGET_VERSION
    return counts


def write_atomically(path, payload):
    """Write beside the target and move, so a crash cannot truncate the seed."""
    directory = os.path.dirname(os.path.abspath(path)) or "."
    handle, scratch = tempfile.mkstemp(dir=directory, suffix=".tmp")
    try:
        with os.fdopen(handle, "w") as out:
            json.dump(payload, out, separators=(",", ":"), sort_keys=True)
        os.replace(scratch, path)
    except BaseException:
        if os.path.exists(scratch):
            os.unlink(scratch)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("path", help="the vehicle-layouts.json to migrate")
    parser.add_argument("-o", "--output", help="write here instead of in place")
    parser.add_argument(
        "--dry-run", action="store_true", help="report what would change, write nothing"
    )
    args = parser.parse_args()

    with open(args.path) as source:
        file = json.load(source)

    version = file.get("version")
    if version == TARGET_VERSION:
        print(f"already version {TARGET_VERSION}; nothing to do")
        return 0
    if version not in MIGRATABLE:
        print(
            f"version {version!r} is not one of {sorted(MIGRATABLE)}; refusing to guess",
            file=sys.stderr,
        )
        return 1

    before = os.path.getsize(args.path)
    counts = migrate(file)
    target = args.output or args.path

    if args.dry_run:
        print(
            f"would migrate {counts['entries']} entries and {counts['patterns']} "
            f"patterns from version {version} to {TARGET_VERSION}, keeping "
            f"{counts['wagons']} wagons of which {counts['named']} carry a class name"
        )
        return 0

    write_atomically(target, file)
    after = os.path.getsize(target)
    print(f"migrated version {version} -> {TARGET_VERSION}")
    print(f"{counts['entries']} entries, {counts['patterns']} patterns kept")
    print(f"{counts['wagons']} wagons, {counts['named']} of them with a class name")
    print(f"{before:,} -> {after:,} bytes ({100 * (before - after) // max(before, 1)}% smaller)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
