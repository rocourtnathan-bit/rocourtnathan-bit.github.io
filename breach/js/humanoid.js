// 3D role-players (OPFOR, civilians, hostages). Limbs are solved with two-bone IK each frame,
// so hands stay on the weapon while it is raised and feet stay planted while the body moves.
import * as THREE from 'three';
import { RoundedBoxGeometry } from '../vendor/three/addons/geometries/RoundedBoxGeometry.js';

const UP = new THREE.Vector3(0, 1, 0);
const _d = new THREE.Vector3(), _p = new THREE.Vector3(), _e = new THREE.Vector3(), _t = new THREE.Vector3();
const _h = new THREE.Vector3(), _f = new THREE.Vector3(), _s = new THREE.Vector3(), _m = new THREE.Vector3();
const _ray = new THREE.Raycaster(), _eul = new THREE.Euler();

const SKIN = [0xe0b394, 0xc68e6a, 0x8d5a3b, 0xf1c9a8, 0x6b4430];
const CIV_TOP = [0x3a6ea5, 0xb84a3a, 0x5e8c4a, 0xd8c27a, 0x7a4e8c, 0xdcdcdc, 0xcc7a2a];
const HOS_TOP = [0x2a2c2a, 0x2f3a2a, 0x3a3028, 0x1f2530, 0x403c36];
const PANTS = [0x2b3a55, 0x3b3b3b, 0x5a4a36, 0x1f1f1f, 0x4a5560];
const HAIR = [0x2a1d14, 0x5a3a1a, 0x111111, 0x8a6a3a, 0x3a2a1a, 0x9a9a9a];

const UA = 0.28, FA = 0.26, TH = 0.44, SH = 0.43, ANKLE = 0.07;

let G = null;
function geos() {
  if (G) return G;
  G = {
    head: new THREE.SphereGeometry(0.1, 20, 16),
    hair: new THREE.SphereGeometry(0.106, 20, 10, 0, Math.PI * 2, 0, 1.45),
    helmet: new THREE.SphereGeometry(0.118, 20, 10, 0, Math.PI * 2, 0, 1.5),
    eyeband: new THREE.SphereGeometry(0.1025, 16, 4, Math.PI / 2 - 0.85, 1.7, 1.28, 0.3),
    eye: new THREE.SphereGeometry(0.011, 8, 6),
    chest: new RoundedBoxGeometry(0.38, 0.5, 0.22, 3, 0.07),
    pelvis: new RoundedBoxGeometry(0.33, 0.22, 0.2, 3, 0.06),
    vest: new RoundedBoxGeometry(0.4, 0.36, 0.27, 2, 0.04),
    pouch: new RoundedBoxGeometry(0.085, 0.12, 0.05, 1, 0.012),
    neck: new THREE.CylinderGeometry(0.045, 0.05, 0.1, 10),
    ua: new THREE.CapsuleGeometry(0.048, UA, 4, 10),
    fa: new THREE.CapsuleGeometry(0.04, FA, 4, 10),
    th: new THREE.CapsuleGeometry(0.074, TH, 4, 10),
    sh: new THREE.CapsuleGeometry(0.055, SH, 4, 10),
    hand: new RoundedBoxGeometry(0.075, 0.09, 0.05, 2, 0.02),
    boot: new RoundedBoxGeometry(0.1, 0.09, 0.26, 2, 0.03),
    phone: new THREE.BoxGeometry(0.07, 0.14, 0.01),
  };
  return G;
}

function placeBone(mesh, a, b) {
  mesh.position.copy(a).add(b).multiplyScalar(0.5);
  _d.subVectors(b, a).normalize();
  mesh.quaternion.setFromUnitVectors(UP, _d);
}

// Two-bone IK: returns elbow/knee position in outE and the (possibly clamped) end point in outT.
function ik(S, T, la, lb, pole, outE, outT) {
  _d.subVectors(T, S);
  let L = _d.length();
  if (L < 1e-4) { _d.set(0, -1, 0); L = 1e-4; }
  _d.multiplyScalar(1 / L);
  const Lc = Math.min(L, la + lb - 0.002);
  const x = (la * la - lb * lb + Lc * Lc) / (2 * Lc);
  const h = Math.sqrt(Math.max(0, la * la - x * x));
  _p.copy(pole).addScaledVector(_d, -pole.dot(_d));
  if (_p.lengthSq() < 1e-6) _p.set(0, 0, 1);
  _p.normalize();
  outE.copy(S).addScaledVector(_d, x).addScaledVector(_p, h);
  outT.copy(S).addScaledVector(_d, Lc);
}

