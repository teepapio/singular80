/**
 * Generates the images Google Play asks for, from the game's own icon:
 *
 *   assets/generated/icon-512.png                 512×512, 32-bit PNG w/ alpha
 *   assets/generated/feature-graphic-1024x500.png 1024×500, 24-bit PNG, no alpha
 *   assets/generated/icon-192.png                 launcher icon (legacy launchers)
 *   assets/generated/adaptive-background-432.png  adaptive icon background layer
 *   assets/generated/adaptive-foreground-432.png  adaptive icon foreground layer
 *   assets/generated/adaptive-monochrome-432.png  themed icon layer
 *
 * No ImageMagick, no Python, no npm install: shapes are rasterised from signed
 * distance fields and written as PNG by hand. The geometry mirrors
 * `godot/icon.svg`.
 *
 * Two deliberate deviations from the in-app icon, because Play masks differently
 * on every surface: the store icon is a full-bleed square (no rounded corners,
 * no alpha at the edges), so any mask Play applies cuts background and never
 * artwork; the adaptive foreground keeps the mark inside the middle 66 % safe
 * zone.
 */
import { writeFileSync, existsSync, mkdirSync, statSync } from 'node:fs';
import { deflateSync } from 'node:zlib';
import { join } from 'node:path';
import { ASSET_DIR, ok, info, warn, fail, step, done, tryRun, ensureDir } from './lib.mjs';

// --- PNG encoding -----------------------------------------------------------

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i += 1) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}

/**
 * Writes RGBA bytes as a PNG; `alpha: false` writes a 24-bit PNG.
 *
 * Row filters matter: the artwork is smooth gradients, and with filter "none"
 * the 512 px icon lands right at Play's 1 MB limit. The per-row choice is the
 * standard minimum-sum-of-absolute-differences heuristic from libpng.
 */
function writePng(path, width, height, pixels, { alpha = true } = {}) {
  const channels = alpha ? 4 : 3;
  const stride = width * channels;
  const raw = Buffer.alloc((stride + 1) * height);
  const line = Buffer.alloc(stride);
  const prior = Buffer.alloc(stride);
  const candidate = Buffer.alloc(stride);

  const paeth = (a, b, c) => {
    const p = a + b - c;
    const pa = Math.abs(p - a);
    const pb = Math.abs(p - b);
    const pc = Math.abs(p - c);
    return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
  };

  for (let y = 0; y < height; y += 1) {
    pixels.copy ? pixels.copy(line, 0, y * stride, y * stride + stride)
      : line.set(pixels.subarray(y * stride, y * stride + stride));
    let bestType = 0;
    let best = null;
    let bestScore = Infinity;
    for (let type = 0; type <= 4; type += 1) {
      let score = 0;
      for (let i = 0; i < stride; i += 1) {
        const a = i >= channels ? line[i - channels] : 0;
        const b = prior[i];
        const c = i >= channels ? prior[i - channels] : 0;
        let v = line[i];
        if (type === 1) v = (line[i] - a) & 0xff;
        else if (type === 2) v = (line[i] - b) & 0xff;
        else if (type === 3) v = (line[i] - ((a + b) >> 1)) & 0xff;
        else if (type === 4) v = (line[i] - paeth(a, b, c)) & 0xff;
        candidate[i] = v;
        score += v < 128 ? v : 256 - v;
      }
      if (score < bestScore) {
        bestScore = score;
        bestType = type;
        best = Buffer.from(candidate);
      }
    }
    raw[y * (stride + 1)] = bestType;
    best.copy(raw, y * (stride + 1) + 1);
    line.copy(prior);
  }

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = alpha ? 6 : 2; // colour type: RGBA / RGB
  writeFileSync(
    path,
    Buffer.concat([
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      chunk('IHDR', ihdr),
      chunk('IDAT', deflateSync(raw, { level: 9 })),
      chunk('IEND', Buffer.alloc(0)),
    ]),
  );
}

// --- rasterising ------------------------------------------------------------

const SS = 3; // supersampling per axis

function canvas(w, h) {
  return { w, h, data: new Float32Array(w * h * 4) };
}

/** Source-over blend of one (r,g,b,a) sample at x,y into the canvas. */
function put(cv, x, y, [r, g, b, a]) {
  if (a <= 0) return;
  const i = (y * cv.w + x) * 4;
  const dst = cv.data;
  const inv = 1 - a;
  dst[i] = r * a + dst[i] * inv;
  dst[i + 1] = g * a + dst[i + 1] * inv;
  dst[i + 2] = b * a + dst[i + 2] * inv;
  dst[i + 3] = a + dst[i + 3] * inv;
}

