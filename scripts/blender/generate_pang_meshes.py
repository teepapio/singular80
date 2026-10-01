"""Headless Blender generator for the "Pang 3D" mesh pack.

Produces the low-poly ``.glb`` collection of the Pang clone: the bouncing balls
(all four size levels share one mesh, the game scales it), the harpoon, the
fixed platform and the three bonus pickups.

Usage::

    blender --background --python scripts/blender/generate_pang_meshes.py
    blender --background --python scripts/blender/generate_pang_meshes.py -- --only orb,harpoon

Meshes land in ``godot/assets/meshes/pang`` and are registered in
``AssetRegistry.KEYS`` (see AGENTS.md). The breakable crate is the shared
``rpg/crate``, so the pack stays as small as the game needs. Reuses the
primitive helpers from ``make_mesh.py`` so the new props are built from exactly
the same parts as the rest of the collection.

Blender is Z-up, so "up" in every builder below is ``+Z``; Godot's glTF
importer does the axis conversion.
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
# The orbs are tinted per size level at runtime, so the base material stays a
# neutral pearl that reads well both tinted and untouched.
ORB_SHELL = (0.72, 0.80, 0.88, 1.0)
ORB_CORE = (0.96, 0.98, 1.0, 1.0)
GOLD = (0.95, 0.76, 0.22, 1.0)
GOLD_DARK = (0.62, 0.45, 0.10, 1.0)
STEEL = (0.70, 0.74, 0.80, 1.0)
STEEL_DARK = (0.32, 0.36, 0.44, 1.0)
STONE = (0.52, 0.53, 0.58, 1.0)
STONE_DARK = (0.31, 0.32, 0.37, 1.0)
GLASS = (0.30, 0.78, 0.88, 1.0)
BONE = (0.90, 0.88, 0.80, 1.0)
GREEN = (0.16, 0.62, 0.38, 1.0)
PINK = (0.95, 0.28, 0.48, 1.0)

TAU_3 = 2.0 * math.pi / 3.0


# --- primitive helpers ------------------------------------------------------
# The shared helpers take RGBA tuples; the builders below think in RGB, so every
# primitive is wrapped once here instead of at ~80 call sites.
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
    return mm._ico(name, scale, location, _rgba(color), emission, roughness, metallic, subdivisions)


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


def _pivot_cyl(
    name: str,
    radius: float,
    depth: float,
    offset: tuple[float, float, float],
    location: tuple[float, float, float],
    color: tuple[float, ...],
    emission: float = 0.0,
    roughness: float = 0.5,
    metallic: float = 0.1,
    vertices: int = 8,
) -> bpy.types.Object:
    """A cylinder whose origin sits at the given offset instead of its centre."""
    obj = _cyl(name, vertices, radius, depth, (0.0, 0.0, 0.0), color, emission, roughness, metallic)
    obj.data.transform(mm.Matrix.Translation(offset))
    obj.location = location
    return obj


# --- orbs -------------------------------------------------------------------

def build_orb() -> bpy.types.Object:
    """The bouncing ball. Radius 1.0 around the origin; the game scales it to
    the size level, so the mesh has to stay a clean unit sphere."""
    _ico("PangOrbShell", (1.0, 1.0, 1.0), (0.0, 0.0, 0.0), ORB_SHELL, 0.0, 0.28, 0.25, subdivisions=2)
    # A slightly smaller bright core peeking through reads as a glass bubble.
    _ico("PangOrbCore", (0.62, 0.62, 0.62), (0.0, 0.0, 0.0), ORB_CORE, 0.5, 0.2, 0.1, subdivisions=1)
    return bpy.data.objects["PangOrbShell"]


def build_platform() -> bpy.types.Object:
    """Fixed platform the harpoon sticks into and the balls bounce off. Long
    axis along X, resting on the origin so the screen can place it by its base."""
    _box("PangPlatformBody", (4.4, 0.66, 0.9), (0.0, 0.0, 0.35), STONE, 0.0, 0.92, 0.05)
    _box("PangPlatformTop", (4.6, 0.78, 0.18), (0.0, 0.0, 0.68), STONE_DARK, 0.0, 0.85, 0.08)
    for i, x in enumerate((-2.1, 2.1)):
        _box(f"PangPlatformCap{i}", (0.3, 0.98, 0.86), (x, 0.0, 0.32), STONE_DARK, 0.0, 0.95, 0.05)
        _box(f"PangPlatformBand{i}", (0.38, 1.04, 0.2), (x, 0.0, 0.6), GOLD_DARK, 0.0, 0.6, 0.4)
    return bpy.data.objects["PangPlatformBody"]


def build_ice() -> bpy.types.Object:
    """Freeze bonus: an ice cube, so the drop reads at a glance."""
    core = _box("PangIceBody", (0.62, 0.62, 0.62), (0.0, 0.0, 0.0), GLASS, 0.7, 0.12, 0.15)
    core.rotation_euler = (0.5, 0.7, 0.3)
    for i, offset in enumerate(((0.26, 0.2, 0.22), (-0.24, -0.18, 0.26), (0.06, -0.3, 0.1))):
        shard = _cone(f"PangIceShard{i}", 4, 0.14, 0.0, 0.4, offset, GLASS, 0.9, 0.1, 0.1)
        shard.rotation_euler = (0.6 * (i + 1), 0.5 * i, 0.9)
    return core


#: A disc that should face the camera is rotated a quarter turn about X, which
#: lays it in the XZ plane with its axis along Y.
#:
#: Which way that axis has to point is measured, not remembered: a probe cube
#: placed at Blender ``+Y`` exports to a glTF node with translation
#: ``(0, 0, -1)``, so Blender ``-Y`` is Godot ``+Z`` -- and the Pang camera
#: sits at ``PLAYER_Z`` looking down ``-Z``. The dial therefore faces Blender
#: ``-Y``, and ``render_mesh_views.py``'s "front" cell photographs from Blender
#: ``-Y`` as well, which is why that cell is what the player ends up seeing.
_DIAL_FACING = (math.pi / 2.0, 0.0, 0.0)


def build_clock() -> bpy.types.Object:
    """Time bonus: a pocket stopwatch, standing on edge with the dial towards the
    camera.

    Every part shares one axis (see ``_DIAL_FACING``): case, bezel, dial and
    hands are concentric discs in the same XZ plane, which is what makes the
    silhouette a circle. The previous version put the rim in the XY plane and
    the dial on the X axis, so the two were perpendicular and it read as an egg
    in a hoop. The crown sits *in* the case (its base is below the case's top
    rim) instead of hovering above it, and there are no feet: a stopwatch pickup
    is held up, it does not stand on the floor.

    Laid out from photographs of pocket stopwatches (Wikimedia Commons): a round
    case standing on edge, a bezel ring proud of a pale dial, thin dark hands
    pivoting at the centre, a small sub-dial low on the face, and a crown at
    twelve o'clock.
    """
    face = -0.07  # y of the dial's front surface; everything on the dial sits here

    case = _cyl("PangClockCase", 20, 0.33, 0.20, (0.0, 0.06, 0.0), STEEL, 0.0, 0.42, 0.35)
    case.rotation_euler = _DIAL_FACING
    # The bezel is a ring around the same centre, sitting 0.015 in front of the
    # dial so the dial reads as recessed rather than pasted on.
    rim = _torus("PangClockRim", 0.345, 0.06, (0.0, -0.03, 0.0), STEEL_DARK, 0.0, 0.3, 0.6, major_segments=20, minor_segments=6)
    rim.rotation_euler = _DIAL_FACING
    # Radius 0.295 overlaps the bezel's inner tube (0.285), so no gap opens up
    # between ring and dial at any angle.
    dial = _cyl("PangClockDial", 20, 0.295, 0.07, (0.0, -0.035, 0.0), BONE, 0.0, 0.45, 0.05)
    dial.rotation_euler = _DIAL_FACING

    # Twelve chapter ticks on a 0.25 radius, each one turned to point at the
    # centre. theta is measured from twelve o'clock and grows clockwise, which is
    # what a rotation of +theta about Y does to a mark placed at +Z.
    for i in range(12):
        theta = i * math.pi / 6.0
        _box(
            f"PangClockTick{i}",
            (0.018, 0.03, 0.05),
            (math.sin(theta) * 0.25, face - 0.008, math.cos(theta) * 0.25),
            STEEL_DARK,
            0.0,
            0.35,
            0.4,
            rotation=(0.0, theta, 0.0),
        )

    # The hands are needles that grow out of the pivot rather than through it,
    # which is what ``_pivot_cyl`` is for: the object's origin stays the middle
    # of the dial, so the rotation below aims the hand. Twelve and six make one
    # straight line through the hub, which is what makes the face read as a
    # clock; the short one stops clear of the sub-dial below it.
    for name, length, theta in (("PangClockHandLong", 0.21, 0.0), ("PangClockHandShort", 0.075, math.pi)):
        hand = _pivot_cyl(name, 0.013, length, (0.0, 0.0, length / 2.0), (0.0, face - 0.010, 0.0), STEEL_DARK, 0.0, 0.4, 0.3)
        hand.rotation_euler = (0.0, theta, 0.0)
    hub = _cyl("PangClockHub", 8, 0.032, 0.028, (0.0, face - 0.022, 0.0), STEEL_DARK, 0.0, 0.35, 0.5)
    hub.rotation_euler = _DIAL_FACING

    # The sub-dial is what stops the pale circle from reading as a blank plate.
    # Low and centred, like the pocket stopwatch, with a clear gap on both sides:
    # below the short hand's tip and above the six o'clock tick.
    sub = _cyl("PangClockSub", 12, 0.055, 0.018, (0.0, face - 0.006, -0.165), STONE, 0.0, 0.5, 0.1)
    sub.rotation_euler = _DIAL_FACING
    sub_hand = _pivot_cyl("PangClockSubHand", 0.007, 0.038, (0.0, 0.0, 0.019), (0.0, face - 0.021, -0.165), STEEL_DARK, 0.0, 0.4, 0.3)
    sub_hand.rotation_euler = (0.0, math.radians(35.0), 0.0)

    # The crown rises out of the case's top rim: the case is a drum standing on
    # edge, so its outline peaks at z = 0.33 and the crown's base is at 0.325,
    # five thousandths inside it. Nothing floats.
    _cyl("PangClockCrown", 8, 0.075, 0.12, (0.0, 0.0, 0.385), GOLD, 0.18, 0.3, 0.7)
    loop = _torus("PangClockLoop", 0.065, 0.02, (0.0, 0.0, 0.51), GOLD_DARK, 0.1, 0.3, 0.7, major_segments=12, minor_segments=6)
    loop.rotation_euler = _DIAL_FACING
    return case


def build_heart() -> bpy.types.Object:
    """Extra life: the classic arcade heart."""
    for i, (sx, sy) in enumerate(((-0.13, 0.06), (0.13, 0.06), (0.0, -0.16))):
        _ico(f"PangHeartLobe{i}", (0.19, 0.19, 0.19), (sx, sy, 0.0), PINK, 0.8, 0.35, 0.1, subdivisions=1)
    _cone("PangHeartTip", 4, 0.2, 0.0, 0.42, (0.0, -0.26, -0.06), PINK, 0.8, 0.35, 0.1, flip=True)
    return bpy.data.objects["PangHeartLobe0"]


# --- harpoon ----------------------------------------------------------------

def build_harpoon() -> bpy.types.Object:
    """The harpoon, pointing up (+Z) with its origin at the rope eye, so the
    game can just move it upwards and stretch the rope cylinder behind it."""
    eye = _torus("PangHarpoonEye", 0.16, 0.045, (0.0, 0.0, 0.0), STEEL_DARK, 0.0, 0.35, 0.5, major_segments=10, minor_segments=6)
    eye.rotation_euler = (math.pi / 2.0, 0.0, 0.0)
    _cyl("PangHarpoonShaft", 8, 0.065, 1.35, (0.0, 0.0, 0.86), STEEL, 0.0, 0.3, 0.7)
    _cone("PangHarpoonTip", 6, 0.13, 0.0, 0.44, (0.0, 0.0, 1.74), STEEL, 0.0, 0.22, 0.8)
    for i in range(3):
        angle = i * TAU_3
        # Barbs splay outward from the shaft, angled slightly back toward the
        # rope so a stuck harpoon reads as a grappling hook.
        barb = _cone(
            f"PangHarpoonBarb{i}",
            4,
            0.075,
            0.0,
            0.32,
            (math.cos(angle) * 0.12, math.sin(angle) * 0.12, 1.42),
            STEEL_DARK,
            0.0,
            0.35,
            0.6,
        )
        barb.rotation_euler = (0.0, -0.6, angle)
    _cyl("PangHarpoonCollar", 8, 0.11, 0.14, (0.0, 0.0, 1.30), GOLD, 0.15, 0.3, 0.6)
    return eye


# --- obstacles --------------------------------------------------------------






BUILDERS = {
    "orb": build_orb,
    "harpoon": build_harpoon,
    "platform": build_platform,
    "ice": build_ice,
    "clock": build_clock,
    "heart": build_heart,
}


def parse_args() -> argparse.Namespace:
    argv = sys.argv
    argv = argv[argv.index("--") + 1 :] if "--" in argv else []
    parser = argparse.ArgumentParser(description="Generate the Pang mesh pack.")
    parser.add_argument("--out-dir", default="godot/assets/meshes/pang", help="output directory for the .glb files")
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