function buildRifle(M) {
  const g = new THREE.Group();
  const b = (w, h, d, x, y, z, m, rx = 0) => { const me = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), m); me.position.set(x, y, z); me.rotation.x = rx; me.castShadow = true; g.add(me); return me; };
  b(0.045, 0.065, 0.3, 0, 0, 0.02, M.gun);
  b(0.05, 0.055, 0.2, 0, 0.005, 0.27, M.gun);
  const br = new THREE.Mesh(new THREE.CylinderGeometry(0.009, 0.009, 0.16, 8).rotateX(Math.PI / 2), M.gun); br.position.set(0, 0.01, 0.45); g.add(br);
  b(0.04, 0.075, 0.17, 0, -0.01, -0.21, M.gun);
  b(0.028, 0.16, 0.055, 0, -0.1, 0.06, M.gun, -0.25);
  b(0.03, 0.09, 0.04, 0, -0.07, -0.06, M.gun, 0.3);
  b(0.035, 0.04, 0.07, 0, 0.055, 0.03, M.gun);
  return { g, grip: new THREE.Vector3(0, -0.075, -0.06), fore: new THREE.Vector3(0, -0.035, 0.27), muzzle: new THREE.Vector3(0, 0.01, 0.55) };
}
function buildPistol(M) {
  const g = new THREE.Group();
  const b = (w, h, d, x, y, z, rx = 0) => { const me = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), M.gun); me.position.set(x, y, z); me.rotation.x = rx; me.castShadow = true; g.add(me); };
  b(0.028, 0.04, 0.19, 0, 0.02, 0.03); b(0.028, 0.1, 0.045, 0, -0.04, -0.04, 0.2);
  return { g, grip: new THREE.Vector3(0, -0.045, -0.04), fore: new THREE.Vector3(0.01, -0.06, -0.035), muzzle: new THREE.Vector3(0, 0.02, 0.15) };
}

// Pose goals. wp/wr = weapon position / [pitch, yaw] in torso space. lh/rh = free hand targets (unarmed or overriding).
const POSES = {
  ready: { wp: [-0.07, 0.2, 0.2], wr: [0.8, 0.55], hip: 0.93, pitch: 0.03, fl: [0.11, 0, 0.03], fr: [-0.11, 0, -0.05] },
  aim: { wp: [-0.125, 0.435, 0.25], wr: [0, 0], hip: 0.9, pitch: 0.1, fl: [0.12, 0, 0.13], fr: [-0.13, 0, -0.15] },
  pready: { wp: [-0.03, 0.13, 0.27], wr: [0.9, 0.1], hip: 0.93, pitch: 0.03, fl: [0.11, 0, 0.03], fr: [-0.11, 0, -0.05] },
  paim: { wp: [-0.04, 0.52, 0.5], wr: [0, 0], hip: 0.9, pitch: 0.08, fl: [0.13, 0, 0.12], fr: [-0.13, 0, -0.12] },
  crouch: { wp: [-0.07, 0.22, 0.22], wr: [0.6, 0.5], hip: 0.52, pitch: 0.38, fl: [0.14, 0, 0.14], fr: [-0.14, 0, -0.22] },
  stun: { wp: [-0.22, 0.02, 0.14], wr: [1.35, 0], lh: [0.05, 0.64, 0.15], hip: 0.84, pitch: 0.42, fl: [0.14, 0, 0.05], fr: [-0.14, 0, -0.1] },
  idle: { lh: [0.25, -0.03, 0.03], rh: [-0.25, -0.03, 0.03], hip: 0.93, pitch: 0, fl: [0.1, 0, 0.02], fr: [-0.1, 0, 0] },
  phone: { lh: [0.25, -0.03, 0.03], rh: [-0.13, 0.63, 0.1], hip: 0.93, pitch: 0, fl: [0.1, 0, 0.02], fr: [-0.1, 0, 0] },
  handsup: { lh: [0.3, 0.82, 0.1], rh: [-0.3, 0.82, 0.1], hip: 0.92, pitch: -0.03, fl: [0.11, 0, 0.02], fr: [-0.11, 0, 0] },
  cower: { lh: [0.12, 0.72, 0.12], rh: [-0.12, 0.72, 0.12], hip: 0.5, pitch: 0.6, fl: [0.14, 0, 0.14], fr: [-0.14, 0, -0.12] },
  kneel: { lh: [0.07, 0.03, -0.15], rh: [-0.07, 0.03, -0.15], hip: 0.5, pitch: 0.14, fl: [0.12, 0, -0.4], fr: [-0.12, 0, -0.4] },
};

