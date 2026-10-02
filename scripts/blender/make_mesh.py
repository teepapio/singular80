"""Headless Blender mesh generator for Singular 80.

Usage (Blender must be on PATH, see AGENTS.md):

    blender --background --python scripts/blender/make_mesh.py -- \
        --out public/assets/crystal.glb --name crystal

The script builds a low-poly mesh with a flat-shaded material and exports it as a
binary glTF (.glb), which can be loaded in the game with three.js GLTFLoader.

To create another asset, add a builder function and register it in ``BUILDERS``.
Keep meshes low-poly (a few hundred triangles) to protect the web build size.
"""

from __future__ import annotations

import argparse
import math
import os
import sys

import bpy
from mathutils import Matrix, Quaternion, Vector


_MATERIAL_CACHE: dict[tuple[object, ...], bpy.types.Material] = {}


def reset_scene() -> None:
    """Start from an empty scene (no default cube/camera/light)."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _MATERIAL_CACHE.clear()


def _apply_material(
    obj: bpy.types.Object,
    color: tuple[float, float, float, float],
    emission: float,
    roughness: float = 0.25,
    metallic: float = 0.1,
) -> None:
    # Reuse identical materials so joined meshes stay small (one primitive each).
    key: tuple[object, ...] = (
        tuple(round(channel, 4) for channel in color),
        round(emission, 4),
        round(roughness, 4),
        round(metallic, 4),
    )
    mat = _MATERIAL_CACHE.get(key)
    if mat is None:
        mat = bpy.data.materials.new(f"Material{len(_MATERIAL_CACHE)}")
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes.get("Principled BSDF")
        if bsdf is not None:
            bsdf.inputs["Base Color"].default_value = color
            # Blender 4.x renamed "Emission" to "Emission Color".
            for name in ("Emission Color", "Emission"):
                if name in bsdf.inputs:
                    bsdf.inputs[name].default_value = color
                    break
            if "Emission Strength" in bsdf.inputs:
                bsdf.inputs["Emission Strength"].default_value = emission
            if "Roughness" in bsdf.inputs:
                bsdf.inputs["Roughness"].default_value = roughness
            if "Metallic" in bsdf.inputs:
                bsdf.inputs["Metallic"].default_value = metallic
        _MATERIAL_CACHE[key] = mat
    obj.data.materials.append(mat)


def _primitive(
    name: str,
    color: tuple[float, float, float, float],
    emission: float,
    roughness: float = 0.35,
    metallic: float = 0.1,
) -> bpy.types.Object:
    """Give the current active object a name and material, then flat-shade it."""
    obj = bpy.context.active_object
    obj.name = name
    bpy.ops.object.shade_flat()
    _apply_material(obj, color, emission, roughness, metallic)
    return obj


def _cone(
    name: str,
    vertices: int,
    radius1: float,
    radius2: float,
    depth: float,
    location: tuple[float, float, float],
    color: tuple[float, float, float, float],
    emission: float,
    roughness: float = 0.35,
    metallic: float = 0.1,
    flip: bool = False,
) -> bpy.types.Object:
    """A flat-shaded faceted cone/cylinder, optionally flipped to point down."""
    rotation = (math.pi, 0.0, 0.0) if flip else (0.0, 0.0, 0.0)
    bpy.ops.mesh.primitive_cone_add(
        vertices=vertices,
        radius1=radius1,
        radius2=radius2,
        depth=depth,
        location=location,
        rotation=rotation,
    )
    return _primitive(name, color, emission, roughness, metallic)


def _torus(
    name: str,
    major: float,
    minor: float,
    location: tuple[float, float, float],
    color: tuple[float, float, float, float],
    emission: float,
    roughness: float = 0.3,
    metallic: float = 0.2,
    major_segments: int = 16,
    minor_segments: int = 8,
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_torus_add(
        major_radius=major,
        minor_radius=minor,
        major_segments=major_segments,
        minor_segments=minor_segments,
        location=location,
    )
    return _primitive(name, color, emission, roughness, metallic)


def _ico(
    name: str,
    scale: tuple[float, float, float],
    location: tuple[float, float, float],
    color: tuple[float, float, float, float],
    emission: float = 0.0,
    roughness: float = 0.6,
    metallic: float = 0.05,
    subdivisions: int = 1,
) -> bpy.types.Object:
    """A flat-shaded, scaled icosphere — the workhorse for organic props."""
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdivisions, radius=1.0, location=location)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return _primitive(name, color, emission, roughness, metallic)


def _box(
    name: str,
    size: tuple[float, float, float],
    location: tuple[float, float, float],
    color: tuple[float, float, float, float],
    emission: float,
    roughness: float = 0.6,
    metallic: float = 0.05,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    """A flat-shaded box with half-extents ``size`` (full dimensions = size)."""
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=location, rotation=rotation)
    obj = bpy.context.active_object
    obj.scale = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return _primitive(name, color, emission, roughness, metallic)


#: Every crystal in the game is built from this, so the set reads as one family.
#: Reference photographs of amethyst and quartz clusters (Wikimedia Commons,
#: "Quartz var Amethyst Specimen 22", "Quartz Crystal Cluster") agree on the
#: vocabulary: a **hexagonal** prism shaft, a **pyramidal termination** of six
#: triangles meeting at a point, and a flat or slightly tapered base. The point
#: is what makes a shape read as "crystal" at all — a 4- or 5-sided cone or a
#: scaled icosphere reads as a rock or a gem, never as a crystal.
CRYSTAL_FACETS = 6


def crystal_shaft(
    name: str,
    radius: float,
    shaft_height: float,
    tip_height: float,
    base_tip: float = 0.0,
    location: tuple[float, float, float] = (0.0, 0.0, 0.0),
    tilt: tuple[float, float, float] = (0.0, 0.0, 0.0),
    color: tuple[float, float, float, float] = (0.15, 0.8, 1.0, 1.0),
    emission: float = 1.5,
    roughness: float = 0.3,
    metallic: float = 0.2,
) -> bpy.types.Object:
    """One crystal: a hexagonal shaft, a pyramidal tip, optionally a tapered base.

    `base_tip` gives the underside an inverted pyramid of that height instead of
    a flat cut — real terminations are often doubly pointed, and a flat base
    next to a pointed top looks like a pencil.

    The parts are separate objects parented to the shaft, so the whole point
    can be moved and tilted as a unit. Returns the shaft.
    """
    body = _cone(
        f"{name}Shaft",
        CRYSTAL_FACETS,
        radius,
        radius,
        shaft_height,
        (0.0, 0.0, 0.0),
        color,
        emission,
        roughness,
        metallic,
    )
    parts = [body]
    if tip_height > 0.0:
        parts.append(
            _cone(
                f"{name}Tip",
                CRYSTAL_FACETS,
                radius,
                0.0,
                tip_height,
                (0.0, 0.0, shaft_height / 2.0 + tip_height / 2.0),
                color,
                emission,
                roughness,
                metallic,
            )
        )
    if base_tip > 0.0:
        parts.append(
            _cone(
                f"{name}Base",
                CRYSTAL_FACETS,
                radius,
                0.0,
                base_tip,
                (0.0, 0.0, -shaft_height / 2.0 - base_tip / 2.0),
                color,
                emission,
                roughness,
                metallic,
                flip=True,
            )
        )
    for part in parts[1:]:
        part.parent = body
        part.matrix_parent_inverse = body.matrix_world.inverted()

    body.matrix_world = (
        Matrix.Translation(location)
        @ Matrix.Rotation(tilt[2], 4, "Z")
        @ Matrix.Rotation(tilt[1], 4, "Y")
        @ Matrix.Rotation(tilt[0], 4, "X")
    )
    return body


def crystal_cluster(
    name: str,
    color: tuple[float, float, float, float],
    emission: float,
    roughness: float = 0.3,
    metallic: float = 0.2,
) -> bpy.types.Object:
    """Several shafts of different heights and tilts sharing one base.

    A single crystal is a lonely spear; the amethyst reference is a *cluster*,
    and a cluster is what gives the silhouette its irregular outline. The
    tallest shaft stands in the middle and the smaller ones lean out around it.
    """
    specs = (
        # (x, y, radius, shaft, tip, base_tip, tilt_x, tilt_y)
        (0.0, 0.0, 0.30, 1.55, 0.62, 0.34, 0.0, 0.0),
        (0.42, 0.18, 0.20, 1.00, 0.44, 0.22, 0.18, -0.26),
        (-0.38, 0.26, 0.17, 0.82, 0.38, 0.0, -0.22, 0.28),
        (0.16, -0.40, 0.19, 0.64, 0.32, 0.0, 0.30, 0.12),
    )
    base = None
    for i, (x, y, radius, shaft, tip, base_tip, tilt_x, tilt_y) in enumerate(specs):
        # Lift each shaft so its base still sits on z=0 after tilting.
        lift = shaft / 2.0 + base_tip
        point = crystal_shaft(
            f"{name}{i}",
            radius,
            shaft,
            tip,
            base_tip=base_tip,
            location=(x, y, lift),
            tilt=(tilt_x, tilt_y, 0.0),
            color=color,
            emission=emission,
            roughness=roughness,
            metallic=metallic,
        )
        if base is None:
            base = point
    if base is None:  # pragma: no cover - specs is a constant
        raise RuntimeError("crystal_cluster needs at least one shaft")
    return base


def build_crystal() -> bpy.types.Object:
    """A faceted, glowing crystal cluster used as a collectible."""
    color = (0.15, 0.8, 1.0, 1.0)
    cluster = crystal_cluster("Crystal", color, 2.0)
    return cluster


def build_ship() -> bpy.types.Object:
    """A simple low-poly player ship (tip pointing +Z)."""
    bpy.ops.mesh.primitive_cone_add(vertices=6, radius1=0.8, radius2=0.0, depth=1.8)
    obj = bpy.context.active_object
    obj.name = "Ship"
    bpy.ops.object.shade_flat()
    _apply_material(obj, (0.98, 0.75, 0.15, 1.0), emission=0.4)
    return obj


def build_ornament() -> bpy.types.Object:
    """A round Christmas bauble with a small cap (legacy shared bauble)."""
    bpy.ops.mesh.primitive_uv_sphere_add(segments=18, ring_count=12, radius=1.0)
    ball = bpy.context.active_object
    ball.name = "Ornament"
    ball.scale = (1.0, 1.0, 1.12)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bpy.ops.object.shade_smooth()
    _apply_material(ball, (0.85, 0.12, 0.12, 1.0), emission=0.5)

    bpy.ops.mesh.primitive_cylinder_add(vertices=12, radius=0.26, depth=0.3, location=(0.0, 0.0, 1.05))
    cap = bpy.context.active_object
    cap.name = "OrnamentCap"
    bpy.ops.object.shade_flat()
    _apply_material(cap, (0.85, 0.68, 0.2, 1.0), emission=0.25)
    return ball


def build_pumpkin() -> bpy.types.Object:
    """A squat low-poly pumpkin with a small stem (legacy shared pumpkin)."""
    bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=10, radius=1.0)
    body = bpy.context.active_object
    body.name = "Pumpkin"
    body.scale = (1.15, 1.15, 0.82)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bpy.ops.object.shade_flat()
    _apply_material(body, (0.95, 0.42, 0.08, 1.0), emission=0.65)

    bpy.ops.mesh.primitive_cylinder_add(vertices=8, radius=0.16, depth=0.5, location=(0.0, 0.0, 0.86))
    stem = bpy.context.active_object
    stem.name = "PumpkinStem"
    bpy.ops.object.shade_flat()
    _apply_material(stem, (0.28, 0.42, 0.12, 1.0), emission=0.1)
    return body


# --- Merge 3D themed tiers (Christmas + Halloween) --------------------------
#
# Every merge tier gets its own recognizable mesh instead of one recolored
# bauble/pumpkin, so a merge visibly turns into the next named item. The meshes
# use roughly twice the polygons of the old ornament/pumpkin and are tinted by
# the game to match the tier name.

def _tube(
    name: str,
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    radius: float,
    color: tuple[float, float, float, float],
    emission: float = 0.3,
    roughness: float = 0.45,
    metallic: float = 0.1,
    vertices: int = 8,
) -> bpy.types.Object:
    """A faceted cylinder spanning two points (used for the candy-cane hook)."""
    a = Vector(start)
    b = Vector(end)
    direction = b - a
    midpoint = (a + b) / 2.0
    obj = _cone(name, vertices, radius, radius, max(direction.length, 1e-4), (0.0, 0.0, 0.0), color, emission, roughness, metallic)
    obj.matrix_world = Matrix.Translation(midpoint) @ direction.to_track_quat("Z", "Y").to_matrix().to_4x4()
    return obj


def _bevel(obj: bpy.types.Object, width: float = 0.045, segments: int = 1) -> bpy.types.Object:
    """Round the edges of a mesh with an applied bevel modifier."""
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    modifier = obj.modifiers.new("Bevel", "BEVEL")
    modifier.width = width
    modifier.segments = segments
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    return obj


def _join_all(name: str) -> bpy.types.Object:
    """Merge all mesh objects of the scene into one multi-material mesh."""
    bpy.ops.object.select_all(action="DESELECT")
    meshes = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    for obj in meshes:
        obj.select_set(True)
    active = meshes[0]
    bpy.context.view_layer.objects.active = active
    if len(meshes) > 1:
        bpy.ops.object.join()
    active.name = name
    active.data.name = f"{name}Mesh"
    return active


def _star_prism(
    name: str,
    points: int,
    outer: float,
    inner: float,
    depth: float,
    color: tuple[float, float, float, float],
    emission: float,
    roughness: float = 0.55,
    metallic: float = 0.05,
    upright: bool = False,
) -> bpy.types.Object:
    """A flat n-pointed star prism; ``upright`` stands it on edge facing -Y."""
    half = depth / 2.0
    count = points * 2
    vertices: list[tuple[float, float, float]] = []
    for i in range(count):
        angle = math.pi / 2.0 + i * math.pi / points
        radius = outer if i % 2 == 0 else inner
        x = math.cos(angle) * radius
        y = math.sin(angle) * radius
        if upright:
            vertices.append((x, -half, y))
            vertices.append((x, half, y))
        else:
            vertices.append((x, y, half))
            vertices.append((x, y, -half))
    center_front = len(vertices)
    center_back = center_front + 1
    if upright:
        vertices.append((0.0, -half, 0.0))
        vertices.append((0.0, half, 0.0))
    else:
        vertices.append((0.0, 0.0, half))
        vertices.append((0.0, 0.0, -half))
    faces: list[list[int]] = []
    for i in range(count):
        j = (i + 1) % count
        faces.append([center_front, i * 2, j * 2])
        faces.append([center_back, j * 2 + 1, i * 2 + 1])
        faces.append([i * 2, j * 2, j * 2 + 1, i * 2 + 1])
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    mesh.validate()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    # Normalise winding (the concave star caps would otherwise be inverted).
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.shade_flat()
    _apply_material(obj, color, emission, roughness, metallic)
    return obj


#: Thickness of the plate that closes each gable end of a `gable_roof`.
GABLE_END_THICKNESS = 0.06

#: How far that plate is pulled into the roof's own cross-section. Its sloped
#: edges would otherwise lie exactly on the underside of the two slabs, and two
#: coincident faces show up as a hairline seam in the render.
GABLE_INSIDE = 0.99


def _triangle_prism(
    name: str,
    triangle: list[tuple[float, float]],
    thickness: float,
    location: tuple[float, float, float],
    color: tuple[float, float, float, float],
    emission: float,
    roughness: float = 0.6,
    metallic: float = 0.05,
) -> bpy.types.Object:
    """A prism with `triangle` (X, Z pairs) as its cross-section, extruded in Y.

    Built with ``from_pydata`` like `_star_prism`, because a gable end is a
    triangle and no Blender primitive is one.
    """
    half = thickness * 0.5
    ox, oy, oz = location
    vertices: list[tuple[float, float, float]] = [
        (x + ox, oy - half, z + oz) for x, z in triangle
    ]
    vertices += [(x + ox, oy + half, z + oz) for x, z in triangle]
    faces: list[list[int]] = [
        [0, 1, 2],  # near cap (-Y)
        [5, 4, 3],  # far cap (+Y)
        [0, 3, 4, 1],
        [1, 4, 5, 2],
        [2, 5, 3, 0],
    ]
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    mesh.validate()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.shade_flat()
    _apply_material(obj, color, emission, roughness, metallic)
    return obj


def gable_roof(
    name: str,
    width: float,
    depth: float,
    rise: float,
    location: tuple[float, float, float],
    color: tuple[float, float, float, float],
    emission: float = 0.0,
    roughness: float = 0.7,
    metallic: float = 0.05,
    eave: float = 0.08,
    slab: float = 0.07,
    ends: bool = True,
) -> list[bpy.types.Object]:
    """A two-slope roof whose ridge runs along Y, closed at both gable ends.

    `location` is the middle of the eave line — the top of the wall it stands on
    — and `rise` the height of the ridge above it, so the roof sits flush on the
    wall. `width` is the full span across the slopes, which is what sets the
    eave overhang: a builder passes a little more than the wall is wide.

    Do not reach for a four-sided cone instead. Blender puts the base vertices
    of `primitive_cone_add` on the axes, so `vertices=4` is already a diamond
    with half-diagonal `radius1`, and its corners point along X and Y instead of
    matching a rectangular wall — on a 1.1 x 1.0 wall, `radius1=0.86` left all
    four wall corners (|x|+|y| = 1.05) outside the roof faces.
    """
    half = width * 0.5
    slope = math.atan2(rise, half)
    slab_len = math.hypot(half, rise)
    parts = [
        _box(
            name,
            (width, depth, eave),
            (location[0], location[1], location[2] + eave * 0.5),
            color,
            emission,
            roughness,
            metallic,
        ),
        # A +Y rotation lifts the **-X** end (measured in Blender 4.5, not
        # assumed), so the -X slab takes -slope to put its high end at the
        # middle. `generate_siedler_meshes` used to build its own copy of this
        # roof with the two signs the other way round: measured 2026-10-02 on
        # its KeepRoof, its left slab ran from z=2.809 down to z=2.271 towards
        # the middle, so the two slabs met in a valley instead of a ridge and
        # the castle wore an inverted butterfly. It now calls this function,
        # which is why the signs are pinned down in a comment rather than left
        # to the next reader.
        _box(
            f"{name}SlabL",
            (slab_len, depth, slab),
            (location[0] - half * 0.5, location[1], location[2] + rise * 0.5),
            color,
            emission,
            roughness,
            metallic,
            (0.0, -slope, 0.0),
        ),
        _box(
            f"{name}SlabR",
            (slab_len, depth, slab),
            (location[0] + half * 0.5, location[1], location[2] + rise * 0.5),
            color,
            emission,
            roughness,
            metallic,
            (0.0, slope, 0.0),
        ),
    ]
    if not ends:
        return parts

    # The closing plate follows the underside of the slabs: the slab centre line
    # runs from the eave to the ridge, and its underside sits `drop` lower, with
    # `drop` the half thickness measured vertically. Clip that line where it
    # meets the wall top, so the plate is buried in the eave board at its base
    # and under the slabs along its sloped edges.
    drop = (slab * 0.5) / math.cos(slope)
    base_half = max(0.0, half * (1.0 - drop / max(rise, 1e-6)))
    triangle = [(-base_half, 0.0), (base_half, 0.0), (0.0, rise - drop)]
    cx = sum(point[0] for point in triangle) / 3.0
    cz = sum(point[1] for point in triangle) / 3.0
    triangle = [
        (cx + (x - cx) * GABLE_INSIDE, cz + (z - cz) * GABLE_INSIDE) for x, z in triangle
    ]
    thickness = min(GABLE_END_THICKNESS, depth * 0.5)
    for end, tag in ((-1.0, "A"), (1.0, "B")):
        parts.append(
            _triangle_prism(
                f"{name}End{tag}",
                triangle,
                thickness,
                (location[0], location[1] + end * (depth * 0.5 - thickness * 0.5), location[2]),
                color,
                emission,
                roughness,
                metallic,
            )
        )
    return parts


def _jack_o_lantern_face(name: str, size: float) -> None:
    """Triangular eyes and a jagged mouth on the front (-Y) of a pumpkin."""
    dark = (0.11, 0.07, 0.03, 1.0)
    front = -size * 0.74
    for side in (-1.0, 1.0):
        eye = _cone(
            f"{name}Eye{'L' if side < 0 else 'R'}",
            3,
            0.17 * size,
            0.0,
            0.12 * size,
            (side * 0.3 * size, front, 0.2 * size),
            dark,
            0.0,
            0.9,
            0.0,
        )
        eye.rotation_euler = (math.pi / 2.0, 0.0, math.pi / 6.0 * side)
    for i, offset in enumerate((-0.3, 0.0, 0.3)):
        _box(f"{name}Mouth{i}", (0.14 * size, 0.12 * size, 0.2 * size), (offset * size, front, -0.24 * size), dark, 0.0, 0.9, 0.0)


def _pumpkin(
    name: str,
    size: float,
    ribs: int,
    body_color: tuple[float, float, float, float],
    rib_color: tuple[float, float, float, float],
    stem_color: tuple[float, float, float, float],
    emission: float = 0.6,
    face: bool = False,
    detail: int = 2,
) -> bpy.types.Object:
    """A ribbed low-poly pumpkin built from a core plus vertical lobes."""
    body = _ico(name, (size * 0.82, size * 0.82, size * 0.72), (0.0, 0.0, 0.0), body_color, emission, 0.6, 0.05, subdivisions=detail)
    for i in range(ribs):
        angle = i * 2.0 * math.pi / ribs
        rib = _ico(
            f"{name}Rib{i}",
            (size * 0.5, size * 0.24, size * 0.76),
            (math.cos(angle) * size * 0.48, math.sin(angle) * size * 0.48, 0.0),
            rib_color,
            emission * 0.85,
            0.6,
            0.05,
            subdivisions=detail,
        )
        rib.rotation_euler = (0.0, 0.0, angle)
    _cone(f"{name}Stem", 8, 0.12 * size, 0.09 * size, 0.4 * size, (0.0, 0.0, size * 0.7 + 0.1 * size), stem_color, 0.1, 0.85, 0.0)
    if face:
        _jack_o_lantern_face(name, size)
    return body


def build_xmas_pinecone() -> bpy.types.Object:
    """Tier 1 — a fir cone (rounded brown core covered in scales)."""
    core = _ico("PineconeCore", (0.5, 0.5, 0.95), (0.0, 0.0, 0.0), (0.42, 0.25, 0.09, 1.0), 0.1, 0.9, 0.0, subdivisions=3)
    scale_color = (0.5, 0.3, 0.12, 1.0)
    rings = 6
    per_ring = 8
    for ring_index in range(rings):
        t = ring_index / (rings - 1)
        z = -0.62 + t * 1.36
        ring_radius = 0.16 + 0.34 * math.sin(math.pi * (0.12 + 0.76 * t))
        for scale_index in range(per_ring):
            angle = scale_index * 2.0 * math.pi / per_ring + ring_index * 0.45
            position = (math.cos(angle) * ring_radius, math.sin(angle) * ring_radius, z)
            scale = _cone(
                f"PineconeScale{ring_index}_{scale_index}",
                4,
                0.17,
                0.0,
                0.28,
                (0.0, 0.0, 0.0),
                scale_color,
                0.1,
                0.85,
                0.0,
            )
            scale.matrix_world = (
                Matrix.Translation(position)
                @ Matrix.Rotation(angle, 4, "Z")
                @ Matrix.Rotation(math.pi * 0.63, 4, "Y")
            )
    return _join_all("Pinecone")


def build_xmas_candy_cane() -> bpy.types.Object:
    """Tier 2 — a peppermint candy cane: straight shaft plus a rounded hook."""
    red = (0.86, 0.12, 0.14, 1.0)
    white = (0.96, 0.96, 0.97, 1.0)
    shaft = _cone("CandyShaft", 10, 0.155, 0.155, 1.45, (-0.5, 0.0, -0.225), red, 0.45, 0.3, 0.15)
    previous: tuple[float, float, float] | None = None
    steps = 9
    for i in range(steps + 1):
        theta = math.pi * (1.0 - i / steps)
        point = (math.cos(theta) * 0.5, 0.0, 0.5 + math.sin(theta) * 0.5)
        if previous is not None:
            _tube("CandyHook", previous, point, 0.155, red, 0.45, 0.3, 0.15, 8)
        previous = point
    # Thin ridges hint at the classic white peppermint stripes.
    for index, z in enumerate((-0.72, -0.2, 0.28)):
        _torus(f"CandyStripe{index}", 0.165, 0.035, (-0.5, 0.0, z), white, 0.35, 0.35, 0.1, 10, 6)
    return _join_all("CandyCane")


def build_xmas_bauble() -> bpy.types.Object:
    """Tier 3 — a shiny glass bauble with a cap and hanging loop."""
    bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=16, radius=1.0)
    ball = bpy.context.active_object
    ball.name = "Bauble"
    ball.scale = (0.92, 0.92, 1.0)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bpy.ops.object.shade_smooth()
    _apply_material(ball, (0.45, 0.8, 0.96, 1.0), 0.6, 0.12, 0.3)
    _cone("BaubleCap", 12, 0.24, 0.24, 0.3, (0.0, 0.0, 1.0), (0.92, 0.78, 0.32, 1.0), 0.25, 0.4, 0.7)
    _torus("BaubleLoop", 0.1, 0.03, (0.0, 0.0, 1.22), (0.92, 0.78, 0.32, 1.0), 0.25, 0.35, 0.7, 10, 6)
    return _join_all("Bauble")


def build_xmas_gingerbread_star() -> bpy.types.Object:
    """Tier 4 — a gingerbread star cookie with beveled edges, icing and dots."""
    star = _star_prism("GingerbreadStar", 5, 0.98, 0.42, 0.3, (0.72, 0.45, 0.16, 1.0), 0.3, 0.7, 0.02)
    _bevel(star, 0.06, 2)
    icing = _star_prism("GingerbreadIcing", 5, 0.58, 0.24, 0.1, (0.98, 0.95, 0.9, 1.0), 0.2, 0.6, 0.05)
    icing.location = (0.0, 0.0, 0.15)
    _ico("GingerbreadCenter", (0.2, 0.2, 0.08), (0.0, 0.0, 0.2), (0.98, 0.95, 0.9, 1.0), 0.2, 0.6, 0.05, subdivisions=2)
    for i in range(5):
        angle = math.pi / 2.0 + i * 2.0 * math.pi / 5.0
        _ico(
            f"GingerbreadDot{i}",
            (0.1, 0.1, 0.05),
            (math.cos(angle) * 0.72, math.sin(angle) * 0.72, 0.18),
            (0.98, 0.95, 0.9, 1.0),
            0.2,
            0.6,
            0.05,
            subdivisions=1,
        )
    return _join_all("GingerbreadStar")


def build_xmas_star() -> bpy.types.Object:
    """Tier 5 — an upright radiant Christmas star with halo and back star."""
    star = _star_prism("ChristmasStar", 5, 0.95, 0.36, 0.24, (0.98, 0.82, 0.3, 1.0), 1.1, 0.35, 0.4, upright=True)
    _bevel(star, 0.05, 1)
    back = _star_prism("ChristmasStarBack", 5, 0.8, 0.3, 0.18, (1.0, 0.72, 0.2, 1.0), 0.9, 0.35, 0.4, upright=True)
    back.rotation_euler = (0.0, math.pi / 5.0, 0.0)
    halo = _torus("ChristmasStarHalo", 0.98, 0.05, (0.0, 0.0, 0.0), (1.0, 0.92, 0.55, 1.0), 1.0, 0.3, 0.4, 20, 8)
    halo.rotation_euler = (math.pi / 2.0, 0.0, 0.0)
    _ico("ChristmasStarCore", (0.32, 0.16, 0.32), (0.0, 0.0, 0.0), (1.0, 0.9, 0.5, 1.0), 1.4, 0.3, 0.4, subdivisions=2)
    return _join_all("ChristmasStar")


def build_halloween_seed() -> bpy.types.Object:
    """Tier 1 — a pale pumpkin seed."""
    seed = _ico("PumpkinSeed", (0.34, 0.22, 0.6), (0.0, 0.0, 0.0), (0.95, 0.9, 0.72, 1.0), 0.3, 0.6, 0.02, subdivisions=3)
    _cone("PumpkinSeedTip", 6, 0.08, 0.0, 0.2, (0.0, 0.0, 0.66), (0.82, 0.74, 0.5, 1.0), 0.2, 0.7, 0.0)
    return _join_all("PumpkinSeed")


def build_halloween_candy() -> bpy.types.Object:
    """Tier 2 — a wrapped sweet with pointed twisted ends."""
    body = _ico("CandyBody", (0.52, 0.42, 0.42), (0.0, 0.0, 0.0), (0.9, 0.35, 0.62, 1.0), 0.55, 0.4, 0.1, subdivisions=3)
    for side in (-1.0, 1.0):
        wrapper = _cone(
            f"CandyWrapper{'R' if side > 0 else 'L'}",
            8,
            0.36,
            0.0,
            0.6,
            (side * 0.72, 0.0, 0.0),
            (0.95, 0.55, 0.75, 1.0),
            0.5,
            0.4,
            0.1,
        )
        wrapper.rotation_euler = (0.0, side * math.pi / 2.0, 0.0)
        _ico(f"CandyKnot{'R' if side > 0 else 'L'}", (0.09, 0.09, 0.09), (side * 1.0, 0.0, 0.0), (0.98, 0.75, 0.88, 1.0), 0.4, 0.5, 0.05, subdivisions=1)
    return _join_all("Candy")


def build_halloween_mini_pumpkin() -> bpy.types.Object:
    """Tier 3 — a small plain pumpkin."""
    _pumpkin(
        "MiniPumpkin",
        0.72,
        6,
        (0.95, 0.5, 0.1, 1.0),
        (0.85, 0.38, 0.05, 1.0),
        (0.32, 0.44, 0.14, 1.0),
        0.5,
        detail=2,
    )
    return _join_all("MiniPumpkin")


def build_halloween_pumpkin() -> bpy.types.Object:
    """Tier 4 — a carved jack-o'-lantern."""
    _pumpkin(
        "Pumpkin",
        1.0,
        8,
        (0.96, 0.48, 0.08, 1.0),
        (0.85, 0.35, 0.04, 1.0),
        (0.3, 0.42, 0.12, 1.0),
        0.65,
        face=True,
        detail=2,
    )
    return _join_all("Pumpkin")


