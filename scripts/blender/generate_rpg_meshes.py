"""Headless Blender generator for the "Drachen-RPG 3D" mesh pack.

Produces the dragon-RPG asset collection (~50 low-poly ``.glb`` files: dragons,
environment props, loot/gear and the player knight) in a single Blender run,
reusing the primitive helpers from ``make_mesh.py``.

Usage::

    blender --background --python scripts/blender/generate_rpg_meshes.py
    blender --background --python scripts/blender/generate_rpg_meshes.py -- --only knight,sword

Meshes land in ``public/assets/rpg`` and are registered in ``src/game/assets.ts``
(see AGENTS.md). Keep every mesh low-poly — it protects the web build size.
"""

from __future__ import annotations

import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bmesh  # noqa: E402
import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

import make_mesh as mm  # noqa: E402

# --- palette ----------------------------------------------------------------
WOOD = (0.42, 0.27, 0.14, 1.0)
WOOD_DARK = (0.26, 0.16, 0.08, 1.0)
WOOD_LIGHT = (0.62, 0.45, 0.24, 1.0)
STONE = (0.44, 0.45, 0.5, 1.0)
STONE_DARK = (0.28, 0.29, 0.34, 1.0)
STEEL = (0.66, 0.7, 0.76, 1.0)
STEEL_DARK = (0.34, 0.38, 0.45, 1.0)
GOLD = (0.95, 0.76, 0.22, 1.0)
BONE = (0.88, 0.86, 0.78, 1.0)
LEATHER = (0.45, 0.29, 0.15, 1.0)
GREEN = (0.16, 0.5, 0.2, 1.0)
GREEN_DARK = (0.1, 0.34, 0.14, 1.0)
RED = (0.8, 0.15, 0.12, 1.0)
BLUE = (0.18, 0.45, 0.85, 1.0)
CYAN = (0.15, 0.8, 0.9, 1.0)
PURPLE = (0.5, 0.22, 0.7, 1.0)
ORANGE = (0.95, 0.45, 0.1, 1.0)
WHITE = (0.92, 0.93, 0.95, 1.0)
BLACK = (0.1, 0.1, 0.13, 1.0)


# --- primitive helpers ------------------------------------------------------
_cone = mm._cone
_box = mm._box
_torus = mm._torus


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
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdivisions, radius=1.0, location=location)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return mm._primitive(name, color, emission, roughness, metallic)


def _cyl(
    name: str,
    vertices: int,
    radius: float,
    depth: float,
    location: tuple[float, float, float],
    color: tuple[float, float, float, float],
    emission: float = 0.0,
    roughness: float = 0.5,
    metallic: float = 0.1,
) -> bpy.types.Object:
    return mm._cone(name, vertices, radius, radius, depth, location, color, emission, roughness, metallic)