function wrap(a) { while (a > Math.PI) a -= Math.PI * 2; while (a < -Math.PI) a += Math.PI * 2; return a; }

export class Figure {
  constructor(level, kind, x, z, yaw, opts = {}) {
    this.level = level; this.kind = kind; this.isFigure = true;
    this.hostile = kind === 'hostile';
    this.room = opts.room; this.popup = !!opts.ambush; this.patrol = !!opts.patrol;
    let s = (opts.seed || 1) * 9301 + 49297; const r = this.rand = () => { s = (s * 9301 + 49297) % 233280; return s / 233280; };
    this.state = this.popup ? 'down' : 'up';
    this.neutralized = false; this.civHit = false; this.secured = false;
    this.hits = 0; this.score = 0; this.exposure = 0; this.react = 1; this.stunUntil = 0; this.fireFlash = 0;
    this.alert = 0; this.aimK = 0; this.lastSeen = new THREE.Vector3(x, 0, z); this.homeYaw = yaw; this.yaw = yaw;
    this.walk = 0; this.walkSpeed = 0; this.scared = false; this.losT = r() * 0.1; this.see = false;
    this.flinch = 0; this.flinchV = 0; this.flinchSide = 0; this.dead = null; this.aimPitch = 0; this.headYaw = 0;
    this.pistol = this.hostile && r() > 0.6;
    this.armed = this.hostile;

    const Gs = geos();
    const skin = SKIN[Math.floor(r() * SKIN.length)];
    const top = this.hostile ? HOS_TOP[Math.floor(r() * HOS_TOP.length)] : CIV_TOP[Math.floor(r() * CIV_TOP.length)];
    const fabric = level.g.T.camo.normalMap;
    const M = this.M = {
      skin: new THREE.MeshStandardMaterial({ color: skin, roughness: 0.75 }),
      top: new THREE.MeshStandardMaterial({ color: top, roughness: 0.9, normalMap: fabric, normalScale: new THREE.Vector2(0.5, 0.5) }),
      pants: new THREE.MeshStandardMaterial({ color: PANTS[Math.floor(r() * PANTS.length)], roughness: 0.9, normalMap: fabric, normalScale: new THREE.Vector2(0.5, 0.5) }),
      gear: new THREE.MeshStandardMaterial({ color: 0x23261f, roughness: 0.8, normalMap: fabric, normalScale: new THREE.Vector2(0.8, 0.8) }),
      boot: new THREE.MeshStandardMaterial({ color: 0x151412, roughness: 0.7 }),
      gun: level.mats.gunmetal,
      dark: new THREE.MeshStandardMaterial({ color: 0x141414, roughness: 0.85 }),
    };
    const root = this.group = new THREE.Group(); root.position.set(x, 0, z); root.rotation.y = yaw;
    const pelvis = this.pelvis = new THREE.Group(); root.add(pelvis);
    const torso = this.torso = new THREE.Group(); torso.position.y = 0.06; pelvis.add(torso);
    this.parts = [];
    const part = (geo, mat, parent, zone) => { const m = new THREE.Mesh(geo, mat); m.castShadow = true; m.receiveShadow = true; m.userData = { surf: 'body', target: this, zone }; parent.add(m); this.parts.push(m); return m; };
    part(Gs.pelvis, M.pants, pelvis, 'torso').position.y = -0.01;
    part(Gs.chest, M.top, torso, 'torso').position.y = 0.26;
    if (this.hostile && r() > 0.3) {
      const v = part(Gs.vest, M.gear, torso, 'torso'); v.position.y = 0.27;
      for (let i = 0; i < 3; i++) { const p = new THREE.Mesh(Gs.pouch, M.gear); p.position.set(-0.1 + i * 0.1, 0.16, 0.15); torso.add(p); }
      this.vest = true;
    }
    const neck = new THREE.Mesh(Gs.neck, M.skin); neck.position.y = 0.54; torso.add(neck);
    const head = this.head = new THREE.Group(); head.position.y = 0.68; torso.add(head);
    const masked = this.hostile && r() > 0.25;
    const hm = part(Gs.head, masked ? M.dark : M.skin, head, 'head'); hm.scale.set(0.95, 1.15, 1.02);
    if (masked) { const band = new THREE.Mesh(Gs.eyeband, M.skin); band.scale.set(0.95, 1.15, 1.02); head.add(band); }
    else {
      const hair = new THREE.Mesh(Gs.hair, new THREE.MeshStandardMaterial({ color: HAIR[Math.floor(r() * HAIR.length)], roughness: 0.95 }));
      hair.scale.set(0.97, 1.15, 1.05); hair.rotation.x = -0.25; head.add(hair);
      const nose = new THREE.Mesh(new THREE.BoxGeometry(0.02, 0.035, 0.03), M.skin); nose.position.set(0, -0.012, 0.1); head.add(nose);
    }
    for (const sx of [-1, 1]) { const e = new THREE.Mesh(Gs.eye, M.dark); e.position.set(sx * 0.036, 0.018, 0.092); head.add(e); }
    if (this.hostile && r() > 0.55) { const hl = new THREE.Mesh(Gs.helmet, M.gear); hl.scale.set(1, 1.1, 1.08); hl.position.y = 0.012; hl.castShadow = true; head.add(hl); }

    // Limbs (transforms are driven by IK every frame)
    this.uaL = part(Gs.ua, M.top, torso, 'arm'); this.faL = part(Gs.fa, M.top, torso, 'arm');
    this.uaR = part(Gs.ua, M.top, torso, 'arm'); this.faR = part(Gs.fa, M.top, torso, 'arm');
    this.handL = new THREE.Mesh(Gs.hand, this.hostile ? M.dark : M.skin); this.handR = new THREE.Mesh(Gs.hand, this.hostile ? M.dark : M.skin);
    torso.add(this.handL, this.handR);
    this.thL = part(Gs.th, M.pants, root, 'limb'); this.shL = part(Gs.sh, M.pants, root, 'limb');
    this.thR = part(Gs.th, M.pants, root, 'limb'); this.shR = part(Gs.sh, M.pants, root, 'limb');
    this.bootL = new THREE.Mesh(Gs.boot, M.boot); this.bootR = new THREE.Mesh(Gs.boot, M.boot);
    this.bootL.castShadow = this.bootR.castShadow = true;
    root.add(this.bootL, this.bootR);

    // Weapon
    if (this.armed) {
      const w = this.pistol ? buildPistol(M) : buildRifle(M);
      this.wdef = w; this.weapon = w.g; this.weapon.rotation.order = 'YXZ'; torso.add(w.g);
      const fm = new THREE.SpriteMaterial({ map: level.g.flashTex, color: new THREE.Color(6, 4, 2), blending: THREE.AdditiveBlending, depthWrite: false, toneMapped: false });
      this.flashSprite = new THREE.Sprite(fm); this.flashSprite.scale.setScalar(this.pistol ? 0.3 : 0.5); this.flashSprite.position.copy(w.muzzle); this.flashSprite.visible = false;
      w.g.add(this.flashSprite);
    } else if (kind === 'civilian' && r() > 0.5) {
      this.phone = new THREE.Mesh(Gs.phone, new THREE.MeshStandardMaterial({ color: 0x111111, emissive: 0x224466, roughness: 0.3 }));
      torso.add(this.phone);
    }

    // Pose state
    this.poseName = this.popup ? 'crouch' : kind === 'hostage' ? 'kneel' : this.hostile ? (this.pistol ? 'pready' : 'ready') : (this.phone ? 'phone' : 'idle');
    const P = POSES[this.poseName];
    this.cur = {
      wp: new THREE.Vector3().fromArray(P.wp || [0, 0.2, 0.2]), wrx: P.wr ? P.wr[0] : 0, wry: P.wr ? P.wr[1] : 0,
      lh: new THREE.Vector3().fromArray(P.lh || [0.25, 0, 0]), rh: new THREE.Vector3().fromArray(P.rh || [-0.25, 0, 0]),
      lhFree: P.lh ? 1 : 0, hip: P.hip, pitch: P.pitch, fl: new THREE.Vector3().fromArray(P.fl), fr: new THREE.Vector3().fromArray(P.fr),
    };
    this.SL = new THREE.Vector3(0.2, 0.44, 0); this.SR = new THREE.Vector3(-0.2, 0.44, 0);
    this.poleL = new THREE.Vector3(0.7, -1, -0.35); this.poleR = new THREE.Vector3(-0.7, -1, -0.35);
    this.kneePole = new THREE.Vector3(0, 0.15, 1);
    this.meshes = this.parts;
    if (!Figure.blobMat) {
      const c = document.createElement('canvas'); c.width = c.height = 64; const x = c.getContext('2d');
      const gr = x.createRadialGradient(32, 32, 2, 32, 32, 31); gr.addColorStop(0, 'rgba(0,0,0,0.55)'); gr.addColorStop(1, 'rgba(0,0,0,0)');
      x.fillStyle = gr; x.fillRect(0, 0, 64, 64);
      Figure.blobMat = new THREE.MeshBasicMaterial({ map: new THREE.CanvasTexture(c), transparent: true, depthWrite: false, polygonOffset: true, polygonOffsetFactor: -1 });
      Figure.blobGeo = new THREE.PlaneGeometry(0.95, 0.95).rotateX(-Math.PI / 2);
    }
    this.blob = new THREE.Mesh(Figure.blobGeo, Figure.blobMat); this.blob.position.y = 0.012; this.blob.renderOrder = 1; root.add(this.blob);
    level.group.add(root);
    for (const m of this.parts) level.shootables.push(m);
    this.solve(0, 1);
  }

