// Procedural PBR textures (color + normal + roughness), generated once at load.
// Everything tiles seamlessly so walls/floors can repeat without visible seams.
import * as THREE from 'three';

function rng(seed) {
  let s = seed >>> 0;
  return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; };
}

// Tileable value noise. `period` must divide evenly into the sample range so it wraps.
function makeNoise(seed, size = 256) {
  const r = rng(seed);
  const g = new Float32Array(size * size);
  for (let i = 0; i < g.length; i++) g[i] = r();
  return (x, y, period) => {
    const xi = Math.floor(x), yi = Math.floor(y);
    const xf = x - xi, yf = y - yi;
    const x0 = ((xi % period) + period) % period, y0 = ((yi % period) + period) % period;
    const x1 = (x0 + 1) % period, y1 = (y0 + 1) % period;
    const u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf);
    const a = g[(y0 % size) * size + (x0 % size)], b = g[(y0 % size) * size + (x1 % size)];
    const c = g[(y1 % size) * size + (x0 % size)], d = g[(y1 % size) * size + (x1 % size)];
    return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v;
  };
}

function fbm(n, u, v, base, oct) {
  let sum = 0, amp = 0.5, f = base, norm = 0;
  for (let o = 0; o < oct; o++) { sum += amp * n(u * f, v * f, f); norm += amp; amp *= 0.5; f *= 2; }
  return sum / norm;
}

// Build color / height / roughness buffers from a per-pixel function, then derive a normal map.
function generate(size, fn, normalStrength = 2, repeat = 1) {
  const col = document.createElement('canvas'); col.width = col.height = size;
  const rough = document.createElement('canvas'); rough.width = rough.height = size;
  const nrm = document.createElement('canvas'); nrm.width = nrm.height = size;
  const cctx = col.getContext('2d'), rctx = rough.getContext('2d'), nctx = nrm.getContext('2d');
  const cimg = cctx.createImageData(size, size), rimg = rctx.createImageData(size, size), nimg = nctx.createImageData(size, size);
  const h = new Float32Array(size * size);
  const out = { r: 0, g: 0, b: 0, h: 0, rough: 0.8 };
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      fn(x / size, y / size, out);
      const i = y * size + x, j = i * 4;
      cimg.data[j] = Math.max(0, Math.min(255, out.r * 255));
      cimg.data[j + 1] = Math.max(0, Math.min(255, out.g * 255));
      cimg.data[j + 2] = Math.max(0, Math.min(255, out.b * 255));
      cimg.data[j + 3] = 255;
      const rv = Math.max(0, Math.min(255, out.rough * 255));
      rimg.data[j] = rimg.data[j + 1] = rimg.data[j + 2] = rv; rimg.data[j + 3] = 255;
      h[i] = out.h;
    }
  }
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const xl = (x - 1 + size) % size, xr = (x + 1) % size, yu = (y - 1 + size) % size, yd = (y + 1) % size;
      const dx = (h[y * size + xr] - h[y * size + xl]) * normalStrength;
      const dy = (h[yd * size + x] - h[yu * size + x]) * normalStrength;
      const len = Math.hypot(dx, dy, 1);
      const j = (y * size + x) * 4;
      nimg.data[j] = (-dx / len * 0.5 + 0.5) * 255;
      nimg.data[j + 1] = (dy / len * 0.5 + 0.5) * 255;
      nimg.data[j + 2] = (1 / len * 0.5 + 0.5) * 255;
      nimg.data[j + 3] = 255;
    }
  }
  cctx.putImageData(cimg, 0, 0); rctx.putImageData(rimg, 0, 0); nctx.putImageData(nimg, 0, 0);
  const mk = (c, srgb) => {
    const t = new THREE.CanvasTexture(c);
    t.wrapS = t.wrapT = THREE.RepeatWrapping;
    t.repeat.set(repeat, repeat);
    if (srgb) t.colorSpace = THREE.SRGBColorSpace;
    t.anisotropy = 8;
    return t;
  };
  return { map: mk(col, true), normalMap: mk(nrm, false), roughnessMap: mk(rough, false) };
}