def build_halloween_ghost_pumpkin() -> bpy.types.Object:
    """Tier 5 — a pale ghost pumpkin with a hovering spirit and halo."""
    _pumpkin(
        "GhostPumpkin",
        0.9,
        8,
        (0.72, 0.86, 0.78, 1.0),
        (0.58, 0.76, 0.7, 1.0),
        (0.45, 0.6, 0.5, 1.0),
        0.9,
        detail=2,
    )
    halo = _torus("GhostPumpkinHalo", 0.88, 0.045, (0.0, 0.0, 0.05), (0.78, 1.0, 0.88, 1.0), 1.6, 0.3, 0.2, 20, 6)
    halo.rotation_euler = (math.pi / 2.0, 0.0, 0.0)
    _ico("GhostSpirit", (0.3, 0.3, 0.36), (0.0, 0.0, 1.05), (0.9, 1.0, 0.94, 1.0), 1.4, 0.5, 0.0, subdivisions=2)
    for i in range(3):
        offset = (i - 1) * 0.34
        _cone(f"GhostWisp{i}", 4, 0.09, 0.0, 0.26, (offset * 0.35, 0.0, 0.72), (0.85, 1.0, 0.92, 1.0), 1.2, 0.5, 0.0)
    return _join_all("GhostPumpkin")