  forward(out) { return out.set(Math.sin(this.yaw), 0, Math.cos(this.yaw)); }
  headPos(out) { return this.head.getWorldPosition(out); }

  rise() { if (this.state === 'down') { this.state = 'up'; this.exposure = -0.35; this.alert = 3; this.level.g.audio.popUp(); } }
  lower() { if (this.kind === 'hostage') this.poseName = 'idle'; }
  reset() { }

  hitTest(hit) { return { zone: hit.object.userData.zone || 'torso', px: 0, py: 0 }; }

  onHit(info, oneHitKill, dir) {
    if (this.neutralized) return { already: true };
    this.hits++;
    let pts = info.zone === 'head' ? 2 : info.zone === 'torso' ? (this.vest ? 0.8 : 1) : info.zone === 'arm' ? 0.7 : 0.5;
    this.score += pts;
    this.flinchV += 5; this.flinchSide = (Math.random() - 0.5) * 2;
    const front = dir ? this.forward(_f).dot(dir) < 0 : true;
    if (!this.hostile) {
      this.civHit = true;
      this.neutralized = true; this.state = 'dead'; this.dead = { t: 0, dir: front ? 1 : -1, twist: (Math.random() - 0.5) * 0.8 };
      return { civ: true, zone: info.zone };
    }
    if (this.score >= 1.6 || oneHitKill) {
      this.neutralized = true; this.state = 'dead';
      this.dead = { t: 0, dir: front ? 1 : -1, twist: (Math.random() - 0.5) * 0.9 };
      if (this.weapon) { this.group.attach(this.weapon); this.dropW = { y0: this.weapon.position.y, t: 0 }; }
      return { kill: true, zone: info.zone };
    }
    // Getting hit spoils their aim and tells them where you are
    this.exposure = Math.min(this.exposure, this.react * 0.25);
    this.alert = 5; this.lastSeen.copy(this.level.g.player.pos);
    return { zone: info.zone };
  }