export function buildTextures() {
  const T = {};
  const n1 = makeNoise(11), n2 = makeNoise(23), n3 = makeNoise(37), n4 = makeNoise(59);
  const R = rng(7);
  const speck = new Float32Array(512 * 512);
  for (let i = 0; i < speck.length; i++) speck[i] = R();

  // Poured concrete slab with expansion joints, wear and damp stains.
  T.concrete = generate(512, (u, v, o) => {
    const n = fbm(n1, u, v, 4, 5);
    const stain = Math.max(0, fbm(n2, u, v, 2, 3) - 0.52) * 3;
    const s = speck[Math.floor(v * 511) * 512 + Math.floor(u * 511)];
    const joint = (Math.min(u, 1 - u) < 0.004 || Math.min(v, 1 - v) < 0.004) ? 1 : 0;
    let c = 0.47 + (n - 0.5) * 0.22 - stain * 0.12 + (s > 0.985 ? -0.12 : s < 0.01 ? 0.08 : 0);
    if (joint) c *= 0.45;
    o.r = c * 1.0; o.g = c * 0.98; o.b = c * 0.95;
    o.h = n * 0.6 + (s > 0.985 ? -0.3 : 0) - joint * 0.8;
    o.rough = 0.82 - stain * 0.35 + (n - 0.5) * 0.1;
  }, 3, 1);

  // Painted cinder-block for exterior shoot-house walls.
  T.block = generate(512, (u, v, o) => {
    const rows = 8, cols = 4;
    const ry = v * rows, row = Math.floor(ry);
    const rx = u * cols + (row % 2) * 0.5, col = Math.floor(rx);
    const fx = rx - col, fy = ry - row;
    const mortar = (fx < 0.015 || fx > 0.985 || fy < 0.035 || fy > 0.965) ? 1 : 0;
    const n = fbm(n3, u, v, 8, 4);
    const tint = (n4(col * 3.1, row * 1.7, 64) - 0.5) * 0.06;
    let c = mortar ? 0.36 : 0.5 + tint + (n - 0.5) * 0.12;
    const dirt = Math.max(0, 0.35 - v) * fbm(n2, u, v, 4, 3) * 0.5;
    o.r = c * 1.02 - dirt * 0.4; o.g = c * 0.99 - dirt * 0.45; o.b = c * 0.93 - dirt * 0.5;
    o.h = mortar ? -0.6 : n * 0.5;
    o.rough = 0.88;
  }, 2.2, 1);

  // Plywood sheets for interior partitions and doors.
  T.plywood = generate(512, (u, v, o) => {
    const warp = fbm(n1, u, v, 2, 3) * 6;
    const grain = Math.sin((v * 22 + warp) * Math.PI) * 0.5 + 0.5;
    const fine = fbm(n3, u * 1, v * 1, 16, 3);
    const knot = Math.max(0, 1 - Math.hypot((u - 0.3) * 6, (v - 0.62) * 14)) + Math.max(0, 1 - Math.hypot((u - 0.78) * 7, (v - 0.2) * 16));
    const seam = (Math.min(u, 1 - u) < 0.003) ? 1 : 0;
    let c = 0.66 + grain * 0.035 + (fine - 0.5) * 0.08 - knot * 0.08;
    if (seam) c *= 0.4;
    o.r = c * 1.0; o.g = c * 0.80; o.b = c * 0.56;
    o.h = grain * 0.08 + fine * 0.25 - seam;
    o.rough = 0.72 + grain * 0.1;
  }, 1.4, 1);

  // Gravel / packed dirt for outdoor ground.
  const pebbles = [];
  for (let i = 0; i < 900; i++) pebbles.push([R(), R(), 0.003 + R() * 0.009, R()]);
  const pebGrid = new Map();
  for (const p of pebbles) {
    const k = Math.floor(p[0] * 32) + ',' + Math.floor(p[1] * 32);
    if (!pebGrid.has(k)) pebGrid.set(k, []);
    pebGrid.get(k).push(p);
  }
  T.gravel = generate(512, (u, v, o) => {
    const n = fbm(n2, u, v, 4, 5);
    let peb = 0, pc = 0;
    const gx = Math.floor(u * 32), gy = Math.floor(v * 32);
    for (let dx = -1; dx <= 1; dx++) for (let dy = -1; dy <= 1; dy++) {
      const list = pebGrid.get(((gx + dx + 32) % 32) + ',' + ((gy + dy + 32) % 32));
      if (!list) continue;
      for (const p of list) {
        let ddx = Math.abs(u - p[0]); ddx = Math.min(ddx, 1 - ddx);
        let ddy = Math.abs(v - p[1]); ddy = Math.min(ddy, 1 - ddy);
        const d = Math.hypot(ddx, ddy) / p[2];
        if (d < 1) { const hh = Math.sqrt(1 - d * d); if (hh > peb) { peb = hh; pc = p[3]; } }
      }
    }
    const base = 0.33 + (n - 0.5) * 0.16;
    const pcol = 0.3 + pc * 0.2;
    const c = peb > 0 ? pcol * (0.75 + peb * 0.25) : base;
    o.r = c * 1.02; o.g = c * 0.93; o.b = c * 0.80;
    o.h = n * 0.3 + peb * 0.9;
    o.rough = 0.95 - peb * 0.2;
  }, 2.5, 1);

  // Painted steel (doors, plates, consoles).
  T.steel = generate(256, (u, v, o) => {
    const n = fbm(n4, u, v, 4, 4);
    const scratch = Math.abs(Math.sin((u * 0.3 + v) * 140 + n * 20)) > 0.996 ? 1 : 0;
    let c = 0.28 + (n - 0.5) * 0.08 + scratch * 0.3;
    o.r = c * 0.92; o.g = c * 0.97; o.b = c * 1.02;
    o.h = n * 0.3 - scratch * 0.4;
    o.rough = 0.55 + (n - 0.5) * 0.3 - scratch * 0.3;
  }, 1.5, 1);

  // Dirt for backstop berms.
  T.dirt = generate(256, (u, v, o) => {
    const n = fbm(n1, u, v, 4, 5), m = fbm(n3, u, v, 8, 3);
    const c = 0.30 + (n - 0.5) * 0.2 + (m - 0.5) * 0.08;
    o.r = c * 1.1; o.g = c * 0.88; o.b = c * 0.66;
    o.h = n * 0.8 + m * 0.4;
    o.rough = 0.97;
  }, 3, 1);

  // Multicam-style fabric for sleeves.
  T.camo = generate(256, (u, v, o) => {
    const a = fbm(n1, u, v, 4, 3), b = fbm(n2, u, v, 4, 3), c = fbm(n3, u, v, 8, 2);
    let r = 0.55, g = 0.50, bl = 0.38;
    if (a > 0.56) { r = 0.38; g = 0.36; bl = 0.26; }
    if (b > 0.6) { r = 0.30; g = 0.27; bl = 0.20; }
    if (c > 0.66) { r = 0.70; g = 0.66; bl = 0.52; }
    const weave = (Math.sin(u * 512 * Math.PI) * Math.sin(v * 512 * Math.PI)) * 0.04;
    o.r = r + weave; o.g = g + weave; o.b = bl + weave;
    o.h = weave * 4 + a * 0.1;
    o.rough = 0.92;
  }, 1.5, 2);

  // Stippled polymer for grips/handguards (normal detail only).
  T.polymer = generate(128, (u, v, o) => {
    const n = fbm(n4, u, v, 16, 2);
    o.r = o.g = o.b = 0.5;
    o.h = n;
    o.rough = 0.7;
  }, 3, 4);

  return T;
}