def _pivot_box(
    name: str,
    size: tuple[float, float, float],
    offset: tuple[float, float, float],
    location: tuple[float, float, float],
    color: tuple[float, float, float, float],
    emission: float = 0.0,
    roughness: float = 0.5,
    metallic: float = 0.1,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    """A box whose pivot sits at ``location`` (mesh offset by ``offset``)."""
    obj = mm._box(name, size, (0.0, 0.0, 0.0), color, emission, roughness, metallic)
    obj.data.transform(Matrix.Translation(offset))
    obj.location = location
    obj.rotation_euler = rotation
    return obj


def _membrane_wing(
    name: str,
    side: float,
    span: float,
    color: tuple[float, float, float, float],
    accent: tuple[float, float, float, float],
    thickness: float = 0.035,
) -> bpy.types.Object:
    """One dragon wing, built around the origin so the pivot is the shoulder.

    The game flaps the wings by setting ``rotation.z`` on the objects named
    ``DragonWingL`` / ``DragonWingR``, so each wing must stay a **single**
    object whose origin sits at the shoulder — see
    ``godot/src/game/dragon_flight/dragon_flight_screen.gd``. Everything below
    (arm bone, finger bones, membrane) is therefore built into one mesh and
    given one object with its origin at (0, 0, 0); the caller places it.

    What the reference photographs show (Wikimedia Commons, "Flying bat with
    tree", "Rhamphorhynchus life restoration"), and what the previous build —
    a flat plank plus two floating cones — did not have:

    * an **arm bone** running out and slightly back, thickening at the shoulder
      and tapering to the wrist, so the wing has a leading edge with a direction;
    * **finger bones** fanning from the wrist to the trailing edge — four of
      them, which is what gives a bat or dragon wing its ribbed look;
    * a **membrane** spanning those fingers, i.e. the wing has area rather than
      being struts with holes in them;
    * a **scalloped trailing edge**: the outline between two finger tips curves
      *inwards*, a concave arc. This is the single feature that makes the
      silhouette read as a membrane wing instead of as a plank;
    * a slight **upward curl**, so the wing is not a flat plane.

    The wing is built for `side = +1` pointing along +X and mirrored by scaling
    X, rather than by negating every coordinate, which keeps the scallop arcs
    symmetric.
    """
    # --- planform of the membrane, in wing-local space ------------------------
    # X out along the span, Y back along the body (the dragon faces +Y),
    # Z up. `span` scales the whole thing.
    #
    # The anatomy is the bat's: the **arm reaches the wing tip**, forming the
    # whole leading edge, and the fingers fan back from a wrist partway along
    # it. An earlier version made the wrist the end of the arm and put the
    # tips beyond it, which produced a solid triangular slab — the fan of
    # membrane had no notches to be notched into, so the scallops vanished and
    # the wing read as a paddle.
    root_front = Vector((0.02 * span, 0.04 * span, 0.05 * span))
    # Elbow and wrist partway along the arm.
    elbow = Vector((0.34 * span, -0.06 * span, 0.10 * span))
    wrist = Vector((0.70 * span, -0.26 * span, 0.16 * span))
    # The wing tip: the end of the arm, the outermost point of the whole wing.
    tip = Vector((1.34 * span, -0.50 * span, 0.20 * span))

    # Finger tips, fanning back from the wrist to the trailing edge. These sit
    # on the concave trailing edge, behind and below the arm.
    tips = [
        Vector((1.06 * span, -0.80 * span, 0.10 * span)),
        Vector((0.78 * span, -1.06 * span, 0.02 * span)),
        Vector((0.46 * span, -1.20 * span, -0.05 * span)),
        Vector((0.16 * span, -1.16 * span, -0.08 * span)),
    ]
    root_back = Vector((0.04 * span, -0.62 * span, -0.04 * span))

    # Outline walked along the leading edge from the root out to the tip, then
    # back along the trailing edge through the finger tips to the rear root.
    outline = [root_front, elbow, wrist, tip, *tips, root_back]

    # The trailing edge runs between consecutive finger tips. A scallop is the
    # midpoint of that chord pushed **perpendicular** to the chord, inwards.
    # Pushing it towards the wrist instead — which looks like the obvious thing
    # to do — moves the point mostly along the edge and merely rotates it, so
    # the outline comes out almost straight. The sign is chosen by testing
    # against the wrist, so the dent always goes into the membrane.
    trailing = []
    for i in range(len(tips) - 1):
        a = tips[i]
        b = tips[i + 1]
        mid = (a + b) * 0.5
        chord = b - a
        normal = Vector((-chord.y, chord.x, 0.0))
        if normal.length < 1e-6:
            trailing.append(mid)
            trailing.append(b)
            continue
        normal.normalize()
        if normal.dot(wrist - mid) < 0.0:
            normal = -normal
        # Deep enough to read at gallery size: a third of a span.
        trailing.append(mid + normal * (0.26 * span))
        trailing.append(b)
    trailing.append(root_back)

    # A slight upward curl: raise the middle of the membrane, so the wing is a
    # shallow curved surface rather than a plane. `tip.x` is the full span, so
    # normalising against it puts the crest mid-membrane and zero at the root.
    def _curl(point: Vector) -> Vector:
        out = point.copy()
        t = min(1.0, max(0.0, out.x / max(1e-6, tip.x)))
        out.z += 0.09 * span * (1.0 - abs(2.0 * t - 1.0))
        return out

    outline = [_curl(p) for p in outline]
    trailing = [_curl(p) for p in trailing]

    bm = bmesh.new()

    def _vert(point: Vector) -> bmesh.types.BMVert:
        vert = bm.verts.new((point.x * side, point.y, point.z))
        return vert

    # --- the membrane surface ------------------------------------------------
    # Fill the outline as a polygon rather than fanning it from the wrist. The
    # trailing edge is deliberately concave — that is the scallop — and a fan
    # from an interior hub simply ignores the concavity: it would produce
    # overlapping triangles and a flat, convex hull instead of a notched edge.
    # `triangle_fill` ear-clips the loop, so the notches survive.
    ring = [_vert(p) for p in outline]
    for i in range(len(ring)):
        bm.edges.new((ring[i], ring[(i + 1) % len(ring)]))
    bmesh.ops.triangle_fill(bm, use_beauty=True, edges=list(bm.edges))

    # --- finger bones --------------------------------------------------------
    # Thin tapered prisms from the wrist out to each finger tip, plus one along
    # the arm itself. They stand slightly proud of the membrane so they read as
    # ribs on top of it rather than being lost in the sheet.
    def _rib(name_start: str, start: Vector, end: Vector, r0: float, r1: float, sides: int) -> None:
        length = (end - start).length
        if length <= 1e-6:
            return
        direction = (end - start).normalized()
        perp = direction.cross(Vector((0.0, 0.0, 1.0)))
        if perp.length < 1e-6:
            perp = direction.cross(Vector((0.0, 1.0, 0.0)))
        perp.normalize()
        second = direction.cross(perp).normalized()
        # Lift the rib a hair off the membrane plane so it is visible on top.
        lift = Vector((0.0, 0.0, 0.018 * span))
        near = []
        far = []
        for k in range(sides):
            angle = 2.0 * math.pi * k / sides
            offset = (perp * math.cos(angle) + second * math.sin(angle))
            near.append(_vert(start + lift + offset * r0))
            far.append(_vert(end + lift + offset * r1))
        for k in range(sides):
            n = (k + 1) % sides
            bm.faces.new((near[k], near[n], far[n], far[k]))

    for i, finger_tip in enumerate(tips):
        _rib(f"Finger{i}", wrist, finger_tip, 0.03 * span, 0.012 * span, 3)

    # --- arm bone ------------------------------------------------------------
    # Two tapering segments, shoulder → elbow → wrist → tip: the leading edge
    # has thickness, which is what separates a wing from a sheet of paper.
    _rib("ArmLower", root_front, elbow, 0.075 * span, 0.055 * span, 5)
    _rib("ArmUpper", elbow, wrist, 0.055 * span, 0.042 * span, 5)
    _rib("ArmTip", wrist, tip, 0.042 * span, 0.008 * span, 4)

    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    mm._apply_material(obj, color, 0.0, 0.7, 0.05)

    # Give the membrane real thickness. A single-sided sheet is invisible from
    # behind and looks like a hole in the wing on a phone; a 3.5 cm slab reads
    # as a membrane from every angle.
    solidify = obj.modifiers.new("MembraneThickness", type="SOLIDIFY")
    solidify.thickness = thickness * span
    solidify.offset = 0.0
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=solidify.name)
    return obj


