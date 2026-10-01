"""Headless step that takes the shipped low tier to its triangle target.

The low tier is the geometry the games actually run, so its triangle count is a
product decision rather than an accident. This script owns that number: it reads
the base mesh a builder produced, refines it until it reaches the target stored
in ``godot/assets/meshes/low_target.json``, and writes the result back over the
same ``.glb``.

Why a data file and not a constant
----------------------------------

``LOW_MULTIPLIER`` alone would be a rounding error on any mesh whose base count
is not a multiple of three, and "roughly three times" is not a number a test can
assert on. So the target per mesh is committed data, and this script only ever
moves a mesh *towards* that target. Running it twice gives the same file, which
is the property that matters: a mesh is reproducible from its builder plus this
step, without anybody hand-editing a binary.

    blender --background --python scripts/blender/refine_low_meshes.py -- \
        --out godot/assets/meshes --targets godot/assets/meshes/low_target.json \
        --stats godot/assets/meshes/lod.json

    # a single mesh, while iterating on its builder
    ... --only candy/bonbon

    # write the targets for meshes that have none yet, from their current count
    ... --adopt

Adding a new mesh
-----------------

Build it as usual, then run this script with ``--adopt`` once. That records the
measured base count times ``LOW_MULTIPLIER`` as the mesh's target, so from then
on the target is explicit and re-running the pipeline is stable. Without that
step a new mesh simply keeps whatever the builder produced, which is a
legitimate but temporary state.

The med and high tiers are derived from whatever this script leaves behind, by
``generate_lod_meshes.py``.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import bmesh
import bpy


#: How much denser than the builder's base mesh the shipped low tier is. The
#: flat facets of the base mesh are the low-poly look; refining smooths the
#: silhouette without changing the shape, so the count can rise a long way
#: before the mesh stops reading as the same object.
LOW_MULTIPLIER = 3.0

#: Never go below this. A mesh whose base is 10 triangles gets 30, which is
#: already more than a phone needs for a pebble; the floor stops a degenerate
#: builder from producing a target the refine pass cannot hit.
MIN_TARGET = 24

#: How far above the target a full subdivision pass may land before it is
#: rejected in favour of a calibrated partial pass. A whole pass multiplies by
#: four, so allowing it whenever "4x still fits in the budget" lands a third of
#: the way over the target; the calibrated path below can hit much closer, so
#: the full pass is only worth taking when it barely overshoots.
OVERSHOOT = 1.15

#: How close a mesh has to land to its target for the refine pass to stop. The
#: step size is one subdivided face, so the count moves in quanta of a few
#: triangles; asking for an exact hit would spend passes chasing a rounding
#: difference that costs nothing.
TOLERANCE = 0.06

#: Rounds of measure-then-step before the pass gives up on hitting the target
#: exactly. Each round costs one extra subdivision over the ideal single step.
MAX_ROUNDS = 12

CALIBRATION_STRIDE = 16
MAX_PASSES = 8


def _reset_scene() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)


def _tri_count(obj: bpy.types.Object) -> int:
    obj.data.calc_loop_triangles()
    return len(obj.data.loop_triangles)


def _subdivide(obj: bpy.types.Object, stride: int) -> int:
    """Grid-fill every `stride`-th face; returns how many faces were touched."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    faces = list(bm.faces)
    chosen = faces[::stride] if stride > 1 else faces
    if not chosen:
        bm.free()
        return 0
    edges: set = set()
    for face in chosen:
        edges.update(face.edges)
    bmesh.ops.subdivide_edges(
        bm, edges=list(edges), cuts=1, use_grid_fill=True, smooth=0.0
    )
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()
    return len(chosen)


def _refine_to(obj: bpy.types.Object, target: int) -> int:
    """Refine `obj` towards `target` triangles; return the real count.

    Whole passes first, while one still lands near the target — a full pass
    multiplies the count by four, so it is only worth taking when that lands
    close. After that the mesh is walked there in measured steps: each round
    subdivides a *fraction* of the faces, sized from how many triangles one
    refined face actually bought on this mesh last time. A cone and a
    subdivided icosphere gain very different amounts per face, which is why the
    number is measured per mesh rather than assumed.

    The rounding loop matters: one measured step is itself only an estimate, so
    without re-measuring the result lands anywhere between badly short and
    several times over. `TOLERANCE` decides when to stop.
    """
    count = _tri_count(obj)
    if count >= target or count <= 0:
        return count

    passes = 0
    while count * 4 <= target * OVERSHOOT and passes < MAX_PASSES:
        before = count
        _subdivide(obj, 1)
        count = _tri_count(obj)
        passes += 1
        if count <= before * 1.1:
            break  # nothing left to split
        if count >= target:
            return count

    if count >= target or passes >= MAX_PASSES:
        return count

    per_face = 0.0
    for _round in range(MAX_ROUNDS):
        if count >= target:
            break
        if per_face <= 0.0:
            # Measure: split one slice of the faces and see what it cost.
            before = count
            touched = _subdivide(obj, CALIBRATION_STRIDE)
            after = _tri_count(obj)
            if after <= before or touched <= 0:
                break  # nothing left to split
            per_face = float(after - before) / float(touched)
            count = after
            if count >= target or abs(count - target) <= target * TOLERANCE:
                break
            continue

        needed = (target - count) / per_face
        remaining_faces = len(obj.data.polygons)
        if needed <= 0.0 or remaining_faces <= 0:
            break
        stride = max(1, int(remaining_faces / needed))
        if stride == 1:
            # A full pass would overshoot; measure another slice instead and let
            # the next round decide with a fresher number.
            per_face = 0.0
            continue
        before = count
        _subdivide(obj, stride)
        count = _tri_count(obj)
        if count <= before:
            break
        if abs(count - target) <= target * TOLERANCE:
            break

    return count


