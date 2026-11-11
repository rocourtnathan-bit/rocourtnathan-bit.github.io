// Builds missions from grid maps (or the open range), plus targets, doors, steel and the drill.
import * as THREE from 'three';
import { mergeGeometries } from '../vendor/three/addons/utils/BufferGeometryUtils.js';
import { worldBox } from './textures.js';

export const WALL_H = 2.7;
const _v = new THREE.Vector3(), _v2 = new THREE.Vector3(), _ray = new THREE.Raycaster();

function projectUV(g, tile) {
  const p = g.attributes.position, n = g.attributes.normal, uv = g.attributes.uv;
  for (let i = 0; i < p.count; i++) {
    const ax = Math.abs(n.getX(i)), ay = Math.abs(n.getY(i)), az = Math.abs(n.getZ(i));
    let u, v;
    if (ax >= ay && ax >= az) { u = p.getZ(i); v = p.getY(i); }
    else if (ay >= az) { u = p.getX(i); v = p.getZ(i); }
    else { u = p.getX(i); v = p.getY(i); }
    uv.setXY(i, u / tile, v / tile);
  }
  return g;
}

function prism(len, h, front, back, x, z, alongX = true) {
  // Trapezoid berm cross-section, extruded along its length.
  const s = new THREE.Shape();
  s.moveTo(-front, 0); s.lineTo(0, h); s.lineTo(back * 0.3, h); s.lineTo(back, 0); s.lineTo(-front, 0);
  const g = new THREE.ExtrudeGeometry(s, { depth: len, bevelEnabled: false });
  g.translate(0, 0, -len / 2);
  if (alongX) g.rotateY(Math.PI / 2); // shape x -> world -z... cross-section faces along z
  g.translate(x, 0, z);
  g.computeVertexNormals();
  return g;
}

function textCanvasTexture(lines, w = 256, h = 128, bg = '#1c2a1c', fg = '#d8f0c0', font = 'bold 40px monospace') {
  const c = document.createElement('canvas'); c.width = w; c.height = h;
  const x = c.getContext('2d');
  x.fillStyle = bg; x.fillRect(0, 0, w, h);
  x.fillStyle = fg; x.font = font; x.textAlign = 'center'; x.textBaseline = 'middle';
  lines.forEach((l, i) => x.fillText(l, w / 2, h / 2 + (i - (lines.length - 1) / 2) * (h / (lines.length + 0.5))));
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace; t.anisotropy = 4;
  t.userData = { canvas: c };
  return t;
}

// ---------- Target figures ----------
const SKIN = ['#e0b394', '#c68e6a', '#8d5a3b', '#f1c9a8', '#6b4430'];
const CIV_TOP = ['#3a6ea5', '#b84a3a', '#5e8c4a', '#d8c27a', '#7a4e8c', '#e6e6e6', '#cc7a2a'];
const HOS_TOP = ['#262626', '#2f3a2a', '#3a2f28', '#1f2530', '#403c36'];
const PANTS = ['#2b3a55', '#3b3b3b', '#5a4a36', '#1f1f1f', '#4a5560'];