def build_crystal_shard() -> bpy.types.Object:
    """Tier 1 — a raw, pale splinter: two small shafts, barely grown.

    The lowest tier has to stay visibly *less* than the tiers above it, so this
    is one thin shaft with a short tip and a single small companion rather than
    a full cluster.
    """
    color = (0.6, 0.78, 1.0, 1.0)
    main = crystal_shaft(
        "CrystalShard",
        radius=0.26,
        shaft_height=1.0,
        tip_height=0.44,
        base_tip=0.2,
        location=(0.0, 0.0, 0.7),
        color=color,
        emission=1.0,
        roughness=0.5,
        metallic=0.05,
    )
    crystal_shaft(
        "CrystalShardSmall",
        radius=0.15,
        shaft_height=0.5,
        tip_height=0.26,
        location=(0.3, -0.14, 0.38),
        tilt=(0.14, -0.3, 0.0),
        color=color,
        emission=1.0,
        roughness=0.5,
        metallic=0.05,
    )
    return main


def build_crystal_gem() -> bpy.types.Object:
    """Tier 2 — a single well-formed crystal, taller than tier 1's splinter."""
    return crystal_shaft(
        "CrystalGem",
        radius=0.34,
        shaft_height=1.15,
        tip_height=0.58,
        base_tip=0.3,
        location=(0.0, 0.0, 0.88),
        color=(0.13, 0.83, 0.93, 1.0),
        emission=1.3,
        roughness=0.42,
        metallic=0.1,
    )


