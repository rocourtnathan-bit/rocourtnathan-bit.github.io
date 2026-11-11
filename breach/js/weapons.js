// Weapon definitions, procedural first-person models, and the viewmodel/firing state machine.
import * as THREE from 'three';
import { muzzleFlashTexture, reticleTexture } from './textures.js';

export const WEAPONS = {
  m4: {
    id: 'm4', name: 'M4A1 CARBINE', cal: '5.56×45mm', kind: 'rifle', mag: 30, spare: 5, rpm: 800, modes: ['AUTO', 'SEMI'],
    velocity: 880, pellets: 1, hipSpread: 0.03, adsSpread: 0.0006, moveSpread: 0.025,
    recoil: { v: 0.0115, h: 0.0045, kick: 0.6, rot: 2.2 }, reload: 2.1, reloadEmpty: 2.7, adsTime: 0.2, zoom: 1.4, speed: 0.95,
    stats: { power: 0.8, rate: 0.8, control: 0.7, handling: 0.6 }, desc: 'Flat-shooting all-rounder. Accurate at range, controllable in short bursts.',
  },
  mp5: {
    id: 'mp5', name: 'MP5A3 SMG', cal: '9×19mm', kind: 'smg', mag: 30, spare: 5, rpm: 800, modes: ['AUTO', 'SEMI'],
    velocity: 400, pellets: 1, hipSpread: 0.022, adsSpread: 0.0012, moveSpread: 0.012,
    recoil: { v: 0.0062, h: 0.003, kick: 0.4, rot: 1.4 }, reload: 2.0, reloadEmpty: 2.5, adsTime: 0.15, zoom: 1.25, speed: 1.0,
    stats: { power: 0.55, rate: 0.8, control: 0.9, handling: 0.9 }, desc: 'The classic entry weapon. Light, soft recoil, fast to the shoulder. More drop past 50 m.',
  },
  m870: {
    id: 'm870', name: 'M870 BREACHER', cal: '12 gauge', kind: 'shotgun', mag: 7, spare: 21, rpm: 75, modes: ['PUMP'],
    velocity: 400, pellets: 9, pelletSpread: 0.03, hipSpread: 0.012, adsSpread: 0.002, moveSpread: 0.01,
    recoil: { v: 0.05, h: 0.012, kick: 1.6, rot: 6 }, shellTime: 0.5, adsTime: 0.22, zoom: 1.2, speed: 0.93,
    stats: { power: 1.0, rate: 0.15, control: 0.35, handling: 0.6 }, desc: 'Devastating up close and blows locked doors off their hinges. Slow pump, slow reload.',
  },
  g17: {
    id: 'g17', name: 'G17 PISTOL', cal: '9×19mm', kind: 'pistol', mag: 17, spare: 3, rpm: 500, modes: ['SEMI'],
    velocity: 375, pellets: 1, hipSpread: 0.02, adsSpread: 0.0018, moveSpread: 0.01,
    recoil: { v: 0.017, h: 0.006, kick: 0.7, rot: 4.5 }, reload: 1.5, reloadEmpty: 1.85, adsTime: 0.13, zoom: 1.15, speed: 1.04,
    stats: { power: 0.5, rate: 0.5, control: 0.6, handling: 1.0 }, desc: 'Sidearm. Switching to it is faster than reloading when your primary runs dry.',
  },
};

export const OPTICS = {
  holo: { name: 'HOLOGRAPHIC', desc: 'Wide window, ring-dot reticle. Fast in rooms.' },
  reddot: { name: 'RED DOT', desc: 'Tube sight, small dot. Precise at range.' },
};

function makeMats(T) {
  return {
    metal: new THREE.MeshStandardMaterial({ color: 0x1b1c1e, metalness: 0.75, roughness: 0.38, normalMap: T.polymer.normalMap, normalScale: new THREE.Vector2(0.15, 0.15) }),
    polymer: new THREE.MeshStandardMaterial({ color: 0x1e1f20, metalness: 0.0, roughness: 0.62, normalMap: T.polymer.normalMap, normalScale: new THREE.Vector2(0.5, 0.5) }),
    fde: new THREE.MeshStandardMaterial({ color: 0x7d6a4c, metalness: 0.0, roughness: 0.66, normalMap: T.polymer.normalMap, normalScale: new THREE.Vector2(0.5, 0.5) }),
    barrel: new THREE.MeshStandardMaterial({ color: 0x2a2a2a, metalness: 0.9, roughness: 0.3 }),
    glove: new THREE.MeshStandardMaterial({ color: 0x2b2a27, roughness: 0.85, normalMap: T.polymer.normalMap, normalScale: new THREE.Vector2(0.6, 0.6) }),
    knuckle: new THREE.MeshStandardMaterial({ color: 0x1a1a19, roughness: 0.7 }),
    sleeve: new THREE.MeshStandardMaterial({ map: T.camo.map, normalMap: T.camo.normalMap, roughness: 0.95 }),
    watch: new THREE.MeshStandardMaterial({ color: 0x101010, roughness: 0.4, metalness: 0.3 }),
    glass: new THREE.MeshStandardMaterial({ color: 0x88aacc, transparent: true, opacity: 0.12, roughness: 0.05, metalness: 0.9, depthWrite: false }),
    brass: new THREE.MeshStandardMaterial({ color: 0xc9a14a, metalness: 1, roughness: 0.3 }),
    shell: new THREE.MeshStandardMaterial({ color: 0x9a1b16, roughness: 0.5 }),
    light: new THREE.MeshStandardMaterial({ color: 0x111111, metalness: 0.6, roughness: 0.4 }),
    lens: new THREE.MeshBasicMaterial({ color: 0xfff3d0 }),
  };
}