  // ---- AI (hostiles) ----
  ai(dt, t, c) {
    if (this.neutralized || this.state === 'down') return;
    const armed = this.pistol ? ['pready', 'paim'] : ['ready', 'aim'];
    if (t < this.stunUntil) { this.poseName = 'stun'; this.exposure = 0; this.aimK = 0; this.walkSpeed = 0; return; }
    const head = this.headPos(_h);
    const toP = _t.subVectors(c.eye, head); const dist = toP.length(); toP.multiplyScalar(1 / dist);
    this.forward(_f);
    // Line of sight (re-checked ~12x a second, staggered between figures)
    this.losT -= dt;
    if (this.losT <= 0) {
      this.losT = 0.08;
      this.see = false;
      if (dist < c.detect && (_f.dot(toP) > 0.15 || dist < 2.4)) {
        _ray.set(head, toP); _ray.far = dist - 0.25;
        this.see = _ray.intersectObjects(c.level.occluders, false).length === 0;
      }
    }
    const P = c.P;
    if (this.see) { this.alert = 4; this.lastSeen.copy(P.pos); }
    else if (c.g.shotPulse && dist < 22) { this.alert = Math.max(this.alert, 3); this.lastSeen.copy(P.pos); }
    let facing = false;
    if (this.alert > 0) {
      this.alert -= dt; this.walkSpeed = 0;
      const want = Math.atan2(this.lastSeen.x - this.group.position.x, this.lastSeen.z - this.group.position.z);
      const diff = wrap(want - this.yaw), rate = c.diff.turn * dt;
      this.yaw += Math.max(-rate, Math.min(rate, diff));
      facing = Math.abs(diff) < 0.35;
    } else if (this.patrol) this.doPatrol(dt, c);
    else { const diff = wrap(this.homeYaw - this.yaw); this.yaw += Math.max(-dt, Math.min(dt, diff)); }

    if (this.see) {
      let mult = facing ? 1 : 0.35;
      if (P.sprinting) mult *= 1.3;
      if (P.crouch > 0.5) mult *= 0.85;
      if (Math.abs(P.lean) > 0.5) mult *= 0.8;
      this.exposure += dt * mult;
      this.aimPitch = Math.atan2(c.eye.y - head.y + 0.22, Math.max(0.5, dist));
      if (this.exposure >= this.react && facing) {
        this.exposure = this.react * 0.5;
        let chance = c.diff.hit;
        if (P.speed > 2.5) chance *= 0.75;
        if (P.crouch > 0.5) chance *= 0.85;
        if (Math.abs(P.lean) > 0.5) chance *= 0.7;
        if (dist > 15) chance *= 0.7;
        if (this.pistol) chance *= 0.85;
        this.fireFlash = 0.06; this.flinchV += 2.5;
        this.weapon.updateWorldMatrix(true, false);
        const mz = _m.copy(this.wdef.muzzle).applyMatrix4(this.weapon.matrixWorld);
        c.g.hostileFires(mz, Math.random() < chance, dist, this.pistol);
      }
    } else this.exposure = Math.max(0, this.exposure - dt * 0.5);
    const wantAim = this.see ? Math.min(1, 0.25 + this.exposure / this.react * 1.4) : (this.alert > 0 ? 0.3 : 0);
    this.aimK += (wantAim - this.aimK) * Math.min(1, dt * 9);
    this.poseName = armed[0]; this.poseAim = armed[1];
    // Head tracks the player when they can see them
    const hy = this.see ? wrap(Math.atan2(toP.x, toP.z) - this.yaw) : 0;
    this.headYaw += (Math.max(-0.9, Math.min(0.9, hy)) - this.headYaw) * Math.min(1, dt * 6);
  }