def build_crystal_jewel() -> bpy.types.Object:
    """Tier 3 — a crystal with a smaller companion and a girdle ring."""
    color = (0.2, 0.9, 0.55, 1.0)
    main = crystal_shaft(
        "Jewel",
        radius=0.30,
        shaft_height=0.95,
        tip_height=0.62,
        base_tip=0.26,
        location=(0.0, 0.0, 0.74),
        color=color,
        emission=1.6,
        roughness=0.35,
        metallic=0.15,
    )
    crystal_shaft(
        "JewelSmall",
        radius=0.17,
        shaft_height=0.6,
        tip_height=0.36,
        location=(0.34, 0.12, 0.48),
        tilt=(0.1, -0.34, 0.0),
        color=color,
        emission=1.6,
        roughness=0.35,
        metallic=0.15,
    )
    _torus("JewelGirdle", 0.5, 0.055, (0.0, 0.0, 0.72), (0.85, 1.0, 0.9, 1.0), 1.2, 0.3, 0.3)
    return main


def build_crystal_prism() -> bpy.types.Object:
    """Tier 4 — a tall hexagonal prism crowned with pyramidal tips (doubly pointed)."""
    color = (0.98, 0.75, 0.15, 1.0)
    main = crystal_shaft(
        "Prism",
        radius=0.46,
        shaft_height=1.35,
        tip_height=0.6,
        base_tip=0.6,
        color=color,
        emission=1.8,
        roughness=0.3,
        metallic=0.25,
    )
    _torus("PrismHalo", 0.78, 0.07, (0.0, 0.0, 0.05), (1.0, 0.92, 0.6, 1.0), 1.4, 0.25, 0.35)
    return main


