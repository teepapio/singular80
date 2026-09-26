"""Headless Blender generator for the "Candy Crush 3D" board pieces.

Produces the low-poly ``.glb`` pieces of the match-3 in
``godot/src/core/logic/candy_match3.gd`` that do not exist yet: the six sweets
of the candy world, the six flowers of the flower world and one extra Christmas
prop. The other worlds reuse meshes that are already bundled (crystals,
Halloween sweets, Xmas decorations, RPG treasure).

Usage::

    blender --background --python scripts/blender/generate_candy_meshes.py
    blender --background --python scripts/blender/generate_candy_meshes.py -- --only rose

Meshes land in ``godot/assets/meshes/candy`` and are registered in
``AssetRegistry.KEYS`` (see AGENTS.md). Every piece is built from a *single*
material on purpose: the game tints a piece with its level colour, so one
material per piece means one draw call per board tile on a phone. Shape, not
texture, carries the identity. Keep every piece low-poly — it protects the APK
size and every mobile GPU.
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

# Neutral mid tone — the screen overrides it with the world colour.
PIECE = (0.72, 0.72, 0.78, 1.0)

_cone = mm._cone


def _merge(name: str) -> bpy.types.Object:
    """Join the scene into one mesh that uses a single material."""
    obj = mm._join_all(name)
    if obj.data.materials:
        for polygon in obj.data.polygons:
            polygon.material_index = 0
        obj.data.materials.clear()
    mm._apply_material(obj, PIECE, 0.12, 0.32, 0.22)
    return obj


def _ico(
    name: str,
    scale: tuple[float, float, float],
    location: tuple[float, float, float],
    subdivisions: int = 1,
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdivisions, radius=1.0, location=location)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return mm._primitive(name, PIECE, 0.1, 0.4, 0.08)


def _box(
    name: str,
    size: tuple[float, float, float],
    location: tuple[float, float, float],
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=location, rotation=rotation)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return mm._primitive(name, PIECE, 0.1, 0.45, 0.08)


def _torus(
    name: str,
    major: float,
    minor: float,
    location: tuple[float, float, float],
    major_segments: int = 12,
    minor_segments: int = 5,
    flatten: float = 1.0,
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_torus_add(
        major_radius=major,
        minor_radius=minor,
        major_segments=major_segments,
        minor_segments=minor_segments,
        location=location,
    )
    obj = bpy.context.active_object
    obj.name = name
    if flatten != 1.0:
        obj.scale = (1.0, 1.0, flatten)
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return mm._primitive(name, PIECE, 0.12, 0.32, 0.22)


def _cone(
    name: str,
    vertices: int,
    r1: float,
    r2: float,
    depth: float,
    location: tuple[float, float, float],
    flip: bool = False,
) -> bpy.types.Object:
    return mm._cone(name, vertices, r1, r2, depth, location, PIECE, 0.1, 0.45, 0.08, flip)


def _at(obj: bpy.types.Object, translation: tuple[float, float, float], rotation: tuple[float, float, float]) -> bpy.types.Object:
    """Place a part built at the origin with a translation and an XYZ rotation."""
    obj.matrix_world = (
        Matrix.Translation(translation)
        @ Matrix.Rotation(rotation[2], 4, "Z")
        @ Matrix.Rotation(rotation[1], 4, "Y")
        @ Matrix.Rotation(rotation[0], 4, "X")
    )
    return obj


def _petal(
    name: str,
    angle: float,
    radius: float,
    z: float,
    length: float,
    width: float,
    height: float,
    tilt: float,
) -> bpy.types.Object:
    """A flattened petal pointing outwards from the flower centre."""
    return _at(
        _ico(name, (length, width, height), (0.0, 0.0, 0.0)),
        (math.cos(angle) * radius, math.sin(angle) * radius, z),
        (0.0, tilt, angle),
    )


def _stem(name: str, height: float, leaves: int = 2) -> None:
    """A short stem (plus leaves) under a flower head centred on the origin."""
    _cone(f"{name}Stem", 6, 0.08, 0.05, height, (0.0, 0.0, -height / 2.0))
    for i in range(leaves):
        side = -1.0 if i % 2 == 0 else 1.0
        level = height * (0.5 + 0.25 * (i // 2))
        _at(
            _ico(f"{name}Leaf{i}", (0.32, 0.14, 0.05), (0.0, 0.0, 0.0)),
            (side * 0.3, 0.1 * i, -level),
            (0.0, side * 0.45, side * 0.4),
        )


# --- candy world ------------------------------------------------------------
def build_bonbon() -> bpy.types.Object:
    """Piece 1 — a domed bonbon with a ridged swirl on top."""
    _ico("BonbonShell", (0.6, 0.6, 0.44), (0.0, 0.0, 0.34), subdivisions=2)
    _ico("BonbonFoot", (0.62, 0.62, 0.1), (0.0, 0.0, 0.0), subdivisions=2)
    for i in range(3):
        _torus(f"BonbonSwirl{i}", 0.14 + i * 0.14, 0.06, (0.0, 0.0, 0.66 - i * 0.02), flatten=0.55)
    _ico("BonbonKnot", (0.08, 0.08, 0.1), (0.0, 0.0, 0.82))
    return _merge("CandyBonbon")


def build_lolly() -> bpy.types.Object:
    """Piece 2 — a swirled lollipop disc on a stick."""
    _cone("LollyDisc", 14, 0.58, 0.58, 0.16, (0.0, 0.0, 0.5))
    _cone("LollyRim", 14, 0.6, 0.5, 0.1, (0.0, 0.0, 0.42))
    for i in range(3):
        _torus(f"LollySwirl{i}", 0.14 + i * 0.15, 0.055, (0.0, 0.0, 0.58), flatten=0.6)
    _cone("LollyStick", 6, 0.06, 0.06, 0.72, (0.0, 0.0, -0.12))
    return _merge("CandyLolly")


def build_jellybean() -> bpy.types.Object:
    """Piece 3 — a bean-shaped jelly with a sugar sheen."""
    _at(_ico("JellyBean", (0.48, 0.3, 0.6), (0.0, 0.0, 0.0), subdivisions=2), (0.0, 0.0, 0.42), (0.0, 0.45, 0.0))
    _at(_ico("JellyTip", (0.2, 0.16, 0.28), (0.0, 0.0, 0.0)), (0.36, 0.0, 0.84), (0.0, 0.45, 0.0))
    _at(_ico("JellyTail", (0.2, 0.16, 0.28), (0.0, 0.0, 0.0)), (-0.34, 0.0, 0.2), (0.0, -0.5, 0.0))
    _torus("JellySheen", 0.3, 0.05, (0.0, 0.0, 0.36), flatten=0.8)
    return _merge("CandyJellybean")


def build_gumdrop() -> bpy.types.Object:
    """Piece 4 — a classic sugar gumdrop dome."""
    _cone("GumdropBody", 12, 0.32, 0.6, 0.74, (0.0, 0.0, 0.37))
    _ico("GumdropFoot", (0.6, 0.6, 0.1), (0.0, 0.0, 0.0))
    for i in range(6):
        angle = i * math.pi / 3.0
        _ico(f"GumdropSugar{i}", (0.07, 0.07, 0.07), (math.cos(angle) * 0.5, math.sin(angle) * 0.5, 0.14))
    _ico("GumdropCrown", (0.16, 0.16, 0.12), (0.0, 0.0, 0.76))
    return _merge("CandyGumdrop")


def build_chocolate() -> bpy.types.Object:
    """Piece 5 — a beveled chocolate square with a raised cross."""
    bar = _box("ChocolateBar", (1.0, 1.0, 0.3), (0.0, 0.0, 0.2))
    mm._bevel(bar, 0.07, 2)
    _box("ChocolateRidgeX", (0.88, 0.12, 0.08), (0.0, 0.0, 0.38))
    _box("ChocolateRidgeY", (0.12, 0.88, 0.08), (0.0, 0.0, 0.38))
    for i, (x, y) in enumerate(((-0.28, -0.28), (0.28, 0.28), (-0.28, 0.28), (0.28, -0.28))):
        _ico(f"ChocolateChip{i}", (0.09, 0.09, 0.06), (x, y, 0.38))
    return _merge("CandyChocolate")


def build_heart() -> bpy.types.Object:
    """Piece 6 — a plump heart sweet."""
    _ico("HeartCushion", (0.5, 0.42, 0.42), (0.0, 0.0, 0.5), subdivisions=2)
    for side in (-1.0, 1.0):
        _ico(f"HeartLobe{'R' if side > 0 else 'L'}", (0.3, 0.3, 0.3), (side * 0.19, 0.0, 0.74))
    _cone("HeartPoint", 8, 0.5, 0.0, 0.76, (0.0, 0.0, 0.2), flip=True)
    return _merge("CandyHeart")


# --- flower world -----------------------------------------------------------
def build_rose() -> bpy.types.Object:
    """Piece 1 — a layered rose bloom."""
    _stem("Rose", 0.5, leaves=2)
    _ico("RoseCore", (0.18, 0.18, 0.16), (0.0, 0.0, 0.18))
    for ring, (count, radius, length, z, tilt) in enumerate(((6, 0.22, 0.28, 0.14, 0.5), (7, 0.32, 0.32, 0.28, 0.9), (6, 0.4, 0.28, 0.42, 1.2))):
        for i in range(count):
            _petal(f"RosePetal{ring}_{i}", i * 2.0 * math.pi / count + ring * 0.4, radius, z, length, 0.16, 0.07, tilt)
    return _merge("FlowerRose")


def build_tulip() -> bpy.types.Object:
    """Piece 2 — a tulip cup on a stem."""
    _stem("Tulip", 0.62, leaves=2)
    _ico("TulipCup", (0.32, 0.32, 0.42), (0.0, 0.0, 0.4), subdivisions=2)
    for i in range(5):
        angle = i * 2.0 * math.pi / 5.0
        _at(
            _ico(f"TulipBlade{i}", (0.15, 0.08, 0.42), (0.0, 0.0, 0.0)),
            (math.cos(angle) * 0.2, math.sin(angle) * 0.2, 0.44),
            (0.25, 0.0, -angle),
        )
    return _merge("FlowerTulip")


def build_sunflower() -> bpy.types.Object:
    """Piece 3 — a big sunflower with a seeded centre."""
    _stem("Sunflower", 0.5, leaves=2)
    for i in range(12):
        _petal(f"SunflowerPetal{i}", i * math.pi / 6.0, 0.44, 0.34, 0.38, 0.12, 0.055, 0.25)
    _ico("SunflowerCentre", (0.3, 0.3, 0.15), (0.0, 0.0, 0.36), subdivisions=2)
    for i in range(6):
        angle = i * math.pi / 3.0
        _ico(f"SunflowerSeed{i}", (0.07, 0.07, 0.05), (math.cos(angle) * 0.15, math.sin(angle) * 0.15, 0.48))
    return _merge("FlowerSunflower")


def build_daisy() -> bpy.types.Object:
    """Piece 4 — a white daisy with a golden heart."""
    _stem("Daisy", 0.56, leaves=2)
    for i in range(10):
        _petal(f"DaisyPetal{i}", i * math.pi / 5.0, 0.32, 0.3, 0.32, 0.11, 0.05, 0.15)
    _torus("DaisyHeart", 0.14, 0.12, (0.0, 0.0, 0.36), 10, 6)
    return _merge("FlowerDaisy")


def build_lily() -> bpy.types.Object:
    """Piece 5 — a lily with six long pointed petals and a trumpet."""
    _stem("Lily", 0.52, leaves=2)
    for i in range(6):
        _petal(f"LilyPetal{i}", i * math.pi / 3.0, 0.3, 0.3, 0.44, 0.09, 0.045, 0.1)
    for i in range(6):
        _petal(f"LilyPetalLow{i}", i * math.pi / 3.0 + 0.3, 0.24, 0.16, 0.32, 0.09, 0.05, 0.7)
    _cone("LilyTrumpet", 8, 0.28, 0.1, 0.32, (0.0, 0.0, 0.24), flip=True)
    for i in range(3):
        angle = i * 2.0 * math.pi / 3.0
        _at(
            _cone(f"LilyStamen{i}", 4, 0.03, 0.0, 0.32, (0.0, 0.0, 0.0)),
            (math.cos(angle) * 0.08, math.sin(angle) * 0.08, 0.48),
            (0.0, 0.28, 0.0),
        )
    return _merge("FlowerLily")


def build_lotus() -> bpy.types.Object:
    """Piece 6 — a water lily floating on a pad."""
    _ico("LotusPad", (0.66, 0.66, 0.08), (0.0, 0.0, 0.0))
    for ring, (count, radius, length, z, tilt) in enumerate(
        ((8, 0.24, 0.32, 0.14, 0.5), (8, 0.38, 0.38, 0.26, 0.8), (6, 0.48, 0.4, 0.38, 1.1))
    ):
        for i in range(count):
            _petal(f"LotusPetal{ring}_{i}", i * 2.0 * math.pi / count + ring * 0.35, radius, z, length, 0.19, 0.055, tilt)
    _ico("LotusHeart", (0.15, 0.15, 0.13), (0.0, 0.0, 0.48))
    return _merge("FlowerLotus")


# --- christmas extra --------------------------------------------------------
def build_gift() -> bpy.types.Object:
    """A wrapped present with a ribbon cross and a bow."""
    box = _box("GiftBox", (0.88, 0.88, 0.7), (0.0, 0.0, 0.4))
    mm._bevel(box, 0.05, 1)
    _box("GiftRibbonA", (0.2, 0.9, 0.74), (0.0, 0.0, 0.4))
    _box("GiftRibbonB", (0.9, 0.2, 0.74), (0.0, 0.0, 0.4))
    _ico("GiftLid", (0.5, 0.5, 0.08), (0.0, 0.0, 0.78))
    for side in (-1.0, 1.0):
        _at(
            _torus(f"GiftBow{'L' if side < 0 else 'R'}", 0.16, 0.065, (0.0, 0.0, 0.0)),
            (side * 0.19, 0.0, 0.9),
            (0.0, math.pi / 2.0, side * 0.4),
        )
    _ico("GiftKnot", (0.1, 0.1, 0.09), (0.0, 0.0, 0.9))
    return _merge("XmasGift")


BUILDERS: dict[str, object] = {
    # Candy world.
    "bonbon": build_bonbon,
    "lolly": build_lolly,
    "jellybean": build_jellybean,
    "gumdrop": build_gumdrop,
    "chocolate": build_chocolate,
    "heart": build_heart,
    # Flower world.
    "rose": build_rose,
    "tulip": build_tulip,
    "sunflower": build_sunflower,
    "daisy": build_daisy,
    "lily": build_lily,
    "lotus": build_lotus,
    # Christmas extra.
    "gift": build_gift,
}


def parse_args() -> argparse.Namespace:
    argv = sys.argv
    argv = argv[argv.index("--") + 1 :] if "--" in argv else []
    parser = argparse.ArgumentParser(description="Generate the Candy Crush mesh pack.")
    parser.add_argument("--out-dir", default="godot/assets/meshes/candy", help="output directory for the .glb files")
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