# --- dragons ----------------------------------------------------------------
def build_dragon(
    body: tuple[float, float, float],
    belly: tuple[float, float, float],
    accent: tuple[float, float, float],
    *,
    size: float = 1.0,
    horn_count: int = 2,
    horn_len: float = 0.5,
    wing_span: float = 1.0,
    spikes: bool = True,
    tail_len: float = 1.0,
    neck_len: float = 1.0,
    legs: bool = True,
    crest: bool = False,
) -> bpy.types.Object:
    """A low-poly dragon facing +Y, feet near z=0. ``size`` scales everything."""
    s = size
    body_c = (*body, 1.0)
    belly_c = (*belly, 1.0)
    accent_c = (*accent, 1.0)

    torso = _ico("DragonBody", (0.62 * s, 1.08 * s, 0.56 * s), (0.0, 0.0, 1.05 * s), body_c, 0.0, 0.7, 0.05)
    _ico("DragonBelly", (0.5 * s, 0.9 * s, 0.44 * s), (0.0, 0.06 * s, 0.9 * s), belly_c, 0.0, 0.8, 0.02)

    neck = _cone("DragonNeck", 8, 0.36 * s, 0.24 * s, neck_len * 0.95 * s, (0.0, 0.52 * s, 1.28 * s), body_c, 0.0, 0.7, 0.05)
    neck.rotation_euler = (-0.6, 0.0, 0.0)

    head_y = 0.52 * s + neck_len * 0.95 * s * 0.5 * 0.565
    head_z = 1.28 * s + neck_len * 0.95 * s * 0.5 * 0.825
    _box("DragonHead", (0.44 * s, 0.6 * s, 0.4 * s), (0.0, head_y + 0.16 * s, head_z + 0.02 * s), body_c, 0.0, 0.65, 0.05)
    _box("DragonSnout", (0.3 * s, 0.42 * s, 0.22 * s), (0.0, head_y + 0.56 * s, head_z - 0.06 * s), body_c, 0.0, 0.65, 0.05)
    _box("DragonJaw", (0.26 * s, 0.36 * s, 0.12 * s), (0.0, head_y + 0.54 * s, head_z - 0.2 * s), belly_c, 0.0, 0.75, 0.02)
    _ico("DragonEyeL", (0.08 * s, 0.08 * s, 0.08 * s), (-0.17 * s, head_y + 0.34 * s, head_z + 0.12 * s), accent_c, 2.2, 0.3, 0.1)
    _ico("DragonEyeR", (0.08 * s, 0.08 * s, 0.08 * s), (0.17 * s, head_y + 0.34 * s, head_z + 0.12 * s), accent_c, 2.2, 0.3, 0.1)

    for i in range(horn_count):
        spread = (i - (horn_count - 1) / 2.0) * 0.22 * s
        horn = _cone(
            f"DragonHorn{i}", 4, 0.09 * s, 0.0, horn_len * s,
            (spread, head_y - 0.08 * s, head_z + 0.28 * s), accent_c, 0.2, 0.5, 0.2,
        )
        horn.rotation_euler = (0.75 + i * 0.08, 0.0, spread * 1.2)

    if crest:
        crest_obj = _cone("DragonCrest", 5, 0.16 * s, 0.0, 0.5 * s, (0.0, head_y - 0.2 * s, head_z + 0.3 * s), accent_c, 0.4, 0.5, 0.1)
        crest_obj.rotation_euler = (0.5, 0.0, 0.0)

    # Wings — one object per side, origin at the shoulder, so the scene can
    # flap them by setting rotation.z (dragon_flight_screen.gd:397). The
    # membrane, the arm bone and the finger bones are all part of that single
    # object, because a wing split across several nodes would leave the
    # membrane behind while the bones flap.
    for side, tag in ((-1.0, "L"), (1.0, "R")):
        wing = _membrane_wing(f"DragonWing{tag}", side, wing_span * s, body_c, accent_c)
        # Place the shoulder and tilt the wing back and up like a real one at
        # rest. A little dihedral, so the wings are not perfectly flat.
        wing.location = (side * 0.34 * s, 0.16 * s, 1.36 * s)
        wing.rotation_euler = (0.0, -side * 0.30, -side * 0.22)

    # Tail — three tapering segments sweeping back and down.
    tail_len = tail_len * s
    _cone("DragonTailA", 7, 0.26 * s, 0.2 * s, 0.7 * tail_len, (0.0, -1.05 * s, 0.95 * s), body_c, 0.0, 0.7, 0.05).rotation_euler = (1.4, 0.0, 0.0)
    _cone("DragonTailB", 7, 0.19 * s, 0.12 * s, 0.7 * tail_len, (0.0, -1.72 * s, 0.78 * s), body_c, 0.0, 0.7, 0.05).rotation_euler = (1.75, 0.0, 0.0)
    tail_tip = _cone("DragonTailC", 6, 0.12 * s, 0.0, 0.7 * tail_len, (0.0, -2.32 * s, 0.56 * s), body_c, 0.0, 0.7, 0.05)
    tail_tip.rotation_euler = (2.05, 0.0, 0.0)
    fin = _pivot_box("DragonTailFin", (0.06 * s, 0.5 * s, 0.5 * s), (0.0, -0.3 * s, 0.15 * s), (0.0, -2.6 * s, 0.72 * s), accent_c, 0.2, 0.5, 0.1, rotation=(0.5, 0.0, 0.0))
    fin.rotation_euler = (0.6, 0.0, 0.0)

    if legs:
        for side in (-1.0, 1.0):
            for front in (True, False):
                y = 0.5 * s if front else -0.58 * s
                _cone(f"DragonLeg{'F' if front else 'B'}{'L' if side < 0 else 'R'}", 6, 0.16 * s, 0.1 * s, 0.95 * s, (side * 0.4 * s, y, 0.5 * s), body_c, 0.0, 0.7, 0.05)

    if spikes:
        for i in range(5):
            spike = _cone(
                f"DragonSpike{i}", 4, 0.1 * s, 0.0, 0.34 * s,
                (0.0, 0.35 * s - i * 0.34 * s, 1.5 * s - i * 0.05 * s), accent_c, 0.2, 0.5, 0.15,
            )
            spike.rotation_euler = (-0.2, 0.0, 0.0)

    return torso


DRAGON_VARIANTS: list[tuple[str, dict[str, object]]] = [
    ("dragon_hatchling", dict(body=(0.24, 0.55, 0.24), belly=(0.62, 0.8, 0.42), accent=(0.95, 0.8, 0.2), size=0.72, horn_count=1, horn_len=0.28, wing_span=0.7, tail_len=0.8, neck_len=0.8)),
    ("dragon_ember", dict(body=(0.72, 0.16, 0.1), belly=(0.95, 0.55, 0.15), accent=(1.0, 0.75, 0.2), size=0.95, horn_count=2, horn_len=0.5, wing_span=1.0, tail_len=1.0)),
    ("dragon_frost", dict(body=(0.25, 0.55, 0.85), belly=(0.75, 0.88, 1.0), accent=(0.7, 0.95, 1.0), size=0.95, horn_count=2, horn_len=0.55, wing_span=1.0, spikes=True, tail_len=1.0)),
    ("dragon_venom", dict(body=(0.3, 0.5, 0.16), belly=(0.6, 0.75, 0.3), accent=(0.6, 0.25, 0.75), size=0.92, horn_count=3, horn_len=0.4, wing_span=0.9, tail_len=1.1)),
    ("dragon_storm", dict(body=(0.45, 0.3, 0.78), belly=(0.75, 0.72, 0.95), accent=(0.55, 0.9, 1.0), size=0.95, horn_count=2, horn_len=0.6, wing_span=1.15, tail_len=1.0, crest=True)),
    ("dragon_stone", dict(body=(0.4, 0.41, 0.44), belly=(0.6, 0.58, 0.52), accent=(0.75, 0.6, 0.3), size=1.0, horn_count=2, horn_len=0.4, wing_span=0.8, spikes=True, tail_len=0.9)),
    ("dragon_shadow", dict(body=(0.14, 0.13, 0.2), belly=(0.3, 0.28, 0.42), accent=(0.6, 0.3, 0.85), size=1.0, horn_count=3, horn_len=0.6, wing_span=1.1, tail_len=1.15)),
    ("dragon_bone", dict(body=(0.82, 0.8, 0.72), belly=(0.6, 0.58, 0.52), accent=(0.5, 0.75, 0.55), size=1.0, horn_count=2, horn_len=0.65, wing_span=1.0, tail_len=1.0, crest=True)),
    ("dragon_crystal", dict(body=(0.2, 0.65, 0.78), belly=(0.7, 0.92, 0.95), accent=(0.6, 1.0, 1.0), size=1.05, horn_count=4, horn_len=0.5, wing_span=1.05, tail_len=1.0, crest=True)),
    ("dragon_gold", dict(body=(0.8, 0.6, 0.15), belly=(0.95, 0.85, 0.4), accent=(1.0, 0.9, 0.45), size=1.1, horn_count=3, horn_len=0.7, wing_span=1.2, tail_len=1.1, crest=True)),
    ("dragon_elder", dict(body=(0.48, 0.1, 0.12), belly=(0.8, 0.35, 0.18), accent=(0.95, 0.55, 0.2), size=1.3, horn_count=4, horn_len=0.85, wing_span=1.35, tail_len=1.2, crest=True)),
    ("dragon_lord", dict(body=(0.3, 0.08, 0.4), belly=(0.65, 0.3, 0.75), accent=(1.0, 0.55, 0.15), size=1.55, horn_count=5, horn_len=1.0, wing_span=1.6, tail_len=1.3, crest=True)),
]


