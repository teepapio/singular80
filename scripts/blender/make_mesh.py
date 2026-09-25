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
from mathutils import Matrix, Vector


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


def build_crystal() -> bpy.types.Object:
    """A faceted, glowing crystal used as a collectible."""
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=1.0)
    obj = bpy.context.active_object
    obj.name = "Crystal"
    obj.scale = (0.6, 0.6, 1.4)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bpy.ops.object.shade_flat()
    _apply_material(obj, (0.15, 0.8, 1.0, 1.0), emission=2.0)
    return obj


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
    """Tier 1 — a raw, pale splinter of crystal."""
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=0.7)
    obj = bpy.context.active_object
    obj.name = "CrystalShard"
    obj.scale = (0.34, 0.34, 1.0)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return _primitive(obj.name, (0.6, 0.78, 1.0, 1.0), emission=1.0, roughness=0.5, metallic=0.05)


def build_crystal_gem() -> bpy.types.Object:
    """Tier 2 — a round, faceted gemstone."""
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=0.82)
    obj = bpy.context.active_object
    obj.name = "CrystalGem"
    obj.scale = (0.84, 0.84, 1.0)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return _primitive(obj.name, (0.13, 0.83, 0.93, 1.0), emission=1.3, roughness=0.42, metallic=0.1)


def build_crystal_jewel() -> bpy.types.Object:
    """Tier 3 — a cut jewel with a brilliant-style crown and pavilion."""
    _cone("JewelCrown", 8, 0.9, 0.44, 0.6, (0.0, 0.0, 0.46), (0.2, 0.9, 0.55, 1.0), 1.6, 0.35, 0.15)
    _cone("JewelPavilion", 8, 0.9, 0.0, 0.95, (0.0, 0.0, -0.3), (0.2, 0.9, 0.55, 1.0), 1.6, 0.35, 0.15, flip=True)
    _torus("JewelGirdle", 0.88, 0.08, (0.0, 0.0, 0.12), (0.85, 1.0, 0.9, 1.0), 1.2, 0.3, 0.3)
    obj = bpy.data.objects["JewelCrown"]
    return obj


def build_crystal_prism() -> bpy.types.Object:
    """Tier 4 — a tall hexagonal prism crowned with pyramidal tips."""
    _cone("PrismBody", 6, 0.46, 0.46, 1.35, (0.0, 0.0, 0.0), (0.98, 0.75, 0.15, 1.0), 1.8, 0.3, 0.25)
    _cone("PrismTipTop", 6, 0.46, 0.0, 0.6, (0.0, 0.0, 0.97), (0.98, 0.75, 0.15, 1.0), 1.8, 0.3, 0.25)
    _cone("PrismTipBottom", 6, 0.46, 0.0, 0.6, (0.0, 0.0, -0.97), (0.98, 0.75, 0.15, 1.0), 1.8, 0.3, 0.25, flip=True)
    _torus("PrismHalo", 0.78, 0.07, (0.0, 0.0, 0.05), (1.0, 0.92, 0.6, 1.0), 1.4, 0.25, 0.35)
    return bpy.data.objects["PrismBody"]


def build_crystal_star() -> bpy.types.Object:
    """Tier 5 — a radiant star core with radiating spikes and a halo."""
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=0.5)
    core = bpy.context.active_object
    core.name = "StarCore"
    _primitive(core.name, (0.96, 0.45, 0.72, 1.0), 2.4, 0.22, 0.4)

    for i in range(6):
        angle = i * math.pi / 3.0
        spike = _cone(
            f"StarSpike{i}",
            4,
            0.2,
            0.0,
            0.85,
            (math.cos(angle) * 0.45, 0.0, math.sin(angle) * 0.45),
            (0.96, 0.45, 0.72, 1.0),
            2.0,
            0.25,
            0.35,
        )
        # Point the spike away from the core (cone default axis is +Z).
        spike.rotation_euler = (0.0, math.pi / 2.0 - angle, 0.0)
    _cone("StarSpikeUp", 4, 0.2, 0.0, 0.9, (0.0, 0.55, 0.0), (0.96, 0.45, 0.72, 1.0), 2.0, 0.25, 0.35)
    _cone("StarSpikeDown", 4, 0.2, 0.0, 0.9, (0.0, -0.55, 0.0), (0.96, 0.45, 0.72, 1.0), 2.0, 0.25, 0.35, flip=True)
    _torus("StarHalo", 0.95, 0.06, (0.0, 0.0, 0.0), (1.0, 0.85, 0.95, 1.0), 1.6, 0.2, 0.4)
    return core


