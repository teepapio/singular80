"""Headless renderer that photographs a batch of meshes from several angles.

Run through ``scripts/blender/shot_mesh.py`` — this file is the Blender half and
is meant to be invoked as::

    blender --background --python scripts/blender/render_mesh_views.py -- \
        --meshes godot/assets/meshes --keys candy/bonbon --tier low \
        --out /tmp/shot --size 512

It writes one PNG per view plus a JSON report with the measured geometry, and
the driver stitches the views into a single contact sheet. Nothing here decides
whether a mesh looks right: that judgement belongs to a human or to an AI
session looking at the sheet, which is the whole point of the tool.

Deliberately *not* joined: the objects are rendered exactly as the game imports
them, so an animation pivot or a parented wing shows up the way it will in play.
The bounding box is taken over every mesh object in the scene.
"""

from __future__ import annotations

import json
import math
import os
import sys

import bpy
from mathutils import Vector


#: Camera directions to shoot from. Each entry is (label, azimuth, elevation)
#: in degrees. Four angles is the smallest set that catches a shape which only
#: reads correctly from one side — the classic failure of a lollipop or a wing.
VIEWS = (
    ("front", 0.0, 12.0),
    ("three-quarter", 55.0, 18.0),
    ("side", 90.0, 8.0),
    ("top", 35.0, 72.0),
)

#: Camera lens in millimetres. A 50 mm keeps the perspective honest: a short
#: lens would make a stubby candy look like a monument.
LENS_MM = 50.0

#: Sensor width for a square render, so the horizontal and vertical fields of
#: view are equal and the framing code only has to solve for one half-angle.
SENSOR_MM = 36.0

#: How much empty room to leave around the object. Below ~1.05 the silhouette
#: touches the frame edge and a fat wing looks cropped rather than wide.
FRAME_MARGIN = 1.12

BACKGROUND = (0.62, 0.64, 0.68, 1.0)
GROUND_COLOR = (0.42, 0.44, 0.47, 1.0)


def _parse_args() -> dict:
    argv = sys.argv
    argv = argv[argv.index("--") + 1 :] if "--" in argv else []
    meshes = ""
    keys = ""
    tier = "low"
    out = "/tmp/mesh-shot"
    size = 512
    ground = "1"
    i = 0
    while i < len(argv):
        flag = argv[i]
        value = argv[i + 1] if i + 1 < len(argv) else ""
        if flag == "--meshes":
            meshes = value
        elif flag == "--keys":
            keys = value
        elif flag == "--tier":
            tier = value
        elif flag == "--out":
            out = value
        elif flag == "--size":
            size = int(value)
        elif flag == "--ground":
            ground = value
        i += 2
    return {
        "meshes": meshes,
        "keys": [key.strip() for key in keys.split(",") if key.strip()],
        "tier": tier,
        "out": out,
        "size": size,
        "ground": ground not in ("0", "false", "no", ""),
    }


def _reset_scene() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)


def _world() -> None:
    """A flat mid-grey world so the silhouette reads and nothing glows."""
    world = bpy.data.worlds.new("ShotWorld")
    world.use_nodes = True
    background = world.node_tree.nodes.get("Background")
    if background is not None:
        background.inputs[0].default_value = BACKGROUND
        background.inputs[1].default_value = 0.9
    bpy.context.scene.world = world


def _material(name: str, color: tuple[float, float, float, float]) -> bpy.types.Material:
    mat = bpy.data.materials.get(name)
    if mat is not None:
        return mat
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf is not None:
        bsdf.inputs["Base Color"].default_value = color
        bsdf.inputs["Roughness"].default_value = 0.75
        bsdf.inputs["Metallic"].default_value = 0.0
    return mat


def _lights() -> None:
    """One key light with shadows, one cool fill, one warm rim.

    Three lights rather than a flat emission look: the point of the shot is to
    read the *shape*, and a single flat light flattens exactly the creases and
    wing folds that need checking.
    """
    key_data = bpy.data.lights.new("Key", type="SUN")
    key_data.energy = 3.4
    key_data.angle = math.radians(9.0)
    key = bpy.data.objects.new("Key", key_data)
    key.rotation_euler = (math.radians(52.0), 0.0, math.radians(38.0))
    bpy.context.collection.objects.link(key)

    fill_data = bpy.data.lights.new("Fill", type="AREA")
    fill_data.energy = 90.0
    fill_data.size = 6.0
    fill = bpy.data.objects.new("Fill", fill_data)
    fill.location = (-4.0, -3.5, 2.4)
    fill.rotation_euler = (math.radians(66.0), 0.0, math.radians(-48.0))
    bpy.context.collection.objects.link(fill)

    rim_data = bpy.data.lights.new("Rim", type="AREA")
    rim_data.energy = 130.0
    rim_data.size = 3.0
    rim = bpy.data.objects.new("Rim", rim_data)
    rim.location = (3.0, 4.5, 3.0)
    rim.rotation_euler = (math.radians(132.0), 0.0, math.radians(200.0))
    bpy.context.collection.objects.link(rim)


def _render_settings(size: int) -> None:
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.render.resolution_x = size
    scene.render.resolution_y = size
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    eevee = scene.eevee
    if hasattr(eevee, "taa_render_samples"):
        eevee.taa_render_samples = 24
    for name in ("use_shadows", "use_raytracing"):
        if hasattr(eevee, name):
            setattr(eevee, name, True)