/** Box-downsample a supersampled canvas to `out` and return RGBA bytes. */
function resolve(cv, out) {
  const bytes = Buffer.alloc(out * out * 4);
  for (let y = 0; y < out; y += 1) {
    for (let x = 0; x < out; x += 1) {
      let r = 0;
      let g = 0;
      let b = 0;
      let a = 0;
      for (let sy = 0; sy < SS; sy += 1) {
        for (let sx = 0; sx < SS; sx += 1) {
          const i = ((y * SS + sy) * cv.w + (x * SS + sx)) * 4;
          r += cv.data[i];
          g += cv.data[i + 1];
          b += cv.data[i + 2];
          a += cv.data[i + 3];
        }
      }
      const n = SS * SS;
      const i = (y * out + x) * 4;
      // Premultiplied averaging: correct for transparent edges.
      const alpha = a / n;
      const scale = alpha > 0 ? 1 / a : 0;
      bytes[i] = Math.round(Math.min(255, (r * scale) * 255));
      bytes[i + 1] = Math.round(Math.min(255, (g * scale) * 255));
      bytes[i + 2] = Math.round(Math.min(255, (b * scale) * 255));
      bytes[i + 3] = Math.round(alpha * 255);
    }
  }
  return bytes;
}

const hex = (h) => [
  parseInt(h.slice(1, 3), 16) / 255,
  parseInt(h.slice(3, 5), 16) / 255,
  parseInt(h.slice(5, 7), 16) / 255,
];
const mix = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];

const COLORS = {
  bgTop: hex('#0f172a'),
  bgBottom: hex('#05070d'),
  markStart: hex('#38bdf8'),
  markEnd: hex('#a855f7'),
  core: hex('#f8fafc'),
  bar: hex('#0ea5e9'),
};

/** Draws the Singular 80 mark; a `safeZone` below 1 clips it to the middle. */
function drawMark(cv, { cx, cy, size, safeZone = 1, background = true, mono = false }) {
  const half = size / 2;
  for (let y = 0; y < cv.h; y += 1) {
    for (let x = 0; x < cv.w; x += 1) {
      // Normalised coordinates inside the icon square, -1 … 1.
      const u = (x - cx) / half;
      const v = (y - cy) / half;
      const inBox = Math.max(Math.abs(u), Math.abs(v));
      const diag = (u + v) / 2 + 0.5;

      if (background) {
        const bg = mix(COLORS.bgTop, COLORS.bgBottom, (v + 1) / 2);
        put(cv, x, y, [...bg, 1]);
      }

      // Everything below is skipped outside the safe zone.
      const k = inBox <= safeZone ? 1 : 0;
      if (k === 0) continue;

      const mark = mono ? [1, 1, 1] : mix(COLORS.markStart, COLORS.markEnd, diag);

      const d = Math.hypot(u, v);
      if (Math.abs(d - 0.656) < 0.0195) put(cv, x, y, [...mark, 0.85]);

      if (Math.abs(u) + Math.abs(v) <= 0.3125) put(cv, x, y, [...mark, 1]);

      if (d <= 0.078) put(cv, x, y, [...COLORS.core, 1]);

      if (Math.abs(v - 0.648) <= 0.023 && Math.abs(u) <= 0.156) {
        const corner = Math.max(Math.abs(u) - (0.156 - 0.023), Math.abs(v - 0.648) - 0);
        if (corner <= 0) put(cv, x, y, [...(mono ? [1, 1, 1] : COLORS.bar), 0.8]);
      }
    }
  }
}

function square(size, opts) {
  const cv = canvas(size * SS, size * SS);
  drawMark(cv, { cx: size * SS / 2, cy: size * SS / 2, size: size * SS, ...opts });
  return resolve(cv, size);
}

function featureGraphic(w, h) {
  const cv = canvas(w * 2, h * 2);
  const W = w * 2;
  const H = h * 2;
  for (let y = 0; y < H; y += 1) {
    for (let x = 0; x < W; x += 1) {
      const t = (x / W + y / H) / 2;
      // Deep background with a soft glow behind the mark, not pure black: pure
      // black makes the graphic disappear into the Play Store background.
      const base = mix(hex('#0b1120'), hex('#131a35'), t);
      const glow = Math.max(0, 1 - Math.hypot((x - W / 2) / (W * 0.42), (y - H / 2) / (H * 0.75)));
      put(cv, x, y, [...mix(base, hex('#1e2a52'), glow * 0.55 * glow), 1]);
    }
  }
  drawMark(cv, {
    cx: W / 2,
    cy: H / 2,
    size: H * 0.86,
    background: false,
  });
  const bytes = resolve(cv, w);
  return bytes;
}

