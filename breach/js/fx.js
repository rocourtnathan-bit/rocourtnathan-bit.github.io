// Impact particles, bullet-hole decals, ejected casings with simple rigid-body bounce.
import * as THREE from 'three';
import { bulletHoleTexture } from './textures.js';

const PVERT = `
attribute float aSize; attribute float aAlpha; attribute vec3 aColor;
uniform float uScale;
varying float vA; varying vec3 vC;
void main(){
  vec4 mv = modelViewMatrix * vec4(position, 1.0);
  gl_Position = projectionMatrix * mv;
  gl_PointSize = aSize * uScale / max(0.05, -mv.z);
  vA = aAlpha; vC = aColor;
}`;
const PFRAG = `
varying float vA; varying vec3 vC;
uniform float uSoft;
void main(){
  float d = length(gl_PointCoord - 0.5);
  if (d > 0.5) discard;
  float a = vA * mix(1.0, smoothstep(0.5, 0.0, d), uSoft);
  gl_FragColor = vec4(vC, a);
}`;

class Particles {
  constructor(scene, max, additive) {
    this.max = max; this.n = 0; this.cursor = 0;
    const g = new THREE.BufferGeometry();
    this.pos = new Float32Array(max * 3); this.col = new Float32Array(max * 3);
    this.size = new Float32Array(max); this.alpha = new Float32Array(max);
    g.setAttribute('position', new THREE.BufferAttribute(this.pos, 3).setUsage(THREE.DynamicDrawUsage));
    g.setAttribute('aColor', new THREE.BufferAttribute(this.col, 3).setUsage(THREE.DynamicDrawUsage));
    g.setAttribute('aSize', new THREE.BufferAttribute(this.size, 1).setUsage(THREE.DynamicDrawUsage));
    g.setAttribute('aAlpha', new THREE.BufferAttribute(this.alpha, 1).setUsage(THREE.DynamicDrawUsage));
    this.mat = new THREE.ShaderMaterial({
      vertexShader: PVERT, fragmentShader: PFRAG,
      uniforms: { uScale: { value: 400 }, uSoft: { value: additive ? 0.6 : 1.0 } },
      transparent: true, depthWrite: false,
      blending: additive ? THREE.AdditiveBlending : THREE.NormalBlending,
    });
    this.points = new THREE.Points(g, this.mat);
    this.points.frustumCulled = false;
    this.points.renderOrder = 5;
    scene.add(this.points);
    this.p = [];
    for (let i = 0; i < max; i++) this.p.push({ life: 0, max: 1, x: 0, y: 0, z: 0, vx: 0, vy: 0, vz: 0, s0: 0, s1: 0, a0: 1, r: 1, g: 1, b: 1, grav: 0, drag: 0 });
    this.geo = g;
  }
  spawn(x, y, z, vx, vy, vz, life, s0, s1, a0, r, g, b, grav, drag) {
    const p = this.p[this.cursor]; this.cursor = (this.cursor + 1) % this.max;
    Object.assign(p, { life, max: life, x, y, z, vx, vy, vz, s0, s1, a0, r, g, b, grav, drag });
  }
  update(dt) {
    let k = 0;
    for (let i = 0; i < this.max; i++) {
      const p = this.p[i];
      if (p.life <= 0) continue;
      p.life -= dt;
      if (p.life <= 0) continue;
      const dr = Math.exp(-p.drag * dt);
      p.vx *= dr; p.vy = p.vy * dr - p.grav * dt; p.vz *= dr;
      p.x += p.vx * dt; p.y += p.vy * dt; p.z += p.vz * dt;
      if (p.y < 0.01 && p.vy < 0) { p.y = 0.01; p.vy *= -0.3; p.vx *= 0.5; p.vz *= 0.5; }
      const t = 1 - p.life / p.max;
      this.pos[k * 3] = p.x; this.pos[k * 3 + 1] = p.y; this.pos[k * 3 + 2] = p.z;
      this.col[k * 3] = p.r; this.col[k * 3 + 1] = p.g; this.col[k * 3 + 2] = p.b;
      this.size[k] = p.s0 + (p.s1 - p.s0) * t;
      this.alpha[k] = p.a0 * (1 - t) * (1 - t);
      k++;
    }
    this.geo.setDrawRange(0, k);
    for (const a of ['position', 'aColor', 'aSize', 'aAlpha']) this.geo.attributes[a].needsUpdate = true;
  }
}

const SURF_COLOR = {
  concrete: [0.55, 0.53, 0.5], block: [0.6, 0.58, 0.55], wood: [0.62, 0.5, 0.34], target: [0.62, 0.5, 0.34],
  dirt: [0.4, 0.32, 0.22], gravel: [0.45, 0.4, 0.33], metal: [0.4, 0.4, 0.42], steel: [0.4, 0.4, 0.42], door: [0.5, 0.45, 0.35],
};