function box(p, w, h, d, x, y, z, mat, rx = 0, ry = 0, rz = 0) {
  const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mat);
  m.position.set(x, y, z); m.rotation.set(rx, ry, rz); p.add(m); return m;
}
function cyl(p, r, len, x, y, z, mat, seg = 16, r2, open = false) {
  const g = new THREE.CylinderGeometry(r2 ?? r, r, len, seg, 1, open);
  g.rotateX(Math.PI / 2);
  const m = new THREE.Mesh(g, mat); m.position.set(x, y, z); p.add(m); return m;
}
const _up = new THREE.Vector3(0, 1, 0);
function limb(p, a, b, r1, r2, mat) {
  const dir = new THREE.Vector3().subVectors(b, a); const len = dir.length();
  const m = new THREE.Mesh(new THREE.CylinderGeometry(r2, r1, len, 14), mat);
  m.position.copy(a).addScaledVector(dir, 0.5);
  m.quaternion.setFromUnitVectors(_up, dir.normalize());
  p.add(m); return m;
}

function gripHand(p, M, x, y, z, tilt = -0.3) {
  const h = new THREE.Group(); h.position.set(x, y, z); h.rotation.x = tilt; p.add(h);
  box(h, 0.028, 0.085, 0.07, 0.03, 0, 0.01, M.glove);              // palm on right side
  box(h, 0.06, 0.07, 0.024, 0.006, -0.008, -0.03, M.glove);        // fingers wrap front
  box(h, 0.062, 0.016, 0.026, 0.006, -0.03, -0.031, M.knuckle);
  box(h, 0.02, 0.022, 0.05, -0.022, 0.035, -0.005, M.glove, 0, 0.2, 0); // thumb over
  box(h, 0.014, 0.016, 0.05, 0.018, 0.05, -0.05, M.glove, 0.15, 0, 0);  // trigger finger
  return h;
}

function supportHand(p, M, x, y, z) {
  const h = new THREE.Group(); h.position.set(x, y, z); p.add(h);
  box(h, 0.072, 0.026, 0.085, -0.006, -0.042, 0, M.glove);          // palm under
  box(h, 0.022, 0.06, 0.08, -0.044, -0.01, 0, M.glove);             // fingers left side
  box(h, 0.018, 0.055, 0.07, 0.04, -0.014, 0.004, M.glove);         // thumb right side
  box(h, 0.026, 0.05, 0.084, -0.05, -0.006, 0, M.knuckle);
  return h;
}

function addOptic(root, M, optic, y, z) {
  const g = new THREE.Group(); g.position.set(0, y, z); root.add(g);
  let sightY;
  const ret = new THREE.MeshBasicMaterial({ map: reticleTexture(optic), transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, toneMapped: false, color: new THREE.Color(3, 3, 3) });
  if (optic === 'holo') {
    box(g, 0.046, 0.016, 0.095, 0, 0.008, 0, M.metal);
    box(g, 0.005, 0.05, 0.085, 0.025, 0.04, -0.005, M.metal);
    box(g, 0.005, 0.05, 0.085, -0.025, 0.04, -0.005, M.metal);
    box(g, 0.055, 0.006, 0.085, 0, 0.066, -0.005, M.metal);
    box(g, 0.03, 0.012, 0.02, 0.01, 0.022, 0.04, M.polymer);
    const glass = new THREE.Mesh(new THREE.PlaneGeometry(0.045, 0.045), M.glass); glass.position.set(0, 0.04, -0.04); g.add(glass);
    const r = new THREE.Mesh(new THREE.PlaneGeometry(0.03, 0.03), ret); r.position.set(0, 0.04, -0.0415); r.renderOrder = 10; g.add(r);
    sightY = y + 0.04;
  } else {
    box(g, 0.03, 0.022, 0.05, 0, 0.011, 0, M.metal);
    const tube = cyl(g, 0.019, 0.075, 0, 0.042, -0.005, M.metal, 24, 0.019, true);
    tube.material = M.metal.clone(); tube.material.side = THREE.DoubleSide;
    cyl(g, 0.021, 0.008, 0, 0.042, -0.04, M.metal, 24, 0.021, true).material = tube.material;
    box(g, 0.012, 0.016, 0.02, 0.022, 0.042, 0, M.polymer);
    const glass = new THREE.Mesh(new THREE.CircleGeometry(0.018, 24), M.glass); glass.position.set(0, 0.042, -0.035); g.add(glass);
    const r = new THREE.Mesh(new THREE.PlaneGeometry(0.012, 0.012), ret); r.position.set(0, 0.042, -0.036); r.renderOrder = 10; g.add(r);
    sightY = y + 0.042;
  }
  return sightY;
}