// Simple canvas helpers for sprites/decals.
export function radialTexture(size, stops) {
  const c = document.createElement('canvas'); c.width = c.height = size;
  const x = c.getContext('2d');
  const g = x.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
  for (const [p, col] of stops) g.addColorStop(p, col);
  x.fillStyle = g; x.fillRect(0, 0, size, size);
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace;
  return t;
}

export function muzzleFlashTexture() {
  const s = 256, c = document.createElement('canvas'); c.width = c.height = s;
  const x = c.getContext('2d');
  x.translate(s / 2, s / 2);
  const g = x.createRadialGradient(0, 0, 0, 0, 0, s / 2);
  g.addColorStop(0, 'rgba(255,250,230,1)');
  g.addColorStop(0.15, 'rgba(255,210,120,0.95)');
  g.addColorStop(0.45, 'rgba(255,120,30,0.35)');
  g.addColorStop(1, 'rgba(255,80,0,0)');
  x.fillStyle = g;
  for (let i = 0; i < 6; i++) {
    x.rotate(Math.PI / 3 + (Math.random() - 0.5) * 0.3);
    x.beginPath(); x.moveTo(0, -10); x.lineTo(s * 0.48, 0); x.lineTo(0, 10); x.fill();
  }
  x.beginPath(); x.arc(0, 0, s * 0.22, 0, Math.PI * 2); x.fill();
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace;
  return t;
}