def build_crystal_star() -> bpy.types.Object:
    """Tier 5 — a radiant star core with radiating spikes and a halo.

    The spikes are hexagonal crystal points now rather than 4-sided cones, so
    the top tier still belongs to the same family as the tiers below it.
    """
    color = (0.96, 0.45, 0.72, 1.0)
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=0.5)
    core = bpy.context.active_object
    core.name = "StarCore"
    _primitive(core.name, color, 2.4, 0.22, 0.4)

    # Six short hexagonal points radiating in the XZ plane, plus one up and one
    # down, each standing off the core rather than floating beside it.
    for i in range(6):
        angle = i * math.pi / 3.0
        spike = _cone(
            f"StarSpike{i}",
            CRYSTAL_FACETS,
            0.2,
            0.0,
            0.85,
            (math.cos(angle) * 0.45, 0.0, math.sin(angle) * 0.45),
            color,
            2.0,
            0.25,
            0.35,
        )
        # Point the spike away from the core (cone default axis is +Z).
        spike.rotation_euler = (0.0, math.pi / 2.0 - angle, 0.0)
    _cone("StarSpikeUp", CRYSTAL_FACETS, 0.2, 0.0, 0.9, (0.0, 0.55, 0.0), color, 2.0, 0.25, 0.35)
    _cone("StarSpikeDown", CRYSTAL_FACETS, 0.2, 0.0, 0.9, (0.0, -0.55, 0.0), color, 2.0, 0.25, 0.35, flip=True)
    _torus("StarHalo", 0.95, 0.06, (0.0, 0.0, 0.0), (1.0, 0.85, 0.95, 1.0), 1.6, 0.2, 0.4)
    return core