function weaponLight(root, M, x, y, z) {
  const g = new THREE.Group(); g.position.set(x, y, z); root.add(g);
  cyl(g, 0.013, 0.07, 0, 0, 0, M.light, 16);
  cyl(g, 0.016, 0.02, 0, 0, -0.04, M.light, 16);
  const lens = new THREE.Mesh(new THREE.CircleGeometry(0.014, 16), M.lens); lens.position.set(0, 0, -0.0505); lens.rotation.y = Math.PI; g.add(lens);
  lens.rotation.y = 0;
  return lens;
}

export function buildModel(id, optic, T) {
  const M = makeMats(T);
  const root = new THREE.Group();
  const out = { root, M };
  const muzzle = new THREE.Object3D(), eject = new THREE.Object3D();
  root.add(muzzle); root.add(eject);
  out.muzzle = muzzle; out.eject = eject;
  let leftHand, rightHand;

  if (id === 'm4') {
    box(root, 0.05, 0.056, 0.25, 0, 0.03, -0.02, M.metal);
    box(root, 0.046, 0.05, 0.17, 0, -0.02, 0.0, M.metal);
    box(root, 0.052, 0.05, 0.075, 0, -0.04, -0.06, M.metal);
    box(root, 0.006, 0.012, 0.07, 0, -0.06, 0.02, M.metal);
    box(root, 0.032, 0.105, 0.045, 0, -0.075, 0.075, M.polymer, -0.35);
    box(root, 0.06, 0.064, 0.30, 0, 0.028, -0.29, M.fde);
    for (let i = 0; i < 9; i++) box(root, 0.064, 0.006, 0.012, 0, 0.012 + (i % 3) * 0.016, -0.18 - Math.floor(i / 3) * 0.08, M.polymer);
    box(root, 0.024, 0.01, 0.55, 0, 0.063, -0.14, M.metal);
    for (let i = 0; i < 14; i++) box(root, 0.026, 0.003, 0.006, 0, 0.068, -0.1 - i * 0.02, M.metal);
    cyl(root, 0.0095, 0.17, 0, 0.03, -0.525, M.barrel);
    box(root, 0.026, 0.03, 0.03, 0, 0.032, -0.455, M.metal);
    cyl(root, 0.013, 0.06, 0, 0.03, -0.63, M.metal, 6);
    muzzle.position.set(0, 0.03, -0.665);
    cyl(root, 0.016, 0.21, 0, 0.022, 0.2, M.metal);
    box(root, 0.044, 0.08, 0.15, 0, 0.0, 0.29, M.fde);
    box(root, 0.046, 0.1, 0.02, 0, -0.005, 0.37, M.polymer);
    box(root, 0.044, 0.012, 0.03, 0, 0.056, 0.115, M.metal);
    box(root, 0.004, 0.02, 0.05, 0.026, 0.032, -0.01, M.barrel);
    eject.position.set(0.03, 0.03, -0.01);
    const mag = new THREE.Group(); mag.position.set(0, -0.065, -0.06); root.add(mag);
    box(mag, 0.025, 0.1, 0.068, 0, -0.04, 0, M.polymer, 0.1);
    box(mag, 0.025, 0.08, 0.066, 0, -0.12, -0.014, M.polymer, 0.28);
    box(mag, 0.03, 0.012, 0.072, 0, -0.16, -0.026, M.polymer, 0.28);
    out.mag = mag;
    out.light = weaponLight(root, M, 0.045, 0.03, -0.36);
    out.sightY = addOptic(root, M, optic, 0.068, -0.03);
    rightHand = gripHand(root, M, 0, -0.07, 0.072);
    leftHand = supportHand(root, M, 0, 0.02, -0.33);
    out.adsZ = -0.25; out.hip = new THREE.Vector3(0.16, -0.165, -0.42);
  } else if (id === 'mp5') {
    box(root, 0.05, 0.07, 0.30, 0, 0.022, -0.08, M.metal);
    cyl(root, 0.026, 0.3, 0, 0.032, -0.08, M.metal, 20);
    box(root, 0.044, 0.04, 0.16, 0, -0.018, 0.02, M.polymer);
    box(root, 0.03, 0.105, 0.045, 0, -0.075, 0.07, M.polymer, -0.3);
    box(root, 0.058, 0.064, 0.14, 0, 0.012, -0.31, M.polymer);
    cyl(root, 0.0105, 0.1, 0, 0.032, -0.43, M.barrel);
    cyl(root, 0.016, 0.03, 0, 0.032, -0.47, M.metal, 10);
    cyl(root, 0.012, 0.03, 0, 0.065, -0.4, M.metal, 10);
    muzzle.position.set(0, 0.032, -0.49);
    box(root, 0.008, 0.008, 0.25, 0.022, 0.02, 0.18, M.metal);
    box(root, 0.008, 0.008, 0.25, -0.022, 0.02, 0.18, M.metal);
    box(root, 0.05, 0.09, 0.02, 0, 0.0, 0.31, M.polymer);
    box(root, 0.03, 0.025, 0.04, -0.02, 0.06, -0.24, M.metal);
    eject.position.set(0.03, 0.035, -0.06);
    const mag = new THREE.Group(); mag.position.set(0, -0.012, -0.17); root.add(mag);
    box(mag, 0.024, 0.09, 0.04, 0, -0.045, 0, M.metal, 0.2);
    box(mag, 0.024, 0.08, 0.04, 0, -0.12, -0.03, M.metal, 0.48);
    out.mag = mag;
    box(root, 0.03, 0.02, 0.08, 0, 0.07, -0.07, M.metal);
    out.light = weaponLight(root, M, 0.04, 0.012, -0.33);
    out.sightY = addOptic(root, M, optic, 0.08, -0.07);
    rightHand = gripHand(root, M, 0, -0.07, 0.068);
    leftHand = supportHand(root, M, 0, 0.012, -0.31);
    out.adsZ = -0.26; out.hip = new THREE.Vector3(0.16, -0.17, -0.42);
  } else if (id === 'm870') {
    box(root, 0.05, 0.07, 0.22, 0, 0.022, -0.02, M.metal);
    box(root, 0.044, 0.03, 0.12, 0, -0.025, 0.0, M.metal);
    box(root, 0.032, 0.105, 0.045, 0, -0.08, 0.075, M.polymer, -0.35);
    cyl(root, 0.0115, 0.5, 0, 0.044, -0.38, M.barrel);
    cyl(root, 0.0135, 0.42, 0, 0.006, -0.33, M.metal);
    box(root, 0.02, 0.016, 0.03, 0, 0.044, -0.6, M.metal);
    cyl(root, 0.016, 0.04, 0, 0.044, -0.63, M.metal, 8);
    muzzle.position.set(0, 0.044, -0.66);
    cyl(root, 0.016, 0.2, 0, 0.02, 0.2, M.metal);
    box(root, 0.044, 0.085, 0.13, 0, 0.0, 0.3, M.polymer);
    box(root, 0.022, 0.008, 0.2, 0, 0.061, -0.02, M.metal);
    eject.position.set(0.03, 0.02, -0.04);
    const pump = new THREE.Group(); pump.position.set(0, 0, -0.26); root.add(pump);
    box(pump, 0.056, 0.05, 0.17, 0, 0.004, 0, M.polymer);
    for (let i = 0; i < 6; i++) box(pump, 0.06, 0.004, 0.008, 0, -0.008, -0.06 + i * 0.024, M.metal);
    out.pump = pump;
    const shell = new THREE.Group(); shell.visible = false; root.add(shell);
    cyl(shell, 0.0095, 0.05, 0, 0, -0.01, M.shell); cyl(shell, 0.0098, 0.016, 0, 0, 0.022, M.brass);
    out.shell = shell;
    out.light = weaponLight(root, M, 0.035, 0.0, -0.36);
    out.sightY = addOptic(root, M, optic === 'holo' ? 'holo' : 'reddot', 0.066, -0.02);
    rightHand = gripHand(root, M, 0, -0.075, 0.072);
    leftHand = supportHand(root, M, 0, 0.0, 0); pump.add(leftHand);
    out.adsZ = -0.27; out.hip = new THREE.Vector3(0.16, -0.17, -0.42);
  } else {
    // G17
    const slide = new THREE.Group(); root.add(slide);
    box(slide, 0.027, 0.03, 0.19, 0, 0.032, -0.06, M.metal);
    for (let i = 0; i < 6; i++) box(slide, 0.029, 0.022, 0.004, 0, 0.032, 0.015 + i * 0.008, M.barrel);
    box(slide, 0.004, 0.008, 0.008, 0.007, 0.051, 0.025, M.metal);
    box(slide, 0.004, 0.008, 0.008, -0.007, 0.051, 0.025, M.metal);
    box(slide, 0.004, 0.008, 0.006, 0, 0.051, -0.145, M.metal);
    out.slide = slide;
    box(root, 0.025, 0.024, 0.17, 0, 0.007, -0.055, M.polymer);
    box(root, 0.028, 0.11, 0.05, 0, -0.045, 0.012, M.polymer, -0.28);
    box(root, 0.005, 0.016, 0.04, 0, -0.012, -0.03, M.polymer);
    muzzle.position.set(0, 0.034, -0.16);
    eject.position.set(0.016, 0.04, -0.03);
    const mag = new THREE.Group(); mag.position.set(0, -0.07, 0.02); root.add(mag);
    box(mag, 0.024, 0.04, 0.045, 0, -0.03, 0.008, M.polymer, -0.28);
    out.mag = mag;
    out.light = weaponLight(root, M, 0, -0.012, -0.11);
    out.sightY = 0.055;
    rightHand = gripHand(root, M, 0, -0.05, 0.01, -0.28);
    leftHand = new THREE.Group(); leftHand.position.set(-0.012, -0.055, 0.0); root.add(leftHand);
    box(leftHand, 0.026, 0.08, 0.075, -0.018, 0, 0, M.glove, -0.28);
    box(leftHand, 0.02, 0.02, 0.06, -0.008, 0.035, -0.035, M.glove, 0, 0.3, 0);
    out.adsZ = -0.36; out.hip = new THREE.Vector3(0.13, -0.14, -0.4);
  }

  // Forearms/sleeves: from hands back toward the bottom corners of the screen.
  const rh = rightHand.position.clone();
  limb(root, rh.clone().add(new THREE.Vector3(0.02, -0.03, 0.04)), new THREE.Vector3(0.14, -0.22, 0.45), 0.033, 0.045, M.sleeve);
  box(root, 0.05, 0.03, 0.03, rh.x + 0.025, rh.y - 0.04, rh.z + 0.055, M.watch, -0.5);
  out.leftArm = new THREE.Group(); root.add(out.leftArm);
  out.leftArmMesh = limb(out.leftArm, new THREE.Vector3(0, 0, 0), new THREE.Vector3(0, 0, 1), 0.031, 0.042, M.sleeve);
  out.leftHand = leftHand; out.rightHand = rightHand;
  out.leftHandHome = leftHand.position.clone();

  // Muzzle flash: three crossed additive cards on the muzzle.
  const flashMat = new THREE.MeshBasicMaterial({ map: muzzleFlashTexture(), transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, toneMapped: false, color: new THREE.Color(4, 3, 2), side: THREE.DoubleSide });
  const flash = new THREE.Group(); muzzle.add(flash);
  const size = id === 'm870' ? 0.22 : id === 'm4' ? 0.17 : 0.12;
  const f1 = new THREE.Mesh(new THREE.PlaneGeometry(size, size), flashMat); flash.add(f1);
  const f2 = new THREE.Mesh(new THREE.PlaneGeometry(size * 0.6, size * 1.8), flashMat); f2.rotation.x = Math.PI / 2; f2.position.z = -size * 0.6; flash.add(f2);
  const f3 = f2.clone(); f3.rotation.y = Math.PI / 2; f3.rotation.x = 0; f3.rotation.z = Math.PI / 2; flash.add(f3);
  flash.visible = false;
  out.flash = flash;
  root.traverse(o => { if (o.isMesh) { o.frustumCulled = false; } });
  return out;
}

