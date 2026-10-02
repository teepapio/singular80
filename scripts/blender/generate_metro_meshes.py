"""Headless Blender generator for the "Metropol 3D" mesh pack.

Produces the low-poly ``.glb`` collection of the 3D metro-network builder: the
station pavilions, the rolling stock, the river infrastructure and the city
blocks that dress the map.

Usage::

    blender --background --python scripts/blender/generate_metro_meshes.py
    blender --background --python scripts/blender/generate_metro_meshes.py -- --only station,loco

Meshes land in ``godot/assets/meshes/metro`` and are registered in
``AssetRegistry.KEYS`` (see AGENTS.md). Reuses the primitive helpers from
``make_mesh.py``, so every builder is a handful of boxes and cones.

Scenery the game borrows from the other packs instead of rebuilding here:
``rpg/pine_tree``, ``rpg/bush``, ``rpg/rock_small``, ``rpg/stone_pillar``,
``rpg/dead_tree``, ``tree``.
"""

from __future__ import annotations

import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy  # noqa: E402

import make_mesh as mm  # noqa: E402

# --- palette ----------------------------------------------------------------
CONCRETE = (0.74, 0.75, 0.78, 1.0)
CONCRETE_DARK = (0.42, 0.44, 0.5, 1.0)
STEEL = (0.62, 0.66, 0.72, 1.0)
STEEL_DARK = (0.3, 0.34, 0.4, 1.0)
GLASS = (0.55, 0.78, 0.9, 1.0)
GLASS_LIT = (1.0, 0.86, 0.45, 1.0)
ROOF = (0.3, 0.36, 0.46, 1.0)
ROOF_TRIM = (0.86, 0.88, 0.92, 1.0)
BODY = (0.9, 0.9, 0.92, 1.0)
ACCENT = (0.05, 0.65, 0.9, 1.0)
LAMP = (1.0, 0.93, 0.7, 1.0)
WOOD = (0.45, 0.3, 0.18, 1.0)
BRICK = (0.62, 0.34, 0.28, 1.0)
PLASTER = (0.82, 0.79, 0.72, 1.0)
SLATE = (0.28, 0.32, 0.4, 1.0)
DARK = (0.13, 0.14, 0.18, 1.0)
LEAF = (0.18, 0.45, 0.24, 1.0)

# Wrappers so the builders below can think in RGB instead of RGBA.
_box = mm._box
_cone = mm._cone
_torus = mm._torus
_ico = mm._ico
_join_all = mm._join_all
_bevel = mm._bevel
gable_roof = mm.gable_roof


# --- shared parts -----------------------------------------------------------
def _windows(prefix: str, count: int, span: float, y: float, z: float, size: tuple[float, float, float], lit_every: int = 3) -> None:
    """A row of window panes along the X axis, every `lit_every` one lit."""
    for i in range(count):
        x = -span * 0.5 + span * (float(i) + 0.5) / float(count)
        lit = i % lit_every == 0
        _box(
            f"{prefix}{i}",
            size,
            (x, y, z),
            GLASS_LIT if lit else GLASS,
            1.6 if lit else 0.0,
            0.25,
            0.1,
        )


def _bogies(prefix: str, x: float, z: float) -> None:
    """The two wheel sets under a rail vehicle."""
    for side in (-1, 1):
        _box(f"{prefix}Axle{side}", (0.5, 0.94, 0.14), (x, 0.0, z), STEEL_DARK, 0.0, 0.5, 0.5)
        for end in (-1, 1):
            _ico(f"{prefix}Wheel{side}{end}", (0.15, 0.15, 0.15), (x, side * 0.5, z + end * 0.3), STEEL_DARK, 0.0, 0.4, 0.7, 1)


def _platform(prefix: str, width: float, depth: float, height: float = 0.22) -> None:
    _box(f"{prefix}Slab", (width, depth, height), (0.0, 0.0, height * 0.5), CONCRETE, 0.0, 0.9, 0.0)
    _box(f"{prefix}Edge", (width, 0.08, 0.06), (0.0, depth * 0.5, height + 0.03), ACCENT, 1.2, 0.4, 0.0)