/** resolve() assumes a square canvas, so crop the 2× feature graphic by hand. */
function downsample2x(cv, w, h) {
  const bytes = Buffer.alloc(w * h * 4);
  for (let y = 0; y < h; y += 1) {
    for (let x = 0; x < w; x += 1) {
      let r = 0;
      let g = 0;
      let b = 0;
      let a = 0;
      for (let sy = 0; sy < 2; sy += 1) {
        for (let sx = 0; sx < 2; sx += 1) {
          const i = ((y * 2 + sy) * cv.w + (x * 2 + sx)) * 4;
          r += cv.data[i];
          g += cv.data[i + 1];
          b += cv.data[i + 2];
          a += cv.data[i + 3];
        }
      }
      const n = 4;
      const i = (y * w + x) * 4;
      const alpha = a / n;
      const scale = alpha > 0 ? 1 / a : 0;
      bytes[i] = Math.round(Math.min(255, r * scale * 255));
      bytes[i + 1] = Math.round(Math.min(255, g * scale * 255));
      bytes[i + 2] = Math.round(Math.min(255, b * scale * 255));
      bytes[i + 3] = Math.round(alpha * 255);
    }
  }
  return bytes;
}

// --- output -----------------------------------------------------------------

const out = ensureDir(join(ASSET_DIR, 'generated'));
const written = [];

function emit(name, width, height, bytes, alpha) {
  const path = join(out, name);
  writePng(path, width, height, bytes, { alpha });
  written.push({ name, width, height, alpha, size: statSync(path).size });
}

// Store icon: full bleed, no rounding — Play applies its own mask.
emit('icon-512.png', 512, 512, square(512, { safeZone: 1 }), true);
emit('icon-192.png', 192, 192, square(192, { safeZone: 1 }), true);
// The adaptive foreground must survive a circular mask (66 % safe zone).
emit('adaptive-background-432.png', 432, 432, square(432, { safeZone: 1 }), true);
emit('adaptive-foreground-432.png', 432, 432, square(432, { safeZone: 1, background: false }), true);
emit('adaptive-monochrome-432.png', 432, 432, square(432, { safeZone: 1, background: false, mono: true }), true);

// 24-bit PNG without an alpha channel — Play rejects alpha.
{
  const W = 1024;
  const H = 500;
  const cv = canvas(W * 2, H * 2);
  for (let y = 0; y < H * 2; y += 1) {
    for (let x = 0; x < W * 2; x += 1) {
      const t = (x / (W * 2) + y / (H * 2)) / 2;
      const base = mix(hex('#0b1120'), hex('#131a35'), t);
      const glow = Math.max(0, 1 - Math.hypot((x - W) / (W * 0.5), (y - H) / (H * 1.1)));
      put(cv, x, y, [...mix(base, hex('#1e2a52'), glow * 0.5 * glow), 1]);
    }
  }
  drawMark(cv, { cx: W, cy: H, size: H * 1.1, background: false });
  const rgba = downsample2x(cv, W, H);
  const rgb = Buffer.alloc(W * H * 3);
  for (let i = 0; i < W * H; i += 1) {
    rgb[i * 3] = rgba[i * 4];
    rgb[i * 3 + 1] = rgba[i * 4 + 1];
    rgb[i * 3 + 2] = rgba[i * 4 + 2];
  }
  emit('feature-graphic-1024x500.png', W, H, rgb, false);
}

// --- report -----------------------------------------------------------------

step(`Grafiken → ${out}`);
for (const f of written) {
  const kb = (f.size / 1024).toFixed(0);
  ok(`${f.name}  ${f.width}×${f.height}  ${f.alpha ? 'RGBA' : 'RGB'}  ~${kb} KB`);
}

const icon = written.find((f) => f.name === 'icon-512.png');
if (icon.size > 1024 * 1024) warn('icon-512.png ist über 1 MB — Play lehnt das ab.');

done('Grafiken erzeugt. Im Play Console unter "Graphics" hochladen.');
