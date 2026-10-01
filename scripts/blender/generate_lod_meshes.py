"""Headless Blender generator for the medium- and high-detail LOD tiers.

The shipped meshes are deliberately low-poly (a few hundred triangles each) so
the APK stays small and every Android GPU can keep up. This script derives the
two richer tiers from those same meshes, so the gallery can show every object in
three levels of detail without any of the games growing:

    low     the shipped mesh, a few hundred triangles
    medium  ~1 000 triangles, smoothly shaded
    high   ~10 000 triangles, smoothly shaded plus real surface displacement

Usage:

    blender --background --python scripts/blender/generate_lod_meshes.py -- \
        --out godot/assets/meshes --stats godot/assets/meshes/lod.json

    # only some keys
    ... --out godot/assets/meshes --only rpg/dragon_lord,rpg/knight

Triangle counts are measured, not guessed: every mesh is refined until it lands
on the budget, and the real count of every tier is written to the stats file so
the gallery can display it and the test suite can verify it.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import bmesh
import bpy


#: Triangle budget per tier. The low tier is the shipped mesh and is never
#: rewritten here; these two are produced from it.
#:
#: The numbers are a *floor*, not a fixed count. The low tier is refined to its
#: own committed target by `refine_low_meshes.py` and some meshes reach a few
#: thousand triangles; a flat med target of 1000 would then be coarser than the
#: tier below it, which the gallery would show as a "simpler" middle step and
#: the `Mesh — Detailstufen` suite would reject. So each tier is at least its
#: floor and at least this many times the low tier, and the per-mesh count is
#: measured and written to the stats file either way.
TIER_TARGETS: dict[str, int] = {"med": 1000, "high": 10000}

#: Multiples of the low tier's own count, so the three tiers stay ordered and
#: roughly comparable in richness whatever the low mesh happens to cost.
#: Multiples of the low tier's own count, so the three tiers stay ordered and
#: roughly comparable in richness whatever the low mesh happens to cost.
#:
#: These factors are deliberately modest. Their only job is to lift a tier clear
#: of the one below it; the floors do the visual work for the cheap meshes. At
#: 3x/16x the med+high folders measured 83 MB against 45 MB before, nearly
#: doubling what the two gallery tiers cost in the APK to buy detail nobody
#: looks at twice. At 2x/10x the same ordering holds and the growth is about
#: half that, so that is what is used.
TIER_MIN_FACTOR: dict[str, float] = {"med": 2.0, "high": 10.0}


def _tier_target(tier: str, low: int) -> int:
    """The triangle target for `tier`, given the low tier's real count."""
    return max(TIER_TARGETS[tier], int(round(TIER_MIN_FACTOR[tier] * low)))

#: A full grid-fill pass roughly quadruples the count, so a pass is only taken
#: when the result stays below `target * OVERSHOOT`.
OVERSHOOT = 1.5

#: Displacement amplitude as a fraction of the bounding radius. The medium tier
#: stays perfectly smooth; only the high tier earns real surface relief.
DISPLACE = {"med": 0.0, "high": 0.022}

#: Calibration stride: refine a sixteenth of the faces to measure how many
#: triangles one refined face actually buys.
CALIBRATION_STRIDE = 16

MAX_PASSES = 8


def _reset_scene() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)


def _tri_count(obj: bpy.types.Object) -> int:
    obj.data.calc_loop_triangles()
    return len(obj.data.loop_triangles)


def _face_count(obj: bpy.types.Object) -> int:
    return len(obj.data.polygons)