  doPatrol(dt, c) {
    const L = c.level, pos = this.group.position;
    if (this.turnLeft > 0) { const st = Math.min(this.turnLeft, 2.2 * dt); this.yaw += st; this.turnLeft -= st; this.walkSpeed = 0; return; }
    this.forward(_f);
    if (L.cellBlocked(pos.x + _f.x * 1.1, pos.z + _f.z * 1.1) || L.blocked(pos.x + _f.x * 0.7, pos.z + _f.z * 0.7, 0.3)) { this.turnLeft = Math.PI; this.homeYaw = this.yaw + Math.PI; return; }
    this.walkSpeed = 0.95;
    pos.x += _f.x * this.walkSpeed * dt; pos.z += _f.z * this.walkSpeed * dt;
    this.room = L.roomAt(pos.x, pos.z);
  }

  // ---- Civilians react to gunfire ----
  civ(dt, t, c) {
    if (this.neutralized || this.kind !== 'civilian') return;
    if (!this.scared) {
      const d = this.group.position.distanceTo(c.P.pos);
      if ((c.g.shotPulse && d < 20) || (d < 5 && c.P.room === this.room) || t < this.stunUntil) {
        this.scared = true; this.poseName = this.rand() > 0.45 ? 'handsup' : 'cower';
        if (this.phone) this.phone.visible = false;
      }
    }
    // Look at the player
    const head = this.headPos(_h); _t.subVectors(c.eye, head);
    const hy = wrap(Math.atan2(_t.x, _t.z) - this.yaw);
    this.headYaw += (Math.max(-1, Math.min(1, Math.abs(hy) < 1.6 ? hy : 0)) - this.headYaw) * Math.min(1, dt * 4);
  }