HORSE_COAT = (0.55, 0.33, 0.16, 1.0)
HORSE_DARK = (0.20, 0.11, 0.05, 1.0)
HORSE_MUZZLE = (0.78, 0.62, 0.50, 1.0)
HOOF_COLOR = (0.13, 0.11, 0.10, 1.0)

#: Near-black and glossy. A horse's eye is a wet dark bead, and the reference
#: photograph shows it catching the light — a matte brown one disappears into
#: the coat at gallery distance, which is where this mesh is actually seen.
EYE_COLOR = (0.05, 0.04, 0.04, 1.0)


def _horse_segment(
    name: str,
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    r0: float,
    r1: float,
    color: tuple[float, float, float, float],
    sides: int = 6,
    flatten: float = 1.0,
    pivot_at_start: bool = False,
    roll: float = 0.0,
) -> bpy.types.Object:
    """A tapered limb segment running from ``start`` to ``end``.

    The cone primitive stands on +Z, so the segment is rotated onto the
    direction it actually runs: a straight prism for a cannon bone, a steeply
    pitched one for a neck. ``flatten`` squashes the cross-section along the
    mesh's own X *before* that rotation, which is only safe because a rotation
    about X leaves X alone — it is how a neck gets to be deeper than it is wide
    without becoming a cylinder.

    ``pivot_at_start`` puts the object's origin on the shoulder or hip instead
    of halfway down the bone, so the screen can swing the whole leg around the
    joint a real leg turns on.

    ``roll`` spins the cross-section about the segment's own axis. It is what
    turns an eight-sided prism from a roof ridge into a barrel: half a step of
    roll moves the single top vertex aside and leaves one flat facet facing up.
    """
    a = Vector(start)
    b = Vector(end)
    delta = b - a
    length = delta.length
    if length <= 1e-6:
        raise ValueError(f"{name}: segment start and end are the same point")
    obj = _cone(name, sides, r0, r1, length, (0.0, 0.0, 0.0), color, 0.0, 0.7, 0.0)
    if flatten != 1.0:
        obj.data.transform(Matrix.Diagonal((flatten, 1.0, 1.0, 1.0)))
    if pivot_at_start:
        # The cone's data is centred on its own origin, spanning -length/2 to
        # +length/2. Shifting it by *half* the length puts the whole segment in
        # front of the origin, so the origin ends up on `start`. Shifting the
        # other way would mirror the segment across `start` and send it off the
        # other side of the shoulder it is supposed to hang from.
        obj.data.transform(Matrix.Translation((0.0, 0.0, length / 2.0)))
        obj.location = a
    else:
        obj.location = (a + b) * 0.5
    rotation = Vector((0.0, 0.0, 1.0)).rotation_difference(delta)
    if roll:
        rotation = rotation @ Quaternion((0.0, 0.0, 1.0), roll)
    obj.rotation_euler = rotation.to_euler()
    return obj


def _horse_joint(
    name: str,
    x: float,
    y: float,
    z: float,
    radius: float,
    color: tuple[float, float, float, float],
) -> bpy.types.Object:
    """The knob at a joint — carpus, hock, fetlock.

    A leg bone meeting at an angle with nothing at the corner reads as two
    cylinders that happen to touch. These are what make the bend visible.
    """
    return _ico(name, (radius, radius, radius), (x, y, z), color, 0.0, 0.65, 0.0, 1)


def _horse_leg(
    name: str,
    x: float,
    joints: tuple[tuple[float, float, float], ...],
    hoof: tuple[float, float],
) -> bpy.types.Object:
    """One leg, built from a chain of ``(y, z, radius)`` joints.

    The chain is walked once: a tapered segment between every pair of joints, a
    knob at each interior one, and a hoof at the end. The first segment keeps
    the name ``name`` and its origin on the shoulder or hip — the screen looks
    the legs up by exactly that name and swings them about that point.

    ``hoof`` is the ``(y, z)`` of the hoof's bottom face; the pastern angle is
    taken from where the chain ends, so the hoof always points the way that
    leg's fetlock does.
    """
    points = [(x, y, z) for (y, z, _radius) in joints]
    radii = [radius for (_y, _z, radius) in joints]

    leg = _horse_segment(
        name, points[0], points[1], radii[0], radii[1], HORSE_COAT, pivot_at_start=True
    )
    parts = [leg]
    for i in range(1, len(points) - 1):
        parts.append(_horse_joint(f"{name}Joint{i}", x, points[i][1], points[i][2], radii[i] * 1.35, HORSE_COAT))
        parts.append(
            _horse_segment(f"{name}Seg{i}", points[i], points[i + 1], radii[i], radii[i + 1], HORSE_COAT)
        )
    # The hoof is wider at the ground than at the coronet, which is the one
    # detail that stops the bottom of a leg reading as a cut-off cylinder.
    pastern_top = points[-1]
    parts.append(
        _horse_segment(
            f"{name}Hoof",
            pastern_top,
            (x, hoof[0], hoof[1]),
            radii[-1] * 1.02,
            radii[-1] * 1.72,
            HOOF_COLOR,
        )
    )

    bpy.context.view_layer.update()
    for part in parts[1:]:
        part.parent = leg
        part.matrix_parent_inverse = leg.matrix_world.inverted()
    return leg


