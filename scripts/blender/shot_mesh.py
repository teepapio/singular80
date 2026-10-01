"""Photograph a mesh and answer the question "does this look like the thing?".

    python3 scripts/blender/shot_mesh.py --keys candy/bonbon --out /tmp/shots
    python3 scripts/blender/shot_mesh.py --keys rpg/dragon_lord,candy/lolly
    python3 scripts/blender/shot_mesh.py --keys all --tier med --group-by-crystal

The mesh lives in ``godot/assets/meshes/<key>.glb`` for the low tier and in
``med/`` or ``high/`` for the richer ones. Blender renders each requested
angle (``render_mesh_views.py``); this script stitches them into a single
contact sheet per mesh, because four loose files in ``/tmp`` are four files
nobody looks at, and one sheet is one thing a reviewer can judge at a glance.

**Why this exists.** A ``.glb`` is binary: nothing in a diff, a triangle count
or a passing test suite says whether a dragon's wing looks like a wing. A
previous bonbon passed every check and was an unrecognisable grey blob, because
the only way to know what a mesh looks like is to look at it. This script is the
"look at it" half — the other half is a human or an AI session reading the
sheet, which no amount of assertions can replace.

Every new mesh asset should be photographed and reviewed before it is committed
(see AGENTS.md, "Neue Meshes"). Reference photographs of the real-world or
in-game subject are worth five minutes first: a search for how crystals or
dragon wings are actually shaped prevents a lot of very plausible nonsense.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import subprocess
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # pragma: no cover - the driver's own dependency
    print("[shot] Pillow is required: pip install Pillow", file=sys.stderr)
    raise

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MESH_DIR = os.path.join(REPO_ROOT, "godot", "assets", "meshes")
RENDERER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "render_mesh_views.py")
FONT_CANDIDATES = (
    os.path.join(REPO_ROOT, "godot", "assets", "fonts", "DejaVuSans-Bold.ttf"),
    os.path.join(REPO_ROOT, "godot", "assets", "fonts", "DejaVuSans.ttf"),
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
)

#: Label strip height per view, in pixels, at the default view size.
LABEL_HEIGHT = 34

#: Colour band behind the caption. Dark, because the label sits on top of a
#: mid-grey render and has to stay readable on both a pale crystal and a black
#: shadow dragon.
LABEL_BG = (28, 30, 34, 235)
LABEL_FG = (238, 240, 244, 255)


def _font(size: int) -> ImageFont.ImageFont:
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def _blender() -> str:
    found = shutil.which("blender")
    if not found:
        raise SystemExit("[shot] blender is not on PATH (see AGENTS.md)")
    return found


def discover_keys(tier: str) -> list[str]:
    """Every mesh key that has a file for `tier`."""
    root = os.path.join(MESH_DIR, tier)
    if not os.path.isdir(root):
        raise SystemExit(f"[shot] no {tier} tier directory under {MESH_DIR}")
    keys = []
    for path in glob.glob(os.path.join(root, "**", "*.glb"), recursive=True):
        rel = os.path.relpath(path, root)[: -len(".glb")]
        keys.append(rel.replace(os.sep, "/"))
    return sorted(keys)


def resolve_keys(keys: list[str]) -> list[str]:
    if keys == ["all"]:
        return discover_keys("low")
    return keys


def render(keys: list[str], out_dir: str, tier: str, size: int, ground: bool) -> list[dict]:
    os.makedirs(out_dir, exist_ok=True)
    meshes = MESH_DIR if tier == "low" else os.path.join(MESH_DIR, tier)
    command = [
        _blender(),
        "--background",
        "--factory-startup",
        "--python",
        RENDERER,
        "--",
        "--meshes", meshes,
        "--keys", ",".join(keys),
        "--tier", tier,
        "--out", out_dir,
        "--size", str(size),
        "--ground", "1" if ground else "0",
    ]
    result = subprocess.run(command, cwd=REPO_ROOT, check=False)
    if result.returncode != 0:
        raise SystemExit(f"[shot] blender exited with {result.returncode}")
    with open(os.path.join(out_dir, "report.json"), encoding="utf-8") as handle:
        return json.load(handle)


def _caption(size: int) -> tuple[int, ImageDraw.ImageDraw]:
    height = LABEL_HEIGHT
    strip = Image.new("RGBA", (size, height), LABEL_BG)
    return strip, ImageDraw.Draw(strip)


def sheet_for(entry: dict, out_dir: str, size: int) -> str:
    """Stitch the four angles of one mesh into a single sheet with a caption."""
    views = entry["views"]
    images = [Image.open(path).convert("RGBA") for path in views]
    width, height = images[0].size

    sheet = Image.new("RGBA", (width, height + LABEL_HEIGHT), (255, 255, 255, 255))
    for index, image in enumerate(images):
        sheet.paste(image, (0, index * (height + LABEL_HEIGHT)))
        strip, draw = _caption(width)
        label = os.path.basename(views[index]).replace(".png", "").split("__")[-1]
        draw.text((10, 8), label, font=_font(20), fill=LABEL_FG)
        sheet.paste(strip, (0, index * (height + LABEL_HEIGHT) + height))

    stem = entry["key"].replace("/", "__")
    path = os.path.join(out_dir, f"{stem}__sheet.png")
    sheet.convert("RGB").save(path)
    return path


def summary_for(entry: dict, size: int) -> str:
    """A fact strip under the sheet: the numbers a reviewer cannot eyeball.

    Silhouette alone cannot tell a 4-triangle plane from a 4 000-triangle one,
    and "it looks like a bonbon" is easier to judge when the aspect ratio is
    printed next to it — a bonbon that is 1.4 times taller than wide is not a
    bonbon.
    """
    bounds = entry["bounds"]
    extent = entry["size"]
    font = _font(19)
    lines = [
        f"{entry['key']}   tris {entry['triangles']}   verts {entry['vertices']}   objects {entry['objects']}",
        "size x {0[0]:.2f}  y {0[1]:.2f}  z {0[2]:.2f}   height/width {aspect:.2f}".format(
            extent, aspect=entry["aspect_height_over_width"]
        ),
        "z {0[2]:+.2f} .. {1[2]:+.2f}   x {0[0]:+.2f} .. {1[0]:+.2f}".format(bounds["min"], bounds["max"]),
    ]
    heights = [font.getbbox(line)[3] + 8 for line in lines]
    strip = Image.new("RGBA", (size, sum(heights) + 12), (250, 250, 252, 255))
    draw = ImageDraw.Draw(strip)
    y = 6
    for line, height in zip(lines, heights):
        draw.text((10, y), line, font=font, fill=(30, 32, 38, 255))
        y += height
    return strip


def build_sheets(report: list[dict], out_dir: str, size: int) -> list[str]:
    written = []
    for entry in report:
        sheet_path = sheet_for(entry, out_dir, size)
        views = [Image.open(path).convert("RGBA") for path in entry["views"]]
        width, height = views[0].size
        summary = summary_for(entry, width)
        full = Image.new(
            "RGBA",
            (width, height * len(views) + LABEL_HEIGHT * len(views) + summary.height),
            (255, 255, 255, 255),
        )
        y = 0
        for image, view_path in zip(views, entry["views"]):
            full.paste(image, (0, y))
            strip, draw = _caption(width)
            label = os.path.basename(view_path).replace(".png", "").split("__")[-1]
            draw.text((10, 8), label, font=_font(20), fill=LABEL_FG)
            full.paste(strip, (0, y + height))
            y += height + LABEL_HEIGHT
        full.paste(summary, (0, y))
        out_path = os.path.join(out_dir, f"{entry['key'].replace('/', '__')}__sheet.png")
        full.convert("RGB").save(out_path)
        for view in views:
            view.close()
        written.append(out_path)
        if sheet_path != out_path:
            try:
                os.remove(sheet_path)
            except OSError:
                pass
    return written


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render mesh screenshots and stitch them into review sheets.",
        epilog="Review the sheets yourself, or hand the paths to an AI session — "
               "that is the check. A sheet nobody looks at proves nothing.",
    )
    parser.add_argument("--keys", default="", help="comma-separated mesh keys, or 'all'")
    parser.add_argument("--tier", default="low", choices=("low", "med", "high"), help="which tier to photograph")
    parser.add_argument("--out", default="/tmp/mesh-shot", help="output directory")
    parser.add_argument("--size", type=int, default=512, help="pixels per view")
    parser.add_argument("--no-ground", action="store_true", help="omit the shadow floor")
    parser.add_argument("--keep-views", action="store_true", help="also keep the single-angle PNGs")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    keys = [key.strip() for key in args.keys.split(",") if key.strip()]
    if not keys:
        raise SystemExit("[shot] pass --keys, e.g. --keys candy/bonbon or --keys all")
    keys = resolve_keys(keys)
    os.makedirs(args.out, exist_ok=True)

    report = render(keys, args.out, args.tier, args.size, not args.no_ground)
    sheets = build_sheets(report, args.out, args.size)

    if not args.keep_views:
        for entry in report:
            for view in entry["views"]:
                try:
                    os.remove(view)
                except OSError:
                    pass

    print(f"[shot] {len(sheets)} sheet(s) in {args.out}")
    for path in sheets:
        print(f"[shot]   {path}")


if __name__ == "__main__":
    main()