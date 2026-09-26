"""Headless Blender generator for the "Drachenflug" mesh pack.

Produces the low-poly ``.glb`` collection of the dragon-flight game: the new
dragon breeds, the breeding area (eggs, nests, pedestals) and the flying/ground
enemies plus the sky props.

Usage::

    blender --background --python scripts/blender/generate_flight_meshes.py
    blender --background --python scripts/blender/generate_flight_meshes.py -- --only egg,nest

Meshes land in ``godot/assets/meshes/flight`` and are registered in
``AssetRegistry.KEYS`` (see AGENTS.md). Reuses the primitive helpers from
``make_mesh.py`` and ``build_dragon`` from the RPG pack, so the new breeds are
built from exactly the same parts (named ``DragonWingL``/``DragonTailA``/…) and
the flight screen can flap the wings and sweep the tail of every dragon.
"""

from __future__ import annotations

import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy  # noqa: E402

import generate_rpg_meshes as rpg  # noqa: E402
import make_mesh as mm  # noqa: E402

# --- primitive helpers ------------------------------------------------------
# The shared helpers take RGBA tuples; the builders below think in RGB, so every
# primitive is wrapped once here instead of at ~200 call sites.
def _rgba(color: tuple[float, ...]) -> tuple[float, float, float, float]:
    if len(color) == 3:
        return (color[0], color[1], color[2], 1.0)
    return (color[0], color[1], color[2], color[3])


def _ico(
    name: str,
    scale: tuple[float, float, float],
    location: tuple[float, float, float],
    color: tuple[float, ...],
    emission: float = 0.0,
    roughness: float = 0.6,
    metallic: float = 0.05,
    subdivisions: int = 1,
) -> bpy.types.Object:
    return rpg._ico(name, scale, location, _rgba(color), emission, roughness, metallic, subdivisions)