#: Shoulder, elbow, carpus (the knee a horse actually has), fetlock and the top
#: of the pastern. The foreleg hangs plumb — every one of these shares almost
#: the same ``y``, and only the pastern steps forward at the end.
HORSE_FORE_LEG = (
    (0.55, 1.40, 0.145),
    (0.52, 1.02, 0.105),
    (0.50, 0.72, 0.088),
    (0.50, 0.25, 0.062),
    (0.545, 0.115, 0.054),
)

#: Hip, hock, fetlock, pastern. The thigh goes down and **back** to the hock at
#: ``y = -0.84`` and the cannon below it comes forward again to ``y = -0.755``:
#: that reversal is the hind leg.
HORSE_HIND_LEG = (
    (-0.58, 1.36, 0.185),
    (-0.84, 0.80, 0.090),
    (-0.755, 0.25, 0.062),
    (-0.715, 0.115, 0.054),
)


def build_horse() -> bpy.types.Object:
    """A low-poly horse facing +Y (Blender), hooves on z = 0.

    A **prism** is the barrel, not a box, and the eight sides are rolled half a
    step so one facet faces straight up: a horse's back is a flat line between
    the withers and the croup, an ellipsoid can only ever give a dome, and a
    box gives the right back and the wrong everything else. The chest and the
    rump are rounded so the prism's ends close off. The legs, neck, head and
    tail keep their node names (``HorseLegFL`` … ``HorseLegBR``,
    ``HorseNeck``, ``HorseHead``, ``HorseTail``), which is what the runner
    screen animates.
    """
    # Radius 0.285 rolled by half a step: back flat at 1.59, belly at 1.07.
    body = _horse_segment(
        "HorseBody", (0.0, -0.46, 1.33), (0.0, 0.36, 1.33), 0.285, 0.285, HORSE_COAT, 8, roll=math.pi / 8.0
    )
    _ico("HorseChest", (0.31, 0.30, 0.30), (0.0, 0.40, 1.30), HORSE_COAT, 0.0, 0.7, 0.0, 2)
    _ico("HorseRump", (0.31, 0.32, 0.31), (0.0, -0.58, 1.32), HORSE_COAT, 0.0, 0.7, 0.0, 2)
    # Fills the corner where the neck meets the shoulder, and carries the
    # withers — the highest point of the back. Without it the neck sits on a
    # stalk and the front view reads as wings either side of a pole.
    _ico("HorseShoulder", (0.27, 0.22, 0.26), (0.0, 0.48, 1.40), HORSE_COAT, 0.0, 0.7, 0.0, 1)

    # The neck is short, steep and **deep** — a horse's neck is the deepest
    # part of the animal relative to its width, and a thin pole reads as a
    # giraffe's. It carries the head on its far end.
    _horse_segment(
        "HorseNeck", (0.0, 0.60, 1.50), (0.0, 1.00, 1.98), 0.25, 0.145, HORSE_COAT, 6, 0.60, True
    )
    # The head hangs down and forward at about 41°, and its origin sits on the
    # poll so a nod turns it on the neck joint rather than in mid-air.
    _horse_segment(
        "HorseHead", (0.0, 1.00, 1.98), (0.0, 1.42, 1.62), 0.155, 0.075, HORSE_COAT, 6, 0.76, True
    )
    _ico("HorseJaw", (0.09, 0.12, 0.105), (0.0, 1.08, 1.86), HORSE_COAT, 0.0, 0.7, 0.0, 1)
    _box("HorseMuzzle", (0.105, 0.13, 0.10), (0.0, 1.43, 1.61), HORSE_MUZZLE, 0.0, 0.8, 0.0, rotation=(-0.86, 0.0, 0.0))

    # An eye on each side, high on the head just behind the brow. The close-up
    # photograph spends most of its frame on it, and it is the one feature that
    # separates a head from a wedge: a head with no eye reads as a box from the
    # front. Set into the cheek, so the sphere is mostly inside the skull.
    for i, x in enumerate((-0.108, 0.108)):
        _ico(f"HorseEye{i}", (0.035, 0.055, 0.048), (x, 1.12, 1.90), EYE_COLOR, 0.0, 0.35, 0.0, 1)

    # Nostrils, one each side of the muzzle. Small, but the muzzle is the one
    # part of the head that points at the player in the runner game, and a
    # featureless pale block there is the weakest thing on the animal.
    for i, x in enumerate((-0.052, 0.052)):
        _ico(f"HorseNostril{i}", (0.026, 0.030, 0.036), (x, 1.47, 1.63), HORSE_DARK, 0.0, 0.8, 0.0, 1)

    for i, x in enumerate((-0.075, 0.075)):
        ear = _cone(f"HorseEar{i}", 4, 0.050, 0.0, 0.26, (x, 0.99, 2.02), HORSE_DARK, 0.0, 0.9, 0.0)
        # Pricked up, tipped forward and splayed out: a horse's ears stand, and
        # the splay is what the front view is read by.
        ear.rotation_euler = (-0.25, 0.0, 0.32 if x < 0.0 else -0.32)

    # The mane is a **band lying on the crest**, not a row of spikes standing
    # off it. Both references agree and neither leaves room for argument: the
    # PSF anatomy plate draws it as a scalloped ridge sitting on the top line
    # of the neck, and the Mongolia photograph has it falling down the near
    # side. What the previous mane did instead was fan its four shards from
    # -0.695 to -0.425 about X, which tips them progressively further off the
    # neck's own axis; from the side they clear the silhouette and read as a
    # mohawk. Keeping every shard on one rotation is what puts the hair back on
    # the horse.
    #
    # The crest is the *surface* of the neck, not its axis: the axis runs from
    # the withers to the poll, and the crest is that line pushed sideways by
    # the neck's own radius. Shards placed on the axis end up inside the neck.
    crest_a = Vector((0.0, 0.42, 1.66))
    crest_b = Vector((0.0, 0.89, 2.07))
    _horse_segment(
        "HorseManeRidge", crest_a, crest_b, 0.105, 0.070, HORSE_DARK, 6, 0.70, True
    )
    # The locks hang down the **side** of the neck rather than out along the
    # crest, so they are offset in X — the neck is flattened to 0.60, so its own
    # surface there is only about 0.15 from the axis and a lock on the axis
    # would be buried in it. Seen from the side these are the serrated edge that
    # tells the neck it is a horse and not a pole.
    for i, t in enumerate((0.14, 0.40, 0.64, 0.85)):
        p = crest_a.lerp(crest_b, t)
        _horse_segment(
            f"HorseManeLock{i}",
            (p.x - 0.055, p.y, p.z - 0.01),
            (p.x - 0.080, p.y + 0.07, p.z - 0.21),
            0.055,
            0.022,
            HORSE_DARK,
            4,
            0.80,
        )
    # The forelock falls off the poll forward over the forehead, which is the
    # one part of a horse's hair that hangs in front of the face rather than
    # along the neck.
    _box("HorseForelock", (0.09, 0.12, 0.26), (0.0, 1.06, 2.03), HORSE_DARK, 0.0, 0.9, 0.0, rotation=(-0.9, 0.0, 0.0))

    # Tail: a dock leaving the croup downwards, then the lock hanging behind
    # the hocks. Both references put it close to vertical — the anatomy plate
    # has it falling straight down the buttock to the level of the hock, and the
    # photograph has the same — and the previous version ran the dock out at
    # 45 degrees to the rear, which from the side reads as a flag on a pole.
    # The dock starts well inside the rump; starting it on the croup's upper
    # edge leaves it floating.
    _horse_segment("HorseTail", (0.0, -0.70, 1.44), (0.0, -0.84, 1.26), 0.155, 0.115, HORSE_DARK)
    _horse_segment(
        "HorseTailLock", (0.0, -0.84, 1.27), (0.0, -0.95, 0.82), 0.115, 0.070, HORSE_DARK, 6, 0.85
    )
    _horse_segment(
        "HorseTailLock2", (0.0, -0.80, 1.24), (0.0, -0.88, 0.92), 0.085, 0.050, HORSE_DARK, 5, 0.90
    )

    # Shoulder-width apart, at the widest part of the barrel: a horse stands on
    # legs under its own body, and pulling them inwards makes the front view a
    # set of knees almost touching.
    for side, x in (("L", -0.30), ("R", 0.30)):
        _horse_leg(f"HorseLegF{side}", x, HORSE_FORE_LEG, hoof=(0.565, 0.0))
        _horse_leg(f"HorseLegB{side}", x, HORSE_HIND_LEG, hoof=(-0.700, 0.0))
    return body