// Spring helper: critically-damped-ish return to zero.
class Spring {
  constructor(k = 220, d = 18) { this.k = k; this.d = d; this.x = 0; this.v = 0; }
  update(dt) { const a = -this.k * this.x - this.d * this.v; this.v += a * dt; this.x += this.v * dt; return this.x; }
}

export class Arsenal {
  constructor(game, vmScene, T) {
    this.g = game; this.T = T;
    this.holder = new THREE.Group();
    vmScene.add(this.holder);
    this.slots = [];
    this.cur = 0;
    this.kickZ = new Spring(260, 24); this.kickX = new Spring(240, 20); this.kickRot = new Spring(200, 18); this.kickRoll = new Spring(200, 16);
    this.sway = new THREE.Vector2(); this.swayV = new THREE.Vector2();
    this.ads = 0; this.sprint = 0; this.lower = 0;
    this.reloading = false; this.reloadT = 0; this.reloadDur = 1; this.reloadEmpty = false;
    this.pumpT = 0; this.pumping = false;
    this.switching = 0; this.switchTarget = -1;
    this.cooldown = 0; this.triggerHeld = false; this.triggerReleased = true;
    this.flashTime = 0; this.burst = 0;
    this.shellLoad = 0;
    this._v = new THREE.Vector3(); this._v2 = new THREE.Vector3();
    this.events = [];
  }