# --- player -----------------------------------------------------------------
def build_knight() -> bpy.types.Object:
    """An armoured knight facing +Y, feet at z=0."""
    torso = mm._box("KnightTorso", (0.74, 0.46, 0.78), (0.0, 0.0, 1.62), STEEL, 0.0, 0.45, 0.55)
    mm._box("KnightChest", (0.5, 0.16, 0.4), (0.0, 0.26, 1.72), GOLD, 0.2, 0.4, 0.6)
    mm._box("KnightBelt", (0.78, 0.5, 0.14), (0.0, 0.0, 1.22), GOLD, 0.1, 0.4, 0.6)
    mm._box("KnightCape", (0.66, 0.08, 0.95), (0.0, -0.3, 1.55), RED, 0.0, 0.8, 0.0)

    for side, tag in ((-1.0, "L"), (1.0, "R")):
        mm._box(f"KnightBoot{tag}", (0.36, 0.52, 0.24), (side * 0.24, 0.04, 0.12), STEEL_DARK, 0.0, 0.5, 0.5)
        _cone(f"KnightShin{tag}", 6, 0.16, 0.13, 0.66, (side * 0.24, 0.0, 0.55), STEEL, 0.0, 0.45, 0.6)
        _cone(f"KnightThigh{tag}", 6, 0.19, 0.15, 0.5, (side * 0.24, 0.0, 1.0), STEEL_DARK, 0.0, 0.5, 0.5)
        _ico(f"KnightShoulder{tag}", (0.32, 0.34, 0.24), (side * 0.52, 0.0, 1.94), STEEL, 0.0, 0.45, 0.6)
        _cone(f"KnightArm{tag}", 6, 0.14, 0.11, 0.72, (side * 0.54, 0.0, 1.5), STEEL, 0.0, 0.45, 0.6)
        _ico(f"KnightHand{tag}", (0.13, 0.13, 0.15), (side * 0.54, 0.0, 1.08), LEATHER, 0.0, 0.7, 0.0)

    _cyl("KnightNeck", 6, 0.12, 0.18, (0.0, 0.0, 2.12), STEEL_DARK, 0.0, 0.5, 0.5)
    _ico("KnightHelmet", (0.3, 0.33, 0.34), (0.0, 0.0, 2.42), STEEL, 0.0, 0.4, 0.65)
    mm._box("KnightVisor", (0.32, 0.08, 0.07), (0.0, 0.28, 2.44), BLACK, 0.0, 0.4, 0.3)
    plume = _cone("KnightPlume", 4, 0.1, 0.0, 0.45, (0.0, -0.05, 2.72), RED, 0.15, 0.7, 0.0)
    plume.rotation_euler = (-0.4, 0.0, 0.0)
    return torso


# --- environment props ------------------------------------------------------
def build_pine_tree() -> bpy.types.Object:
    trunk = _cone("TreeTrunk", 8, 0.24, 0.16, 1.7, (0.0, 0.0, 0.85), WOOD, 0.0, 0.9, 0.0)
    _cone("TreeFoliageA", 9, 1.2, 0.0, 1.6, (0.0, 0.0, 1.95), GREEN, 0.0, 0.85, 0.0)
    _cone("TreeFoliageB", 9, 0.95, 0.0, 1.45, (0.0, 0.0, 2.72), GREEN_DARK, 0.0, 0.85, 0.0)
    _cone("TreeFoliageC", 8, 0.65, 0.0, 1.3, (0.0, 0.0, 3.5), GREEN, 0.0, 0.85, 0.0)
    return trunk


def build_dead_tree() -> bpy.types.Object:
    trunk = _cone("DeadTrunk", 7, 0.26, 0.14, 2.0, (0.0, 0.0, 1.0), WOOD_DARK, 0.0, 0.95, 0.0)
    branches = [
        ((0.5, 0.0), (0.0, 0.0, 1.9)),
        ((-0.6, 0.3), (0.0, 0.0, 1.6)),
        ((0.35, -0.6), (0.0, 0.0, 2.05)),
        ((-0.4, -0.4), (0.0, 0.0, 1.35)),
    ]
    for i, (target, base) in enumerate(branches):
        branch = _cone(f"DeadBranch{i}", 4, 0.08, 0.0, 0.9, (base[0] + target[0] * 0.4, base[1] + target[1] * 0.4, base[2] + 0.25), WOOD_DARK, 0.0, 0.95, 0.0)
        branch.rotation_euler = (target[1] * 0.9, -target[0] * 0.9, 0.0)
    return trunk


def build_bush() -> bpy.types.Object:
    bush = _ico("Bush", (0.6, 0.6, 0.42), (0.0, 0.0, 0.4), GREEN, 0.0, 0.9, 0.0)
    _ico("BushB", (0.42, 0.42, 0.34), (0.42, 0.15, 0.32), GREEN_DARK, 0.0, 0.9, 0.0)
    _ico("BushC", (0.4, 0.4, 0.3), (-0.4, -0.1, 0.3), GREEN, 0.0, 0.9, 0.0)
    return bush


def build_grass_tuft() -> bpy.types.Object:
    base = None
    for i in range(5):
        angle = i * math.pi * 0.4
        blade = _cone(f"Grass{i}", 4, 0.06, 0.0, 0.55 + (i % 2) * 0.2, (math.cos(angle) * 0.12, math.sin(angle) * 0.12, 0.3), GREEN, 0.0, 0.9, 0.0)
        blade.rotation_euler = (math.sin(angle) * 0.35, -math.cos(angle) * 0.35, 0.0)
        if base is None:
            base = blade
    return base  # type: ignore[return-value]