def build_tree() -> bpy.types.Object:
    """A low-poly park tree: trunk plus three stacked foliage cones."""
    trunk = _cone("TreeTrunk", 8, 0.22, 0.15, 1.7, (0.0, 0.0, 0.85), (0.32, 0.19, 0.08, 1.0), 0.0, 0.9, 0.0)
    _cone("TreeFoliageA", 9, 1.15, 0.0, 1.5, (0.0, 0.0, 1.95), (0.10, 0.40, 0.13, 1.0), 0.0, 0.85, 0.0)
    _cone("TreeFoliageB", 9, 0.92, 0.0, 1.4, (0.0, 0.0, 2.72), (0.13, 0.46, 0.16, 1.0), 0.0, 0.85, 0.0)
    _cone("TreeFoliageC", 8, 0.62, 0.0, 1.25, (0.0, 0.0, 3.48), (0.17, 0.52, 0.19, 1.0), 0.0, 0.85, 0.0)
    return trunk


def build_rock() -> bpy.types.Object:
    """A low-poly boulder obstacle (flat shaded, sits on the ground)."""
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=1.0, location=(0.0, 0.0, 0.34))
    rock = bpy.context.active_object
    rock.name = "Rock"
    rock.scale = (0.60, 0.46, 0.42)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bpy.ops.object.shade_flat()
    _apply_material(rock, (0.40, 0.41, 0.45, 1.0), 0.0, 0.95, 0.05)
    return rock


def build_log() -> bpy.types.Object:
    """A fallen log obstacle lying across the path (axis along X)."""
    log = _cone("Log", 10, 0.34, 0.34, 1.75, (0.0, 0.0, 0.34), (0.42, 0.26, 0.12, 1.0), 0.0, 0.9, 0.0)
    log.rotation_euler = (0.0, math.pi / 2.0, 0.0)
    for i, x in enumerate((-0.88, 0.88)):
        _cone(f"LogCap{i}", 10, 0.29, 0.29, 0.07, (x, 0.0, 0.34), (0.66, 0.48, 0.27, 1.0), 0.0, 0.85, 0.0)
        bpy.data.objects[f"LogCap{i}"].rotation_euler = (0.0, math.pi / 2.0, 0.0)
    return log


def build_fence() -> bpy.types.Object:
    """A low-poly wooden fence jump for the parcours."""
    _cone("FencePostL", 6, 0.075, 0.075, 1.05, (-0.85, 0.0, 0.52), (0.52, 0.36, 0.19, 1.0), 0.0, 0.85, 0.0)
    _cone("FencePostR", 6, 0.075, 0.075, 1.05, (0.85, 0.0, 0.52), (0.52, 0.36, 0.19, 1.0), 0.0, 0.85, 0.0)
    _box("FenceRailLow", (1.85, 0.09, 0.09), (0.0, 0.0, 0.48), (0.60, 0.43, 0.23, 1.0), 0.0, 0.85, 0.0)
    _box("FenceRailHigh", (1.85, 0.09, 0.09), (0.0, 0.0, 0.82), (0.60, 0.43, 0.23, 1.0), 0.0, 0.85, 0.0)
    return bpy.data.objects["FencePostL"]


BUILDERS = {
    "crystal": build_crystal,
    "crystal_shard": build_crystal_shard,
    "crystal_gem": build_crystal_gem,
    "crystal_jewel": build_crystal_jewel,
    "crystal_prism": build_crystal_prism,
    "crystal_star": build_crystal_star,
    "ship": build_ship,
    "ornament": build_ornament,
    "pumpkin": build_pumpkin,
    # Merge 3D themed tiers.
    "xmas_pinecone": build_xmas_pinecone,
    "xmas_candy_cane": build_xmas_candy_cane,
    "xmas_bauble": build_xmas_bauble,
    "xmas_gingerbread_star": build_xmas_gingerbread_star,
    "xmas_star": build_xmas_star,
    "halloween_seed": build_halloween_seed,
    "halloween_candy": build_halloween_candy,
    "halloween_mini_pumpkin": build_halloween_mini_pumpkin,
    "halloween_pumpkin": build_halloween_pumpkin,
    "halloween_ghost_pumpkin": build_halloween_ghost_pumpkin,
    "horse": build_horse,
    "tree": build_tree,
    "rock": build_rock,
    "log": build_log,
    "fence": build_fence,
}


def parse_args() -> argparse.Namespace:
    argv = sys.argv
    argv = argv[argv.index("--") + 1 :] if "--" in argv else []
    parser = argparse.ArgumentParser(description="Generate a low-poly .glb asset with Blender.")
    parser.add_argument("--out", required=True, help="output .glb path")
    parser.add_argument("--name", default="crystal", choices=sorted(BUILDERS), help="asset builder to use")
    return parser.parse_args(argv)


def main() -> None:
    args = parse_args()
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    reset_scene()
    obj = BUILDERS[args.name]()
    bpy.ops.export_scene.gltf(filepath=args.out, export_format="GLB")
    print(f"[blender] wrote {args.out} ({args.name}, mesh={obj.name})")


if __name__ == "__main__":
    main()