HORSE_COAT = (0.55, 0.33, 0.16, 1.0)
HORSE_DARK = (0.20, 0.11, 0.05, 1.0)
HORSE_MUZZLE = (0.78, 0.62, 0.50, 1.0)
HOOF_COLOR = (0.13, 0.11, 0.10, 1.0)


def _horse_leg(
    name: str,
    x: float,
    y: float,
    hip_z: float,
    length: float,
    hoof_name: str,
) -> bpy.types.Object:
    """A leg whose origin sits at the hip so three.js can swing it around it."""
    leg = _cone(name, 8, 0.055, 0.09, length, (x, y, hip_z), HORSE_COAT, 0.0, 0.7, 0.0)
    # Move the mesh data down so the object's pivot is the top of the leg.
    leg.data.transform(Matrix.Translation((0.0, 0.0, -length / 2.0)))
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=8, radius=0.095, depth=0.13, location=(x, y, hip_z - length + 0.065)
    )
    hoof = _primitive(hoof_name, HOOF_COLOR, 0.0, 0.5, 0.0)
    hoof.parent = leg
    hoof.matrix_parent_inverse = leg.matrix_world.inverted()
    return leg


def build_horse() -> bpy.types.Object:
    """A low-poly horse facing +Y (Blender).

    The four legs are separate nodes whose pivot is the hip, named
    ``HorseLegFL`` … ``HorseLegBR``, so the three.js scene can drive a proper
    gallop and a tucked jump pose. Body, neck, head, mane and tail are siblings.
    """
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=1.0, location=(0.0, 0.0, 1.20))
    body = bpy.context.active_object
    body.name = "HorseBody"
    body.scale = (0.40, 0.78, 0.34)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bpy.ops.object.shade_flat()
    _apply_material(body, HORSE_COAT, 0.0, 0.7, 0.0)

    _box("HorseNeck", (0.19, 0.22, 0.46), (0.0, 0.70, 1.72), HORSE_COAT, 0.0, 0.7, 0.0, rotation=(-0.55, 0.0, 0.0))
    _box("HorseHead", (0.16, 0.26, 0.17), (0.0, 1.02, 2.10), HORSE_COAT, 0.0, 0.7, 0.0, rotation=(0.18, 0.0, 0.0))
    _box("HorseMuzzle", (0.12, 0.18, 0.12), (0.0, 1.24, 2.06), HORSE_MUZZLE, 0.0, 0.8, 0.0, rotation=(0.18, 0.0, 0.0))
    _box("HorseMane", (0.06, 0.11, 0.42), (0.0, 0.60, 1.92), HORSE_DARK, 0.0, 0.9, 0.0, rotation=(-0.55, 0.0, 0.0))
    _box("HorseForelock", (0.06, 0.10, 0.20), (0.0, 0.86, 2.34), HORSE_DARK, 0.0, 0.9, 0.0, rotation=(0.4, 0.0, 0.0))

    for i, x in enumerate((-0.075, 0.075)):
        _cone(f"HorseEar{i}", 4, 0.055, 0.0, 0.18, (x, 0.90, 2.30), HORSE_DARK, 0.0, 0.9, 0.0)

    _cone("HorseTail", 6, 0.03, 0.13, 0.78, (0.0, -0.78, 1.02), HORSE_DARK, 0.0, 0.9, 0.0)

    for side, x in (("L", -0.30), ("R", 0.30)):
        _horse_leg(f"HorseLegF{side}", x, 0.54, 1.06, 1.06, f"HorseHoofF{side}")
        _horse_leg(f"HorseLegB{side}", x, -0.54, 1.06, 1.06, f"HorseHoofB{side}")
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