def build_mushroom() -> bpy.types.Object:
    stem = _cyl("MushroomStem", 8, 0.11, 0.5, (0.0, 0.0, 0.25), WHITE, 0.0, 0.8, 0.0)
    _ico("MushroomCap", (0.45, 0.45, 0.3), (0.0, 0.0, 0.55), RED, 0.15, 0.7, 0.0)
    for i in range(3):
        angle = i * 2.1
        _ico(f"MushroomDot{i}", (0.09, 0.09, 0.06), (math.cos(angle) * 0.22, math.sin(angle) * 0.22, 0.72), WHITE, 0.0, 0.8, 0.0)
    return stem


def build_rock_small() -> bpy.types.Object:
    return _ico("RockSmall", (0.5, 0.42, 0.34), (0.0, 0.0, 0.28), STONE, 0.0, 0.95, 0.05)


def build_rock_large() -> bpy.types.Object:
    rock = _ico("RockLarge", (0.95, 0.78, 0.68), (0.0, 0.0, 0.6), STONE, 0.0, 0.95, 0.05)
    _ico("RockLargeB", (0.5, 0.45, 0.4), (0.8, 0.35, 0.34), STONE_DARK, 0.0, 0.95, 0.05)
    return rock


def build_stalagmite() -> bpy.types.Object:
    spike = _cone("Stalagmite", 6, 0.3, 0.04, 1.9, (0.0, 0.0, 0.95), STONE, 0.0, 0.95, 0.05)
    _cone("StalagmiteB", 6, 0.2, 0.03, 1.1, (0.5, 0.25, 0.55), STONE_DARK, 0.0, 0.95, 0.05)
    _cone("StalagmiteC", 6, 0.16, 0.03, 0.8, (-0.45, -0.2, 0.4), STONE, 0.0, 0.95, 0.05)
    return spike


def build_crystal_cluster() -> bpy.types.Object:
    """A cluster of hexagonal crystal shafts of mixed heights and angles.

    This was four smooth 5-sided cones — 32 triangles for the whole object,
    which is not enough to show a crystal. Real clusters are hexagonal shafts
    with pyramidal terminations (see the amethyst reference in make_mesh.py), so
    each point here is a shaft plus a 6-triangle tip, leaning outwards from a
    shared base.
    """
    base = None
    # (x, y, radius, shaft height, tip height, base tip, tilt x, tilt y)
    specs = (
        (0.0, 0.0, 0.28, 1.45, 0.6, 0.3, 0.0, 0.0),
        (0.4, 0.2, 0.19, 1.0, 0.44, 0.0, 0.2, -0.28),
        (-0.35, 0.3, 0.16, 0.82, 0.38, 0.0, -0.24, 0.3),
        (0.15, -0.4, 0.18, 0.64, 0.32, 0.0, 0.3, 0.14),
    )
    for i, (x, y, radius, shaft, tip, base_tip, tilt_x, tilt_y) in enumerate(specs):
        shard = mm.crystal_shaft(
            f"CrystalShard{i}",
            radius=radius,
            shaft_height=shaft,
            tip_height=tip,
            base_tip=base_tip,
            location=(x, y, shaft / 2.0 + base_tip),
            tilt=(tilt_x, tilt_y, 0.0),
            color=CYAN,
            emission=1.6,
            roughness=0.3,
            metallic=0.2,
        )
        if base is None:
            base = shard
    return base  # type: ignore[return-value]


def build_stone_pillar() -> bpy.types.Object:
    body = _cyl("PillarBody", 8, 0.28, 2.4, (0.0, 0.0, 1.25), STONE, 0.0, 0.9, 0.05)
    mm._box("PillarCapital", (0.8, 0.8, 0.22), (0.0, 0.0, 2.55), STONE_DARK, 0.0, 0.9, 0.05)
    mm._box("PillarBase", (0.9, 0.9, 0.28), (0.0, 0.0, 0.14), STONE_DARK, 0.0, 0.9, 0.05)
    return body


def build_broken_pillar() -> bpy.types.Object:
    body = _cyl("BrokenPillarBody", 8, 0.3, 1.4, (0.0, 0.0, 0.7), STONE, 0.0, 0.9, 0.05)
    top = mm._box("BrokenPillarTop", (0.62, 0.62, 0.4), (0.05, 0.1, 1.55), STONE_DARK, 0.0, 0.9, 0.05)
    top.rotation_euler = (0.3, 0.2, 0.0)
    _ico("BrokenPillarRubble", (0.4, 0.35, 0.28), (0.7, 0.3, 0.24), STONE, 0.0, 0.95, 0.05)
    return body


def build_rune_stone() -> bpy.types.Object:
    slab = mm._box("RuneStone", (0.75, 0.32, 1.55), (0.0, 0.0, 0.78), STONE_DARK, 0.0, 0.9, 0.05)
    mm._box("RuneGlyph", (0.3, 0.08, 0.3), (0.0, 0.19, 1.0), CYAN, 2.2, 0.3, 0.2)
    mm._box("RuneGlyph2", (0.12, 0.08, 0.5), (0.0, 0.19, 0.55), CYAN, 2.2, 0.3, 0.2)
    return slab


def build_dungeon_arch() -> bpy.types.Object:
    left = _cyl("ArchLeft", 6, 0.3, 2.8, (-1.4, 0.0, 1.4), STONE, 0.0, 0.9, 0.05)
    _cyl("ArchRight", 6, 0.3, 2.8, (1.4, 0.0, 1.4), STONE, 0.0, 0.9, 0.05)
    _box("ArchTop", (3.6, 0.7, 0.55), (0.0, 0.0, 2.95), STONE_DARK, 0.0, 0.9, 0.05)
    _box("ArchKeystone", (0.6, 0.75, 0.7), (0.0, 0.0, 3.05), GOLD, 0.15, 0.6, 0.4)
    return left


def build_chest() -> bpy.types.Object:
    body = mm._box("ChestBody", (1.2, 0.78, 0.6), (0.0, 0.0, 0.3), WOOD, 0.0, 0.85, 0.05)
    mm._box("ChestLid", (1.28, 0.86, 0.32), (0.0, 0.0, 0.72), WOOD_LIGHT, 0.0, 0.85, 0.05)
    mm._box("ChestBandA", (0.12, 0.84, 0.96), (-0.38, 0.0, 0.48), GOLD, 0.1, 0.5, 0.6)
    mm._box("ChestBandB", (0.12, 0.84, 0.96), (0.38, 0.0, 0.48), GOLD, 0.1, 0.5, 0.6)
    mm._box("ChestLock", (0.24, 0.14, 0.3), (0.0, 0.44, 0.5), GOLD, 0.25, 0.4, 0.7)
    return body