  equip(primaryId, optic) {
    for (const s of this.slots) this.holder.remove(s.model.root);
    this.slots = [];
    for (const id of [primaryId, 'g17']) {
      const def = WEAPONS[id];
      const model = buildModel(id, optic, this.T);
      model.root.visible = false;
      this.holder.add(model.root);
      const slot = { def, model, mode: 0, chambered: true, mag: def.mag, spare: [] };
      if (def.kind === 'shotgun') slot.loose = def.spare;
      else for (let i = 0; i < def.spare; i++) slot.spare.push(def.mag);
      this.slots.push(slot);
    }
    this.cur = 0;
    this.slots[0].model.root.visible = true;
    this.reloading = false; this.switching = 0; this.pumping = false; this.ads = 0;
  }

  get s() { return this.slots[this.cur]; }

  ammoText() {
    const s = this.s; if (!s) return '';
    return `${s.mag}${s.chambered ? '+1' : ''}`;
  }

  busy() { return this.reloading || this.switching > 0 || this.pumping; }

  reload() {
    const s = this.s; if (!s || this.busy() || this.pendingPump > 0) return;
    const d = s.def;
    if (d.kind === 'shotgun') {
      if (s.mag >= d.mag || s.loose <= 0) return;
      this.reloading = true; this.reloadT = 0; this.shellLoad = 0; this.reloadDur = d.shellTime;
      this.reloadEmpty = !s.chambered;
      return;
    }
    if (!s.spare.length) { this.g.toast('NO SPARE MAGAZINES'); return; }
    if (s.mag >= d.mag) return;
    this.reloading = true; this.reloadT = 0;
    this.reloadEmpty = !s.chambered;
    this.reloadDur = this.reloadEmpty ? d.reloadEmpty : d.reload;
    this.events = [[0.22, 'magOut'], [0.62, 'magIn']];
    if (this.reloadEmpty) this.events.push([0.86, 'bolt']);
  }

