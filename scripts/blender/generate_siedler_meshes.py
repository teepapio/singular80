"""Headless Blender generator for the "Siedler 3D" mesh pack.

Produces the low-poly ``.glb`` collection of the *Die Siedler* homage in
``godot/src/core/logic/siedler.gd`` (production buildings, the castle, road
flags, the little settlers and the resource nodes) in a single Blender run,
reusing the primitive helpers from ``make_mesh.py``.

Usage::

    blender --background --python scripts/blender/generate_siedler_meshes.py
    blender --background --python scripts/blender/generate_siedler_meshes.py -- --only castle,flag

Meshes land in ``godot/assets/meshes/siedler`` and are registered in
``AssetRegistry.KEYS`` (see AGENTS.md). Keep every mesh low-poly — it protects
the APK size and every mobile GPU.

Nodes that the screen animates are named so it can find them:

* ``WindmillSails`` — empty the scene spins on the windmill
* ``ForgeGlow`` / ``SmelterGlow`` — emissive, brightens while working
* ``SettlerArmL`` / ``SettlerArmR`` / ``SettlerLegL`` / ``SettlerLegR`` — walk cycle
* ``FlagCloth`` — the flag banner
"""

from __future__ import annotations

import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy  # noqa: E402
from mathutils import Matrix  # noqa: E402

import make_mesh as mm  # noqa: E402

# --- palette (late-medieval village) ----------------------------------------
WOOD = (0.40, 0.26, 0.14, 1.0)
WOOD_DARK = (0.24, 0.15, 0.08, 1.0)
WOOD_LIGHT = (0.58, 0.42, 0.24, 1.0)
PLASTER = (0.86, 0.82, 0.71, 1.0)
PLASTER_DIRTY = (0.72, 0.68, 0.58, 1.0)
THATCH = (0.66, 0.52, 0.24, 1.0)
STONE = (0.52, 0.52, 0.55, 1.0)
STONE_DARK = (0.33, 0.34, 0.38, 1.0)
SLATE = (0.28, 0.30, 0.36, 1.0)
IRON = (0.55, 0.58, 0.63, 1.0)
IRON_DARK = (0.30, 0.33, 0.38, 1.0)
GOLD = (0.95, 0.76, 0.22, 1.0)
COPPER = (0.35, 0.62, 0.52, 1.0)
COAL = (0.11, 0.11, 0.13, 1.0)
WHEAT = (0.85, 0.70, 0.30, 1.0)
WHEAT_DARK = (0.66, 0.52, 0.20, 1.0)
LEAF = (0.24, 0.52, 0.22, 1.0)
LEAF_DARK = (0.14, 0.36, 0.15, 1.0)
CLAY = (0.52, 0.34, 0.22, 1.0)
WATER = (0.22, 0.48, 0.68, 1.0)
BREAD = (0.78, 0.58, 0.30, 1.0)
SKIN = (0.88, 0.72, 0.58, 1.0)
TUNIC = (0.72, 0.24, 0.20, 1.0)
BRIBE = (0.35, 0.42, 0.68, 1.0)
RUST = (0.60, 0.32, 0.14, 1.0)
GREEN_LIGHT = (0.42, 0.68, 0.28, 1.0)
LEATHER_DARK = (0.28, 0.18, 0.10, 1.0)
GLASS = (0.55, 0.78, 0.85, 1.0)
ORANGE_HOT = (1.0, 0.45, 0.08, 1.0)

# --- primitive helpers ------------------------------------------------------
_ico = mm._ico
_box = mm._box
_cone = mm._cone
_torus = mm._torus
# One roof primitive for the whole gallery. This pack used to keep its own
# `_gabled_roof`, which had the two slab rotations the other way round from
# `mm.gable_roof` — measured 2026-10-02 on this file's KeepRoof, its left slab
# ran from z=2.809 down to z=2.271 towards the middle, so the two slabs met in
# a **valley** and the keep, the cottages and the warehouse all wore an
# inverted butterfly. See the sign note in `mm.gable_roof`.
gable_roof = mm.gable_roof


def _cyl(
    name: str,
    vertices: int,
    radius: float,
    depth: float,
    location: tuple[float, float, float],
    color: tuple[float, float, float, float],
    emission: float = 0.0,
    roughness: float = 0.6,
    metallic: float = 0.05,
) -> bpy.types.Object:
    return mm._cone(name, vertices, radius, radius, depth, location, color, emission, roughness, metallic)