def _subdivide(obj: bpy.types.Object, stride: int) -> int:
    """Grid-fill every `stride`-th face. Returns the number of faces touched.

    Refining a single face with `cuts=1` and a grid fill turns it into four, so
    splitting a *subset* is the cheap way to land close to a triangle budget
    instead of overshooting it fourfold.
    """
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
    """Refine `obj` until it has about `target` triangles; return the real count."""
    count = _tri_count(obj)
    passes = 0

    # Cheap phase: full passes while they stay inside the budget.
    while count * 4 <= target * OVERSHOOT and passes < MAX_PASSES:
        gained_before = count
        _subdivide(obj, 1)
        count = _tri_count(obj)
        passes += 1
        if count <= gained_before * 1.1:
            break  # nothing splittable left
        if count >= target:
            return count

    if count >= target or count <= 0 or passes >= MAX_PASSES:
        return count

    # Calibrate: how many triangles does one refined face actually add here?
    calibration_stride = max(1, CALIBRATION_STRIDE)
    before = count
    _subdivide(obj, calibration_stride)
    after = _tri_count(obj)
    if after <= before:
        return after

    faces_total = _face_count(obj)
    faces_touched = max(1, faces_total // calibration_stride)
    per_face = float(after - before) / float(faces_touched)
    if per_face <= 0.0:
        return after

    # How many more faces have to be split to close the remaining gap?
    needed = (target - after) / per_face
    stride = int(faces_total / max(1.0, needed))
    stride = max(1, stride)
    if stride == 1:
        return after  # a full pass would overshoot; keep the calibrated result

    count = _tri_count(obj)
    _subdivide(obj, stride)
    return _tri_count(obj)


def _apply_detail(obj: bpy.types.Object, strength: float) -> None:
    """Add surface relief so the high tier is not merely a smoother blob."""
    if strength <= 0.0 or not obj.data.vertices:
        return
    radius = max((vertex.co.length for vertex in obj.data.vertices), default=0.0)
    if radius <= 0.0:
        return
    texture = bpy.data.textures.new("LodNoise", type="CLOUDS")
    texture.noise_scale = max(0.05, radius * 0.9)
    texture.noise_depth = 3
    modifier = obj.modifiers.new("LodDetail", type="DISPLACE")
    modifier.texture = texture
    modifier.strength = radius * strength
    modifier.mid_level = 0.5
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    bpy.data.textures.remove(texture)


def _shade_smooth(obj: bpy.types.Object) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.shade_smooth()


def _join_objects() -> bpy.types.Object:
    """Merge every mesh in the scene into one object, as the builders do."""
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


def _iter_keys(root: str) -> list[str]:
    keys: list[str] = []
    for folder, _dirs, files in os.walk(root):
        # Only the low-poly tier is a source; the generated folders are outputs.
        rel_folder = os.path.relpath(folder, root)
        if rel_folder != "." and rel_folder.split(os.sep)[0] in TIER_TARGETS:
            continue
        for name in sorted(files):
            if not name.endswith(".glb"):
                continue
            rel = os.path.relpath(os.path.join(folder, name), root)
            keys.append(rel[: -len(".glb")].replace(os.sep, "/"))
    return sorted(keys)


def _load(source: str) -> bpy.types.Object:
    _reset_scene()
    bpy.ops.import_scene.gltf(filepath=source)
    return _join_objects()


def _export(obj: bpy.types.Object, out: str) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    # No UV layer: these meshes are flat-shaded with a single colour and never
    # carry a texture, and dropping the second attribute saves about 20 % of a
    # 10 000-triangle file. Draco would shrink it ninefold, but the Godot build
    # in use has no Draco module, so plain glTF it is.
    bpy.ops.export_scene.gltf(
        filepath=out,
        export_format="GLB",
        export_texcoords=False,
        export_normals=True,
    )


def _build_tier(source: str, out: str, tier: str, low: int) -> int:
    obj = _load(source)
    _refine_to(obj, _tier_target(tier, low))
    _apply_detail(obj, DISPLACE[tier])
    _shade_smooth(obj)
    _export(obj, out)
    return _tri_count(obj)


def _load_stats(path: str) -> dict:
    if path and os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as handle:
                return json.load(handle)
        except (OSError, ValueError):
            return {}
    return {}


def main() -> None:
    argv = sys.argv
    argv = argv[argv.index("--") + 1 :] if "--" in argv else []
    parser = argparse.ArgumentParser(description="Generate medium/high LOD tiers from the low-poly meshes.")
    parser.add_argument("--out", required=True, help="mesh root that holds the low-poly .glb files")
    parser.add_argument("--stats", default="", help="where to write the measured triangle counts")
    parser.add_argument("--only", default="", help="comma-separated keys, e.g. rpg/dragon_lord")
    args = parser.parse_args(argv)

    keys = _iter_keys(args.out)
    if args.only:
        wanted = {key.strip() for key in args.only.split(",") if key.strip()}
        keys = [key for key in keys if key in wanted]
    if not keys:
        print("[lod] nothing to do")
        return

    stats = _load_stats(args.stats)
    for key in keys:
        source = os.path.join(args.out, f"{key}.glb")
        if not os.path.exists(source):
            print(f"[lod] skip {key}: no low-poly source")
            continue
        entry = stats.setdefault(key, {})
        entry["low"] = _tri_count(_load(source))
        for tier in ("med", "high"):
            entry[tier] = _build_tier(source, os.path.join(args.out, tier, f"{key}.glb"), tier, entry["low"])
        print(
            f"[lod] {key}: low={entry['low']} med={entry['med']} high={entry['high']}",
            flush=True,
        )
        if args.stats:
            os.makedirs(os.path.dirname(os.path.abspath(args.stats)), exist_ok=True)
            with open(args.stats, "w", encoding="utf-8") as handle:
                json.dump(stats, handle, indent=2, sort_keys=True)
                handle.write("\n")

    print(f"[lod] {len(keys)} meshes written to {args.out}")


if __name__ == "__main__":
    main()