# --- stations ---------------------------------------------------------------
def build_station() -> bpy.types.Object:
    """A small halt: platform, canopy on two posts and an illuminated sign."""
    _platform("Station", 2.6, 1.5)
    for side in (-1, 1):
        _box(f"StationPost{side}", (0.09, 0.09, 1.1), (side * 0.9, -0.5, 0.72), STEEL_DARK, 0.0, 0.5, 0.3)
    _box("StationCanopy", (2.3, 1.0, 0.1), (0.0, -0.45, 1.3), ROOF, 0.0, 0.7, 0.1)
    _box("StationSign", (1.0, 0.08, 0.34), (0.0, 0.62, 1.12), ACCENT, 1.8, 0.4, 0.0)
    _box("StationMast", (0.1, 0.1, 2.2), (1.15, 0.55, 1.1), STEEL_DARK, 0.0, 0.5, 0.3)
    _ico("StationLamp", (0.16, 0.16, 0.14), (1.15, 0.55, 2.24), LAMP, 2.6, 0.3, 0.0)
    _box("StationBench", (0.7, 0.22, 0.1), (-0.6, 0.2, 0.44), WOOD, 0.0, 0.8, 0.0)
    for leg in (-1, 1):
        _box(f"StationBenchLeg{leg}", (0.08, 0.2, 0.2), (-0.6 + leg * 0.28, 0.2, 0.32), STEEL_DARK, 0.0, 0.5, 0.4)
    return _join_all("MetroStation")


def build_interchange() -> bpy.types.Object:
    """A bigger two-platform junction, used where three or more lines meet."""
    _platform("Hub", 3.4, 2.6)
    _box("HubBody", (2.2, 1.5, 1.1), (0.0, 0.0, 0.77), CONCRETE, 0.0, 0.85, 0.0)
    _box("HubBand", (2.26, 1.56, 0.16), (0.0, 0.0, 1.14), ACCENT, 1.4, 0.4, 0.0)
    _box("HubRoof", (2.5, 1.8, 0.12), (0.0, 0.0, 1.38), ROOF, 0.0, 0.7, 0.15)
    _windows("HubWindow", 5, 1.9, -0.78, 0.8, (0.26, 0.06, 0.4))
    _torus("HubRing", 0.9, 0.07, (0.0, 0.0, 2.0), ACCENT, 1.6, 0.3, 0.2, 20, 6)
    for side in (-1, 1):
        _box(f"HubStair{side}", (0.5, 0.9, 0.06), (side * 1.45, 0.9, 0.19), CONCRETE_DARK, 0.0, 0.9, 0.0)
    return _join_all("MetroInterchange")


def build_transfer_ring() -> bpy.types.Object:
    """The floating marker above a station where lines can be changed."""
    _torus("RingOuter", 1.0, 0.1, (0.0, 0.0, 0.0), ACCENT, 2.2, 0.25, 0.2, 24, 8)
    _torus("RingInner", 0.62, 0.06, (0.0, 0.0, 0.0), LAMP, 2.6, 0.25, 0.1, 20, 6)
    for i in range(4):
        angle = i * math.pi * 0.5
        _box(
            f"RingTick{i}",
            (0.16, 0.16, 0.3),
            (math.cos(angle) * 1.18, math.sin(angle) * 1.18, 0.0),
            ACCENT,
            2.0,
            0.3,
            0.0,
            (0.0, 0.0, angle),
        )
    return _join_all("MetroTransferRing")


# --- rolling stock ----------------------------------------------------------
def build_loco() -> bpy.types.Object:
    """The powered car: blunt nose, cab windows and a pantograph."""
    _box("LocoBody", (2.5, 1.05, 0.78), (0.0, 0.0, 0.72), BODY, 0.0, 0.45, 0.15)
    _box("LocoNose", (0.5, 0.92, 0.6), (1.28, 0.0, 0.62), ROOF, 0.0, 0.5, 0.15)
    _box("LocoSkirt", (2.46, 1.0, 0.22), (0.0, 0.0, 0.28), STEEL_DARK, 0.0, 0.6, 0.3)
    _box("LocoStripe", (2.52, 1.07, 0.12), (0.0, 0.0, 0.62), ACCENT, 1.3, 0.4, 0.0)
    _windows("LocoWindow", 3, 1.0, 0.0, 1.16, (0.3, 0.9, 0.28), 2)
    _box("LocoHeadlight", (0.14, 0.42, 0.2), (1.5, 0.0, 0.72), LAMP, 3.0, 0.2, 0.0)
    _box("LocoRoofBox", (0.8, 0.6, 0.14), (-0.5, 0.0, 1.16), STEEL_DARK, 0.0, 0.6, 0.3)
    for side in (-1, 1):
        _box(f"LocoPantoArm{side}", (0.07, 0.07, 0.36), (-0.5, side * 0.3, 1.4), STEEL, 0.0, 0.4, 0.6)
    _box("LocoPantoBar", (0.1, 0.9, 0.07), (-0.5, 0.0, 1.6), STEEL, 0.0, 0.4, 0.6)
    _bogies("Loco", 0.82, 0.24)
    _bogies("LocoRear", -0.82, 0.24)
    return _join_all("MetroLoco")