def _join_objects() -> bpy.types.Object:
    meshes = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    if not meshes:
        raise RuntimeError("no mesh in the imported scene")
    if len(meshes) > 1:
        bpy.ops.object.select_all(action="DESELECT")
        for obj in meshes:
            obj.select_set(True)
        bpy.context.view_layer.objects.active = meshes[0]
        bpy.ops.object.join()
    return bpy.context.view_layer.objects.active


def _load(path: str) -> bpy.types.Object:
    _reset_scene()
    bpy.ops.import_scene.gltf(filepath=path)
    return _join_objects()


def _iter_keys(root: str) -> list[str]:
    keys: list[str] = []
    for folder, _dirs, files in os.walk(root):
        rel_folder = os.path.relpath(folder, root)
        if rel_folder != "." and rel_folder.split(os.sep)[0] in ("med", "high"):
            continue
        for name in sorted(files):
            if name.endswith(".glb"):
                rel = os.path.relpath(os.path.join(folder, name), root)
                keys.append(rel[: -len(".glb")].replace(os.sep, "/"))
    return sorted(keys)


def _load_json(path: str) -> dict:
    if path and os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as handle:
                return json.load(handle)
        except (OSError, ValueError):
            return {}
    return {}


def _write_json(path: str, data: dict) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")


def _measure(root: str, key: str) -> int:
    return _tri_count(_load(os.path.join(root, f"{key}.glb")))


def main() -> None:
    argv = sys.argv
    argv = argv[argv.index("--") + 1 :] if "--" in argv else []
    parser = argparse.ArgumentParser(
        description="Refine the low tier of every mesh to its committed target."
    )
    parser.add_argument("--out", required=True, help="mesh root that holds the low-poly .glb files")
    parser.add_argument("--targets", required=True, help="JSON file with the per-mesh triangle targets")
    parser.add_argument("--stats", default="", help="lod.json to keep the low counts in sync")
    parser.add_argument("--only", default="", help="comma-separated keys, e.g. candy/bonbon")
    parser.add_argument(
        "--adopt",
        action="store_true",
        help="write a target for every mesh that has none, from its current count",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report what would change without writing any .glb",
    )
    args = parser.parse_args(argv)

    keys = _iter_keys(args.out)
    if args.only:
        wanted = {key.strip() for key in args.only.split(",") if key.strip()}
        keys = [key for key in keys if key in wanted]
    if not keys:
        print("[refine] nothing to do")
        return

    targets = _load_json(args.targets)
    stats = _load_json(args.stats)

    for key in keys:
        source = os.path.join(args.out, f"{key}.glb")
        if not os.path.exists(source):
            print(f"[refine] skip {key}: no low-poly source")
            continue

        if args.adopt and key not in targets:
            # Measure the builder's own output, then record the target. Run this
            # on a freshly built tree, before this script has touched anything.
            base = _measure(args.out, key)
            targets[key] = max(MIN_TARGET, int(round(base * LOW_MULTIPLIER)))
            _write_json(args.targets, targets)
            print(f"[refine] adopted {key}: base={base} target={targets[key]}")

        target = targets.get(key)
        if target is None:
            print(f"[refine] skip {key}: no target (run with --adopt once)")
            continue

        obj = _load(source)
        before = _tri_count(obj)
        if before >= target:
            print(f"[refine] {key}: {before} >= target {target}, unchanged")
            stats.setdefault(key, {})["low"] = before
            continue

        count = _refine_to(obj, target)
        if args.dry_run:
            print(f"[refine] {key}: would go {before} -> {count} (target {target})")
            continue

        if count > before:
            bpy.ops.export_scene.gltf(
                filepath=source,
                export_format="GLB",
                export_texcoords=False,
                export_normals=True,
            )
        stats.setdefault(key, {})["low"] = count
        flag = "" if count <= target * OVERSHOOT else "  (over target)"
        print(
            f"[refine] {key}: {before} -> {count} (target {target}, x{count / max(1, before):.2f}){flag}",
            flush=True,
        )

    if not args.dry_run:
        if args.stats:
            _write_json(args.stats, stats)
    print(f"[refine] {len(keys)} mesh(es) considered")


if __name__ == "__main__":
    main()