def build_barrel() -> bpy.types.Object:
    body = _cyl("BarrelBody", 10, 0.45, 1.1, (0.0, 0.0, 0.55), WOOD, 0.0, 0.85, 0.05)
    mm._torus("BarrelHoopA", 0.46, 0.05, (0.0, 0.0, 0.2), STEEL_DARK, 0.0, 0.6, 0.6)
    mm._torus("BarrelHoopB", 0.46, 0.05, (0.0, 0.0, 0.9), STEEL_DARK, 0.0, 0.6, 0.6)
    return body


def build_crate() -> bpy.types.Object:
    box = mm._box("Crate", (0.9, 0.9, 0.9), (0.0, 0.0, 0.45), WOOD, 0.0, 0.85, 0.05)
    mm._box("CratePlankA", (0.98, 0.1, 0.1), (0.0, 0.42, 0.85), WOOD_LIGHT, 0.0, 0.85, 0.05)
    mm._box("CratePlankB", (0.1, 0.98, 0.1), (0.42, 0.0, 0.1), WOOD_LIGHT, 0.0, 0.85, 0.05)
    return box


def build_gravestone() -> bpy.types.Object:
    stone = mm._box("Gravestone", (0.7, 0.2, 0.85), (0.0, 0.0, 0.45), STONE, 0.0, 0.95, 0.0)
    top = _cyl("GravestoneTop", 8, 0.35, 0.2, (0.0, 0.0, 0.9), STONE, 0.0, 0.95, 0.0)
    top.rotation_euler = (math.pi / 2.0, 0.0, 0.0)
    mm._box("GravestoneCrossA", (0.5, 0.06, 0.1), (0.0, 0.12, 0.6), STONE_DARK, 0.0, 0.95, 0.0)
    mm._box("GravestoneCrossB", (0.1, 0.06, 0.5), (0.0, 0.12, 0.6), STONE_DARK, 0.0, 0.95, 0.0)
    return stone


def build_portal_gate() -> bpy.types.Object:
    left = _cyl("PortalPillarL", 6, 0.25, 2.6, (-1.3, 0.0, 1.3), STONE_DARK, 0.0, 0.9, 0.05)
    _cyl("PortalPillarR", 6, 0.25, 2.6, (1.3, 0.0, 1.3), STONE_DARK, 0.0, 0.9, 0.05)
    ring = mm._torus("PortalRing", 1.1, 0.16, (0.0, 0.0, 1.5), PURPLE, 2.4, 0.2, 0.3)
    ring.rotation_euler = (math.pi / 2.0, 0.0, 0.0)
    _ico("PortalCore", (0.75, 0.16, 0.75), (0.0, 0.0, 1.5), CYAN, 2.0, 0.1, 0.0)
    return left


def build_torch() -> bpy.types.Object:
    post = _cone("TorchPost", 6, 0.1, 0.14, 1.7, (0.0, 0.0, 0.85), WOOD_DARK, 0.0, 0.9, 0.0)
    _cyl("TorchBasket", 6, 0.2, 0.3, (0.0, 0.0, 1.75), STEEL_DARK, 0.0, 0.6, 0.5)
    _cone("TorchFlame", 6, 0.22, 0.0, 0.6, (0.0, 0.0, 2.15), ORANGE, 2.6, 0.4, 0.0)
    return post


def build_campfire() -> bpy.types.Object:
    base = None
    for i in range(3):
        angle = i * 2.09
        log = _cone(f"CampfireLog{i}", 6, 0.12, 0.12, 1.1, (0.0, 0.0, 0.18), WOOD_DARK, 0.0, 0.95, 0.0)
        log.rotation_euler = (0.0, math.pi / 2.0, angle)
        if base is None:
            base = log
    _cone("CampfireFlame", 6, 0.4, 0.0, 0.9, (0.0, 0.0, 0.6), ORANGE, 2.6, 0.4, 0.0)
    _cone("CampfireFlameCore", 5, 0.22, 0.0, 0.6, (0.0, 0.0, 0.5), GOLD, 2.8, 0.4, 0.0)
    return base


def build_bone_pile() -> bpy.types.Object:
    base = None
    for i in range(4):
        angle = i * 0.9
        bone = _cone(f"Bone{i}", 5, 0.07, 0.07, 0.9, (math.cos(angle) * 0.25, math.sin(angle) * 0.25, 0.16), BONE, 0.0, 0.8, 0.0)
        bone.rotation_euler = (0.2 * (i % 2), math.pi / 2.0, angle)
        if base is None:
            base = bone
    _ico("BoneSkull", (0.28, 0.3, 0.26), (0.0, 0.0, 0.5), BONE, 0.0, 0.8, 0.0)
    return base  # type: ignore[return-value]


def build_skull() -> bpy.types.Object:
    skull = _ico("Skull", (0.4, 0.45, 0.4), (0.0, 0.0, 0.38), BONE, 0.0, 0.8, 0.0)
    mm._box("SkullJaw", (0.32, 0.3, 0.16), (0.0, 0.42, 0.26), BONE, 0.0, 0.8, 0.0)
    _ico("SkullEyeL", (0.1, 0.08, 0.1), (-0.16, 0.34, 0.44), BLACK, 0.0, 0.4, 0.0)
    _ico("SkullEyeR", (0.1, 0.08, 0.1), (0.16, 0.34, 0.44), BLACK, 0.0, 0.4, 0.0)
    return skull


# --- loot / gear ------------------------------------------------------------
def build_sword() -> bpy.types.Object:
    grip = _cyl("SwordGrip", 6, 0.05, 0.34, (0.0, 0.0, 0.17), LEATHER, 0.0, 0.8, 0.0)
    mm._box("SwordGuard", (0.38, 0.1, 0.09), (0.0, 0.0, 0.35), GOLD, 0.1, 0.4, 0.7)
    mm._box("SwordBlade", (0.1, 0.05, 0.95), (0.0, 0.0, 0.9), STEEL, 0.0, 0.3, 0.85)
    tip = _cone("SwordTip", 4, 0.07, 0.0, 0.24, (0.0, 0.0, 1.5), STEEL, 0.0, 0.3, 0.85)
    tip.rotation_euler = (0.0, 0.0, math.pi / 4.0)
    _ico("SwordPommel", (0.08, 0.08, 0.08), (0.0, 0.0, 0.0), GOLD, 0.1, 0.4, 0.7)
    return grip


def build_greatsword() -> bpy.types.Object:
    grip = _cyl("GreatswordGrip", 6, 0.06, 0.5, (0.0, 0.0, 0.25), LEATHER, 0.0, 0.8, 0.0)
    mm._box("GreatswordGuard", (0.6, 0.12, 0.12), (0.0, 0.0, 0.52), GOLD, 0.1, 0.4, 0.7)
    mm._box("GreatswordBlade", (0.16, 0.06, 1.5), (0.0, 0.0, 1.3), STEEL, 0.0, 0.3, 0.85)
    tip = _cone("GreatswordTip", 4, 0.11, 0.0, 0.4, (0.0, 0.0, 2.25), STEEL, 0.0, 0.3, 0.85)
    tip.rotation_euler = (0.0, 0.0, math.pi / 4.0)
    return grip