export function bulletHoleTexture(metal) {
  const s = 64, c = document.createElement('canvas'); c.width = c.height = s;
  const x = c.getContext('2d');
  if (metal) {
    const g = x.createRadialGradient(32, 32, 0, 32, 32, 30);
    g.addColorStop(0, 'rgba(230,230,225,1)'); g.addColorStop(0.35, 'rgba(160,160,155,0.9)');
    g.addColorStop(0.6, 'rgba(60,60,60,0.5)'); g.addColorStop(1, 'rgba(0,0,0,0)');
    x.fillStyle = g; x.fillRect(0, 0, s, s);
  } else {
    const g = x.createRadialGradient(32, 32, 0, 32, 32, 31);
    g.addColorStop(0, 'rgba(5,5,5,1)'); g.addColorStop(0.22, 'rgba(15,12,10,1)');
    g.addColorStop(0.35, 'rgba(60,55,50,0.8)'); g.addColorStop(0.7, 'rgba(90,85,80,0.25)'); g.addColorStop(1, 'rgba(0,0,0,0)');
    x.fillStyle = g; x.fillRect(0, 0, s, s);
    x.strokeStyle = 'rgba(20,18,15,0.6)'; x.lineWidth = 1.2;
    for (let i = 0; i < 7; i++) {
      const a = Math.random() * Math.PI * 2, l = 10 + Math.random() * 14;
      x.beginPath(); x.moveTo(32 + Math.cos(a) * 6, 32 + Math.sin(a) * 6); x.lineTo(32 + Math.cos(a) * l, 32 + Math.sin(a) * l); x.stroke();
    }
  }
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace;
  return t;
}

export function reticleTexture(kind) {
  const s = 256, c = document.createElement('canvas'); c.width = c.height = s;
  const x = c.getContext('2d');
  x.strokeStyle = x.fillStyle = 'rgb(255,40,30)';
  x.shadowColor = 'rgb(255,60,40)'; x.shadowBlur = 6;
  if (kind === 'holo') {
    x.lineWidth = 5; x.beginPath(); x.arc(128, 128, 92, 0, Math.PI * 2); x.stroke();
    x.beginPath(); x.arc(128, 128, 9, 0, Math.PI * 2); x.fill();
    for (const [a, b] of [[0, -1], [0, 1], [-1, 0], [1, 0]]) {
      x.beginPath(); x.moveTo(128 + a * 92, 128 + b * 92); x.lineTo(128 + a * 110, 128 + b * 110); x.stroke();
    }
  } else {
    x.beginPath(); x.arc(128, 128, 12, 0, Math.PI * 2); x.fill();
  }
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace;
  return t;
}

// Box geometry with world-space UVs so merged walls share one seamless pattern.
export function worldBox(sx, sy, sz, cx, cy, cz, tile = 2) {
  const g = new THREE.BoxGeometry(sx, sy, sz);
  g.translate(cx, cy, cz);
  const p = g.attributes.position, n = g.attributes.normal, uv = g.attributes.uv;
  for (let i = 0; i < p.count; i++) {
    const ax = Math.abs(n.getX(i)), ay = Math.abs(n.getY(i));
    let u, v;
    if (ax > 0.5) { u = p.getZ(i); v = p.getY(i); }
    else if (ay > 0.5) { u = p.getX(i); v = p.getZ(i); }
    else { u = p.getX(i); v = p.getY(i); }
    uv.setXY(i, u / tile, v / tile);
  }
  return g;
}