def build_car() -> bpy.types.Object:
    """A trailer: long window band, doors at both ends."""
    _box("CarBody", (2.4, 1.05, 0.8), (0.0, 0.0, 0.72), BODY, 0.0, 0.45, 0.15)
    _box("CarRoof", (2.3, 0.95, 0.12), (0.0, 0.0, 1.17), ROOF, 0.0, 0.6, 0.15)
    _box("CarSkirt", (2.36, 1.0, 0.2), (0.0, 0.0, 0.28), STEEL_DARK, 0.0, 0.6, 0.3)
    _box("CarStripe", (2.42, 1.07, 0.1), (0.0, 0.0, 0.58), ACCENT, 1.3, 0.4, 0.0)
    _windows("CarWindow", 6, 1.9, 0.0, 0.94, (0.22, 1.07, 0.3), 3)
    for side in (-1, 1):
        _box(f"CarDoor{side}", (0.34, 0.06, 0.62), (side * 0.86, 0.53, 0.68), ROOF_TRIM, 0.0, 0.5, 0.1)
    _bogies("Car", 0.8, 0.24)
    _bogies("CarRear", -0.8, 0.24)
    return _join_all("MetroCar")


# --- river infrastructure ---------------------------------------------------
def build_bridge() -> bpy.types.Object:
    """A short deck span that lifts a line over the water."""
    _box("BridgeDeck", (2.4, 1.5, 0.16), (0.0, 0.0, 0.0), CONCRETE, 0.0, 0.9, 0.0)
    for side in (-1, 1):
        _box(f"BridgeRail{side}", (2.4, 0.08, 0.3), (0.0, side * 0.7, 0.22), STEEL_DARK, 0.0, 0.5, 0.4)
    for end in (-1, 1):
        _box(f"BridgePier{end}", (0.24, 1.3, 0.7), (end * 0.9, 0.0, -0.42), CONCRETE_DARK, 0.0, 0.95, 0.0)
        for side in (-1, 1):
            _box(f"BridgePost{end}{side}", (0.09, 0.09, 0.4), (end * 1.1, side * 0.66, 0.28), STEEL, 0.0, 0.5, 0.4)
    return _join_all("MetroBridge")


def build_tunnel_portal() -> bpy.types.Object:
    """The arched mouth a line dives into to pass under the water."""
    _box("PortalWall", (0.34, 1.7, 1.5), (0.0, 0.0, 0.3), CONCRETE_DARK, 0.0, 0.95, 0.0)
    for side in (-1, 1):
        _cone(f"PortalArch{side}", 6, 0.42, 0.42, 0.34, (0.0, side * 0.62, 0.72), CONCRETE, 0.0, 0.9, 0.0)
    _box("PortalMouth", (0.1, 1.0, 0.86), (0.0, 0.0, 0.3), DARK, 0.0, 1.0, 0.0)
    _box("PortalLamp", (0.14, 0.24, 0.14), (0.2, 0.0, 0.94), LAMP, 3.0, 0.2, 0.0)
    return _join_all("MetroTunnelPortal")