def _ground(z: float) -> None:
    """A shadow-catching plane under the object.

    A floating prop with no floor has no visual anchor, and a floor is what
    makes "is it standing upright or lying on its side" answerable at a glance.
    """
    bpy.ops.mesh.primitive_plane_add(size=200.0, location=(0.0, 0.0, z))
    plane = bpy.context.active_object
    plane.name = "ShotGround"
    plane.data.materials.append(_material("ShotGround", GROUND_COLOR))


def _mesh_objects() -> list[bpy.types.Object]:
    return [obj for obj in bpy.context.scene.objects if obj.type == "MESH" and obj.name != "ShotGround"]


def _stats(objects: list[bpy.types.Object]) -> dict:
    tris = 0
    verts = 0
    for obj in objects:
        obj.data.calc_loop_triangles()
        tris += len(obj.data.loop_triangles)
        verts += len(obj.data.vertices)
    return {"triangles": tris, "vertices": verts, "objects": len(objects)}


def _world_points(objects: list[bpy.types.Object]) -> list[Vector]:
    points: list[Vector] = []
    for obj in objects:
        matrix = obj.matrix_world
        points.extend(matrix @ vertex.co for vertex in obj.data.vertices)
    return points


def _place_camera(
    points: list[Vector],
    azimuth_deg: float,
    elevation_deg: float,
) -> tuple[bpy.types.Object, Vector]:
    """Aim a camera at the object and back it off until everything fits.

    Fitting in camera space rather than by bounding-sphere radius matters for a
    dragon: a sphere around a long body would leave it a speck in the middle of
    the frame, which is exactly the shot that hides a bad wing.
    """
    centre = Vector((0.0, 0.0, 0.0))
    for point in points:
        centre += point
    centre /= max(1, len(points))

    azimuth = math.radians(azimuth_deg)
    elevation = math.radians(elevation_deg)
    # Camera sits on this direction from the centre and looks back at it.
    offset = Vector(
        (
            math.sin(azimuth) * math.cos(elevation),
            -math.cos(azimuth) * math.cos(elevation),
            math.sin(elevation),
        )
    )

    camera_data = bpy.data.cameras.new("ShotCamera")
    camera_data.lens = LENS_MM
    camera_data.sensor_width = SENSOR_MM
    camera_data.sensor_fit = "AUTO"
    camera = bpy.data.objects.new("ShotCamera", camera_data)
    bpy.context.collection.objects.link(camera)

    forward = -offset
    camera.rotation_euler = forward.to_track_quat("-Z", "Y").to_euler()

    half_fov = math.atan(SENSOR_MM / 2.0 / LENS_MM)

    # Distance such that every point stays inside the frustum: the half-extent
    # of the projected cloud divided by the tangent of the half field of view,
    # plus the furthest point's depth towards the camera.
    right = camera.rotation_euler.to_matrix() @ Vector((1.0, 0.0, 0.0))
    up = camera.rotation_euler.to_matrix() @ Vector((0.0, 1.0, 0.0))
    extent = 0.0
    depth = 0.0
    for point in points:
        relative = point - centre
        extent = max(extent, abs(relative.dot(right)), abs(relative.dot(up)))
        depth = max(depth, relative.dot(offset))
    distance = extent / math.tan(half_fov) * FRAME_MARGIN + depth
    camera.location = centre + offset * distance
    return camera, centre


def _shoot(source: str, out_dir: str, size: int, stem: str, ground: bool) -> dict:
    _reset_scene()
    bpy.ops.import_scene.gltf(filepath=source)
    objects = _mesh_objects()
    if not objects:
        raise RuntimeError(f"no mesh object in {source}")

    points = _world_points(objects)
    stats = _stats(objects)
    stats["path"] = source
    stats["bounds"] = {
        "min": [min(p[i] for p in points) for i in range(3)],
        "max": [max(p[i] for p in points) for i in range(3)],
    }
    extent = [
        stats["bounds"]["max"][i] - stats["bounds"]["min"][i] for i in range(3)
    ]
    stats["size"] = extent
    # How tall versus how wide. A bonbon that is nearly as wide as it is tall
    # and a lolly that is far taller than wide are told apart by this alone.
    stats["aspect_height_over_width"] = (
        extent[2] / max(1e-6, max(extent[0], extent[1]))
    )

    if ground:
        _ground(min(p.z for p in points) - 0.001 * max(1.0, extent[2]))

    _world()
    _lights()
    _render_settings(size)

    camera, _centre = _place_camera(points, VIEWS[0][1], VIEWS[0][2])
    bpy.context.scene.camera = camera

    shots = []
    for label, azimuth, elevation in VIEWS:
        _place_camera(points, azimuth, elevation)
        bpy.context.view_layer.update()
        path = os.path.join(out_dir, f"{stem}__{label}.png")
        bpy.context.scene.render.filepath = path
        bpy.ops.render.render(write_still=True)
        shots.append(path)

    stats["views"] = shots
    return stats


def main() -> None:
    args = _parse_args()
    os.makedirs(args["out"], exist_ok=True)
    report = []
    for key in args["keys"]:
        source = os.path.join(args["meshes"], f"{key}.glb")
        if not os.path.exists(source):
            raise SystemExit(f"[shot] missing mesh: {source}")
        stem = key.replace("/", "__")
        stats = _shoot(source, args["out"], args["size"], stem, args["ground"])
        stats["key"] = key
        report.append(stats)
        print(
            f"[shot] {key}: tris={stats['triangles']} objects={stats['objects']} "
            f"size={[round(v, 3) for v in stats['size']]}",
            flush=True,
        )
    report_path = os.path.join(args["out"], "report.json")
    with open(report_path, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2)
    print(f"[shot] report written to {report_path}")


if __name__ == "__main__":
    main()