  finishMagReload() {
    const s = this.s;
    // Tactical reload: partial mag goes back in the pouch, grab the fullest one.
    s.spare.sort((a, b) => b - a);
    const fresh = s.spare.shift();
    if (s.mag > 0) s.spare.push(s.mag);
    s.mag = fresh;
    if (!s.chambered && s.mag > 0) { s.mag--; s.chambered = true; }
  }

  switchTo(i) {
    if (i === this.cur || i >= this.slots.length || this.switching > 0) return;
    if (this.reloading) { this.reloading = false; }
    this.pumping = false;
    this.switchTarget = i; this.switching = 1;
    this.g.audio.switchWeapon();
  }

  toggleMode() {
    const s = this.s; if (!s || s.def.modes.length < 2) return;
    s.mode = (s.mode + 1) % s.def.modes.length;
    this.g.audio.modeSwitch();
  }

  trigger(down) {
    if (down && !this.triggerHeld) { this.triggerReleased = true; this.clickBuffer = 0.15; }
    this.triggerHeld = down;
  }

  tryFire() {
    const s = this.s, d = s.def;
    if (this.switching > 0 || this.sprint > 0.5 || this.lower > 0.3) { this.why = 'pose'; return false; }
    if (this.reloading) {
      if (d.kind === 'shotgun' && s.chambered) { this.reloading = false; } else { this.why = 'reload'; return false; }
    }
    if (this.pumping || this.cooldown > 0) { this.why = 'cooldown'; return false; }
    const mode = d.modes[s.mode];
    if (mode !== 'AUTO' && !this.triggerReleased) { this.why = 'semi'; return false; }
    this.triggerReleased = false;
    if (!s.chambered) { this.g.audio.dryFire(); this.cooldown = 0.25; if (d.kind !== 'shotgun' && s.spare.length && this.g.settings.autoReload) this.reload(); return true; }
    // Fire
    this.cooldown = 60 / d.rpm;
    if (d.kind === 'shotgun') { s.chambered = false; }
    else if (s.mag > 0) s.mag--; else s.chambered = false;
    this.burst++;
    this.g.onFire(s, this);
    // Viewmodel recoil
    const adsK = 1 - this.ads * 0.45;
    this.kickZ.v += d.recoil.kick * adsK * (0.9 + Math.random() * 0.2);
    this.kickRot.v += d.recoil.rot * adsK * (0.85 + Math.random() * 0.3);
    this.kickX.v += (Math.random() - 0.5) * d.recoil.kick * 0.4;
    this.kickRoll.v += (Math.random() - 0.5) * d.recoil.rot * 0.6;
    this.flashTime = 0.045;
    const f = s.model.flash; f.visible = true; f.rotation.z = Math.random() * Math.PI; f.scale.setScalar(0.8 + Math.random() * 0.5);
    if (s.model.slide) this.slideT = 1;
    if (d.kind === 'shotgun') { this.pendingPump = 0.18; }
    else this.g.ejectCasing(s, this);
    return true;
  }