# --- city dressing ----------------------------------------------------------
def build_house() -> bpy.types.Object:
    """A low townhouse that fills the empty blocks between the stations."""
    _box("HouseBody", (1.1, 1.0, 1.0), (0.0, 0.0, 0.5), PLASTER, 0.0, 0.9, 0.0)
    # A gabled roof, not a cone. Blender places the base vertices of
    # `primitive_cone_add` on the axes, so `vertices=4` is already a diamond
    # with half-diagonal radius1 — its corners point along X and Y and never
    # match a rectangular wall. Measured: radius1=0.86 over this 1.1 x 1.0 wall
    # left all four wall corners (|x|+|y| = 1.05) outside the roof faces.
    # The ridge runs along Y, so the -Y facade that carries the door and the
    # windows is the gable end and shows the triangle; the 1.24 width overhangs
    # the 1.10 wall by 0.07 a side and the 1.16 depth overhangs it by 0.08.
    gable_roof("HouseRoof", 1.24, 1.16, 0.5, (0.0, 0.0, 1.0), BRICK, 0.0, 0.85, 0.0)
    _box("HouseDoor", (0.2, 0.06, 0.34), (0.0, -0.51, 0.17), WOOD, 0.0, 0.8, 0.0)
    for side in (-1, 1):
        _box(f"HouseWindow{side}", (0.2, 0.06, 0.22), (side * 0.3, -0.51, 0.6), GLASS_LIT, 1.4, 0.3, 0.0)
    # On the ridge, not beside it: the foot at z=1.30 is buried in the roof, so
    # the chimney comes out of the roof instead of floating in mid air.
    _box("HouseChimney", (0.16, 0.16, 0.5), (0.0, 0.22, 1.55), BRICK, 0.0, 0.9, 0.0)
    return _join_all("MetroHouse")


def build_tower() -> bpy.types.Object:
    """A slim office block for the dense inner districts."""
    _box("TowerBody", (0.9, 0.9, 2.4), (0.0, 0.0, 1.2), SLATE, 0.0, 0.7, 0.1)
    _box("TowerCrown", (1.0, 1.0, 0.12), (0.0, 0.0, 2.46), ACCENT, 1.2, 0.5, 0.2)
    for floor in range(4):
        for side in (-1, 1):
            _box(
                f"TowerWindow{floor}{side}",
                (0.66, 0.05, 0.16),
                (0.0, side * 0.47, 0.36 + floor * 0.56),
                GLASS_LIT if (floor + side) % 3 == 0 else GLASS,
                1.5 if (floor + side) % 3 == 0 else 0.0,
                0.25,
                0.1,
            )
    _box("TowerMast", (0.07, 0.07, 0.44), (0.0, 0.0, 2.7), STEEL_DARK, 0.0, 0.5, 0.4)
    _ico("TowerBeacon", (0.1, 0.1, 0.1), (0.0, 0.0, 2.94), LAMP, 3.2, 0.2, 0.0)
    return _join_all("MetroTower")


def build_park() -> bpy.types.Object:
    """A small green square: lawn, two trees and a bench."""
    _box("ParkLawn", (1.6, 1.6, 0.08), (0.0, 0.0, 0.04), (0.24, 0.44, 0.26, 1.0), 0.0, 0.95, 0.0)
    for i, (x, y) in enumerate(((-0.42, -0.34), (0.4, 0.3))):
        _box(f"ParkTrunk{i}", (0.12, 0.12, 0.44), (x, y, 0.3), WOOD, 0.0, 0.9, 0.0)
        _ico(f"ParkCrown{i}", (0.34, 0.34, 0.3), (x, y, 0.66), LEAF, 0.0, 0.95, 0.0)
    _box("ParkBench", (0.5, 0.16, 0.08), (0.0, 0.62, 0.16), WOOD, 0.0, 0.85, 0.0)
    return _join_all("MetroPark")


def build_passenger() -> bpy.types.Object:
    """A tiny commuter: the unit the waiting rows at a platform are made of."""
    _cone("PassBody", 6, 0.11, 0.09, 0.3, (0.0, 0.0, 0.15), CONCRETE, 0.0, 0.8, 0.0)
    _ico("PassHead", (0.08, 0.08, 0.08), (0.0, 0.0, 0.35), PLASTER, 0.0, 0.9, 0.0)
    return _join_all("MetroPassenger")


# --- registry ---------------------------------------------------------------
BUILDERS: dict[str, object] = {
    "station": build_station,
    "interchange": build_interchange,
    "transfer_ring": build_transfer_ring,
    "loco": build_loco,
    "car": build_car,
    "bridge": build_bridge,
    "tunnel_portal": build_tunnel_portal,
    "house": build_house,
    "tower": build_tower,
    "park": build_park,
    "passenger": build_passenger,
}


def parse_args() -> argparse.Namespace:
    argv = sys.argv
    argv = argv[argv.index("--") + 1 :] if "--" in sys.argv else []
    parser = argparse.ArgumentParser(description="Generate the Metropol 3D mesh pack.")
    parser.add_argument(
        "--out-dir",
        default="godot/assets/meshes/metro",
        help="output directory for the .glb files",
    )
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