export class FX {
  constructor(scene) {
    this.scene = scene;
    this.sparks = new Particles(scene, 400, true);
    this.dust = new Particles(scene, 600, false);
    // Decals
    const holeMat = new THREE.MeshStandardMaterial({ map: bulletHoleTexture(false), transparent: true, depthWrite: false, polygonOffset: true, polygonOffsetFactor: -4, roughness: 1 });
    const scuffMat = new THREE.MeshStandardMaterial({ map: bulletHoleTexture(true), transparent: true, depthWrite: false, polygonOffset: true, polygonOffsetFactor: -4, roughness: 0.3, metalness: 0.8 });
    this.decalMats = { hole: holeMat, scuff: scuffMat };
    const dg = new THREE.PlaneGeometry(1, 1);
    this.decals = [];
    for (let i = 0; i < 260; i++) {
      const m = new THREE.Mesh(dg, holeMat); m.visible = false; m.renderOrder = 2;
      m.matrixAutoUpdate = true;
      scene.add(m); this.decals.push(m);
    }
    this.decalCursor = 0;
    // Casings
    this.casings = [];
    const brass = new THREE.MeshStandardMaterial({ color: 0xc9a14a, metalness: 1, roughness: 0.28 });
    const shellMat = new THREE.MeshStandardMaterial({ color: 0x9a1b16, roughness: 0.5 });
    const rifleG = new THREE.CylinderGeometry(0.0048, 0.0048, 0.045, 8).rotateZ(Math.PI / 2);
    const pistolG = new THREE.CylinderGeometry(0.0048, 0.0048, 0.02, 8).rotateZ(Math.PI / 2);
    const shellG = new THREE.CylinderGeometry(0.0095, 0.0095, 0.068, 10).rotateZ(Math.PI / 2);
    this.casingGeos = { rifle: [rifleG, brass], smg: [pistolG, brass], pistol: [pistolG, brass], shotgun: [shellG, shellMat] };
    for (let i = 0; i < 60; i++) {
      const m = new THREE.Mesh(rifleG, brass); m.visible = false; m.castShadow = true;
      scene.add(m);
      this.casings.push({ m, vel: new THREE.Vector3(), spin: new THREE.Vector3(), life: 0, bounces: 0, kind: 'rifle' });
    }
    this.casingCursor = 0;
    this._v = new THREE.Vector3(); this._q = new THREE.Quaternion();
    this.onCasingBounce = null;
  }

  setScale(px) { this.sparks.mat.uniforms.uScale.value = px; this.dust.mat.uniforms.uScale.value = px; }

  decal(point, normal, parent, surf) {
    const d = this.decals[this.decalCursor]; this.decalCursor = (this.decalCursor + 1) % this.decals.length;
    const metal = surf === 'steel' || surf === 'metal';
    d.material = metal ? this.decalMats.scuff : this.decalMats.hole;
    if (d.parent !== this.scene) this.scene.attach(d);
    d.position.copy(point).addScaledVector(normal, 0.003);
    d.lookAt(this._v.copy(d.position).add(normal));
    d.rotateZ(Math.random() * Math.PI * 2);
    const s = metal ? 0.05 : (surf === 'dirt' || surf === 'gravel' ? 0.07 : 0.03 + Math.random() * 0.01);
    d.scale.set(s, s, s);
    d.visible = true;
    if (parent && parent !== this.scene) parent.attach(d);
  }

  impact(point, normal, surf, dir) {
    const c = SURF_COLOR[surf] || SURF_COLOR.concrete;
    // Dust puff along the reflected direction
    const nd = 6 + Math.floor(Math.random() * 4);
    for (let i = 0; i < nd; i++) {
      const sp = 0.6 + Math.random() * 1.8;
      this.dust.spawn(point.x, point.y, point.z,
        normal.x * sp + (Math.random() - 0.5) * 1.2, normal.y * sp + Math.random() * 0.8, normal.z * sp + (Math.random() - 0.5) * 1.2,
        0.5 + Math.random() * 0.9, 0.04, 0.35 + Math.random() * 0.25, 0.55,
        c[0], c[1], c[2], 0.3, 2.8);
    }
    // Debris chips
    for (let i = 0; i < 5; i++) {
      const sp = 2 + Math.random() * 3;
      this.dust.spawn(point.x, point.y, point.z,
        normal.x * sp + (Math.random() - 0.5) * 3, normal.y * sp + Math.random() * 2, normal.z * sp + (Math.random() - 0.5) * 3,
        0.5 + Math.random() * 0.4, 0.015, 0.012, 1, c[0] * 0.7, c[1] * 0.7, c[2] * 0.7, 9.8, 0.5);
    }
    if (surf === 'steel' || surf === 'metal' || surf === 'concrete' || surf === 'block') {
      const ns = surf === 'steel' ? 14 : 4;
      for (let i = 0; i < ns; i++) {
        const sp = 3 + Math.random() * 6;
        const rx = normal.x - (dir ? dir.x * 0.5 : 0), ry = normal.y, rz = normal.z - (dir ? dir.z * 0.5 : 0);
        this.sparks.spawn(point.x, point.y, point.z,
          rx * sp + (Math.random() - 0.5) * 5, ry * sp + Math.random() * 3, rz * sp + (Math.random() - 0.5) * 5,
          0.12 + Math.random() * 0.25, 0.025, 0.01, 1, 6, 3.4, 1.2, 9.8, 1);
      }
    }
  }