def _pivot_box(
    name: str,
    size: tuple[float, float, float],
    offset: tuple[float, float, float],
    location: tuple[float, float, float],
    color: tuple[float, float, float, float],
    emission: float = 0.0,
    roughness: float = 0.6,
    metallic: float = 0.05,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    """A box whose pivot sits at ``location`` (mesh offset by ``offset``)."""
    obj = mm._box(name, size, (0.0, 0.0, 0.0), color, emission, roughness, metallic)
    obj.data.transform(Matrix.Translation(offset))
    obj.location = location
    obj.rotation_euler = rotation
    return obj


# --- the castle (headquarters) ----------------------------------------------
def build_castle() -> bpy.types.Object:
    """Burg: stone keep with corner towers, a gate and a banner."""
    # Curtain wall base.
    _box("KeepBase", (3.0, 2.6, 0.5), (0.0, 0.0, 0.25), STONE_DARK, 0.0, 0.85)
    _box("KeepBody", (2.4, 2.1, 1.5), (0.0, 0.0, 1.25), STONE, 0.0, 0.8)
    # Crenellations.
    for i in range(5):
        x = -0.96 + i * 0.48
        _box(f"Merlon{i}", (0.26, 2.14, 0.24), (x, 0.0, 2.12), STONE, 0.0, 0.85)
    # Corner towers.
    for sx in (-1.0, 1.0):
        for sy in (-0.86, 0.86):
            _cyl(f"Tower{sx}{sy}", 8, 0.34, 2.1, (sx * 1.32, sy * 1.12, 1.05), STONE, 0.0, 0.8)
            _cone(f"TowerRoof{sx}{sy}", 8, 0.42, 0.0, 0.5, (sx * 1.32, sy * 1.12, 2.35), SLATE, 0.0, 0.6)
    # Gate with portcullis.
    _box("GateFrame", (0.62, 0.3, 0.95), (0.0, -1.06, 0.72), STONE_DARK, 0.0, 0.85)
    _box("GateDoor", (0.5, 0.12, 0.8), (0.0, -1.16, 0.62), WOOD_DARK, 0.0, 0.7)
    # Keep roof + banner.
    gable_roof("KeepRoof", 2.4, 2.1, 0.6, (0.0, 0.0, 2.24), SLATE)
    _cyl("BannerPole", 6, 0.045, 1.5, (0.0, 0.0, 3.3), WOOD_DARK, 0.0, 0.6)
    _box("Banner", (0.06, 0.5, 0.34), (0.0, 0.26, 3.85), TUNIC, 0.35, 0.6)
    return bpy.context.active_object


# --- road flag (Fahne) ------------------------------------------------------
def build_flag() -> bpy.types.Object:
    """The turquoise waypoint flag — a transport hub between two road ends."""
    _cyl("FlagPole", 6, 0.05, 1.5, (0.0, 0.0, 0.75), WOOD_LIGHT, 0.0, 0.6)
    _cyl("FlagBase", 8, 0.16, 0.1, (0.0, 0.0, 0.05), STONE_DARK, 0.0, 0.8)
    _ico("FlagKnob", (0.07, 0.07, 0.07), (0.0, 0.0, 1.53), GOLD, 0.3, 0.25, 0.6)
    cloth = _box("FlagCloth", (0.05, 0.42, 0.3), (0.0, 0.22, 1.22), COPPER, 0.55, 0.5, 0.05)
    cloth.rotation_euler = (0.0, 0.0, 0.0)
    return cloth


# --- the little serf (Siedler) ----------------------------------------------
def _serf_body(name_prefix: str, tunic: tuple[float, float, float, float]) -> bpy.types.Object:
    """Shared humanoid used for the walking settler and the garrison knight."""
    # Legs pivot at the hip so the scene can swing them.
    _pivot_box(f"{name_prefix}LegL", (0.13, 0.15, 0.4), (0.0, 0.0, -0.2), (-0.11, 0.0, 0.42), WOOD_DARK)
    _pivot_box(f"{name_prefix}LegR", (0.13, 0.15, 0.4), (0.0, 0.0, -0.2), (0.11, 0.0, 0.42), WOOD_DARK)
    # Torso / tunic.
    _box(f"{name_prefix}Torso", (0.42, 0.26, 0.4), (0.0, 0.0, 0.82), tunic, 0.0, 0.75)
    _box(f"{name_prefix}Belt", (0.44, 0.28, 0.08), (0.0, 0.0, 0.63), LEATHER_DARK, 0.0, 0.7)
    # Arms pivot at the shoulder.
    _pivot_box(f"{name_prefix}ArmL", (0.1, 0.12, 0.34), (0.0, 0.0, -0.17), (-0.24, 0.0, 0.98), tunic, 0.0, 0.75)
    _pivot_box(f"{name_prefix}ArmR", (0.1, 0.12, 0.34), (0.0, 0.0, -0.17), (0.24, 0.0, 0.98), tunic, 0.0, 0.75)
    # Head.
    _ico(f"{name_prefix}Head", (0.15, 0.14, 0.16), (0.0, 0.0, 1.14), SKIN, 0.0, 0.7)
    _cone(f"{name_prefix}Cap", 6, 0.17, 0.0, 0.14, (0.0, 0.0, 1.3), tunic, 0.0, 0.7)
    return bpy.context.active_object


def build_settler() -> bpy.types.Object:
    """Träger: a settler who walks the roads and carries one item at a time."""
    return _serf_body("Settler", TUNIC)


def build_knight() -> bpy.types.Object:
    """Gefreiter: a settler upgraded with sword and shield."""
    obj = _serf_body("Settler", IRON)
    # Helmet, shield on the left arm, sword in the right hand.
    _ico("Helmet", (0.17, 0.16, 0.14), (0.0, 0.0, 1.22), IRON, 0.0, 0.3, 0.7)
    _cyl("SwordBlade", 4, 0.035, 0.62, (0.0, 0.0, 0.0), IRON, 0.0, 0.25, 0.8)
    blade = bpy.context.active_object
    blade.location = (0.3, 0.02, 0.78)
    blade.rotation_euler = (0.35, 0.0, 0.0)
    _box("SwordGuard", (0.16, 0.07, 0.05), (0.3, 0.02, 0.5), GOLD, 0.0, 0.3, 0.7)
    _cyl("ShieldBoss", 8, 0.24, 0.07, (0.0, 0.0, 0.0), IRON_DARK, 0.0, 0.4, 0.6)
    shield = bpy.context.active_object
    shield.location = (-0.33, -0.06, 0.86)
    shield.rotation_euler = (1.4, 0.0, 0.2)
    _ico("ShieldEmblem", (0.09, 0.03, 0.09), (-0.33, -0.12, 0.86), GOLD, 0.25, 0.3, 0.7)
    return obj


# --- production buildings ---------------------------------------------------
def _cottage(
    name: str,
    w: float,
    d: float,
    h: float,
    roof_color: tuple[float, float, float, float],
    wall: tuple[float, float, float, float] = PLASTER,
) -> None:
    """Small half-timbered house: plastered box, beams, gabled roof."""
    _box(f"{name}Wall", (w, d, h), (0.0, 0.0, h * 0.5), wall, 0.0, 0.85)
    # Corner posts + a mid rail give the timber-frame read.
    for sx in (-1, 1):
        for sy in (-1, 1):
            _box(
                f"{name}Post{sx}{sy}",
                (0.09, 0.09, h),
                (sx * (w * 0.5 - 0.05), sy * (d * 0.5 - 0.05), h * 0.5),
                WOOD_DARK,
                0.0,
                0.8,
            )
    _box(f"{name}Rail", (w + 0.02, d + 0.02, 0.08), (0.0, 0.0, h * 0.52), WOOD_DARK, 0.0, 0.8)
    gable_roof(f"{name}Roof", w + 0.16, d + 0.16, 0.42, (0.0, 0.0, h), roof_color)
    _box(f"{name}Door", (0.24, 0.08, 0.5), (0.0, -d * 0.5 - 0.02, 0.25), WOOD_DARK, 0.0, 0.7)
    _box(f"{name}Window", (0.2, 0.06, 0.2), (w * 0.28, -d * 0.5 - 0.02, h * 0.68), GLASS, 0.3, 0.4)
    _box(f"{name}Window2", (0.2, 0.06, 0.2), (-w * 0.28, -d * 0.5 - 0.02, h * 0.68), GLASS, 0.3, 0.4)



def build_woodcutter() -> bpy.types.Object:
    """Holzfäller: lumberjack's hut beside a stack of logs and a chopped stump."""
    _cottage("Woodcutter", 1.5, 1.3, 0.95, THATCH)
    for i in range(3):
        _cyl(f"LogStack{i}", 7, 0.17, 1.1, (0.95 + i * 0.03, 0.3, 0.17 + i * 0.32), WOOD, 0.0, 0.85)
        _cyl(f"LogStack{i}Rot", 7, 0.17, 1.1, (0.95 + i * 0.03, 0.3, 0.17 + i * 0.32), WOOD_LIGHT, 0.0, 0.85)
        bpy.context.active_object.rotation_euler = (1.5708, 0.0, 0.0)
    # Chopped stump with an axe buried in it.
    _cyl("Stump", 8, 0.22, 0.3, (-0.95, -0.45, 0.15), WOOD_DARK, 0.0, 0.9)
    _box("AxeHandle", (0.05, 0.05, 0.5), (-0.95, -0.45, 0.5), WOOD_LIGHT, 0.0, 0.7)
    _box("AxeHead", (0.1, 0.16, 0.2), (-0.95, -0.45, 0.76), IRON, 0.0, 0.3, 0.7)
    return bpy.context.active_object


def build_forester() -> bpy.types.Object:
    """Förster: the forester plants saplings, so a nursery of young trees."""
    _cottage("Forester", 1.3, 1.2, 0.9, THATCH, WOOD_LIGHT)
    for i, (x, z) in enumerate(((-0.9, 0.7), (-0.2, 0.95), (0.55, 0.75))):
        _cyl(f"SaplingTrunk{i}", 6, 0.06, 0.4, (x, z, 0.2), WOOD_DARK, 0.0, 0.8)
        _ico(f"SaplingCrown{i}", (0.24, 0.24, 0.3), (x, z, 0.5), LEAF, 0.0, 0.85)
    _box("Spade", (0.06, 0.06, 0.6), (0.9, -0.5, 0.3), WOOD_LIGHT, 0.0, 0.7)
    return bpy.context.active_object


def build_sawmill() -> bpy.types.Object:
    """Schreiner: sawmill with an open shed, a saw blade and stacked planks."""
    _cottage("Sawmill", 1.6, 1.4, 0.9, SLATE, WOOD)
    # Open-sided saw shed on the flank.
    _box("ShedFloor", (1.1, 0.9, 0.08), (1.1, 0.1, 0.04), WOOD_DARK, 0.0, 0.9)
    for tag, sx in (("L", -0.5), ("R", 0.5)):
        _box(f"ShedPost{tag}", (0.08, 0.08, 0.9), (1.1 + sx, 0.1, 0.49), WOOD_DARK, 0.0, 0.8)
    gable_roof("ShedRoof", 1.2, 1.0, 0.3, (1.1, 0.1, 0.94), THATCH)
    # Vertical saw blade.
    _cyl("SawBlade", 10, 0.34, 0.06, (1.1, 0.1, 0.62), IRON, 0.0, 0.25, 0.8, )
    bpy.context.active_object.rotation_euler = (0.0, 1.5708, 0.0)
    # Plank stack.
    for i in range(4):
        _box(f"Plank{i}", (1.2, 0.16, 0.07), (-1.05, 0.5, 0.06 + i * 0.08), WOOD_LIGHT, 0.0, 0.8)
    return bpy.context.active_object


def build_quarry() -> bpy.types.Object:
    """Steinmetz / Steinmine: a cut into the hillside with dressed blocks."""
    # Rock face behind the working yard.
    _ico("QuarryFace", (1.1, 0.5, 0.85), (0.0, 0.95, 0.5), STONE_DARK, 0.0, 0.95)
    _ico("QuarryFace2", (0.7, 0.45, 0.55), (-0.75, 0.9, 0.35), STONE, 0.0, 0.95)
    # Dressed building blocks.
    for i in range(3):
        _box(f"Block{i}", (0.42, 0.42, 0.3), (-0.85 + i * 0.5, -0.6, 0.15 + (i % 2) * 0.3), STONE, 0.0, 0.9)
    # Pit prop frame and a pick leaning on it.
    _box("PitFrameL", (0.1, 0.1, 1.0), (0.7, -0.1, 0.5), WOOD_DARK, 0.0, 0.8)
    _box("PitFrameR", (0.1, 0.1, 1.0), (1.15, -0.1, 0.5), WOOD_DARK, 0.0, 0.8)
    _box("PitFrameTop", (0.65, 0.1, 0.1), (0.92, -0.1, 1.0), WOOD_DARK, 0.0, 0.8)
    _box("PickHandle", (0.05, 0.05, 0.8), (0.55, -0.2, 0.4), WOOD_LIGHT, 0.0, 0.7)
    _box("PickHead", (0.34, 0.08, 0.1), (0.55, -0.2, 0.8), IRON, 0.0, 0.3, 0.7)
    return bpy.context.active_object


def _mine_head(
    name: str,
    ore_color: tuple[float, float, float, float],
    spoil: tuple[float, float, float, float],
) -> bpy.types.Object:
    """Shared mine: winding frame over a shaft, ore cart and a spoil heap."""
    # Winding frame (headframe) — two legs, a cross beam and a wheel.
    _box(f"{name}LegL", (0.09, 0.09, 1.3), (-0.45, 0.0, 0.65), WOOD_DARK, 0.0, 0.85)
    _box(f"{name}LegR", (0.09, 0.09, 1.3), (0.45, 0.0, 0.65), WOOD_DARK, 0.0, 0.85)
    _box(f"{name}Top", (1.1, 0.12, 0.12), (0.0, 0.0, 1.32), WOOD_DARK, 0.0, 0.85)
    _torus(f"{name}Wheel", 0.26, 0.06, (0.0, 0.12, 1.32), IRON_DARK, 0.0, 0.4, 0.6)
    bpy.context.active_object.rotation_euler = (1.5708, 0.0, 0.0)
    # Shaft mouth.
    _box(f"{name}Shaft", (0.7, 0.7, 0.1), (0.0, 0.0, 0.05), COAL, 0.0, 0.95)
    # Ore cart on rails.
    _box(f"{name}Cart", (0.5, 0.42, 0.3), (0.85, -0.5, 0.22), WOOD, 0.0, 0.8)
    _ico(f"{name}CartOre", (0.22, 0.18, 0.12), (0.85, -0.5, 0.4), ore_color, 0.0, 0.85)
    for i in range(2):
        _cyl(f"{name}Wheel{i}", 8, 0.1, 0.06, (0.85 + (i - 0.5) * 0.34, -0.5, 0.1), IRON_DARK, 0.0, 0.4, 0.6)
        bpy.context.active_object.rotation_euler = (0.0, 1.5708, 0.0)
    # Spoil heap.
    _ico(f"{name}Spoil", (0.55, 0.4, 0.3), (-0.95, -0.4, 0.2), spoil, 0.0, 0.95)
    return bpy.context.active_object


def build_coal_mine() -> bpy.types.Object:
    """Kohlemine: coal pit with a black spoil heap."""
    return _mine_head("CoalMine", COAL, COAL)


def build_iron_mine() -> bpy.types.Object:
    """Eisenmine: iron pit with a rust-red spoil heap."""
    return _mine_head("IronMine", RUST, RUST)


def build_gold_mine() -> bpy.types.Object:
    """Goldmine: gold pit with a glittering spoil heap."""
    return _mine_head("GoldMine", GOLD, GOLD)


def build_farm() -> bpy.types.Object:
    """Getreidefarm: a fenced grain field with a small hut on the edge."""
    # Tilled field rows.
    for i in range(7):
        _box(f"Furrow{i}", (0.14, 2.1, 0.1), (-0.7 + i * 0.23, 0.0, 0.05), CLAY, 0.0, 0.95)
        # Wheat ears.
        _ico(f"Wheat{i}", (0.11, 2.0, 0.16), (-0.7 + i * 0.23, 0.0, 0.19), WHEAT if i % 2 == 0 else WHEAT_DARK, 0.0, 0.9)
    # Fence.
    for i in range(9):
        _box(f"FencePost{i}", (0.07, 0.07, 0.42), (-0.9 + i * 0.22, -1.15, 0.21), WOOD_LIGHT, 0.0, 0.8)
    _box("FenceRail", (2.0, 0.05, 0.05), (0.0, -1.15, 0.34), WOOD_LIGHT, 0.0, 0.8)
    # Farmer's hut.
    _cottage("FarmHut", 0.9, 0.85, 0.7, THATCH, PLASTER_DIRTY)
    bpy.context.active_object.location = (0.0, 0.0, 0.0)
    _box("Scythe", (0.05, 0.05, 0.6), (0.55, -0.8, 0.3), WOOD_LIGHT, 0.0, 0.7)
    _box("ScytheBlade", (0.3, 0.05, 0.06), (0.62, -0.8, 0.6), IRON, 0.0, 0.3, 0.7)
    return bpy.context.active_object


def build_windmill() -> bpy.types.Object:
    """Windmühle: a round mill tower whose sails the scene rotates."""
    _cyl("MillTower", 10, 0.62, 1.9, (0.0, 0.0, 0.95), PLASTER, 0.0, 0.85)
    _cone("MillRoof", 10, 0.72, 0.0, 0.55, (0.0, 0.0, 2.15), THATCH, 0.0, 0.8)
    _box("MillDoor", (0.26, 0.1, 0.55), (0.0, -0.6, 0.28), WOOD_DARK, 0.0, 0.75)
    _box("MillWindow", (0.18, 0.08, 0.22), (0.34, -0.5, 1.15), GLASS, 0.3, 0.4)
    # Sails on a hub facing +Z. Arms and cloth are parented to an empty called
    # `WindmillSails` so the scene can spin the whole assembly by one rotation.
    hub = _cyl("MillHub", 8, 0.12, 0.2, (0.0, 0.0, 1.55), WOOD_DARK, 0.0, 0.7)
    hub.rotation_euler = (1.5708, 0.0, 0.0)
    sails_root = bpy.data.objects.new("WindmillSails", None)
    sails_root.empty_display_size = 0.2
    sails_root.location = (0.0, 0.0, 1.62)
    bpy.context.scene.collection.objects.link(sails_root)
    rig: list[bpy.types.Object] = [hub]
    for i in range(4):
        angle = i * math.pi / 2.0
        arm = _box(f"MillArm{i}", (0.09, 1.25, 0.07), (0.0, 0.0, 0.0), WOOD_DARK, 0.0, 0.75)
        arm.location = (0.0, 0.62, 1.62)
        arm.rotation_euler = (0.0, 0.0, angle)
        # Sail cloth on the far half of each arm.
        sail = _box(f"MillSail{i}", (0.05, 0.85, 0.5), (0.0, 0.0, 0.0), PLASTER, 0.0, 0.9)
        sail.location = (
            -math.sin(angle) * 0.95,
            math.cos(angle) * 0.95,
            1.62,
        )
        sail.rotation_euler = (0.0, 0.0, angle)
        rig.append(arm)
        rig.append(sail)
    # Parenting after the fact keeps every world transform intact.
    for part in rig:
        part.parent = sails_root
        part.matrix_parent_inverse = sails_root.matrix_world.inverted()
    # Grain sacks by the door.
    _ico("Sack1", (0.2, 0.2, 0.22), (-0.55, -0.5, 0.2), BREAD, 0.0, 0.9)
    _ico("Sack2", (0.18, 0.18, 0.2), (-0.25, -0.55, 0.18), WHEAT, 0.0, 0.9)
    return bpy.context.active_object


def build_bakery() -> bpy.types.Object:
    """Bäckerei: an oven house with a stone dome and a bread counter."""
    _cottage("Bakery", 1.5, 1.3, 0.95, THATCH)
    # Bread oven bulging out of the gable.
    _ico("Oven", (0.62, 0.62, 0.5), (0.0, -0.85, 0.3), STONE_DARK, 0.0, 0.9)
    _box("OvenMouth", (0.3, 0.1, 0.24), (0.0, -1.42, 0.28), COAL, 1.6, 0.6)
    _cyl("OvenStack", 6, 0.11, 0.5, (0.0, -0.85, 0.85), STONE_DARK, 0.0, 0.9)
    # Loaves on the counter.
    for i in range(3):
        _ico(f"Loaf{i}", (0.14, 0.1, 0.09), (-0.45 + i * 0.28, -0.72, 0.62), BREAD, 0.0, 0.85)
    return bpy.context.active_object


def build_fishery() -> bpy.types.Object:
    """Fischerhütte: a hut on stilts over the water, with nets and a boat."""
    for sx in (-0.5, 0.5):
        for sy in (-0.4, 0.4):
            _box(f"Pile{sx}{sy}", (0.09, 0.09, 0.9), (sx, sy, 0.45), WOOD_DARK, 0.0, 0.85)
    _box("Deck", (1.4, 1.1, 0.1), (0.0, 0.0, 0.9), WOOD, 0.0, 0.85)
    _cottage("FisherHut", 1.1, 1.0, 0.8, THATCH)
    for obj in bpy.data.objects:
        if obj.name.startswith("FisherHut") or obj.name.startswith("Merlon"):
            obj.location.z += 0.95
    # Drying net and a rod.
    _box("Net", (0.06, 0.5, 0.4), (-0.75, 0.0, 1.1), PLASTER, 0.0, 0.9)
    _box("Rod", (0.04, 0.04, 1.1), (0.7, 0.0, 1.4), WOOD_LIGHT, 0.0, 0.7)
    # Little rowing boat moored alongside.
    _ico("Boat", (0.45, 0.2, 0.14), (0.0, -0.95, 0.2), WOOD_LIGHT, 0.0, 0.8)
    _box("BoatRim", (0.8, 0.36, 0.05), (0.0, -0.95, 0.24), WOOD_DARK, 0.0, 0.8)
    # A catch of fish on the deck.
    for i in range(2):
        _ico(f"Fish{i}", (0.18, 0.07, 0.05), (-0.3 + i * 0.4, 0.4, 0.98), WATER, 0.0, 0.5, 0.3)
    return bpy.context.active_object


def build_smelter() -> bpy.types.Object:
    """Schmelze: a stone bloomery whose glow brightens while it works."""
    _cyl("SmelterBase", 8, 0.7, 0.9, (0.0, 0.0, 0.45), STONE_DARK, 0.0, 0.9)
    _cyl("SmelterBody", 8, 0.5, 0.7, (0.0, 0.0, 1.25), STONE, 0.0, 0.85)
    _cone("SmelterRoof", 8, 0.6, 0.18, 0.4, (0.0, 0.0, 1.8), SLATE, 0.0, 0.7)
    _cyl("SmelterStack", 6, 0.14, 1.1, (0.0, 0.45, 1.5), STONE_DARK, 0.0, 0.9)
    # Tapping spout with a glowing bloom below.
    _box("TappingSpout", (0.3, 0.1, 0.08), (0.0, -0.6, 0.7), IRON_DARK, 0.0, 0.5, 0.5)
    glow = _ico("SmelterGlow", (0.34, 0.3, 0.12), (0.0, -0.72, 0.16), ORANGE_HOT, 2.4, 0.5)
    _ico("Bloom", (0.2, 0.18, 0.12), (0.0, -0.72, 0.2), ORANGE_HOT, 3.0, 0.4)
    # Charcoal heap and a pair of bellows.
    _ico("CharcoalHeap", (0.4, 0.32, 0.2), (0.75, 0.2, 0.15), COAL, 0.0, 0.95)
    _box("Bellows", (0.34, 0.22, 0.2), (-0.75, -0.3, 0.5), LEATHER_DARK, 0.0, 0.9)
    return glow



def build_toolsmith() -> bpy.types.Object:
    """Schlosserei: the toolmaker's shop — everything is made here."""
    _cottage("Toolsmith", 1.7, 1.5, 1.0, SLATE, WOOD)
    # Lean-to workshop with an open front.
    _box("ShopFloor", (1.2, 0.9, 0.08), (1.15, -0.1, 0.04), WOOD_DARK, 0.0, 0.9)
    gable_roof("ShopRoof", 1.3, 1.0, 0.32, (1.15, -0.1, 1.04), THATCH)
    # Tool rack: a saw, a pick and a hammer hanging on the wall.
    _box("Rack", (1.0, 0.06, 0.06), (1.15, 0.28, 0.95), WOOD_DARK, 0.0, 0.8)
    _box("RackSaw", (0.9, 0.05, 0.16), (1.15, 0.24, 0.8), IRON, 0.0, 0.3, 0.7)
    _box("RackPick", (0.06, 0.06, 0.5), (0.8, 0.24, 0.7), WOOD_LIGHT, 0.0, 0.7)
    _box("RackPickHead", (0.24, 0.06, 0.08), (0.8, 0.24, 0.95), IRON, 0.0, 0.3, 0.7)
    _box("RackHammer", (0.06, 0.06, 0.3), (1.5, 0.24, 0.85), WOOD_LIGHT, 0.0, 0.7)
    _box("RackHammerHead", (0.14, 0.06, 0.12), (1.5, 0.24, 1.0), IRON, 0.0, 0.3, 0.7)
    # Workbench with a vice and finished tools.
    _box("Bench", (0.8, 0.4, 0.1), (1.15, -0.45, 0.5), WOOD, 0.0, 0.8)
    for tag, sx in (("L", -0.32), ("R", 0.32)):
        _box(f"BenchLeg{tag}", (0.07, 0.07, 0.45), (1.15 + sx, -0.45, 0.24), WOOD_DARK, 0.0, 0.85)
    _box("Vice", (0.16, 0.16, 0.16), (0.85, -0.45, 0.62), IRON_DARK, 0.0, 0.4, 0.6)
    return bpy.context.active_object


def build_blacksmith() -> bpy.types.Object:
    """Schmiede: the forge — coal, bellows, anvil and a glowing fire."""
    _cottage("Blacksmith", 1.6, 1.4, 0.95, SLATE, STONE)
    # Forge hearth.
    _box("Hearth", (0.8, 0.7, 0.55), (0.55, 0.1, 0.28), STONE_DARK, 0.0, 0.9)
    glow = _ico("ForgeGlow", (0.3, 0.26, 0.14), (0.55, 0.1, 0.58), ORANGE_HOT, 2.6, 0.5)
    _cyl("ForgeStack", 6, 0.13, 1.0, (0.55, 0.5, 1.4), STONE_DARK, 0.0, 0.9)
    # Anvil on a stump.
    _cyl("AnvilStump", 8, 0.2, 0.4, (-0.5, -0.35, 0.2), WOOD_DARK, 0.0, 0.9)
    _box("AnvilBody", (0.34, 0.16, 0.16), (-0.5, -0.35, 0.48), IRON_DARK, 0.0, 0.35, 0.75)
    _box("AnvilTop", (0.46, 0.2, 0.08), (-0.5, -0.35, 0.6), IRON, 0.0, 0.3, 0.8)
    # Hammer resting on the anvil.
    _box("ForgeHammer", (0.05, 0.05, 0.34), (-0.5, -0.35, 0.76), WOOD_LIGHT, 0.0, 0.7)
    _box("ForgeHammerHead", (0.14, 0.1, 0.1), (-0.5, -0.35, 0.92), IRON, 0.0, 0.3, 0.75)
    # Bellows.
    _box("ForgeBellows", (0.3, 0.2, 0.18), (1.0, -0.25, 0.42), LEATHER_DARK, 0.0, 0.9)
    return glow


def build_watchtower() -> bpy.types.Object:
    """Wachturm: garrisoned, it is what expands your territory."""
    _cyl("TowerBase", 8, 0.62, 0.5, (0.0, 0.0, 0.25), STONE_DARK, 0.0, 0.9)
    _cyl("TowerShaft", 8, 0.45, 2.4, (0.0, 0.0, 1.7), STONE, 0.0, 0.85)
    _cyl("TowerPlatform", 8, 0.72, 0.16, (0.0, 0.0, 3.0), STONE_DARK, 0.0, 0.85)
    # Battlement ring.
    for i in range(8):
        angle = i * math.pi / 4.0
        _box(
            f"TowerMerlon{i}",
            (0.2, 0.2, 0.3),
            (math.cos(angle) * 0.6, math.sin(angle) * 0.6, 3.23),
            STONE,
            0.0,
            0.85,
            rotation=(0.0, 0.0, angle),
        )
    _box("TowerDoor", (0.26, 0.1, 0.55), (0.0, -0.5, 0.3), WOOD_DARK, 0.0, 0.75)
    _box("TowerWindow", (0.16, 0.08, 0.24), (0.0, -0.46, 1.5), GLASS, 0.3, 0.4)
    # Lookout roof on posts.
    for sx in (-0.45, 0.45):
        for sy in (-0.45, 0.45):
            _box(f"TowerPost{sx}{sy}", (0.08, 0.08, 0.8), (sx, sy, 3.48), WOOD_DARK, 0.0, 0.85)
    _cone("TowerRoof", 8, 0.82, 0.0, 0.5, (0.0, 0.0, 4.12), THATCH, 0.0, 0.8)
    return bpy.context.active_object


def build_warehouse() -> bpy.types.Object:
    """Lager: a big storehouse that also raises your settler quota."""
    _box("WarehouseBody", (2.1, 1.7, 1.3), (0.0, 0.0, 0.65), WOOD, 0.0, 0.85)
    for tag, sx in (("L", -0.9), ("R", 0.9)):
        _box(f"WarehousePost{tag}", (0.12, 0.12, 1.3), (sx, 0.78, 0.65), WOOD_DARK, 0.0, 0.8)
    _box("WarehouseRail", (2.12, 0.06, 0.1), (0.0, 0.78, 0.7), WOOD_DARK, 0.0, 0.8)
    gable_roof("WarehouseRoof", 2.3, 1.9, 0.6, (0.0, 0.0, 1.3), THATCH)
    # Wide doors for the carts.
    _box("WarehouseDoorL", (0.42, 0.1, 0.85), (-0.24, -0.87, 0.43), WOOD_DARK, 0.0, 0.75)
    _box("WarehouseDoorR", (0.42, 0.1, 0.85), (0.24, -0.87, 0.43), WOOD_DARK, 0.0, 0.75)
    # Barrels, crates and sacks stacked outside.
    for i, (x, y) in enumerate(((-1.35, -0.5), (-1.35, 0.15), (-1.35, 0.75))):
        _cyl(f"Barrel{i}", 8, 0.24, 0.5, (x, y, 0.25), WOOD_LIGHT, 0.0, 0.85)
        _torus(f"BarrelHoop{i}", 0.24, 0.03, (x, y, 0.34), IRON_DARK, 0.0, 0.4, 0.6)
    for i, (x, y) in enumerate(((1.3, -0.5), (1.4, 0.2))):
        _box(f"Crate{i}", (0.42, 0.42, 0.42), (x, y, 0.21), WOOD_LIGHT, 0.0, 0.85)
    _ico("GrainSack1", (0.26, 0.24, 0.3), (1.2, 0.85, 0.3), BREAD, 0.0, 0.9)
    _ico("GrainSack2", (0.24, 0.22, 0.28), (0.85, 0.95, 0.28), WHEAT, 0.0, 0.9)
    return bpy.context.active_object


def build_construction() -> bpy.types.Object:
    """Bauplatz: the scaffold a half-built building wears until it is finished."""
    for sx in (-0.55, 0.55):
        for sy in (-0.5, 0.5):
            _box(f"ScaffoldPost{sx}{sy}", (0.07, 0.07, 0.9), (sx, sy, 0.45), WOOD_LIGHT, 0.0, 0.85)
    for h in (0.35, 0.8):
        _box(f"ScaffoldRailF{h}", (1.2, 0.06, 0.06), (0.0, -0.5, h), WOOD_LIGHT, 0.0, 0.85)
        _box(f"ScaffoldRailB{h}", (1.2, 0.06, 0.06), (0.0, 0.5, h), WOOD_LIGHT, 0.0, 0.85)
    _box("ScaffoldPlank", (1.2, 0.34, 0.05), (0.0, 0.0, 0.38), WOOD, 0.0, 0.85)
    # Stacked bricks and a bucket of mortar.
    for i in range(3):
        _box(f"BuildBrick{i}", (0.26, 0.2, 0.1), (-0.3, -0.2, 0.06 + i * 0.11), STONE, 0.0, 0.9)
    _cyl("MortarBucket", 8, 0.16, 0.22, (0.35, -0.25, 0.11), WOOD_DARK, 0.0, 0.9)
    _cyl("MortarTop", 8, 0.15, 0.03, (0.35, -0.25, 0.22), PLASTER, 0.0, 0.9)
    # The plan pegged to a post.
    _box("PlanPost", (0.06, 0.06, 0.7), (0.5, 0.35, 0.35), WOOD_LIGHT, 0.0, 0.85)
    _box("Plan", (0.34, 0.02, 0.28), (0.5, 0.31, 0.62), PLASTER, 0.0, 0.9)
    return bpy.context.active_object


# --- terrain / resource props ----------------------------------------------
def _tree(name: str, trunk_color: tuple[float, float, float, float], leaf: tuple[float, float, float, float], height: float) -> bpy.types.Object:
    _cyl(f"{name}Trunk", 6, 0.13, height * 0.45, (0.0, 0.0, height * 0.225), trunk_color, 0.0, 0.9)
    _ico(f"{name}Crown", (height * 0.34, height * 0.34, height * 0.34), (0.0, 0.0, height * 0.66), leaf, 0.0, 0.9)
    _ico(f"{name}Crown2", (height * 0.24, height * 0.24, height * 0.22), (height * 0.14, -height * 0.1, height * 0.5), leaf, 0.0, 0.9)
    return bpy.context.active_object


def build_oak() -> bpy.types.Object:
    """Broadleaf tree — what the woodcutter fells and the forester replants."""
    return _tree("Oak", WOOD_DARK, LEAF, 1.7)


def build_ore_node() -> bpy.types.Object:
    """Shared ore outcrop; the coloured crystal is swapped per deposit kind."""
    _ico("OreRock", (0.42, 0.38, 0.34), (0.0, 0.0, 0.2), STONE_DARK, 0.0, 0.95)
    _ico("OreRock2", (0.26, 0.24, 0.2), (0.24, 0.16, 0.14), STONE, 0.0, 0.95)
    return bpy.context.active_object


def _deposit(name: str, crystal_color: tuple[float, float, float, float], emission: float) -> bpy.types.Object:
    _ico(f"{name}Rock", (0.42, 0.38, 0.34), (0.0, 0.0, 0.2), STONE_DARK, 0.0, 0.95)
    _ico(f"{name}Rock2", (0.26, 0.24, 0.2), (0.24, 0.16, 0.14), STONE, 0.0, 0.95)
    for i, (x, y, z) in enumerate(((-0.12, -0.1, 0.42), (0.16, 0.08, 0.38), (0.0, 0.2, 0.34))):
        _ico(f"{name}Crystal{i}", (0.1, 0.1, 0.18), (x, y, z), crystal_color, emission, 0.35, 0.2)
    return bpy.context.active_object


def build_coal_node() -> bpy.types.Object:
    """Kohle deposit: dull black lumps in a rock."""
    return _deposit("CoalNode", COAL, 0.0)


def build_iron_node() -> bpy.types.Object:
    """Eisenerz deposit: rust-red crystals."""
    return _deposit("IronNode", RUST, 0.15)


def build_gold_node() -> bpy.types.Object:
    """Golderz deposit: glittering gold crystals."""
    return _deposit("GoldNode", GOLD, 0.5)


def build_stone_node() -> bpy.types.Object:
    """Stein deposit: a pale rock outcrop."""
    return _deposit("StoneNode", STONE, 0.0)


def build_fish_spot() -> bpy.types.Object:
    """Fischgrund: a shoal marker sitting on the water."""
    _ico("Shoal", (0.5, 0.5, 0.05), (0.0, 0.0, 0.03), WATER, 0.35, 0.35, 0.2)
    for i, (x, y) in enumerate(((-0.2, -0.1), (0.12, 0.14), (0.24, -0.18))):
        _ico(f"ShoalFish{i}", (0.16, 0.06, 0.05), (x, y, 0.07), (0.75, 0.85, 0.9, 1.0), 0.4, 0.5, 0.3)
    return bpy.context.active_object


# --- registry ---------------------------------------------------------------
BUILDERS: dict[str, object] = {
    "castle": build_castle,
    "flag": build_flag,
    "settler": build_settler,
    "knight": build_knight,
    "woodcutter": build_woodcutter,
    "forester": build_forester,
    "sawmill": build_sawmill,
    "quarry": build_quarry,
    "coal_mine": build_coal_mine,
    "iron_mine": build_iron_mine,
    "gold_mine": build_gold_mine,
    "farm": build_farm,
    "windmill": build_windmill,
    "bakery": build_bakery,
    "fishery": build_fishery,
    "smelter": build_smelter,
    "toolsmith": build_toolsmith,
    "blacksmith": build_blacksmith,
    "watchtower": build_watchtower,
    "warehouse": build_warehouse,
    "construction": build_construction,
    "oak": build_oak,
    "stone_node": build_stone_node,
    "coal_node": build_coal_node,
    "iron_node": build_iron_node,
    "gold_node": build_gold_node,
    "fish_spot": build_fish_spot,
}


def parse_args() -> argparse.Namespace:
    argv = sys.argv
    argv = argv[argv.index("--") + 1 :] if "--" in argv else []
    parser = argparse.ArgumentParser(description="Generate the Siedler 3D mesh pack.")
    parser.add_argument("--out-dir", default="godot/assets/meshes/siedler", help="output directory for the .glb files")
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