def build_dagger() -> bpy.types.Object:
    grip = _cyl("DaggerGrip", 6, 0.045, 0.24, (0.0, 0.0, 0.12), LEATHER, 0.0, 0.8, 0.0)
    mm._box("DaggerGuard", (0.26, 0.09, 0.07), (0.0, 0.0, 0.25), GOLD, 0.1, 0.4, 0.7)
    mm._box("DaggerBlade", (0.08, 0.04, 0.62), (0.0, 0.0, 0.6), STEEL, 0.0, 0.3, 0.85)
    tip = _cone("DaggerTip", 4, 0.055, 0.0, 0.18, (0.0, 0.0, 1.0), STEEL, 0.0, 0.3, 0.85)
    tip.rotation_euler = (0.0, 0.0, math.pi / 4.0)
    return grip


def build_axe() -> bpy.types.Object:
    handle = _cone("AxeHandle", 6, 0.06, 0.06, 1.3, (0.0, 0.0, 0.65), WOOD, 0.0, 0.85, 0.0)
    mm._box("AxeHead", (0.12, 0.34, 0.5), (0.0, 0.16, 1.25), STEEL, 0.0, 0.35, 0.8)
    blade = _cone("AxeBlade", 4, 0.3, 0.0, 0.3, (0.0, 0.46, 1.28), STEEL, 0.0, 0.3, 0.85)
    blade.rotation_euler = (math.pi / 2.0, 0.0, 0.0)
    mm._box("AxeSpike", (0.1, 0.1, 0.34), (0.0, -0.16, 1.28), GOLD, 0.1, 0.4, 0.7)
    return handle


def build_staff() -> bpy.types.Object:
    shaft = _cone("StaffShaft", 6, 0.07, 0.07, 1.9, (0.0, 0.0, 0.95), WOOD, 0.0, 0.85, 0.0)
    _ico("StaffOrb", (0.24, 0.24, 0.26), (0.0, 0.0, 2.05), PURPLE, 2.2, 0.3, 0.1)
    mm._torus("StaffClaw", 0.2, 0.04, (0.0, 0.0, 1.88), GOLD, 0.2, 0.4, 0.7)
    return shaft


def build_bow() -> bpy.types.Object:
    bow = mm._torus("BowCurve", 0.6, 0.05, (0.0, 0.0, 0.6), WOOD_LIGHT, 0.0, 0.8, 0.0)
    bow.scale = (1.0, 0.55, 1.0)
    mm._box("BowString", (0.015, 1.06, 0.015), (0.0, 0.0, 0.6), STEEL, 0.0, 0.5, 0.3)
    mm._box("BowGrip", (0.09, 0.09, 0.28), (0.0, -0.32, 0.6), LEATHER, 0.0, 0.85, 0.0)
    return bow


def build_shield() -> bpy.types.Object:
    shield = _ico("Shield", (0.55, 0.14, 0.64), (0.0, 0.0, 0.7), STEEL, 0.0, 0.4, 0.6)
    _ico("ShieldBoss", (0.18, 0.1, 0.18), (0.0, 0.16, 0.7), GOLD, 0.2, 0.4, 0.7)
    mm._torus("ShieldRim", 0.56, 0.05, (0.0, 0.0, 0.7), GOLD, 0.15, 0.4, 0.7)
    return shield


def build_helmet() -> bpy.types.Object:
    helm = _ico("Helmet", (0.34, 0.38, 0.36), (0.0, 0.0, 0.4), STEEL, 0.0, 0.35, 0.7)
    mm._box("HelmetVisor", (0.36, 0.1, 0.08), (0.0, 0.32, 0.42), BLACK, 0.0, 0.4, 0.3)
    crest = _cone("HelmetCrest", 4, 0.09, 0.0, 0.4, (0.0, -0.02, 0.72), RED, 0.15, 0.7, 0.0)
    crest.rotation_euler = (-0.4, 0.0, 0.0)
    return helm


def build_armor() -> bpy.types.Object:
    torso = mm._box("ArmorTorso", (0.8, 0.5, 0.85), (0.0, 0.0, 0.9), STEEL, 0.0, 0.4, 0.65)
    mm._box("ArmorChest", (0.5, 0.16, 0.4), (0.0, 0.28, 1.0), GOLD, 0.2, 0.4, 0.6)
    _ico("ArmorShoulderL", (0.34, 0.36, 0.26), (-0.55, 0.0, 1.25), STEEL, 0.0, 0.4, 0.65)
    _ico("ArmorShoulderR", (0.34, 0.36, 0.26), (0.55, 0.0, 1.25), STEEL, 0.0, 0.4, 0.65)
    return torso


def build_boots() -> bpy.types.Object:
    left = mm._box("BootLeft", (0.32, 0.5, 0.3), (-0.24, 0.02, 0.16), STEEL_DARK, 0.0, 0.5, 0.4)
    mm._box("BootLeftShin", (0.3, 0.3, 0.5), (-0.24, 0.0, 0.5), STEEL_DARK, 0.0, 0.5, 0.4)
    mm._box("BootRight", (0.32, 0.5, 0.3), (0.24, 0.02, 0.16), STEEL_DARK, 0.0, 0.5, 0.4)
    mm._box("BootRightShin", (0.3, 0.3, 0.5), (0.24, 0.0, 0.5), STEEL_DARK, 0.0, 0.5, 0.4)
    return left


def build_crown() -> bpy.types.Object:
    band = mm._torus("CrownBand", 0.34, 0.08, (0.0, 0.0, 0.3), GOLD, 0.5, 0.35, 0.8)
    for i in range(6):
        angle = i * math.pi / 3.0
        _cone(f"CrownSpike{i}", 4, 0.06, 0.0, 0.26, (math.cos(angle) * 0.34, math.sin(angle) * 0.34, 0.48), GOLD, 0.5, 0.35, 0.8)
    _ico("CrownGem", (0.09, 0.09, 0.09), (0.0, 0.34, 0.36), RED, 1.6, 0.2, 0.2)
    return band


def build_ring() -> bpy.types.Object:
    band = mm._torus("RingBand", 0.24, 0.05, (0.0, 0.0, 0.24), GOLD, 0.4, 0.35, 0.8)
    _ico("RingGem", (0.1, 0.1, 0.12), (0.0, 0.0, 0.5), CYAN, 2.0, 0.2, 0.2)
    return band