  muzzleSmoke(p, dir) {
    for (let i = 0; i < 3; i++) {
      this.dust.spawn(p.x, p.y, p.z, dir.x * 1.5 + (Math.random() - 0.5) * 0.3, dir.y * 1.5 + 0.3, dir.z * 1.5 + (Math.random() - 0.5) * 0.3,
        0.6 + Math.random() * 0.6, 0.05, 0.4, 0.12, 0.8, 0.8, 0.8, -0.3, 3);
    }
  }

  flashBurst(p) {
    for (let i = 0; i < 60; i++) {
      const a = Math.random() * Math.PI * 2, b = Math.random() * Math.PI - Math.PI / 2, sp = 2 + Math.random() * 7;
      this.sparks.spawn(p.x, p.y, p.z, Math.cos(a) * Math.cos(b) * sp, Math.abs(Math.sin(b)) * sp, Math.sin(a) * Math.cos(b) * sp,
        0.2 + Math.random() * 0.4, 0.06, 0.02, 1, 8, 7, 5, 6, 2);
    }
    for (let i = 0; i < 40; i++) {
      const a = Math.random() * Math.PI * 2, sp = 0.5 + Math.random() * 2.5;
      this.dust.spawn(p.x, p.y + 0.1, p.z, Math.cos(a) * sp, Math.random() * 1.5, Math.sin(a) * sp,
        2.5 + Math.random() * 2, 0.3, 2.2, 0.5, 0.75, 0.75, 0.75, -0.15, 1.2);
    }
  }

  ejectCasing(pos, vel, kind) {
    const c = this.casings[this.casingCursor]; this.casingCursor = (this.casingCursor + 1) % this.casings.length;
    const [g, m] = this.casingGeos[kind] || this.casingGeos.rifle;
    c.m.geometry = g; c.m.material = m;
    c.m.position.copy(pos); c.vel.copy(vel);
    c.m.rotation.set(Math.random() * 3, Math.random() * 3, Math.random() * 3);
    c.spin.set((Math.random() - 0.5) * 30, (Math.random() - 0.5) * 40, (Math.random() - 0.5) * 30);
    c.life = 12; c.bounces = 0; c.kind = kind; c.m.visible = true;
  }

  update(dt, floorAt) {
    this.sparks.update(dt); this.dust.update(dt);
    for (const c of this.casings) {
      if (c.life <= 0) continue;
      c.life -= dt;
      if (c.life <= 0) { c.m.visible = false; continue; }
      if (c.bounces > 6) continue;
      c.vel.y -= 9.81 * dt;
      c.m.position.addScaledVector(c.vel, dt);
      c.m.rotation.x += c.spin.x * dt; c.m.rotation.y += c.spin.y * dt; c.m.rotation.z += c.spin.z * dt;
      const fy = floorAt ? floorAt(c.m.position.x, c.m.position.z) : 0;
      if (c.m.position.y < fy + 0.006) {
        c.m.position.y = fy + 0.006;
        if (c.vel.y < -0.4 && this.onCasingBounce && c.bounces < 3) this.onCasingBounce(c.kind === 'shotgun');
        c.vel.y = -c.vel.y * 0.35; c.vel.x *= 0.55; c.vel.z *= 0.55; c.spin.multiplyScalar(0.5);
        c.bounces++;
        if (Math.abs(c.vel.y) < 0.2) { c.bounces = 99; c.m.rotation.x = 0; c.m.rotation.z = 0; }
      }
    }
  }

  clearDecals() {
    for (const d of this.decals) { d.visible = false; if (d.parent !== this.scene) this.scene.attach(d); }
    for (const c of this.casings) { c.life = 0; c.m.visible = false; }
  }
}