  update(dt, t) {
    this.group.rotation.y = this.yaw;
    // Flinch spring
    this.flinchV += (-140 * this.flinch - 14 * this.flinchV) * dt; this.flinch += this.flinchV * dt;
    if (this.fireFlash > 0) { this.fireFlash -= dt; if (this.flashSprite) { this.flashSprite.visible = true; this.flashSprite.material.rotation = Math.random() * 6; } }
    else if (this.flashSprite) this.flashSprite.visible = false;
    if (this.walkSpeed > 0) this.walk += dt * this.walkSpeed * 4.2;
    if (this.dead) {
      this.dead.t += dt;
      if (this.dropW) {
        const d = this.dropW; d.t = Math.min(1, d.t + dt * 2.2);
        this.weapon.position.y = d.y0 + (0.03 - d.y0) * d.t * d.t; this.weapon.rotation.z = d.t * 1.5; this.weapon.rotation.x *= 1 - d.t * 0.3;
      }
      if (this.dead.t > 3 && !this.dead.settled) { this.dead.settled = true; this.solve(dt, 1); return; }
      if (this.dead.settled) return;
    }
    this.solve(dt, Math.min(1, dt * 9));
  }

  solve(dt, k) {
    const C = this.cur;
    let P = POSES[this.poseName] || POSES.idle;
    const A = this.poseAim && this.aimK > 0.01 && !this.dead && this.poseName !== 'stun' ? POSES[this.poseAim] : null;
    const a = A ? this.aimK : 0;
    const mix = (key, i) => { const v = P[key] ? P[key][i] : 0; return A && A[key] ? v + (A[key][i] - v) * a : v; };
    const lerpV = (v, key) => { if (!P[key]) return; v.x += (mix(key, 0) - v.x) * k; v.y += (mix(key, 1) - v.y) * k; v.z += (mix(key, 2) - v.z) * k; };
    let hipGoal = A ? P.hip + (A.hip - P.hip) * a : P.hip, pitchGoal = A ? P.pitch + (A.pitch - P.pitch) * a : P.pitch;
    if (!this.dead) {
      lerpV(C.wp, 'wp'); lerpV(C.lh, 'lh'); lerpV(C.rh, 'rh'); lerpV(C.fl, 'fl'); lerpV(C.fr, 'fr');
      if (P.wr) { C.wrx += (mix('wr', 0) - a * this.aimPitch - C.wrx) * k; C.wry += (mix('wr', 1) - C.wry) * k; }
      C.lhFree += ((P.lh && this.armed ? 1 : 0) - C.lhFree) * k;
      C.hip += (hipGoal - C.hip) * k; C.pitch += (pitchGoal - C.pitch) * k;
    }
    const pelvis = this.pelvis, torso = this.torso;
    let px = 0, pz = 0, prx = 0, pry = 0;
    if (this.dead) {
      // Collapse: knees buckle, body goes down along the shot direction.
      const D = this.dead, p = Math.min(1, D.t / 0.75), e = p * p, s = p * p * (3 - 2 * p);
      const bounce = p >= 1 ? Math.max(0, 0.03 * Math.exp(-(D.t - 0.75) * 9) * Math.abs(Math.cos((D.t - 0.75) * 18))) : 0;
      C.hip += ((0.13 + bounce) - C.hip) * Math.min(1, e * 1.2 + 0.02);
      prx = -D.dir * (Math.PI / 2 - 0.06) * s; pry = D.twist * s; pz = -D.dir * 0.3 * s;
      C.pitch *= 1 - s;
      const lx = 0.36 + 0.1 * s;
      C.lh.lerp(_s.set(lx, D.dir > 0 ? 0.3 : 0.62, D.dir > 0 ? -0.02 : 0.06), s * 0.25); C.rh.lerp(_s.set(-lx, D.dir > 0 ? 0.42 : 0.55, D.dir > 0 ? -0.02 : 0.06), s * 0.25);
      C.fl.lerp(_s.set(0.16, 0, D.dir * 0.55), s * 0.2); C.fr.lerp(_s.set(-0.13, 0, D.dir * 0.62), s * 0.2);
      C.lhFree = 1;
    }
    // Walk cycle
    let fl = C.fl, fr = C.fr, bobY = 0;
    if (this.walkSpeed > 0 && !this.dead) {
      const ph = this.walk;
      fl = _wl.set(0.1, Math.max(0, Math.cos(ph)) * 0.09, Math.sin(ph) * 0.24);
      fr = _wr.set(-0.1, Math.max(0, -Math.cos(ph)) * 0.09, -Math.sin(ph) * 0.24);
      bobY = Math.abs(Math.cos(ph)) * 0.02;
    }
    pelvis.position.set(px, C.hip + bobY, pz);
    this.blob.position.z = pz * 1.4; this.blob.scale.setScalar(1 + (0.93 - C.hip) * 0.9);
    pelvis.rotation.set(prx, pry, 0);
    torso.rotation.set(C.pitch + this.flinch * 0.12, this.flinch * 0.1 * this.flinchSide, 0);
    this.head.rotation.set(this.dead ? 0 : -C.pitch * 0.7, this.dead ? 0 : this.headYaw, 0);

    // Hands
    let hl = C.lh, hr = C.rh;
    if (this.armed && this.weapon && this.weapon.parent === torso) {
      const w = this.weapon; w.position.copy(C.wp); w.rotation.set(C.wrx, C.wry, 0); w.updateMatrix();
      hr = _hr.copy(this.wdef.grip).applyMatrix4(w.matrix);
      const onGun = _hl.copy(this.wdef.fore).applyMatrix4(w.matrix);
      hl = onGun.lerp(C.lh, C.lhFree);
    }
    ik(this.SL, hl, UA, FA, this.poleL, _e, _t); placeBone(this.uaL, this.SL, _e); placeBone(this.faL, _e, _t); this.handL.position.copy(_t); this.handL.quaternion.copy(this.faL.quaternion);
    ik(this.SR, hr, UA, FA, this.poleR, _e, _t); placeBone(this.uaR, this.SR, _e); placeBone(this.faR, _e, _t); this.handR.position.copy(_t); this.handR.quaternion.copy(this.faR.quaternion);
    if (this.phone && this.phone.visible) { this.phone.position.copy(this.handR.position).add(_s.set(0.02, 0.06, 0.03)); this.phone.rotation.set(0.2, 0.4, 0); }

    // Legs (root space): hip joints follow the pelvis transform
    _eul.set(prx, pry, 0);
    for (const side of [1, -1]) {
      const hipJ = _hip.set(side * 0.09, -0.03, 0).applyEuler(_eul).add(pelvis.position);
      const foot = side > 0 ? fl : fr;
      const ankle = _ank.set(foot.x, foot.y + ANKLE, foot.z);
      ik(hipJ, ankle, TH, SH, this.kneePole, _e, _t);
      const th = side > 0 ? this.thL : this.thR, sh = side > 0 ? this.shL : this.shR, boot = side > 0 ? this.bootL : this.bootR;
      placeBone(th, hipJ, _e); placeBone(sh, _e, _t);
      boot.position.set(_t.x, Math.max(0.045, _t.y - ANKLE + 0.045), _t.z + 0.05);
      boot.rotation.set(this.dead ? -this.dead.dir * 1.2 * Math.min(1, this.dead.t / 0.75) : (this.poseName === 'kneel' ? 1.2 : 0), 0, 0);
    }
  }
}
const _hr = new THREE.Vector3(), _hl = new THREE.Vector3(), _hip = new THREE.Vector3(), _ank = new THREE.Vector3(), _wl = new THREE.Vector3(), _wr = new THREE.Vector3();