def build_amulet() -> bpy.types.Object:
    chain = mm._torus("AmuletChain", 0.4, 0.035, (0.0, 0.0, 0.75), GOLD, 0.3, 0.35, 0.8)
    chain.rotation_euler = (math.pi / 2.0, 0.0, 0.0)
    _ico("AmuletPendant", (0.2, 0.12, 0.26), (0.0, 0.0, 0.35), PURPLE, 1.8, 0.25, 0.2)
    return chain


def build_potion_health() -> bpy.types.Object:
    body = _ico("PotionHealth", (0.28, 0.28, 0.36), (0.0, 0.0, 0.36), RED, 1.0, 0.2, 0.1)
    _cyl("PotionHealthNeck", 6, 0.1, 0.2, (0.0, 0.0, 0.68), WHITE, 0.2, 0.2, 0.1)
    _cyl("PotionHealthCork", 6, 0.11, 0.12, (0.0, 0.0, 0.82), WOOD, 0.0, 0.8, 0.0)
    return body


def build_potion_mana() -> bpy.types.Object:
    body = _ico("PotionMana", (0.28, 0.28, 0.36), (0.0, 0.0, 0.36), BLUE, 1.2, 0.2, 0.1)
    _cyl("PotionManaNeck", 6, 0.1, 0.2, (0.0, 0.0, 0.68), WHITE, 0.2, 0.2, 0.1)
    _cyl("PotionManaCork", 6, 0.11, 0.12, (0.0, 0.0, 0.82), WOOD, 0.0, 0.8, 0.0)
    return body


def build_scroll() -> bpy.types.Object:
    scroll = _cyl("Scroll", 8, 0.1, 0.8, (0.0, 0.0, 0.5), WOOD_LIGHT, 0.0, 0.85, 0.0)
    scroll.rotation_euler = (0.0, math.pi / 2.0, 0.0)
    _ico("ScrollSeal", (0.1, 0.1, 0.1), (0.0, 0.0, 0.5), RED, 0.4, 0.4, 0.2)
    mm._box("ScrollRibbon", (0.08, 0.34, 0.08), (0.0, 0.0, 0.5), RED, 0.3, 0.6, 0.1)
    return scroll


def build_key() -> bpy.types.Object:
    ring = mm._torus("KeyRing", 0.2, 0.05, (0.0, 0.0, 0.85), GOLD, 0.3, 0.35, 0.8)
    _cyl("KeyShaft", 6, 0.05, 0.6, (0.0, 0.0, 0.45), GOLD, 0.3, 0.35, 0.8)
    mm._box("KeyBitA", (0.22, 0.06, 0.08), (0.08, 0.0, 0.2), GOLD, 0.3, 0.35, 0.8)
    mm._box("KeyBitB", (0.08, 0.06, 0.16), (0.16, 0.0, 0.28), GOLD, 0.3, 0.35, 0.8)
    return ring


def build_coin() -> bpy.types.Object:
    coin = _cyl("Coin", 12, 0.3, 0.08, (0.0, 0.0, 0.3), GOLD, 0.6, 0.3, 0.85)
    coin.rotation_euler = (math.pi / 2.0, 0.0, 0.0)
    _ico("CoinStar", (0.14, 0.08, 0.14), (0.0, 0.05, 0.3), GOLD, 0.9, 0.25, 0.9)
    return coin


def build_gem() -> bpy.types.Object:
    gem = _ico("Gem", (0.28, 0.28, 0.36), (0.0, 0.0, 0.36), CYAN, 2.0, 0.2, 0.2)
    mm._box("GemGirdle", (0.5, 0.5, 0.06), (0.0, 0.0, 0.36), CYAN, 1.4, 0.2, 0.2)
    return gem


# --- registry ---------------------------------------------------------------
BUILDERS: dict[str, object] = {
    "knight": build_knight,
    "pine_tree": build_pine_tree,
    "dead_tree": build_dead_tree,
    "bush": build_bush,
    "grass_tuft": build_grass_tuft,
    "mushroom": build_mushroom,
    "rock_small": build_rock_small,
    "rock_large": build_rock_large,
    "stalagmite": build_stalagmite,
    "crystal_cluster": build_crystal_cluster,
    "stone_pillar": build_stone_pillar,
    "broken_pillar": build_broken_pillar,
    "rune_stone": build_rune_stone,
    "dungeon_arch": build_dungeon_arch,
    "chest": build_chest,
    "barrel": build_barrel,
    "crate": build_crate,
    "gravestone": build_gravestone,
    "portal_gate": build_portal_gate,
    "torch": build_torch,
    "campfire": build_campfire,
    "bone_pile": build_bone_pile,
    "skull": build_skull,
    "sword": build_sword,
    "greatsword": build_greatsword,
    "dagger": build_dagger,
    "axe": build_axe,
    "staff": build_staff,
    "bow": build_bow,
    "shield": build_shield,
    "helmet": build_helmet,
    "armor": build_armor,
    "boots": build_boots,
    "crown": build_crown,
    "ring": build_ring,
    "amulet": build_amulet,
    "potion_health": build_potion_health,
    "potion_mana": build_potion_mana,
    "scroll": build_scroll,
    "key": build_key,
    "coin": build_coin,
    "gem": build_gem,
}

for _name, _cfg in DRAGON_VARIANTS:
    BUILDERS[_name] = (lambda cfg=_cfg: build_dragon(**cfg))  # type: ignore[assignment]


def parse_args() -> argparse.Namespace:
    argv = sys.argv
    argv = argv[argv.index("--") + 1 :] if "--" in argv else []
    parser = argparse.ArgumentParser(description="Generate the dragon-RPG mesh pack.")
    parser.add_argument("--out-dir", default="public/assets/rpg", help="output directory for the .glb files")
    parser.add_argument("--only", default="", help="comma-separated asset names (default: all)")
    return parser.parse_args(argv)


def main() -> None:
    args = parse_args()
    out_dir = os.path.abspath(args.out_dir)
    os.makedirs(out_dir, exist_ok=True)
    if args.only:
        names = [name.strip() for name in args.only.split(",") if name.strip()]
    else:
        names = list(BUILDERS)
    for name in names:
        builder = BUILDERS.get(name)
        if builder is None:
            raise SystemExit(f"unknown asset '{name}' (known: {', '.join(sorted(BUILDERS))})")
        mm.reset_scene()
        builder()  # type: ignore[operator]
        path = os.path.join(out_dir, f"{name}.glb")
        bpy.ops.export_scene.gltf(filepath=path, export_format="GLB")
        print(f"[blender] wrote {path}")
    print(f"[blender] generated {len(names)} asset(s) into {out_dir}")


if __name__ == "__main__":
    main()
