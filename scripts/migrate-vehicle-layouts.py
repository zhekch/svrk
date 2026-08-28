#!/usr/bin/env python3
"""Lift a learned-layout file from version 2 to version 3.

Version 3 changed two things about what is written down.

The stored layout stopped carrying a ``livery``. Paint is a fact about the
company, not about the train, and every layout read back out of the store has
always been repainted from the operator on the way out — so the six colour
strings on disk were written, read, and discarded unused. Worse than wasted: a
fleet repainted between two builds left every record asserting a colour that was
no longer true, in a field nothing would ever consult.

Its units gained a ``type``: the rolling-stock register's own name for the
vehicle, ``RABe511``, ``Bt``, ``A(2E)``. That is the evidence every other field
on a unit is read *from*, and version 2 threw it away after reading it — so the
database remembered the conclusions and forgot what they were drawn from, and a
better reading of the same names could never reach anything already stored.

Which is the one thing this script cannot repair. Version 2 never wrote the
class names down, so there is nothing here to recover them from; migrated units
come across without a type and acquire one the next time that train is observed.
Nothing is lost by that. Every dimension the drawing actually needs — length,
width, deck, nose, cabs — was already baked into the unit by the version 2
reading, so a migrated formation draws exactly as it did before. The type is
what makes *future* readings improvable, not what makes this one work.

The alternative was to let the version check discard the file, which for the
bundled seed means throwing away several hundred learned trains to gain a field
that would refill on its own anyway. This is cheaper.

    python3 scripts/migrate-vehicle-layouts.py SwissTransit/Resources/vehicle-layouts.json
    python3 scripts/migrate-vehicle-layouts.py in.json -o out.json
    python3 scripts/migrate-vehicle-layouts.py in.json --dry-run

Idempotent: a file already at version 3 is reported and left alone.
"""

import argparse
import json
import os
import sys
import tempfile

SOURCE_VERSION = 2
TARGET_VERSION = 3


def strip_layout(layout):
    """Drop what version 3 does not store. Returns True if anything went."""
    if not isinstance(layout, dict):
        return False
    return layout.pop("livery", None) is not None


def migrate(file):
    """Rewrite one decoded file in place, returning a count of what changed."""
    counts = {"entries": 0, "patterns": 0, "liveries": 0, "units": 0}

    def visit_record(record):
        if not isinstance(record, dict):
            return
        layout = record.get("layout")
        if strip_layout(layout):
            counts["liveries"] += 1
        if isinstance(layout, dict):
            counts["units"] += len(layout.get("units") or [])

    for entry in file.get("entries") or []:
        visit_record(entry.get("record"))
        counts["entries"] += 1

    for pattern in file.get("patterns") or []:
        visit_record(pattern.get("record"))
        # The losing formation is a stored layout too, and one that would
        # otherwise keep its paint until the day it won.
        visit_record(pattern.get("challenger"))
        counts["patterns"] += 1

    # The per-hour tier starts empty and fills as trains are observed. Written
    # explicitly rather than left out so a reader of the file can see that the
    # tier exists and is merely unpopulated, which is not the same as absent.
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
        # Leave the original in place, whatever went wrong.
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
    if version != SOURCE_VERSION:
        print(
            f"version {version!r} is not {SOURCE_VERSION}; refusing to guess",
            file=sys.stderr,
        )
        return 1

    before = os.path.getsize(args.path)
    counts = migrate(file)

    target = args.output or args.path
    if args.dry_run:
        print(
            f"would migrate {counts['entries']} entries and {counts['patterns']} "
            f"patterns, dropping {counts['liveries']} liveries; "
            f"{counts['units']} units keep their dimensions and gain no type"
        )
        return 0

    write_atomically(target, file)
    after = os.path.getsize(target)
    print(
        f"migrated {counts['entries']} entries and {counts['patterns']} patterns "
        f"to version {TARGET_VERSION}"
    )
    print(f"dropped {counts['liveries']} stored liveries")
    print(f"{before:,} -> {after:,} bytes ({100 * (before - after) // max(before, 1)}% smaller)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