  update(dt, input) {
    const s = this.s; if (!s) return;
    const d = s.def, m = s.model;
    this.cooldown = Math.max(0, this.cooldown - dt);

    // Buffered clicks: a press+release inside one frame still fires (matters at low FPS).
    if (this.triggerHeld || this.clickBuffer > 0) { if (this.tryFire()) this.clickBuffer = 0; }
    if (!this.triggerHeld) this.burst = 0;
    this.clickBuffer = Math.max(0, (this.clickBuffer || 0) - dt);

    // Shotgun pump cycle
    if (this.pendingPump !== undefined && this.pendingPump > 0) {
      this.pendingPump -= dt;
      if (this.pendingPump <= 0) { this.pumping = true; this.pumpT = 0; this.g.audio.pump(); this.pendingPump = 0; }
    }
    if (this.pumping) {
      this.pumpT += dt / 0.42;
      if (this.pumpT >= 0.45 && !this.pumpEjected) { this.pumpEjected = true; this.g.ejectCasing(s, this); }
      if (this.pumpT >= 1) {
        this.pumping = false; this.pumpT = 0; this.pumpEjected = false;
        if (s.mag > 0) { s.mag--; s.chambered = true; }
      }
    }

    // Reload progression
    if (this.reloading) {
      this.reloadT += dt / this.reloadDur;
      if (d.kind === 'shotgun') {
        if (this.reloadT >= 1) {
          this.g.audio.shellIn();
          s.mag++; s.loose--;
          this.reloadT = 0;
          if (s.mag >= d.mag || s.loose <= 0) {
            this.reloading = false;
            if (!s.chambered && s.mag > 0) { this.pumping = true; this.pumpT = 0; this.g.audio.pump(); this.pumpEjected = true; }
          }
        }
      } else {
        while (this.events.length && this.reloadT >= this.events[0][0]) {
          const e = this.events.shift()[1];
          if (e === 'magOut') this.g.audio.magOut();
          if (e === 'magIn') this.g.audio.magIn();
          if (e === 'bolt') this.g.audio.boltRelease();
        }
        if (this.reloadT >= 1) { this.reloading = false; this.finishMagReload(); }
      }
    }

    // Weapon switch: lower, swap, raise
    if (this.switching > 0) {
      this.switching -= dt / 0.24;
      if (this.switchTarget >= 0 && this.switching <= 0.5) {
        s.model.root.visible = false;
        this.cur = this.switchTarget; this.switchTarget = -1;
        this.s.model.root.visible = true;
      }
      if (this.switching < 0) this.switching = 0;
    }

    // ADS / sprint blending
    const wantAds = input.ads && !this.reloading && this.switching === 0 && this.sprint < 0.3 && this.lower < 0.3;
    const adsRate = dt / d.adsTime;
    this.ads = Math.max(0, Math.min(1, this.ads + (wantAds ? adsRate : -adsRate * 1.3)));
    this.sprint += ((input.sprinting ? 1 : 0) - this.sprint) * Math.min(1, dt * 8);
    this.lower += ((input.lowered ? 1 : 0) - this.lower) * Math.min(1, dt * 10);

    // Sway from look input, lags behind the camera.
    const swayAmt = 1 - this.ads * 0.97;
    this.swayV.x += -input.lookDX * 0.0025 * swayAmt + (-this.sway.x * 110 - this.swayV.x * 14) * dt;
    this.swayV.y += input.lookDY * 0.0025 * swayAmt + (-this.sway.y * 110 - this.swayV.y * 14) * dt;
    this.sway.x += this.swayV.x * dt; this.sway.y += this.swayV.y * dt;
    this.sway.x = Math.max(-0.05, Math.min(0.05, this.sway.x)); this.sway.y = Math.max(-0.05, Math.min(0.05, this.sway.y));

    const kz = this.kickZ.update(dt) * 0.02, kr = this.kickRot.update(dt) * 0.01, kx = this.kickX.update(dt) * 0.02, kroll = this.kickRoll.update(dt) * 0.01;

    // Compose transform
    const e = this.ads * this.ads * (3 - 2 * this.ads);
    const r = m.root;
    const hip = m.hip;
    const adsPos = this._v.set(0, -m.sightY, m.adsZ);
    r.position.lerpVectors(hip, adsPos, e);
    const bob = input.bob, bobAmt = (1 - e * 0.97);
    r.position.x += Math.cos(bob) * 0.006 * input.moveAmt * bobAmt + this.sway.x * 0.4;
    r.position.y += Math.abs(Math.sin(bob)) * 0.007 * input.moveAmt * bobAmt + this.sway.y * 0.4 + Math.sin(input.time * 1.3) * 0.0012 * (1 - e);
    r.position.z += kz;
    r.position.x += kx * (1 - e * 0.7);
    r.rotation.set(kr + this.sway.y * 1.5, this.sway.x * 1.5, kroll + this.sway.x * 1.2 + input.lean * -0.15);


    // Sprint pose
    const sp = this.sprint * (1 - e);
    r.position.x -= sp * 0.04; r.position.y -= sp * 0.05; r.position.z += sp * 0.03;
    r.rotation.y += sp * 0.7; r.rotation.x -= sp * 0.25; r.rotation.z += sp * 0.2;
    r.position.x += Math.cos(bob) * 0.02 * sp; r.position.y += Math.abs(Math.sin(bob)) * 0.02 * sp;

    // Lowered (throwing / interacting)
    r.position.y -= this.lower * 0.2; r.rotation.x -= this.lower * 0.6;

    // Switch animation
    if (this.switching > 0) { const w = Math.sin(this.switching * Math.PI); r.position.y -= w * 0.25; r.rotation.x -= w * 0.8; }

    // Reload animation
    if (m.mag) { m.mag.position.y = m.magHomeY ?? (m.magHomeY = m.mag.position.y); m.mag.visible = true; }
    m.leftHand.position.copy(m.leftHandHome);
    if (this.reloading && d.kind !== 'shotgun') {
      const t = this.reloadT;
      const tilt = Math.sin(Math.min(1, t * 1.2) * Math.PI);
      r.rotation.z += tilt * 0.45; r.rotation.x += tilt * 0.12; r.position.y -= tilt * 0.03;
      let magDrop = 0;
      if (t > 0.18 && t < 0.62) magDrop = Math.min(1, (t - 0.18) / 0.1) * (t < 0.45 ? 1 : 1 - (t - 0.45) / 0.17);
      if (t > 0.22 && t < 0.4) m.mag.visible = (t > 0.3) ? false : true;
      m.mag.position.y = m.magHomeY - magDrop * 0.25;
      if (t > 0.15 && t < 0.7) {
        const hk = Math.sin((t - 0.15) / 0.55 * Math.PI);
        m.leftHand.position.lerpVectors(m.leftHandHome, this._v2.set(m.mag.position.x - 0.01, m.mag.position.y - 0.08, m.mag.position.z), hk);
      }
      if (this.reloadEmpty && t > 0.8) { const b = Math.sin((t - 0.8) / 0.2 * Math.PI); r.rotation.y += b * 0.08; }
    }
    if (d.kind === 'shotgun') {
      const pumpBack = this.pumping ? Math.sin(Math.min(1, this.pumpT) * Math.PI) : 0;
      m.pump.position.z = -0.26 + pumpBack * 0.08;
      r.position.z += pumpBack * 0.01;
      m.shell.visible = false;
      if (this.reloading) {
        const t = this.reloadT;
        r.rotation.z += 0.35; r.rotation.x += 0.1; r.position.y -= 0.02;
        m.shell.visible = t < 0.7;
        m.shell.position.set(0.0, -0.05 - (1 - t) * 0.06, 0.02 - t * 0.04);
        m.shell.rotation.x = 0.4;
      }
    }
    if (m.slide) { this.slideT = Math.max(0, (this.slideT || 0) - dt * 22); m.slide.position.z = this.slideT * 0.03 + (s.chambered ? 0 : 0.03); }

    // Left forearm follows left hand
    const lh = this._v2.copy(m.leftHand.position);
    if (d.kind === 'shotgun') lh.add(m.pump.position);
    lh.y -= 0.035; lh.z += 0.03;
    const elbow = new THREE.Vector3(-0.2, -0.28, 0.4);
    const dir = new THREE.Vector3().subVectors(elbow, lh); const len = dir.length();
    m.leftArm.position.copy(lh).addScaledVector(dir, 0.5).add(new THREE.Vector3(0, -0.02, 0));
    m.leftArm.quaternion.setFromUnitVectors(_up, dir.normalize());
    m.leftArmMesh.position.set(0, 0, 0); m.leftArmMesh.quaternion.identity(); m.leftArmMesh.scale.set(1, len, 1);

    // Muzzle flash
    if (this.flashTime > 0) { this.flashTime -= dt; if (this.flashTime <= 0) m.flash.visible = false; }
  }
}