function shade(ctx, x, y, w, h, color) {
  ctx.fillStyle = color; ctx.fillRect(x, y, w, h);
  const g = ctx.createLinearGradient(x, 0, x + w, 0);
  g.addColorStop(0, 'rgba(0,0,0,0.35)'); g.addColorStop(0.4, 'rgba(255,255,255,0.06)'); g.addColorStop(1, 'rgba(0,0,0,0.4)');
  ctx.fillStyle = g; ctx.fillRect(x, y, w, h);
}
function limbLine(ctx, x1, y1, x2, y2, w, color) {
  ctx.strokeStyle = color; ctx.lineWidth = w; ctx.lineCap = 'round';
  ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
  ctx.strokeStyle = 'rgba(0,0,0,0.25)'; ctx.lineWidth = w * 0.3;
  ctx.beginPath(); ctx.moveTo(x1 + w * 0.3, y1); ctx.lineTo(x2 + w * 0.3, y2); ctx.stroke();
}
function rifle(ctx, x1, y1, x2, y2) {
  ctx.save(); ctx.translate(x1, y1); ctx.rotate(Math.atan2(y2 - y1, x2 - x1));
  const L = Math.hypot(x2 - x1, y2 - y1);
  ctx.fillStyle = '#121212';
  ctx.fillRect(0, -9, L * 0.75, 18);           // body
  ctx.fillRect(L * 0.7, -4, L * 0.35, 8);       // barrel
  ctx.fillRect(-L * 0.2, -10, L * 0.25, 22);    // stock
  ctx.fillRect(L * 0.3, 6, 16, 34);             // magazine
  ctx.fillStyle = '#2a2a2a'; ctx.fillRect(L * 0.15, -16, 34, 8);
  ctx.restore();
}
function pistolSide(ctx, x, y, dir) {
  ctx.save(); ctx.translate(x, y); ctx.scale(dir, 1);
  ctx.fillStyle = '#111';
  ctx.fillRect(0, -8, 46, 15); ctx.fillRect(2, 4, 13, 24);
  ctx.restore();
}
function head(ctx, cx, cy, skin, hostile, rnd) {
  ctx.fillStyle = skin;
  ctx.beginPath(); ctx.ellipse(cx, cy, 27, 34, 0, 0, Math.PI * 2); ctx.fill();
  if (hostile && rnd > 0.35) {
    ctx.fillStyle = '#151515';
    ctx.beginPath(); ctx.ellipse(cx, cy - 2, 28, 36, 0, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = skin; ctx.fillRect(cx - 18, cy - 10, 36, 11);
    ctx.fillStyle = '#222'; ctx.fillRect(cx - 12, cy - 7, 7, 5); ctx.fillRect(cx + 5, cy - 7, 7, 5);
  } else {
    ctx.fillStyle = ['#2a1d14', '#5a3a1a', '#111', '#8a6a3a', '#3a2a1a'][Math.floor(rnd * 5)];
    ctx.beginPath(); ctx.ellipse(cx, cy - 18, 28, 20, 0, Math.PI, Math.PI * 2); ctx.fill();
    ctx.fillRect(cx - 28, cy - 20, 8, 22); ctx.fillRect(cx + 20, cy - 20, 8, 22);
    ctx.fillStyle = '#222'; ctx.fillRect(cx - 12, cy - 4, 6, 4); ctx.fillRect(cx + 6, cy - 4, 6, 4);
    ctx.fillStyle = 'rgba(120,50,40,0.6)'; ctx.fillRect(cx - 8, cy + 14, 16, 3);
  }
  const g = ctx.createRadialGradient(cx - 8, cy - 10, 4, cx, cy, 38);
  g.addColorStop(0, 'rgba(255,255,255,0.12)'); g.addColorStop(1, 'rgba(0,0,0,0.3)');
  ctx.fillStyle = g; ctx.beginPath(); ctx.ellipse(cx, cy, 28, 35, 0, 0, Math.PI * 2); ctx.fill();
}

export function drawFigure(kind, seed) {
  const W = 256, H = 512;
  const c = document.createElement('canvas'); c.width = W; c.height = H;
  const x = c.getContext('2d');
  let s = seed * 9301 + 49297; const r = () => { s = (s * 9301 + 49297) % 233280; return s / 233280; };
  const hostile = kind === 'hostile';
  const skin = SKIN[Math.floor(r() * SKIN.length)];
  const top = hostile ? HOS_TOP[Math.floor(r() * HOS_TOP.length)] : CIV_TOP[Math.floor(r() * CIV_TOP.length)];
  const pants = PANTS[Math.floor(r() * PANTS.length)];
  const pose = r();
  const kneel = kind === 'hostage';
  const oy = kneel ? 150 : 0;

  // Legs
  if (kneel) {
    shade(x, 80, 400, 96, 60, pants); shade(x, 120, 440, 70, 60, pants);
    x.fillStyle = '#1a1a1a'; x.fillRect(150, 488, 50, 22);
  } else {
    shade(x, 86, 270, 40, 225, pants); shade(x, 130, 270, 40, 225, pants);
    x.fillStyle = '#161616'; x.fillRect(80, 490, 48, 20); x.fillRect(128, 490, 48, 20);
  }
  // Torso
  x.fillStyle = top;
  x.beginPath();
  x.moveTo(62, 112 + oy); x.lineTo(194, 112 + oy); x.lineTo(180, 285 + oy * 0.8); x.lineTo(76, 285 + oy * 0.8); x.closePath(); x.fill();
  const tg = x.createLinearGradient(62, 0, 194, 0);
  tg.addColorStop(0, 'rgba(0,0,0,0.35)'); tg.addColorStop(0.45, 'rgba(255,255,255,0.08)'); tg.addColorStop(1, 'rgba(0,0,0,0.45)');
  x.fillStyle = tg; x.fill();
  if (hostile && pose > 0.5) { // plate carrier / vest
    x.fillStyle = 'rgba(30,35,25,0.9)'; x.fillRect(84, 130 + oy, 88, 110);
    x.fillStyle = 'rgba(0,0,0,0.4)'; for (let i = 0; i < 3; i++) x.fillRect(90 + i * 28, 200 + oy, 22, 34);
  }
  x.fillStyle = skin; x.fillRect(116, 92 + oy, 24, 24);
  head(x, 128, 62 + oy, skin, hostile, r());

  // Arms
  if (hostile) {
    if (pose < 0.55) {
      // Rifle at low ready across the chest
      limbLine(x, 72, 128, 92, 230, 26, top); limbLine(x, 92, 230, 150, 215, 22, top);
      limbLine(x, 184, 128, 192, 200, 26, top); limbLine(x, 192, 200, 176, 170, 22, top);
      rifle(x, 60, 255, 230, 120);
      x.fillStyle = skin; x.beginPath(); x.arc(150, 215, 11, 0, 6.3); x.arc(176, 170, 11, 0, 6.3); x.fill();
    } else {
      // Pistol, arm extended to one side (classic threat target)
      const dir = r() > 0.5 ? 1 : -1;
      const sx = dir > 0 ? 184 : 72;
      limbLine(x, sx, 128, sx + dir * 40, 150, 26, top);
      limbLine(x, sx + dir * 40, 150, sx + dir * 54, 152, 22, top);
      x.fillStyle = skin; x.beginPath(); x.arc(sx + dir * 56, 152, 11, 0, 6.3); x.fill();
      pistolSide(x, sx + dir * 54, 146, dir);
      const ox = dir > 0 ? 72 : 184;
      limbLine(x, ox, 128, ox - dir * 6, 240, 24, top);
      x.fillStyle = skin; x.beginPath(); x.arc(ox - dir * 6, 248, 11, 0, 6.3); x.fill();
    }
  } else if (kneel) {
    limbLine(x, 72, 128 + oy, 80, 250 + oy * 0.6, 24, top);
    limbLine(x, 184, 128 + oy, 176, 250 + oy * 0.6, 24, top);
    x.fillStyle = '#ddd'; x.fillRect(64, 112 + oy + 160, 128, 6); // zip ties hint
  } else if (pose < 0.5) {
    // Hands up
    limbLine(x, 72, 128, 48, 70, 24, top); limbLine(x, 48, 70, 52, 20, 20, skin);
    limbLine(x, 184, 128, 208, 70, 24, top); limbLine(x, 208, 70, 204, 20, 20, skin);
    x.fillStyle = skin; x.fillRect(40, 0, 24, 26); x.fillRect(192, 0, 24, 26);
  } else {
    // Phone / open hands
    limbLine(x, 72, 128, 64, 230, 24, top); x.fillStyle = skin; x.beginPath(); x.arc(64, 240, 11, 0, 6.3); x.fill();
    limbLine(x, 184, 128, 196, 190, 24, top); limbLine(x, 196, 190, 170, 150, 20, top);
    x.fillStyle = skin; x.beginPath(); x.arc(166, 146, 11, 0, 6.3); x.fill();
    x.fillStyle = '#e8e8e8'; x.fillRect(158, 118, 20, 32); x.fillStyle = '#4af'; x.fillRect(160, 121, 16, 25);
  }
  // Outline for readability
  const img = x.getImageData(0, 0, W, H);
  const mask = new Uint8Array((W / 4) * (H / 4));
  for (let yy = 0; yy < H / 4; yy++) for (let xx = 0; xx < W / 4; xx++) mask[yy * (W / 4) + xx] = img.data[((yy * 4 + 2) * W + xx * 4 + 2) * 4 + 3] > 40 ? 1 : 0;
  x.globalCompositeOperation = 'destination-over';
  x.shadowColor = 'rgba(0,0,0,0.9)'; x.shadowBlur = 0;
  x.globalCompositeOperation = 'source-over';
  // Back-side mask canvas
  const mc = document.createElement('canvas'); mc.width = W; mc.height = H;
  const mx = mc.getContext('2d'); mx.drawImage(c, 0, 0);
  mx.globalCompositeOperation = 'source-in'; mx.fillStyle = '#b39470'; mx.fillRect(0, 0, W, H);
  return { canvas: c, ctx: x, mask, maskCanvas: mc, W, H, headY: 62 + oy };
}

class Target {
  constructor(level, kind, x, z, yaw, popup, room, seed) {
    this.level = level; this.kind = kind; this.room = room; this.popup = popup;
    this.hostile = kind === 'hostile';
    this.state = popup ? 'down' : 'up';
    this.angle = popup ? -Math.PI / 2 : 0; this.angVel = 0;
    this.hits = 0; this.score = 0; this.exposure = 0; this.stunUntil = 0; this.fireFlash = 0;
    this.neutralized = false; this.civHit = false; this.secured = false;
    this.react = 1;
    const fig = this.fig = drawFigure(kind, seed);
    this.tex = new THREE.CanvasTexture(fig.canvas); this.tex.colorSpace = THREE.SRGBColorSpace; this.tex.anisotropy = 4;
    const backTex = new THREE.CanvasTexture(fig.maskCanvas); backTex.colorSpace = THREE.SRGBColorSpace;
    const group = this.group = new THREE.Group();
    group.position.set(x, 0, z); group.rotation.y = yaw;
    const pivot = this.pivot = new THREE.Group(); pivot.position.y = 0.06; group.add(pivot);
    const hgt = 1.8, wid = 0.9;
    const front = new THREE.Mesh(new THREE.PlaneGeometry(wid, hgt), new THREE.MeshStandardMaterial({ map: this.tex, alphaTest: 0.5, roughness: 0.85 }));
    front.position.y = hgt / 2; front.castShadow = true;
    const back = new THREE.Mesh(new THREE.PlaneGeometry(wid, hgt), new THREE.MeshStandardMaterial({ map: backTex, alphaTest: 0.5, roughness: 0.9 }));
    back.position.set(0, hgt / 2, -0.012); back.rotation.y = Math.PI; back.castShadow = true;
    front.customDepthMaterial = new THREE.MeshDepthMaterial({ depthPacking: THREE.RGBADepthPacking, map: this.tex, alphaTest: 0.5 });
    back.customDepthMaterial = new THREE.MeshDepthMaterial({ depthPacking: THREE.RGBADepthPacking, map: backTex, alphaTest: 0.5 });
    pivot.add(front, back);
    front.userData = { surf: 'target', target: this, side: 1 };
    back.userData = { surf: 'target', target: this, side: -1 };
    this.meshes = [front, back];
    // Stand
    const M = level.mats;
    const base = new THREE.Mesh(new THREE.BoxGeometry(0.55, 0.08, 0.35), M.steel); base.position.set(0, 0.04, -0.12); base.castShadow = true; base.receiveShadow = true;
    const arm = new THREE.Mesh(new THREE.BoxGeometry(0.06, 0.05, 0.12), M.steel); arm.position.set(0, 0.07, -0.02);
    group.add(base, arm);
    // MILES indicator (hostiles only)
    if (this.hostile) {
      this.ledMat = new THREE.MeshBasicMaterial({ color: new THREE.Color(0, 1.5, 0), toneMapped: false });
      const led = new THREE.Mesh(new THREE.SphereGeometry(0.025, 8, 6), this.ledMat);
      led.position.set(0.12, hgt * 0.95, 0.02); pivot.add(led);
      const fm = new THREE.SpriteMaterial({ map: level.g.flashTex, color: new THREE.Color(6, 4, 2), blending: THREE.AdditiveBlending, depthWrite: false, toneMapped: false });
      this.flashSprite = new THREE.Sprite(fm); this.flashSprite.scale.setScalar(0.5); this.flashSprite.visible = false;
      this.flashSprite.position.set(0, hgt * 0.62, 0.1); pivot.add(this.flashSprite);
    }
    level.group.add(group);
    level.shootables.push(front, back);
  }

  forward(out) { return out.set(Math.sin(this.group.rotation.y), 0, Math.cos(this.group.rotation.y)); }
  headPos(out) { return out.set(0, 1.62 - (this.kind === 'hostage' ? 0.5 : 0), 0.05).applyMatrix4(this.group.matrixWorld); }

  rise() { if (this.state === 'down') { this.state = 'rising'; this.level.g.audio.popUp(); } }
  lower() { if (this.state === 'up' || this.state === 'rising') { this.state = 'lowering'; } }

  reset() {
    this.hits = 0; this.score = 0; this.exposure = 0; this.neutralized = false; this.civHit = false;
    if (this.state === 'dead' || this.state === 'falling') { this.state = 'down'; this.angle = -Math.PI / 2; this.angVel = 0; }
    const c = this.fig.ctx; // repaint
    const fresh = drawFigure(this.kind, Math.random() * 1000 | 0);
    c.clearRect(0, 0, fresh.W, fresh.H); c.drawImage(fresh.canvas, 0, 0);
    this.fig.mask = fresh.mask; this.fig.headY = fresh.headY;
    this.tex.needsUpdate = true;
  }

  // Returns null if the bullet passed through a transparent part.
  hitTest(hit) {
    const side = hit.object.userData.side;
    const u = side > 0 ? hit.uv.x : 1 - hit.uv.x;
    const px = u * this.fig.W, py = (1 - hit.uv.y) * this.fig.H;
    const mx = Math.floor(px / 4), my = Math.floor(py / 4);
    if (mx < 0 || my < 0 || mx >= this.fig.W / 4 || my >= this.fig.H / 4) return null;
    if (!this.fig.mask[my * (this.fig.W / 4) + mx]) return null;
    let zone = 'limb';
    if (Math.hypot(px - 128, (py - this.fig.headY) * 0.8) < 30) zone = 'head';
    else if (px > 80 && px < 176 && py > 100 + (this.fig.headY - 62) && py < 285 + (this.fig.headY - 62)) zone = 'torso';
    return { px, py, zone };
  }

  hole(px, py) {
    const c = this.fig.ctx;
    c.fillStyle = 'rgba(10,8,6,1)'; c.beginPath(); c.arc(px, py, 2.6, 0, 6.3); c.fill();
    c.strokeStyle = 'rgba(80,60,40,0.7)'; c.lineWidth = 1.2; c.beginPath(); c.arc(px, py, 4, 0, 6.3); c.stroke();
    this.tex.needsUpdate = true;
  }

  onHit(info, oneHitKill) {
    if (this.state === 'falling' || this.state === 'dead' || this.state === 'down') return { already: true };
    this.hole(info.px, info.py);
    this.hits++;
    const pts = info.zone === 'head' ? 2 : info.zone === 'torso' ? 1 : 0.5;
    this.score += pts;
    if (!this.hostile) {
      this.civHit = true;
      this.angVel -= 1.2;
      return { civ: true, zone: info.zone };
    }
    if (this.score >= 2 || oneHitKill) {
      this.neutralized = true; this.state = 'falling'; this.angVel = -2.2;
      this.ledMat.color.setRGB(0.2, 0.2, 0.2);
      return { kill: true, zone: info.zone };
    }
    this.angVel -= 1.8;
    // Getting hit spoils their aim for a moment
    this.exposure = Math.min(this.exposure, this.react * 0.3);
    return { zone: info.zone };
  }

  update(dt, t) {
    if (this.state === 'rising') {
      this.angle += dt * 6;
      if (this.angle >= 0) { this.angle = 0; this.state = 'up'; this.angVel = -1; }
    } else if (this.state === 'lowering') {
      this.angle -= dt * 5;
      if (this.angle <= -Math.PI / 2) { this.angle = -Math.PI / 2; this.state = 'down'; }
    } else if (this.state === 'up') {
      this.angVel += (-70 * this.angle - 7 * this.angVel) * dt;
      this.angle += this.angVel * dt;
    } else if (this.state === 'falling') {
      this.angVel += 8.2 * Math.sin(this.angle) * dt - 0.4 * this.angVel * dt;
      this.angle += this.angVel * dt;
      if (this.angle <= -Math.PI / 2) {
        this.angle = -Math.PI / 2;
        if (Math.abs(this.angVel) > 1.2) { this.angVel = -this.angVel * 0.25; this.level.g.audio.targetFall(this.level.g.player.pos.distanceTo(this.group.position)); }
        else { this.state = 'dead'; this.angVel = 0; }
      }
    }
    this.pivot.rotation.x = this.angle;
    if (this.flashSprite) {
      if (this.fireFlash > 0) { this.fireFlash -= dt; this.flashSprite.visible = true; this.flashSprite.material.rotation = Math.random() * 6; }
      else this.flashSprite.visible = false;
      if (!this.neutralized) {
        const k = this.exposure / this.react;
        if (t < this.stunUntil) this.ledMat.color.setRGB(0.8, 0.8, 2);
        else if (k > 0.6) this.ledMat.color.setRGB((Math.sin(t * 40) > 0 ? 3 : 0.4), 0, 0);
        else if (k > 0.05) this.ledMat.color.setRGB(2.5, 1.2, 0);
        else this.ledMat.color.setRGB(0, 1.5, 0);
      }
    }
  }
}

class Door {
  constructor(level, cx, cz, alongX, locked) {
    this.level = level; this.locked = locked; this.alongX = alongX;
    this.cx = cx; this.cz = cz;
    this.angle = 0; this.angVel = 0; this.target = 0; this.spring = true; this.kicks = 0;
    this.base = alongX ? 0 : -Math.PI / 2;
    const pivot = this.pivot = new THREE.Group();
    if (alongX) pivot.position.set(cx - 0.47, 0, cz); else pivot.position.set(cx, 0, cz - 0.47);
    pivot.rotation.y = this.base;
    const M = level.mats;
    const panel = this.panel = new THREE.Mesh(worldBox(0.92, 2.08, 0.045, 0.47, 1.05, 0, 1.2), locked ? M.doorSteel : M.door);
    panel.castShadow = true; panel.receiveShadow = true;
    panel.userData = { surf: locked ? 'steel' : 'door', door: this, dynamic: true };
    pivot.add(panel);
    const hm = locked ? M.lockRed : M.handle;
    for (const s of [1, -1]) {
      const h = new THREE.Mesh(new THREE.BoxGeometry(0.12, 0.025, 0.025), hm);
      h.position.set(0.82, 1.0, s * 0.05); pivot.add(h);
      const b = new THREE.Mesh(new THREE.CylinderGeometry(0.03, 0.03, 0.02, 12).rotateX(Math.PI / 2), hm);
      b.position.set(0.86, 1.0, s * 0.03); pivot.add(b);
    }
    level.group.add(pivot);
    level.shootables.push(panel); level.occluders.push(panel);
  }

  isOpen() { return Math.abs(this.angle) > 0.5; }

  // Which way to swing so the door moves away from someone at (px,pz)
  awaySign(px, pz) { return this.alongX ? (pz > this.cz ? 1 : -1) : (px < this.cx ? 1 : -1); }

  use(px, pz) {
    if (this.locked) { this.level.g.toast('LOCKED — KICK (V) OR BREACH'); this.level.g.audio.click(400, 0.5); return; }
    this.spring = true;
    if (Math.abs(this.target) > 0.1 || Math.abs(this.angle) > 0.3) this.target = 0;
    else { this.target = 1.62 * this.awaySign(px, pz); this.level.g.audio.doorOpen(); }
  }

  kick(px, pz, force = 1) {
    this.kicks++;
    this.level.g.audio.doorKick();
    if (this.locked && this.kicks < 2 && force < 2) {
      this.angVel = 0.6 * this.awaySign(px, pz); this.spring = true; this.target = 0;
      this.level.g.toast('DOOR HOLDING — KICK AGAIN');
      this.level.g.shake(0.3);
      return;
    }
    if (this.locked) { this.locked = false; this.panel.userData.surf = 'door'; }
    this.spring = false;
    this.angVel = 9 * force * this.awaySign(px, pz);
    this.level.g.shake(0.5);
    this.level.onDoorOpened(this);
  }

  update(dt) {
    if (this.spring) this.angVel += (40 * (this.target - this.angle) - 9 * this.angVel) * dt;
    else this.angVel *= Math.exp(-1.8 * dt);
    const prev = this.angle;
    this.angle += this.angVel * dt;
    const lim = 1.78;
    if (Math.abs(this.angle) > lim) {
      this.angle = Math.sign(this.angle) * lim;
      if (Math.abs(this.angVel) > 2) this.level.g.audio.doorThud();
      this.angVel = -this.angVel * 0.25;
    }
    if (Math.abs(prev) < 0.4 && Math.abs(this.angle) >= 0.4) this.level.onDoorOpened(this);
    this.pivot.rotation.y = this.base + this.angle;
  }

  // Segment for player collision (hinge -> tip) in XZ
  segment(a, b) {
    const ang = this.base + this.angle;
    a.set(this.pivot.position.x, this.pivot.position.z);
    b.set(a.x + Math.cos(ang) * 0.94, a.y - Math.sin(ang) * 0.94);
  }
}

class Plate {
  constructor(level, x, z, shape, size, h) {
    this.level = level; this.angle = 0; this.angVel = 0; this.L = 0.3 + size * 0.5;
    const M = level.mats;
    const g = this.group = new THREE.Group(); g.position.set(x, 0, z);
    const postM = M.steel;
    const w = size + 0.3;
    for (const s of [-1, 1]) {
      const p = new THREE.Mesh(new THREE.BoxGeometry(0.06, h, 0.06), postM); p.position.set(s * w / 2, h / 2, 0); p.castShadow = true; g.add(p);
    }
    const bar = new THREE.Mesh(new THREE.BoxGeometry(w + 0.06, 0.06, 0.06), postM); bar.position.y = h; bar.castShadow = true; g.add(bar);
    const pivot = this.pivot = new THREE.Group(); pivot.position.y = h; g.add(pivot);
    for (const s of [-1, 1]) {
      const ch = new THREE.Mesh(new THREE.CylinderGeometry(0.006, 0.006, 0.3, 4), M.chain); ch.position.set(s * size * 0.25, -0.15, 0); pivot.add(ch);
    }
    const c = document.createElement('canvas'); c.width = c.height = 128;
    this.ctx = c.getContext('2d'); this.paint();
    this.tex = new THREE.CanvasTexture(c); this.tex.colorSpace = THREE.SRGBColorSpace;
    const mat = new THREE.MeshStandardMaterial({ map: this.tex, roughness: 0.6, metalness: 0.2 });
    let geo;
    if (shape === 'circle') geo = new THREE.CylinderGeometry(size / 2, size / 2, 0.012, 32).rotateX(Math.PI / 2);
    else if (shape === 'ipsc') {
      const s = new THREE.Shape(); const W = size, H = size * 1.6;
      s.moveTo(-W * 0.5, 0); s.lineTo(W * 0.5, 0); s.lineTo(W * 0.5, H * 0.62); s.lineTo(W * 0.22, H * 0.75); s.lineTo(W * 0.18, H); s.lineTo(-W * 0.18, H); s.lineTo(-W * 0.22, H * 0.75); s.lineTo(-W * 0.5, H * 0.62); s.lineTo(-W * 0.5, 0);
      geo = new THREE.ExtrudeGeometry(s, { depth: 0.012, bevelEnabled: false }); geo.translate(0, -H, 0);
      this.L = 0.3 + H * 0.5;
      const uv = geo.attributes.uv, p = geo.attributes.position;
      for (let i = 0; i < p.count; i++) uv.setXY(i, p.getX(i) / W + 0.5, p.getY(i) / H + 1);
    } else geo = new THREE.BoxGeometry(size, size * 1.4, 0.012);
    if (shape !== 'ipsc') geo.translate(0, -(shape === 'circle' ? size / 2 : size * 0.7), 0);
    const plate = this.plate = new THREE.Mesh(geo, mat);
    plate.position.y = -0.3; plate.castShadow = true;
    plate.userData = { surf: 'steel', plate: this, dynamic: true };
    pivot.add(plate);
    g.rotation.y = 0;
    level.group.add(g);
    level.shootables.push(plate);
  }
  paint() { const x = this.ctx; x.fillStyle = '#e9e7e0'; x.fillRect(0, 0, 128, 128); }
  hit(hitObj) {
    const uv = hitObj.uv;
    if (uv) {
      const x = this.ctx; x.fillStyle = 'rgba(90,90,90,0.9)';
      x.beginPath(); x.arc(uv.x * 128, (1 - uv.y) * 128, 3 + Math.random() * 2, 0, 6.3); x.fill();
      x.fillStyle = 'rgba(140,140,140,0.5)';
      for (let i = 0; i < 6; i++) { const a = Math.random() * 6.3, r = 4 + Math.random() * 6; x.fillRect(uv.x * 128 + Math.cos(a) * r, (1 - uv.y) * 128 + Math.sin(a) * r, 2, 2); }
      this.tex.needsUpdate = true;
    }
    this.angVel += 4.5;
  }
  update(dt) {
    this.angVel += (-(9.81 / this.L) * Math.sin(this.angle) - 0.7 * this.angVel) * dt;
    this.angle += this.angVel * dt;
    this.pivot.rotation.x = this.angle;
  }
}

class Paper {
  constructor(level, x, z) {
    const g = new THREE.Group(); g.position.set(x, 0, z);
    const c = document.createElement('canvas'); c.width = 256; c.height = 384;
    this.ctx = c.getContext('2d'); this.c = c; this.paint();
    this.tex = new THREE.CanvasTexture(c); this.tex.colorSpace = THREE.SRGBColorSpace;
    const m = new THREE.Mesh(new THREE.PlaneGeometry(0.46, 0.69), new THREE.MeshStandardMaterial({ map: this.tex, roughness: 0.95, side: THREE.DoubleSide }));
    m.position.y = 1.35; m.castShadow = true;
    m.userData = { surf: 'target', paper: this };
    g.add(m);
    for (const s of [-1, 1]) {
      const st = new THREE.Mesh(new THREE.BoxGeometry(0.035, 1.7, 0.02), level.mats.wood2); st.position.set(s * 0.22, 0.85, -0.02); st.castShadow = true; g.add(st);
    }
    level.group.add(g); level.shootables.push(m);
  }
  paint() {
    const x = this.ctx;
    x.fillStyle = '#c9a97a'; x.fillRect(0, 0, 256, 384);
    x.strokeStyle = 'rgba(60,40,20,0.6)'; x.lineWidth = 2;
    x.strokeRect(48, 70, 160, 300); x.strokeRect(78, 110, 100, 170);
    x.beginPath(); x.arc(128, 40, 26, 0, 6.3); x.stroke();
    x.strokeRect(104, 20, 48, 30);
    x.fillStyle = 'rgba(60,40,20,0.7)'; x.font = 'bold 18px sans-serif'; x.textAlign = 'center';
    x.fillText('A', 128, 200); x.fillText('C', 64, 340); x.fillText('D', 230, 360);
  }
  hit(h) {
    const x = this.ctx, px = h.uv.x * 256, py = (1 - h.uv.y) * 384;
    x.fillStyle = '#0a0806'; x.beginPath(); x.arc(px, py, 3, 0, 6.3); x.fill();
    this.tex.needsUpdate = true;
  }
}

export class Level {
  constructor(game, mission) {
    this.g = game; this.mission = mission;
    this.group = new THREE.Group(); game.scene.add(this.group);
    this.colliders = []; this.shootables = []; this.occluders = [];
    this.targets = []; this.doors = []; this.plates = []; this.papers = []; this.lampLights = [];
    this.lamps = []; this.extract = null; this.hostage = null;
    this.roomCleared = new Set(); this.roomNames = new Map();
    this.time = 0;
    this.makeMats();
    if (mission.env === 'range') this.buildRange(); else this.buildHouse();
    this.group.updateMatrixWorld(true);
  }

  makeMats() {
    const T = this.g.T;
    const std = (t, extra) => new THREE.MeshStandardMaterial({ map: t.map, normalMap: t.normalMap, roughnessMap: t.roughnessMap, ...extra });
    this.mats = {
      concrete: std(T.concrete, { normalScale: new THREE.Vector2(0.8, 0.8) }),
      block: std(T.block, {}),
      plywood: std(T.plywood, { normalScale: new THREE.Vector2(0.6, 0.6) }),
      gravel: std(T.gravel, { normalScale: new THREE.Vector2(1.2, 1.2) }),
      dirt: std(T.dirt, {}),
      steel: std(T.steel, { metalness: 0.7, color: 0x8a9095 }),
      door: std(T.plywood, { color: 0xb89e80 }),
      doorSteel: std(T.steel, { metalness: 0.6, color: 0x55606a }),
      crate: std(T.plywood, { color: 0x9a8058 }),
      wood2: std(T.plywood, { color: 0x8a6a48 }),
      handle: new THREE.MeshStandardMaterial({ color: 0x888888, metalness: 1, roughness: 0.3 }),
      lockRed: new THREE.MeshStandardMaterial({ color: 0xaa1010, emissive: 0x550000, metalness: 0.5, roughness: 0.4 }),
      chain: new THREE.MeshStandardMaterial({ color: 0x777777, metalness: 1, roughness: 0.5 }),
    };
  }

  addCollider(minX, maxX, minZ, maxZ) { this.colliders.push({ minX, maxX, minZ, maxZ }); }

  addMerged(geos, mat, surf, { occlude = true, shoot = true, shadow = true } = {}) {
    if (!geos.length) return null;
    const g = mergeGeometries(geos, false);
    const m = new THREE.Mesh(g, mat);
    m.castShadow = shadow; m.receiveShadow = true;
    m.userData = { surf };
    this.group.add(m);
    if (shoot) this.shootables.push(m);
    if (occlude) this.occluders.push(m);
    return m;
  }

  floorAt() { return 0; }

  // ---------------- Kill house ----------------
  buildHouse() {
    const map = this.mission.map, H = map.length, W = map[0].length;
    this.W = W; this.H = H;
    const at = (c, r) => (r < 0 || r >= H || c < 0 || c >= W) ? '#' : map[r][c];
    const solid = ch => ch === '#';
    const used = new Uint8Array(W * H);
    const wallGeos = { block: [], plywood: [] };
    const isBorder = (c, r) => r === 0 || c === 0 || r === H - 1 || c === W - 1;
    // Horizontal runs
    for (let r = 0; r < H; r++) {
      let c = 0;
      while (c < W) {
        if (!solid(at(c, r))) { c++; continue; }
        const border = isBorder(c, r);
        let e = c; while (e + 1 < W && solid(at(e + 1, r)) && isBorder(e + 1, r) === border) e++;
        if (e > c) {
          for (let k = c; k <= e; k++) used[r * W + k] = 1;
          wallGeos[border ? 'block' : 'plywood'].push(worldBox(e - c + 1, WALL_H, 1, (c + e + 1) / 2, WALL_H / 2, r + 0.5, border ? 1.6 : 1.22));
          this.addCollider(c, e + 1, r, r + 1);
        }
        c = e + 1;
      }
    }
    // Vertical runs of leftovers
    for (let c = 0; c < W; c++) {
      let r = 0;
      while (r < H) {
        if (!solid(at(c, r)) || used[r * W + c]) { r++; continue; }
        const border = isBorder(c, r);
        let e = r; while (e + 1 < H && solid(at(c, e + 1)) && !used[(e + 1) * W + c] && isBorder(c, e + 1) === border) e++;
        wallGeos[border ? 'block' : 'plywood'].push(worldBox(1, WALL_H, e - r + 1, c + 0.5, WALL_H / 2, (r + e + 1) / 2, border ? 1.6 : 1.22));
        this.addCollider(c, c + 1, r, e + 1);
        r = e + 1;
      }
    }
    // Windows, doors, crates, entities
    const crateGeos = [], trimGeos = [];
    const ents = [];
    let spawn = null;
    for (let r = 0; r < H; r++) for (let c = 0; c < W; c++) {
      const ch = at(c, r), x = c + 0.5, z = r + 0.5;
      if (ch === 'W') {
        wallGeos.plywood.push(worldBox(1, 1.0, 1, x, 0.5, z, 1.22));
        wallGeos.plywood.push(worldBox(1, WALL_H - 2.1, 1, x, (WALL_H + 2.1) / 2, z, 1.22));
        trimGeos.push(worldBox(1.02, 0.05, 1.04, x, 1.02, z, 1));
        this.addCollider(c, c + 1, r, r + 1);
      } else if (ch === 'D' || ch === 'K') {
        wallGeos.plywood.push(worldBox(1, WALL_H - 2.12, 1, x, (WALL_H + 2.12) / 2, z, 1.22));
        const alongX = solid(at(c - 1, r)) && solid(at(c + 1, r));
        this.doors.push(new Door(this, x, z, alongX, ch === 'K'));
        // Frame trim
        if (alongX) { trimGeos.push(worldBox(0.06, 2.12, 1.02, c + 0.03, 1.06, z, 1)); trimGeos.push(worldBox(0.06, 2.12, 1.02, c + 0.97, 1.06, z, 1)); }
        else { trimGeos.push(worldBox(1.02, 2.12, 0.06, x, 1.06, r + 0.03, 1)); trimGeos.push(worldBox(1.02, 2.12, 0.06, x, 1.06, r + 0.97, 1)); }
      } else if (ch === 'X') {
        const s = 0.92, hgt = 0.95;
        crateGeos.push(worldBox(s, hgt, s, x, hgt / 2, z, 1));
        trimGeos.push(worldBox(s + 0.02, 0.06, s + 0.02, x, hgt - 0.03, z, 1));
        trimGeos.push(worldBox(s + 0.02, 0.06, s + 0.02, x, 0.03, z, 1));
        this.addCollider(x - s / 2, x + s / 2, z - s / 2, z + s / 2);
      } else if (ch === 'P') spawn = new THREE.Vector3(x, 0, z);
      else if ('hHcCS'.includes(ch)) ents.push({ ch, x, z, c, r });
      else if (ch === 'L') this.lamps.push({ x, z });
      else if (ch === 'E') this.extractPos = new THREE.Vector3(x, 0, z);
    }
    this.spawn = spawn || new THREE.Vector3(1.5, 0, 1.5);

    const M = this.mats;
    this.addMerged(wallGeos.block, M.block, 'block');
    this.addMerged(wallGeos.plywood, M.plywood, 'wood');
    this.addMerged(crateGeos, M.crate, 'wood');
    this.addMerged(trimGeos, M.wood2, 'wood');

    // Floor slab and surrounding gravel
    const slab = new THREE.Mesh(worldBox(W, 0.1, H, W / 2, -0.05, H / 2, 4), M.concrete);
    slab.receiveShadow = true; slab.userData = { surf: 'concrete' };
    this.group.add(slab); this.shootables.push(slab);
    const ground = new THREE.Mesh(projectUV(new THREE.PlaneGeometry(300, 300).rotateX(-Math.PI / 2).translate(W / 2, -0.02, H / 2), 3), M.gravel);
    ground.receiveShadow = true; ground.userData = { surf: 'gravel' };
    this.group.add(ground); this.shootables.push(ground);
    this.buildSurroundings(W, H);

    // Rooms via flood fill (doors/windows/walls separate rooms)
    this.rooms = new Int16Array(W * H).fill(-1);
    let rid = 0;
    const blocks = ch => '#DKW'.includes(ch);
    for (let r = 0; r < H; r++) for (let c = 0; c < W; c++) {
      if (blocks(at(c, r)) || this.rooms[r * W + c] >= 0) continue;
      const stack = [[c, r]]; this.rooms[r * W + c] = rid;
      while (stack.length) {
        const [cc, rr] = stack.pop();
        for (const [dc, dr] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
          const nc = cc + dc, nr = rr + dr;
          if (nc < 0 || nr < 0 || nc >= W || nr >= H) continue;
          if (blocks(at(nc, nr)) || this.rooms[nr * W + nc] >= 0) continue;
          this.rooms[nr * W + nc] = rid; stack.push([nc, nr]);
        }
      }
      rid++;
    }
    this.spawnRoom = this.roomAt(this.spawn.x, this.spawn.z);

    // Targets: face the nearest door of their room (they cover the entry), or the spawn if in the spawn room.
    let seed = 1;
    for (const e of ents) {
      const room = this.roomAt(e.x, e.z);
      let look = null;
      if (room === this.spawnRoom) look = this.spawn;
      else {
        let best = 1e9;
        for (const d of this.doors) {
          const adj = [[d.cx + 1, d.cz], [d.cx - 1, d.cz], [d.cx, d.cz + 1], [d.cx, d.cz - 1]].some(([ax, az]) => this.roomAt(ax, az) === room);
          if (!adj) continue;
          const dist = Math.hypot(d.cx - e.x, d.cz - e.z);
          if (dist < best) { best = dist; look = new THREE.Vector3(d.cx, 0, d.cz); }
        }
      }
      let yaw = look ? Math.atan2(look.x - e.x, look.z - e.z) : 0;
      yaw += (Math.random() - 0.5) * 0.3;
      const kind = 'hH'.includes(e.ch) ? 'hostile' : e.ch === 'S' ? 'hostage' : 'civilian';
      const t = new Target(this, kind, e.x, e.z, yaw, 'HC'.includes(e.ch), room, seed++ * 17 + Math.floor(Math.random() * 1000));
      this.targets.push(t);
      if (kind === 'hostage') this.hostage = t;
    }
    // Name rooms in discovery order (spawn room is the hallway)
    let n = 1;
    for (const t of this.targets) if (t.room !== this.spawnRoom && !this.roomNames.has(t.room)) this.roomNames.set(t.room, n++);

    // Extraction marker
    if (this.extractPos) {
      const ring = new THREE.Mesh(new THREE.RingGeometry(0.7, 0.85, 40).rotateX(-Math.PI / 2), new THREE.MeshBasicMaterial({ color: new THREE.Color(0.2, 1.6, 0.4), transparent: true, opacity: 0.7, toneMapped: false, depthWrite: false }));
      ring.position.copy(this.extractPos).setY(0.02);
      const beam = new THREE.Mesh(new THREE.CylinderGeometry(0.8, 0.8, 3, 32, 1, true), new THREE.MeshBasicMaterial({ color: new THREE.Color(0.1, 0.8, 0.2), transparent: true, opacity: 0.12, side: THREE.DoubleSide, depthWrite: false, blending: THREE.AdditiveBlending, toneMapped: false }));
      beam.position.copy(this.extractPos).setY(1.5);
      this.group.add(ring, beam);
      this.extract = { ring, beam };
      ring.visible = beam.visible = false;
    }

    // Lamps
    for (const l of this.lamps) this.addLamp(l.x, l.z);
  }

  buildSurroundings(W, H, fence = true) {
    const M = this.mats;
    if (fence) this.buildFence(W, H);
    this.buildTrees(W / 2, H / 2, fence ? 45 : 75);
  }

  buildFence(W, H) {
    const M = this.mats;
    const geos = [];
    for (let i = -8; i < W + 8; i += 3) { geos.push(worldBox(0.08, 2.2, 0.08, i, 1.1, -8, 1)); geos.push(worldBox(0.08, 2.2, 0.08, i, 1.1, H + 8, 1)); }
    for (let i = -8; i < H + 8; i += 3) { geos.push(worldBox(0.08, 2.2, 0.08, -8, 1.1, i, 1)); geos.push(worldBox(0.08, 2.2, 0.08, W + 8, 1.1, i, 1)); }
    this.addMerged(geos, M.steel, 'metal', { occlude: false });
    const fenceMat = new THREE.MeshStandardMaterial({ color: 0x6a6f70, transparent: true, opacity: 0.25, metalness: 0.8, roughness: 0.5, side: THREE.DoubleSide, depthWrite: false });
    for (const [x, z, w, ry] of [[W / 2, -8, W + 16, 0], [W / 2, H + 8, W + 16, 0], [-8, H / 2, H + 16, Math.PI / 2], [W + 8, H / 2, H + 16, Math.PI / 2]]) {
      const f = new THREE.Mesh(new THREE.PlaneGeometry(w, 2.1), fenceMat); f.position.set(x, 1.05, z); f.rotation.y = ry; this.group.add(f);
    }
  }

  buildTrees(cx, cz, minD) {
    const treeG = new THREE.ConeGeometry(2.2, 9, 7); treeG.translate(0, 4.5, 0);
    const trunkG = new THREE.CylinderGeometry(0.2, 0.3, 2, 6); trunkG.translate(0, 1, 0);
    const treeM = new THREE.MeshStandardMaterial({ color: 0x2f3d26, roughness: 0.95 });
    const trees = new THREE.InstancedMesh(treeG, treeM, 90);
    const m4 = new THREE.Matrix4(), q = new THREE.Quaternion(), s = new THREE.Vector3(), p = new THREE.Vector3();
    for (let i = 0; i < 90; i++) {
      const a = Math.random() * Math.PI * 2, d = minD + Math.random() * 60;
      p.set(cx + Math.cos(a) * d, 0, cz + Math.sin(a) * d);
      const k = 0.7 + Math.random() * 0.8; s.set(k, k * (0.8 + Math.random() * 0.5), k);
      m4.compose(p, q, s); trees.setMatrixAt(i, m4);
    }
    trees.castShadow = false; trees.receiveShadow = true;
    this.group.add(trees);
  }

  addLamp(x, z) {
    const g = this.g;
    const shade = new THREE.Mesh(new THREE.ConeGeometry(0.28, 0.22, 16, 1, true), new THREE.MeshStandardMaterial({ color: 0x2a2d2a, metalness: 0.6, roughness: 0.5, side: THREE.DoubleSide }));
    shade.position.set(x, 2.55, z);
    const bulb = new THREE.Mesh(new THREE.SphereGeometry(0.07, 12, 8), new THREE.MeshBasicMaterial({ color: new THREE.Color(6, 4.2, 2.2), toneMapped: false }));
    bulb.position.set(x, 2.46, z);
    const cord = new THREE.Mesh(new THREE.CylinderGeometry(0.005, 0.005, 0.6), this.mats.chain); cord.position.set(x, 2.95, z);
    this.group.add(shade, bulb, cord);
    const sl = new THREE.SpotLight(0xffc98a, 14, 14, 1.05, 0.6, 1.6);
    sl.position.set(x, 2.45, z);
    sl.target.position.set(x, 0, z);
    const allowShadow = this.lampLights.filter(l => l.castShadow).length < g.quality.lampShadows;
    sl.castShadow = allowShadow;
    if (allowShadow) { sl.shadow.mapSize.set(512, 512); sl.shadow.bias = -0.0008; sl.shadow.camera.near = 0.1; sl.shadow.camera.far = 14; }
    this.group.add(sl, sl.target);
    this.lampLights.push(sl);
    sl.userData.bulb = bulb; sl.userData.base = 14; sl.userData.flicker = Math.random() < 0.25;
  }

  // ---------------- Range ----------------
  buildRange() {
    const M = this.mats;
    this.W = 40; this.H = 120;
    this.spawn = new THREE.Vector3(0, 0, 3.5);
    const ground = new THREE.Mesh(projectUV(new THREE.PlaneGeometry(400, 400).rotateX(-Math.PI / 2).translate(0, 0, -50), 3), M.gravel);
    ground.receiveShadow = true; ground.userData = { surf: 'dirt' };
    this.group.add(ground); this.shootables.push(ground);
    // Covered firing point
    const pad = new THREE.Mesh(worldBox(30, 0.1, 7, 0, -0.04, 1.5, 4), M.concrete); pad.receiveShadow = true; pad.userData = { surf: 'concrete' };
    this.group.add(pad); this.shootables.push(pad);
    const roof = [], wood = [], steel = [];
    roof.push(worldBox(31, 0.15, 6, 0, 3.0, 1.8, 2));
    for (let x = -15; x <= 15; x += 5) { steel.push(worldBox(0.15, 3, 0.15, x, 1.5, -1, 1)); steel.push(worldBox(0.15, 3, 0.15, x, 1.5, 4.6, 1)); this.addCollider(x - 0.1, x + 0.1, -1.1, -0.9); this.addCollider(x - 0.1, x + 0.1, 4.5, 4.7); }
    // Lanes: benches and dividers
    for (let i = 0; i < 6; i++) {
      const x = -12.5 + i * 5 + 2.5;
      wood.push(worldBox(1.6, 0.06, 0.7, x, 0.9, -0.4, 1));
      wood.push(worldBox(0.06, 0.9, 0.06, x - 0.75, 0.45, -0.7, 1), worldBox(0.06, 0.9, 0.06, x + 0.75, 0.45, -0.7, 1), worldBox(0.06, 0.9, 0.06, x - 0.75, 0.45, -0.1, 1), worldBox(0.06, 0.9, 0.06, x + 0.75, 0.45, -0.1, 1));
      this.addCollider(x - 0.8, x + 0.8, -0.75, -0.05);
    }
    for (let i = 0; i <= 6; i++) {
      const x = -15 + i * 5;
      wood.push(worldBox(0.05, 1.9, 1.6, x, 0.95, -0.1, 1.22));
      this.addCollider(x - 0.05, x + 0.05, -0.9, 0.7);
    }
    this.addMerged(roof, M.concrete, 'concrete');
    this.addMerged(wood, M.plywood, 'wood');
    this.addMerged(steel, M.steel, 'metal');
    // Berms
    const bermGeos = [
      projectUV(prism(90, 7, 9, 8, 0, -110, true), 3),
      projectUV(prism(110, 3.5, 4, 4, -21, -50, false), 3),
      projectUV(prism(110, 3.5, 4, 4, 21, -50, false), 3),
    ];
    this.addMerged(bermGeos, M.dirt, 'dirt', { occlude: false });
    // Invisible bounds
    this.addCollider(-17, -16, -110, 12); this.addCollider(16, 17, -110, 12);
    this.addCollider(-17, 17, 11, 12); this.addCollider(-17, 17, -104, -103);
    // Distance markers
    for (const d of [7, 15, 25, 50, 75, 100]) {
      const tex = textCanvasTexture([d + ' m'], 128, 64, '#f2f0e6', '#202020', 'bold 34px sans-serif');
      const sign = new THREE.Mesh(new THREE.PlaneGeometry(0.8, 0.4), new THREE.MeshStandardMaterial({ map: tex, roughness: 0.8 }));
      sign.position.set(-15.5, 0.6, -d); sign.rotation.y = 0.5; this.group.add(sign);
      const post = new THREE.Mesh(new THREE.BoxGeometry(0.05, 0.6, 0.05), M.wood2); post.position.set(-15.5, 0.3, -d - 0.02); this.group.add(post);
    }
    // Paper targets (7 & 15 m)
    for (let i = 0; i < 6; i++) { const x = -12.5 + i * 5 + 2.5; this.papers.push(new Paper(this, x - 0.8, -7)); this.papers.push(new Paper(this, x + 0.8, -15)); }
    // Steel
    for (let i = 0; i < 6; i++) {
      const x = -12.5 + i * 5 + 2.5;
      for (const o of [-0.8, 0, 0.8]) this.plates.push(new Plate(this, x + o, -25, 'circle', 0.22, 1.1));
      this.plates.push(new Plate(this, x - 0.6, -50, 'rect', 0.32, 1.4));
      this.plates.push(new Plate(this, x + 0.6, -75, 'ipsc', 0.45, 1.6));
      this.plates.push(new Plate(this, x, -100, 'ipsc', 0.45, 1.9));
    }
    // Drill pop-ups between lanes
    const drillSpots = [];
    for (const d of [10, 18, 30, 40, 60]) for (let i = 0; i < 4; i++) drillSpots.push([-11 + i * 7.3 + (Math.random() - 0.5) * 1.5, -d]);
    let seed = 3;
    for (const [x, z] of drillSpots) {
      const kind = Math.random() < 0.22 ? 'civilian' : 'hostile';
      this.targets.push(new Target(this, kind, x, z, Math.atan2(-x * 0.1, 1), true, 0, seed++ * 13));
    }
    // Console
    const con = new THREE.Group(); con.position.set(-2.5, 0, 1.6);
    const body = new THREE.Mesh(new THREE.BoxGeometry(0.6, 1.1, 0.4), M.steel); body.position.y = 0.55; body.castShadow = true; con.add(body);
    this.consoleTex = textCanvasTexture(['QUAL DRILL', 'PRESS [F]'], 256, 160);
    const screen = new THREE.Mesh(new THREE.PlaneGeometry(0.5, 0.31), new THREE.MeshBasicMaterial({ map: this.consoleTex, toneMapped: false, color: new THREE.Color(1.4, 1.4, 1.4) }));
    screen.position.set(0, 1.05, 0.12); screen.rotation.x = -0.6; con.add(screen);
    con.rotation.y = Math.PI;
    this.group.add(con); this.addCollider(-2.8, -2.2, 1.4, 1.8);
    this.console = { pos: new THREE.Vector3(-2.5, 0, 1.6) };
    this.drill = { active: false };
    // Trees
    this.buildSurroundings(0, -100, false);
  }

  setConsole(lines) {
    const c = this.consoleTex.userData.canvas, x = c.getContext('2d');
    x.fillStyle = '#1c2a1c'; x.fillRect(0, 0, c.width, c.height);
    x.fillStyle = '#d8f0c0'; x.font = 'bold 34px monospace'; x.textAlign = 'center'; x.textBaseline = 'middle';
    lines.forEach((l, i) => x.fillText(l, c.width / 2, c.height / 2 + (i - (lines.length - 1) / 2) * 40));
    this.consoleTex.needsUpdate = true;
  }

  startDrill() {
    if (this.drill.active) return;
    for (const t of this.targets) { t.reset(); if (t.state !== 'down') t.lower(); }
    for (const p of this.papers) p.paint(), (p.tex.needsUpdate = true);
    for (const p of this.plates) p.paint(), (p.tex.needsUpdate = true);
    const seq = [];
    const pool = this.targets.slice();
    for (let i = 0; i < 20; i++) seq.push(pool[Math.floor(Math.random() * pool.length)]);
    this.drill = { active: true, t: -3.5, idx: -1, seq, cur: null, curT: 0, hits: 0, misses: 0, civHits: 0, civPassed: 0, hostilesShown: 0, beeped: 3 };
    this.g.toast('QUALIFICATION DRILL — STAND BY');
  }

  updateDrill(dt) {
    const d = this.drill; if (!d.active) return;
    d.t += dt;
    if (d.t < 0) {
      const sec = Math.ceil(-d.t);
      if (sec < d.beeped + 1 && sec <= 3) { this.g.audio.beep(sec === 0 ? 1320 : 880); d.beeped = sec - 1; this.setConsole(['STAND BY', String(sec)]); }
      return;
    }
    if (!d.cur || d.curT <= 0) {
      if (d.cur) {
        if (d.cur.hostile && !d.cur.neutralized) d.misses++;
        if (!d.cur.hostile && !d.cur.civHit) d.civPassed++;
        d.cur.lower();
      }
      d.idx++;
      if (d.idx >= d.seq.length) return this.endDrill();
      d.cur = d.seq[d.idx];
      d.cur.reset(); d.cur.rise();
      if (d.cur.hostile) d.hostilesShown++;
      d.curT = 3 + 0.4;
      this.setConsole([`TARGET ${d.idx + 1}/20`, `HITS ${d.hits}`]);
    }
    d.curT -= dt;
    if (d.cur && d.cur.neutralized && d.curT > 0.6) d.curT = 0.6;
  }

  endDrill() {
    const d = this.drill; d.active = false;
    const score = Math.max(0, d.hits - d.civHits * 2);
    const total = d.hostilesShown;
    const pct = total ? score / total : 0;
    const badge = pct >= 0.9 ? 'EXPERT' : pct >= 0.75 ? 'SHARPSHOOTER' : pct >= 0.58 ? 'MARKSMAN' : 'UNQUALIFIED';
    this.setConsole([badge, `${score}/${total}`]);
    this.g.drillResult({ score, total, badge, civHits: d.civHits });
  }

  // ---------------- Shared runtime ----------------
  roomAt(x, z) {
    if (!this.rooms) return 0;
    const c = Math.floor(x), r = Math.floor(z);
    if (c < 0 || r < 0 || c >= this.W || r >= this.H) return -1;
    return this.rooms[r * this.W + c];
  }

  onDoorOpened() { }

  update(dt, active = true) {
    this.time += dt;
    const g = this.g, t = this.time;
    for (const d of this.doors) d.update(dt);
    for (const p of this.plates) p.update(dt);
    const pRoom = this.roomAt(g.player.pos.x, g.player.pos.z);
    for (const tg of this.targets) {
      // Pop-ups rise when the player is close in the same room
      if (active && !this.drill && tg.state === 'down' && tg.popup && !tg.neutralized) {
        if (pRoom === tg.room && g.player.pos.distanceTo(tg.group.position) < 9) { tg.rise(); tg.exposure = -0.35; }
      }
      tg.update(dt, t);
    }
    if (this.mission.env === 'range') this.updateDrill(dt);
    else if (active) this.updateHostiles(dt, t);
    // Lamp flicker
    for (const l of this.lampLights) {
      if (!l.userData.flicker) continue;
      const f = Math.random() < 0.04 ? 0.15 : 1;
      l.intensity = l.userData.base * f;
      l.userData.bulb.material.color.setScalar(f > 0.5 ? 1 : 0.1).multiply(new THREE.Color(6, 4.2, 2.2));
    }
    if (this.extract) {
      const ready = g.objectivesDone();
      this.extract.ring.visible = this.extract.beam.visible = ready;
      this.extract.beam.material.opacity = 0.08 + Math.sin(t * 3) * 0.04;
    }
  }

  updateHostiles(dt, t) {
    const g = this.g, P = g.player, diff = g.diff;
    const eye = g.camera.position;
    const night = this.mission.env === 'night';
    if (g.missionTime < 2.5) return;
    let detect = night ? (g.flashlightOn || g.recentShot > 0 ? 26 : 9) : 28;
    detect *= diff.detect;
    for (const tg of this.targets) {
      if (!tg.hostile || tg.state !== 'up' || tg.neutralized) continue;
      tg.react = diff.react * (0.85 + (tg.group.id % 7) * 0.05);
      if (t < tg.stunUntil) { tg.exposure = 0; continue; }
      const head = tg.headPos(_v);
      const toP = _v2.subVectors(eye, head);
      const dist = toP.length();
      let visible = false;
      if (dist < detect) {
        toP.normalize();
        const fwd = tg.forward(new THREE.Vector3());
        if (fwd.dot(toP) > -0.1) {
          _ray.set(head, toP); _ray.far = dist - 0.25;
          const hits = _ray.intersectObjects(this.occluders, false);
          visible = hits.length === 0;
        }
      }
      if (visible) {
        let mult = 1;
        if (P.sprinting) mult *= 1.35;
        if (P.crouch > 0.5) mult *= 0.85;
        if (Math.abs(P.lean) > 0.5) mult *= 0.8; // only a sliver of you is exposed
        tg.exposure += dt * mult;
        if (tg.exposure >= tg.react) {
          tg.exposure = tg.react * 0.45;
          tg.fireFlash = 0.06;
          let chance = diff.hit;
          if (P.speed > 2.5) chance *= 0.75;
          if (P.crouch > 0.5) chance *= 0.85;
          if (Math.abs(P.lean) > 0.5) chance *= 0.7;
          if (dist > 15) chance *= 0.7;
          g.hostileFires(head, Math.random() < chance, dist);
        }
      } else tg.exposure = Math.max(0, tg.exposure - dt * 0.5);
    }
    // Room clear callouts
    const byRoom = new Map();
    for (const tg of this.targets) {
      if (!tg.hostile) continue;
      if (!byRoom.has(tg.room)) byRoom.set(tg.room, { total: 0, down: 0 });
      const e = byRoom.get(tg.room); e.total++; if (tg.neutralized) e.down++;
    }
    for (const [room, e] of byRoom) {
      if (e.down === e.total && !this.roomCleared.has(room)) {
        this.roomCleared.add(room);
        const name = this.roomNames.get(room);
        const area = this.mission.mainArea || 'HALLWAY';
        g.callout(name ? `ROOM ${name} CLEAR` : `${area} CLEAR`, name ? `Room ${name} clear` : `${area.toLowerCase()} clear`);
      }
    }
  }

  flashAt(pos) {
    // Stun hostiles within range and line of sight of the blast.
    let n = 0;
    for (const tg of this.targets) {
      if (!tg.hostile || tg.neutralized) continue;
      const head = tg.headPos(_v);
      const d = head.distanceTo(pos);
      if (d > 7.5) continue;
      _ray.set(pos, _v2.subVectors(head, pos).normalize()); _ray.far = d - 0.1;
      if (_ray.intersectObjects(this.occluders, false).length) continue;
      tg.stunUntil = this.time + 4.5 - d * 0.25; tg.exposure = 0; n++;
    }
    return n;
  }

  collide(pos, radius) {
    // Circle vs AABBs
    for (let iter = 0; iter < 2; iter++) {
      for (const b of this.colliders) {
        const cx = Math.max(b.minX, Math.min(pos.x, b.maxX)), cz = Math.max(b.minZ, Math.min(pos.z, b.maxZ));
        const dx = pos.x - cx, dz = pos.z - cz, d2 = dx * dx + dz * dz;
        if (d2 < radius * radius) {
          if (d2 > 1e-8) { const d = Math.sqrt(d2), push = radius - d; pos.x += dx / d * push; pos.z += dz / d * push; }
          else {
            const l = pos.x - b.minX, r = b.maxX - pos.x, u = pos.z - b.minZ, w = b.maxZ - pos.z, m = Math.min(l, r, u, w);
            if (m === l) pos.x = b.minX - radius; else if (m === r) pos.x = b.maxX + radius; else if (m === u) pos.z = b.minZ - radius; else pos.z = b.maxZ + radius;
          }
        }
      }
      // Doors as segments
      const a = new THREE.Vector2(), bb = new THREE.Vector2();
      for (const d of this.doors) {
        d.segment(a, bb);
        const abx = bb.x - a.x, abz = bb.y - a.y;
        const tt = Math.max(0, Math.min(1, ((pos.x - a.x) * abx + (pos.z - a.y) * abz) / (abx * abx + abz * abz)));
        const px = a.x + abx * tt, pz = a.y + abz * tt;
        const dx = pos.x - px, dz = pos.z - pz, dd = Math.hypot(dx, dz), rr = radius + 0.03;
        if (dd < rr && dd > 1e-6) { pos.x += dx / dd * (rr - dd); pos.z += dz / dd * (rr - dd); }
      }
    }
    return pos;
  }

  blocked(x, z, radius) {
    for (const b of this.colliders) {
      const cx = Math.max(b.minX, Math.min(x, b.maxX)), cz = Math.max(b.minZ, Math.min(z, b.maxZ));
      if ((x - cx) ** 2 + (z - cz) ** 2 < radius * radius) return true;
    }
    return false;
  }

  dispose() {
    this.g.scene.remove(this.group);
    this.group.traverse(o => {
      if (o.geometry) o.geometry.dispose();
      if (o.material) {
        const mats = Array.isArray(o.material) ? o.material : [o.material];
        for (const m of mats) { if (m.map && m.map.userData && m.map.userData.canvas) m.map.dispose(); m.dispose(); }
      }
    });
  }
}