def _box(
    name: str,
    size: tuple[float, float, float],
    location: tuple[float, float, float],
    color: tuple[float, ...],
    emission: float = 0.0,
    roughness: float = 0.6,
    metallic: float = 0.05,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    return mm._box(name, size, location, _rgba(color), emission, roughness, metallic, rotation)


def _cone(
    name: str,
    vertices: int,
    radius1: float,
    radius2: float,
    depth: float,
    location: tuple[float, float, float],
    color: tuple[float, ...],
    emission: float = 0.0,
    roughness: float = 0.35,
    metallic: float = 0.1,
    flip: bool = False,
) -> bpy.types.Object:
    return mm._cone(name, vertices, radius1, radius2, depth, location, _rgba(color), emission, roughness, metallic, flip)


def _cyl(
    name: str,
    vertices: int,
    radius: float,
    depth: float,
    location: tuple[float, float, float],
    color: tuple[float, ...],
    emission: float = 0.0,
    roughness: float = 0.5,
    metallic: float = 0.1,
) -> bpy.types.Object:
    return mm._cone(name, vertices, radius, radius, depth, location, _rgba(color), emission, roughness, metallic)


def _torus(
    name: str,
    major: float,
    minor: float,
    location: tuple[float, float, float],
    color: tuple[float, ...],
    emission: float = 0.0,
    roughness: float = 0.3,
    metallic: float = 0.2,
    major_segments: int = 16,
    minor_segments: int = 8,
) -> bpy.types.Object:
    return mm._torus(name, major, minor, location, _rgba(color), emission, roughness, metallic, major_segments, minor_segments)


def _pivot_box(
    name: str,
    size: tuple[float, float, float],
    offset: tuple[float, float, float],
    location: tuple[float, float, float],
    color: tuple[float, ...],
    emission: float = 0.0,
    roughness: float = 0.5,
    metallic: float = 0.1,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    obj = mm._box(name, size, (0.0, 0.0, 0.0), _rgba(color), emission, roughness, metallic)
    obj.data.transform(mm.Matrix.Translation(offset))
    obj.location = location
    obj.rotation_euler = rotation
    return obj


build_dragon = rpg.build_dragon

STONE = rpg.STONE
STONE_DARK = rpg.STONE_DARK
GOLD = rpg.GOLD
BONE = rpg.BONE
WOOD = rpg.WOOD
WOOD_DARK = rpg.WOOD_DARK
LEATHER = rpg.LEATHER
GREEN = rpg.GREEN
GREEN_DARK = rpg.GREEN_DARK
ORANGE = rpg.ORANGE
RED = rpg.RED
BLUE = rpg.BLUE
CYAN = rpg.CYAN
PURPLE = rpg.PURPLE
WHITE = rpg.WHITE
BLACK = rpg.BLACK


# --- new dragon breeds ------------------------------------------------------
# Same builder as the RPG pack, so the wings/tail keep their part names and the
# size really changes with the breed: `size` scales the whole dragon.
BREED_VARIANTS: list[tuple[str, dict[str, object]]] = [
    (
        "dragon_cloud",
        dict(
            body=(0.72, 0.82, 0.95),
            belly=(0.92, 0.96, 1.0),
            accent=(0.55, 0.85, 1.0),
            size=1.18,
            horn_count=3,
            horn_len=0.6,
            wing_span=1.45,
            tail_len=1.25,
            neck_len=1.05,
            spikes=False,
            crest=True,
        ),
    ),
    (
        "dragon_tide",
        dict(
            body=(0.12, 0.5, 0.62),
            belly=(0.6, 0.92, 0.95),
            accent=(0.35, 0.95, 0.9),
            size=1.32,
            horn_count=4,
            horn_len=0.8,
            wing_span=1.5,
            tail_len=1.45,
            neck_len=1.1,
            spikes=True,
            crest=True,
        ),
    ),
    (
        "dragon_solar",
        dict(
            body=(0.95, 0.68, 0.12),
            belly=(1.0, 0.9, 0.45),
            accent=(1.0, 0.55, 0.1),
            size=1.42,
            horn_count=5,
            horn_len=0.95,
            wing_span=1.6,
            tail_len=1.3,
            neck_len=1.15,
            spikes=True,
            crest=True,
        ),
    ),
    (
        "dragon_void",
        dict(
            body=(0.08, 0.06, 0.14),
            belly=(0.26, 0.12, 0.42),
            accent=(0.72, 0.25, 1.0),
            size=1.62,
            horn_count=5,
            horn_len=1.1,
            wing_span=1.75,
            tail_len=1.5,
            neck_len=1.2,
            spikes=True,
            crest=True,
        ),
    ),
]


# --- breeding props ---------------------------------------------------------
def build_egg() -> bpy.types.Object:
    """A speckled dragon egg, base near z=0 so it rests in a nest."""
    shell = _ico("EggShell", (0.42, 0.42, 0.56), (0.0, 0.0, 0.5), (0.93, 0.89, 0.78), 0.0, 0.45, 0.02)
    for i, (x, y, z, s) in enumerate(
        [
            (0.2, 0.12, 0.42, 0.09),
            (-0.18, -0.14, 0.6, 0.08),
            (0.05, -0.24, 0.78, 0.07),
            (-0.1, 0.22, 0.3, 0.075),
            (0.26, -0.06, 0.66, 0.06),
        ]
    ):
        _ico(f"EggSpeck{i}", (s, s, s), (x, y, z), (0.35, 0.28, 0.24), 0.0, 0.5, 0.02)
    return shell


def build_egg_large() -> bpy.types.Object:
    """An elongated, banded egg for the rare breeds."""
    shell = _ico("EggShell", (0.56, 0.56, 0.86), (0.0, 0.0, 0.78), (0.86, 0.8, 0.72), 0.0, 0.4, 0.05)
    for i in range(3):
        _torus(
            f"EggBand{i}",
            0.42 - i * 0.08,
            0.05,
            (0.0, 0.0, 0.55 + i * 0.22),
            (0.55, 0.45, 0.2),
            0.25,
            0.35,
            0.15,
            major_segments=12,
            minor_segments=6,
        )
    return shell


def build_egg_crystal() -> bpy.types.Object:
    """A faceted crystal egg — the rarest shell in the hatchery."""
    core = _ico("EggCore", (0.46, 0.46, 0.68), (0.0, 0.0, 0.62), (0.45, 0.85, 0.95), 1.4, 0.15, 0.3)
    for i in range(6):
        angle = i * 1.0472
        shard = _cone(
            f"EggShard{i}",
            4,
            0.12,
            0.0,
            0.66,
            (0.34 * math.cos(angle), 0.34 * math.sin(angle), 0.78),
            (0.65, 0.95, 1.0),
            0.9,
            0.2,
            0.25,
        )
        shard.rotation_euler = (-0.32, 0.0, 0.0)
    return core


def build_nest() -> bpy.types.Object:
    """A ring of woven twigs that an egg rests in."""
    for i in range(9):
        angle = i * 0.6981
        radius = 0.62 + 0.06 * (i % 3)
        twig = _cone(
            f"NestTwig{i}",
            4,
            0.07,
            0.03,
            0.78,
            (radius * math.cos(angle), radius * math.sin(angle), 0.1 + 0.05 * (i % 2)),
            WOOD_DARK if i % 2 else WOOD,
            0.0,
            0.85,
            0.0,
        )
        twig.rotation_euler = (1.32, 0.0, angle + 1.57)
    _ico("NestBed", (0.5, 0.5, 0.12), (0.0, 0.0, 0.08), (0.32, 0.24, 0.15), 0.0, 0.9, 0.0)
    return _ico("NestBase", (0.58, 0.58, 0.1), (0.0, 0.0, 0.04), WOOD_DARK, 0.0, 0.9, 0.0)


def build_pedestal() -> bpy.types.Object:
    """A stone plinth in the hatchery; dragons are shown standing on it."""
    _cyl("PedestalFoot", 8, 0.62, 0.16, (0.0, 0.0, 0.08), STONE_DARK)
    _cyl("PedestalShaft", 8, 0.44, 1.15, (0.0, 0.0, 0.72), STONE)
    _cyl("PedestalTop", 8, 0.58, 0.18, (0.0, 0.0, 1.38), STONE_DARK)
    for i in range(4):
        angle = i * 1.5708 + 0.78
        _ico(
            f"PedestalRune{i}",
            (0.09, 0.09, 0.16),
            (0.42 * math.cos(angle), 0.42 * math.sin(angle), 0.86),
            CYAN,
            1.6,
            0.2,
            0.2,
        )
    return _cyl("PedestalCore", 8, 0.62, 0.16, (0.0, 0.0, 0.08), STONE_DARK)


def build_roost() -> bpy.types.Object:
    """A perch the player's active dragon sits on in the hatchery."""
    _cyl("RoostPost", 6, 0.16, 1.0, (0.0, 0.0, 0.5), WOOD_DARK)
    _cyl("RoostBar", 6, 0.1, 1.7, (0.0, 0.0, 1.0), WOOD, 0.0, 0.75, 0.0)
    return _ico("RoostBase", (0.42, 0.42, 0.1), (0.0, 0.0, 0.05), STONE_DARK)


# --- sky props --------------------------------------------------------------
def build_cloud() -> bpy.types.Object:
    """A puffy cloud, built from overlapping spheres for a low-poly look."""
    puffs = [
        (0.0, 0.0, 0.0, 1.0),
        (-0.8, 0.18, -0.12, 0.72),
        (0.82, 0.1, -0.08, 0.66),
        (0.2, -0.62, -0.2, 0.6),
        (-0.3, 0.55, 0.16, 0.54),
    ]
    root = None
    for i, (x, y, z, s) in enumerate(puffs):
        puff = _ico(f"CloudPuff{i}", (s, s * 0.8, s * 0.62), (x, y, z), (0.97, 0.98, 1.0), 0.05, 0.95, 0.0)
        if root is None:
            root = puff
    return root


def build_cloud_storm() -> bpy.types.Object:
    """A dark storm cloud with an emissive core."""
    for i, (x, y, z, s) in enumerate(
        [
            (0.0, 0.0, 0.0, 1.05),
            (-0.85, 0.2, -0.14, 0.7),
            (0.88, 0.12, -0.06, 0.64),
            (0.15, -0.66, -0.24, 0.58),
        ]
    ):
        _ico(f"StormPuff{i}", (s, s * 0.8, s * 0.6), (x, y, z), (0.28, 0.28, 0.38), 0.0, 0.9, 0.05)
    for i in range(3):
        bolt = _cone(
            f"StormBolt{i}",
            4,
            0.07,
            0.0,
            0.7,
            (-0.3 + i * 0.3, 0.0, -0.62),
            (0.75, 0.9, 1.0),
            2.2,
            0.1,
            0.1,
        )
        bolt.rotation_euler = (3.14, 0.0, 0.0)
    return _ico("StormCore", (0.4, 0.4, 0.3), (0.0, 0.0, -0.3), (0.6, 0.8, 1.0), 1.8, 0.2, 0.1)


def build_island() -> bpy.types.Object:
    """A floating rock island — the ground the player flies over."""
    _cyl("IslandTop", 7, 1.0, 0.3, (0.0, 0.0, 0.0), GREEN, 0.0, 0.9, 0.0)
    _ico("IslandRim", (1.02, 1.02, 0.22), (0.0, 0.0, -0.2), (0.36, 0.3, 0.22), 0.0, 0.95, 0.0)
    _cone("IslandSpike", 6, 0.72, 0.0, 2.4, (0.0, 0.0, -1.5), STONE_DARK, 0.0, 0.95, 0.0, flip=True)
    for i in range(3):
        angle = i * 2.0944
        _ico(
            f"IslandStone{i}",
            (0.24, 0.24, 0.2),
            (0.66 * math.cos(angle), 0.66 * math.sin(angle), -0.52),
            STONE,
            0.0,
            0.9,
            0.0,
        )
    return _cyl("IslandGrass", 7, 0.94, 0.12, (0.0, 0.0, 0.1), GREEN_DARK, 0.0, 0.9, 0.0)


def build_totem() -> bpy.types.Object:
    """A waypoint totem that marks a level gate on the flight path."""
    _cyl("TotemFoot", 6, 0.4, 0.2, (0.0, 0.0, 0.1), STONE_DARK)
    _cyl("TotemPole", 6, 0.13, 2.2, (0.0, 0.0, 1.3), WOOD_DARK)
    _ico("TotemGem", (0.3, 0.3, 0.42), (0.0, 0.0, 2.6), CYAN, 2.0, 0.15, 0.3)
    return _cyl("TotemCap", 6, 0.34, 0.14, (0.0, 0.0, 2.4), GOLD, 0.1, 0.3, 0.6)


# --- enemies ----------------------------------------------------------------
def build_wyvern() -> bpy.types.Object:
    """A hostile flying wyvern: lean body, big wings, spiked tail."""
    body = _ico("WyvernBody", (0.42, 0.62, 0.38), (0.0, 0.0, 0.0), (0.36, 0.3, 0.34), 0.0, 0.75, 0.05)
    _ico("WyvernBelly", (0.32, 0.44, 0.28), (0.0, 0.04, -0.14), (0.55, 0.45, 0.4), 0.0, 0.8, 0.02)
    head = _ico("WyvernHead", (0.26, 0.34, 0.24), (0.0, 0.72, 0.06), (0.4, 0.33, 0.36), 0.0, 0.7, 0.05)
    _cone("WyvernSnout", 5, 0.16, 0.08, 0.34, (0.0, 1.02, 0.0), (0.34, 0.28, 0.3), 0.0, 0.7, 0.05)
    for side in (-1.0, 1.0):
        _ico(
            f"WyvernEye{'L' if side < 0 else 'R'}",
            (0.06, 0.06, 0.06),
            (side * 0.12, 0.8, 0.14),
            RED,
            2.4,
            0.2,
            0.1,
        )
        _pivot_box(
            f"WyvernWing{'L' if side < 0 else 'R'}",
            (1.0, 0.62, 0.06),
            (side * 0.48, 0.0, 0.0),
            (side * 0.4, 0.05, 0.16),
            (0.32, 0.27, 0.3),
            0.0,
            0.75,
            0.05,
            rotation=(0.0, -side * 0.2, -side * 0.42),
        )
        for i in range(2):
            _cone(
                f"WyvernClaw{'L' if side < 0 else 'R'}{i}",
                4,
                0.05,
                0.0,
                0.26,
                (side * (0.16 + i * 0.08), 0.3 - i * 0.1, -0.3),
                BONE,
                0.0,
                0.6,
                0.05,
            ).rotation_euler = (1.9, 0.0, 0.0)
    for i in range(3):
        _cone(
            f"WyvernTail{i}",
            5,
            0.15 - i * 0.04,
            0.05,
            0.52,
            (0.0, -0.6 - i * 0.42, -0.06 - i * 0.12),
            (0.34, 0.28, 0.3),
            0.0,
            0.75,
            0.05,
        ).rotation_euler = (1.5 + i * 0.12, 0.0, 0.0)
    _cone("WyvernSpike", 4, 0.08, 0.0, 0.3, (0.0, -1.5, -0.4), BONE, 0.0, 0.5, 0.1).rotation_euler = (2.2, 0.0, 0.0)
    return body


def build_imp() -> bpy.types.Object:
    """A small, fast nuisance flyer."""
    body = _ico("ImpBody", (0.26, 0.34, 0.24), (0.0, 0.0, 0.0), (0.55, 0.24, 0.5), 0.0, 0.7, 0.05)
    _ico("ImpHead", (0.19, 0.2, 0.18), (0.0, 0.34, 0.04), (0.62, 0.28, 0.55), 0.0, 0.7, 0.05)
    for side in (-1.0, 1.0):
        _pivot_box(
            f"ImpWing{'L' if side < 0 else 'R'}",
            (0.46, 0.3, 0.04),
            (side * 0.22, 0.0, 0.0),
            (side * 0.2, 0.0, 0.1),
            (0.75, 0.45, 0.4),
            0.1,
            0.7,
            0.05,
            rotation=(0.0, -side * 0.25, -side * 0.5),
        )
        _ico(
            f"ImpEye{'L' if side < 0 else 'R'}",
            (0.05, 0.05, 0.05),
            (side * 0.09, 0.4, 0.1),
            (1.0, 0.85, 0.2),
            2.2,
            0.2,
            0.1,
        )
    _cone("ImpTail", 5, 0.07, 0.0, 0.4, (0.0, -0.4, -0.04), (0.55, 0.24, 0.5), 0.0, 0.7, 0.05).rotation_euler = (1.5, 0.0, 0.0)
    return body


def build_harpy() -> bpy.types.Object:
    """A diving harpy that swoops at the player."""
    body = _ico("HarpyBody", (0.3, 0.5, 0.3), (0.0, 0.0, 0.0), (0.72, 0.62, 0.5), 0.0, 0.7, 0.05)
    _ico("HarpyHead", (0.17, 0.22, 0.17), (0.0, 0.5, 0.08), (0.8, 0.7, 0.58), 0.0, 0.7, 0.05)
    _cone("HarpyBeak", 4, 0.07, 0.0, 0.26, (0.0, 0.72, 0.04), GOLD, 0.0, 0.4, 0.4).rotation_euler = (1.57, 0.0, 0.0)
    for side in (-1.0, 1.0):
        _pivot_box(
            f"HarpyWing{'L' if side < 0 else 'R'}",
            (0.92, 0.42, 0.05),
            (side * 0.44, 0.0, 0.0),
            (side * 0.26, 0.02, 0.12),
            (0.85, 0.75, 0.6),
            0.0,
            0.7,
            0.05,
            rotation=(0.0, -side * 0.18, -side * 0.38),
        )
        for i in range(3):
            _cone(
                f"HarpyFeather{'L' if side < 0 else 'R'}{i}",
                4,
                0.045,
                0.0,
                0.4,
                (side * (0.5 + i * 0.16), -0.12, 0.08),
                (0.9, 0.82, 0.7),
                0.0,
                0.75,
                0.02,
            ).rotation_euler = (1.5, 0.0, -side * 0.5)
    _cone("HarpyTail", 5, 0.1, 0.02, 0.5, (0.0, -0.5, 0.0), (0.7, 0.6, 0.48), 0.0, 0.7, 0.05).rotation_euler = (1.5, 0.0, 0.0)
    return body


def build_ballista() -> bpy.types.Object:
    """A ground turret that shoots up at the player."""
    _box("BallistaBase", (1.1, 1.1, 0.3), (0.0, 0.0, 0.15), WOOD_DARK, 0.0, 0.85, 0.0)
    _box("BallistaPost", (0.32, 0.32, 0.7), (0.0, 0.0, 0.6), WOOD, 0.0, 0.85, 0.0)
    arm = _box("BallistaArm", (1.5, 0.16, 0.16), (0.0, 0.0, 0.98), LEATHER, 0.0, 0.8, 0.0)
    arm.rotation_euler = (0.0, 0.0, 0.5)
    for side in (-1.0, 1.0):
        _box(
            f"BallistaLimb{'L' if side < 0 else 'R'}",
            (0.7, 0.1, 0.1),
            (side * 0.5, 0.0, 0.98),
            STONE_DARK,
            0.0,
            0.7,
            0.1,
            rotation=(0.0, 0.0, side * 0.25),
        )
    _cyl("BallistaBolt", 6, 0.08, 0.9, (0.0, 0.0, 1.06), STONE, 0.0, 0.6, 0.2)
    return _box("BallistaBoltHead", (0.2, 0.2, 0.28), (0.0, 0.0, 1.5), RED, 0.5, 0.4, 0.3)


def build_golem() -> bpy.types.Object:
    """A heavy floating rock golem that soaks a lot of fire."""
    core = _ico("GolemCore", (0.72, 0.72, 0.78), (0.0, 0.0, 0.0), (0.42, 0.42, 0.46), 0.0, 0.9, 0.1)
    for i in range(7):
        angle = i * 0.8976
        _ico(
            f"GolemChunk{i}",
            (0.3, 0.3, 0.28),
            (0.66 * math.cos(angle), 0.66 * math.sin(angle), 0.2 * math.sin(i)),
            STONE_DARK if i % 2 else STONE,
            0.0,
            0.95,
            0.05,
        )
    for side in (-1.0, 1.0):
        _ico(
            f"GolemEye{'L' if side < 0 else 'R'}",
            (0.14, 0.14, 0.14),
            (side * 0.24, -0.62, 0.2),
            ORANGE,
            2.4,
            0.2,
            0.1,
        )
    return core


def build_fireball() -> bpy.types.Object:
    """The dragon's breath projectile: a bright core inside a hot shell."""
    shell = _ico("FireballShell", (0.24, 0.24, 0.24), (0.0, 0.0, 0.0), (1.0, 0.45, 0.12), 2.6, 0.4, 0.0)
    _ico("FireballCore", (0.13, 0.13, 0.13), (0.0, 0.0, 0.0), (1.0, 0.95, 0.7), 4.0, 0.2, 0.0)
    for i in range(4):
        angle = i * 1.5708
        _ico(
            f"FireballSpark{i}",
            (0.07, 0.07, 0.16),
            (0.22 * math.cos(angle), 0.22 * math.sin(angle), 0.0),
            (1.0, 0.7, 0.2),
            3.0,
            0.3,
            0.0,
        )
    return shell


# --- registry ---------------------------------------------------------------
BUILDERS: dict[str, object] = {
    "egg": build_egg,
    "egg_large": build_egg_large,
    "egg_crystal": build_egg_crystal,
    "nest": build_nest,
    "pedestal": build_pedestal,
    "roost": build_roost,
    "cloud": build_cloud,
    "cloud_storm": build_cloud_storm,
    "island": build_island,
    "totem": build_totem,
    "wyvern": build_wyvern,
    "imp": build_imp,
    "harpy": build_harpy,
    "ballista": build_ballista,
    "golem": build_golem,
    "fireball": build_fireball,
}

for _name, _cfg in BREED_VARIANTS:
    BUILDERS[_name] = (lambda cfg=_cfg: build_dragon(**cfg))  # type: ignore[assignment]


def parse_args() -> argparse.Namespace:
    argv = sys.argv
    argv = argv[argv.index("--") + 1 :] if "--" in sys.argv else []
    parser = argparse.ArgumentParser(description="Generate the dragon-flight mesh pack.")
    parser.add_argument("--out-dir", default="godot/assets/meshes/flight", help="output directory for the .glb files")
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
