import * as THREE from 'three';
import { EffectComposer } from '../vendor/three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from '../vendor/three/addons/postprocessing/RenderPass.js';
import { Pass } from '../vendor/three/addons/postprocessing/Pass.js';
import { UnrealBloomPass } from '../vendor/three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from '../vendor/three/addons/postprocessing/OutputPass.js';
import { ShaderPass } from '../vendor/three/addons/postprocessing/ShaderPass.js';
import { GTAOPass } from '../vendor/three/addons/postprocessing/GTAOPass.js';
import { FXAAShader } from '../vendor/three/addons/shaders/FXAAShader.js';
import { Sky } from '../vendor/three/addons/objects/Sky.js';
import { RoomEnvironment } from '../vendor/three/addons/environments/RoomEnvironment.js';
import { buildTextures, muzzleFlashTexture } from './textures.js';
import { AudioSys } from './audio.js';
import { FX } from './fx.js';
import { Arsenal, WEAPONS, OPTICS } from './weapons.js';
import { Level, WALL_H } from './level.js';
import { MISSIONS, DIFFICULTY } from './maps.js';

const $ = id => document.getElementById(id);
const TEST = new URLSearchParams(location.search).has('test');

const QUALITY = {
  low: { name: 'LOW', pr: 0.75, shadow: 1024, bloom: false, ao: false, aa: false, lampShadows: 0, flashShadow: false },
  medium: { name: 'MEDIUM', pr: 1, shadow: 2048, bloom: true, ao: false, aa: true, lampShadows: 2, flashShadow: true },
  high: { name: 'HIGH', pr: Math.min(window.devicePixelRatio || 1, 1.5), shadow: 4096, bloom: true, ao: true, aa: true, lampShadows: 4, flashShadow: true },
};
const ARMOR = {
  light: { name: 'LIGHT (IIIA)', short: 'IIIA', dmg: 34, speed: 1.0, desc: 'Soft armor. Fast on your feet, but three hits and you are out.' },
  heavy: { name: 'HEAVY (IV)', short: 'IV', dmg: 22, speed: 0.9, desc: 'Rifle plates. Survive five hits, move 10% slower.' },
};

const store = {
  get(k, d) { try { const v = localStorage.getItem('breach.' + k); return v ? JSON.parse(v) : d; } catch (e) { return d; } },
  set(k, v) { try { localStorage.setItem('breach.' + k, JSON.stringify(v)); } catch (e) { /* private mode */ } },
};

// Renders the first-person weapon on top of the world with its own depth buffer, so it never clips into walls.
class ViewmodelPass extends Pass {
  constructor(scene, camera) { super(); this.scene = scene; this.camera = camera; this.needsSwap = false; }
  render(renderer, writeBuffer, readBuffer) {
    const ac = renderer.autoClear; renderer.autoClear = false;
    renderer.setRenderTarget(this.renderToScreen ? null : readBuffer);
    renderer.clearDepth();
    renderer.render(this.scene, this.camera);
    renderer.autoClear = ac;
  }
}

class Game {
  constructor() {
    this.settings = Object.assign({ sens: 1, fov: 74, volume: 0.8, quality: 'medium', voice: true, autoReload: true, toggleAds: false, diff: 'operator' }, store.get('settings', {}));
    this.loadout = Object.assign({ primary: 'm4', optic: 'holo', armor: 'light', flashbangs: 3 }, store.get('loadout', {}));
    this.best = store.get('best', {});
    this.missionIdx = 0;
    this.state = 'loading';
    this.keys = {};
    this.mouse = { dx: 0, dy: 0, ads: false };
    this.player = { pos: new THREE.Vector3(), vel: new THREE.Vector3(), yaw: 0, pitch: 0, crouch: 0, crouchToggle: false, lean: 0, health: 100, speed: 0, sprinting: false, bob: 0, step: 0 };
    this.recoil = { qp: 0, qy: 0, rp: 0, ry: 0, last: 0 };
    this.bullets = []; this.grenades = [];
    this.time = 0; this.recentShot = 0; this.flashlightOn = false; this.shakeAmt = 0; this.breath = 1; this.breathHold = false;
    this.whiteout = 0; this.dmgFlash = 0; this.hitmarkT = 0; this.kickCooldown = 0; this.throwT = 0;
    this.locked = false;
  }

  async init() {
    this.setLoad(10, 'GENERATING TEXTURES');
    await new Promise(r => requestAnimationFrame(() => setTimeout(r, 30)));
    this.T = buildTextures();
    this.flashTex = muzzleFlashTexture();
    this.setLoad(60, 'BUILDING RENDERER');
    await new Promise(r => setTimeout(r, 10));
    this.audio = new AudioSys();
    this.audio.volume = this.settings.volume; this.audio.voice = this.settings.voice;

    const canvas = $('c');
    const renderer = this.renderer = new THREE.WebGLRenderer({ canvas, antialias: false, powerPreference: 'high-performance', stencil: false });
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.outputColorSpace = THREE.SRGBColorSpace;

    this.scene = new THREE.Scene();
    this.camera = new THREE.PerspectiveCamera(this.settings.fov, 1, 0.04, 1500);
    this.camera.rotation.order = 'YXZ';
    this.scene.add(this.camera);
    this.vmScene = new THREE.Scene();
    this.vmCamera = new THREE.PerspectiveCamera(54, 1, 0.01, 10);
    this.pmrem = new THREE.PMREMGenerator(renderer);
    this.roomEnv = this.pmrem.fromScene(new RoomEnvironment(), 0.04).texture;

    // Persistent lights (constant count avoids shader recompiles mid-mission)
    this.hemi = new THREE.HemisphereLight(0xbfd6ff, 0x5a4a3a, 0.8);
    this.sun = new THREE.DirectionalLight(0xfff1dc, 3);
    this.sun.castShadow = true;
    this.sun.shadow.bias = -0.0004; this.sun.shadow.normalBias = 0.025;
    this.scene.add(this.hemi, this.sun, this.sun.target);
    this.flashlight = new THREE.SpotLight(0xfff2dd, 0, 38, 0.36, 0.5, 1.4);
    this.flashlight.shadow.mapSize.set(1024, 1024); this.flashlight.shadow.bias = -0.0006; this.flashlight.shadow.camera.near = 0.2;
    this.scene.add(this.flashlight, this.flashlight.target);
    this.muzzleLight = new THREE.PointLight(0xffa850, 0, 9, 2);
    this.bangLight = new THREE.PointLight(0xf0f4ff, 0, 30, 1.6);
    this.scene.add(this.muzzleLight, this.bangLight);
    this.sky = makeSky(); this.sky.scale.setScalar(1000); this.sky.frustumCulled = false;
    this.scene.add(this.sky);
    this.stars = this.makeStars(); this.scene.add(this.stars);

    // Viewmodel lighting
    this.vmHemi = new THREE.HemisphereLight(0xdfe8ff, 0x403830, 1.2);
    this.vmKey = new THREE.DirectionalLight(0xfff0e0, 1.6); this.vmKey.position.set(-1, 2, 1);
    this.vmMuzzle = new THREE.PointLight(0xffa850, 0, 1.5, 2); this.vmMuzzle.position.set(0.1, -0.05, -0.6);
    this.vmLightGlow = new THREE.PointLight(0xfff2dd, 0, 0.6, 2); this.vmLightGlow.position.set(0.05, -0.05, -0.55);
    this.vmScene.add(this.vmHemi, this.vmKey, this.vmMuzzle, this.vmLightGlow, this.vmCamera);
    this.vmScene.environment = this.roomEnv;

    this.fx = new FX(this.scene);
    this.fx.onCasingBounce = shell => this.audio.casing(shell);
    this.arsenal = new Arsenal(this, this.vmScene, this.T);
    this.arsenal.equip(this.loadout.primary, this.loadout.optic);

    this.grenadeGeo = new THREE.CylinderGeometry(0.03, 0.03, 0.11, 12);
    this.grenadeMat = new THREE.MeshStandardMaterial({ color: 0x3a4030, roughness: 0.6, metalness: 0.3 });

    this.buildComposer();
    window.addEventListener('resize', () => this.resize());
    this.resize();

    this.setLoad(85, 'LOADING RANGE');
    await new Promise(r => setTimeout(r, 10));
    this.loadLevel(0);
    this.bindInput();
    this.buildMenu();
    this.setLoad(100, 'READY');
    $('loading').classList.add('hidden');
    this.showMenu();
    this.last = performance.now();
    renderer.setAnimationLoop(() => this.frame());
    window.BREACH = this;
  }

  setLoad(p, txt) { $('load-bar').style.width = p + '%'; $('load-text').textContent = txt; }

  makeStars() {
    const n = 1500, pos = new Float32Array(n * 3);
    for (let i = 0; i < n; i++) {
      const u = Math.random(), v = Math.random() * 0.5 + 0.5;
      const th = u * Math.PI * 2, ph = Math.acos(2 * v - 1);
      pos[i * 3] = Math.sin(ph) * Math.cos(th) * 800; pos[i * 3 + 1] = Math.abs(Math.cos(ph)) * 800 + 20; pos[i * 3 + 2] = Math.sin(ph) * Math.sin(th) * 800;
    }
    const g = new THREE.BufferGeometry(); g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    const p = new THREE.Points(g, new THREE.PointsMaterial({ color: 0xcfd8ff, size: 1.6, sizeAttenuation: false, fog: false, transparent: true, opacity: 0.85 }));
    p.visible = false; return p;
  }

  buildComposer() {
    const q = this.quality = QUALITY[this.settings.quality];
    const r = this.renderer;
    r.setPixelRatio(q.pr);
    if (this.composer) this.composer.dispose();
    const rt = new THREE.WebGLRenderTarget(2, 2, { type: THREE.HalfFloatType, samples: q.aa && r.capabilities.isWebGL2 ? 0 : 0 });
    const c = this.composer = new EffectComposer(r, rt);
    c.addPass(new RenderPass(this.scene, this.camera));
    this.aoPass = null;
    if (q.ao) {
      this.aoPass = new GTAOPass(this.scene, this.camera, 2, 2);
      this.aoPass.updateGtaoMaterial({ radius: 0.6, distanceExponent: 1.5, thickness: 1, scale: 1.2, samples: 12 });
      this.aoPass.blendIntensity = 0.9;
      c.addPass(this.aoPass);
    }
    c.addPass(new ViewmodelPass(this.vmScene, this.vmCamera));
    this.bloomPass = null;
    if (q.bloom) { this.bloomPass = new UnrealBloomPass(new THREE.Vector2(256, 256), 0.35, 0.5, 1.6); c.addPass(this.bloomPass); }
    c.addPass(new OutputPass());
    this.fxaa = null;
    if (q.aa) { this.fxaa = new ShaderPass(FXAAShader); c.addPass(this.fxaa); }
    this.sun.shadow.mapSize.set(q.shadow, q.shadow);
    if (this.sun.shadow.map) { this.sun.shadow.map.dispose(); this.sun.shadow.map = null; }
    this.flashlight.castShadow = q.flashShadow;
    if (this.flashlight.shadow.map) { this.flashlight.shadow.map.dispose(); this.flashlight.shadow.map = null; }
    this.resize();
  }

  resize() {
    if (!this.renderer) return;
    const w = window.innerWidth, h = window.innerHeight;
    this.renderer.setSize(w, h, false);
    this.composer.setSize(w, h);
    this.camera.aspect = w / h; this.camera.updateProjectionMatrix();
    this.vmCamera.aspect = w / h; this.vmCamera.updateProjectionMatrix();
    const pr = this.renderer.getPixelRatio();
    if (this.fxaa) this.fxaa.material.uniforms.resolution.value.set(1 / (w * pr), 1 / (h * pr));
    if (this.fx) this.fx.setScale(h * pr * 0.5 / Math.tan(THREE.MathUtils.degToRad(this.camera.fov / 2)));
  }

  // ---------------- Levels ----------------
  loadLevel(idx) {
    if (this.level) this.level.dispose();
    this.fx.clearDecals();
    for (const gr of this.grenades) this.scene.remove(gr.mesh);
    this.grenades = []; this.bullets = [];
    this.missionIdx = idx;
    const m = this.mission = MISSIONS[idx];
    this.setupEnvironment(m.env);
    this.level = new Level(this, m);
    this.fitShadow();
    const P = this.player;
    P.pos.copy(this.level.spawn); P.vel.set(0, 0, 0);
    P.yaw = THREE.MathUtils.degToRad(m.yaw || 0); P.pitch = 0; P.crouch = 0; P.crouchToggle = false; P.lean = 0;
    this.updateCamera(0);
  }

  setupEnvironment(env) {
    const s = this.scene, sky = this.sky, u = sky.material.uniforms;
    const sunDir = new THREE.Vector3();
    const setSun = (elev, az) => { sunDir.setFromSphericalCoords(1, THREE.MathUtils.degToRad(90 - elev), THREE.MathUtils.degToRad(az)); u.sunPosition.value.copy(sunDir); };
    this.sunDir = sunDir;
    this.stars.visible = false; sky.visible = true;
    if (env === 'night') {
      sky.visible = false; this.stars.visible = true;
      s.background = new THREE.Color(0x03050a);
      s.fog = new THREE.FogExp2(0x03050a, 0.03);
      sunDir.set(-0.4, 0.7, -0.3).normalize();
      this.sun.color.set(0x8fa8e0); this.sun.intensity = 0.28;
      this.hemi.color.set(0x24304a); this.hemi.groundColor.set(0x080808); this.hemi.intensity = 0.25;
      s.environment = this.roomEnv; s.environmentIntensity = 0.02;
      this.renderer.toneMappingExposure = 1.0;
      this.vmHemi.intensity = 0.12; this.vmKey.intensity = 0.15; this.vmScene.environmentIntensity = 0.05;
      this.flashlightOn = false;
      this.audio.setReverb(1.6, 0.4);
    } else {
      if (env === 'overcast') {
        u.turbidity.value = 14; u.rayleigh.value = 3.2; u.mieCoefficient.value = 0.02; u.mieDirectionalG.value = 0.7; setSun(28, 200);
        s.fog = new THREE.Fog(0x9aa3a8, 25, 180);
        this.sun.color.set(0xe8eef5); this.sun.intensity = 1.3;
        this.hemi.color.set(0xc8d2dc); this.hemi.groundColor.set(0x4a463e); this.hemi.intensity = 1.5;
        this.renderer.toneMappingExposure = 0.85;
      } else {
        u.turbidity.value = 4; u.rayleigh.value = 1.2; u.mieCoefficient.value = 0.005; u.mieDirectionalG.value = 0.8; setSun(env === 'range' ? 34 : 42, env === 'range' ? 210 : 140);
        s.fog = new THREE.Fog(0xb8c8d8, env === 'range' ? 80 : 50, env === 'range' ? 420 : 240);
        this.sun.color.set(0xfff0d8); this.sun.intensity = 2.7;
        this.hemi.color.set(0xd8e2ee); this.hemi.groundColor.set(0x5c4c3a); this.hemi.intensity = 0.6;
        this.renderer.toneMappingExposure = 0.8;
      }
      s.background = null;
      // Environment reflections from the actual sky
      const envScene = new THREE.Scene(); const sk2 = makeSky(); sk2.scale.setScalar(100);
      for (const k of ['turbidity', 'rayleigh', 'mieCoefficient', 'mieDirectionalG']) sk2.material.uniforms[k].value = u[k].value;
      sk2.material.uniforms.sunPosition.value.copy(u.sunPosition.value);
      envScene.add(sk2);
      if (this.skyEnv) this.skyEnv.dispose();
      this.skyEnv = this.pmrem.fromScene(envScene).texture;
      s.environment = this.skyEnv; s.environmentIntensity = env === 'overcast' ? 0.5 : 0.35;
      this.vmHemi.intensity = env === 'overcast' ? 1.4 : 1.1; this.vmKey.intensity = env === 'overcast' ? 0.9 : 1.6; this.vmScene.environmentIntensity = 0.5;
      this.flashlightOn = false;
      this.audio.setReverb(env === 'range' ? 2.2 : 1.0, env === 'range' ? 0.22 : 0.32);
    }
    this.env = env;
  }

  fitShadow() {
    const L = this.level, sh = this.sun.shadow.camera;
    const follow = L.mission.env === 'range';
    this.shadowFollow = follow;
    const ext = follow ? 30 : Math.max(L.W, L.H) / 2 + 3;
    sh.left = -ext; sh.right = ext; sh.top = ext; sh.bottom = -ext; sh.near = 1; sh.far = 200;
    sh.updateProjectionMatrix();
    this.shadowExt = ext;
    if (!follow) this.placeSun(new THREE.Vector3(L.W / 2, 0, L.H / 2));
  }

  placeSun(center) {
    if (this.shadowFollow) {
      // Snap to shadow texels so edges don't shimmer as you move.
      const texel = (this.shadowExt * 2) / this.quality.shadow;
      center.x = Math.round(center.x / texel) * texel; center.z = Math.round(center.z / texel) * texel;
    }
    this.sun.target.position.copy(center);
    this.sun.position.copy(center).addScaledVector(this.sunDir, 80);
  }

  // ---------------- Input ----------------
  bindInput() {
    const canvas = $('c');
    document.addEventListener('pointerlockchange', () => {
      this.locked = document.pointerLockElement === canvas;
      if (!this.locked && this.state === 'playing' && !TEST) this.pause();
    });
    document.addEventListener('mousemove', e => {
      if (this.state !== 'playing' || (!this.locked && !TEST)) return;
      if (Math.abs(e.movementX) > 400 || Math.abs(e.movementY) > 400) return; // pointer-lock spikes
      this.mouse.dx += e.movementX; this.mouse.dy += e.movementY;
    });
    document.addEventListener('mousedown', e => {
      if (this.state === 'brief') { this.begin(); return; }
      if (this.state !== 'playing') return;
      if (!this.locked && !TEST) { this.lock(); return; }
      if (e.button === 0) this.arsenal.trigger(true);
      if (e.button === 2) this.mouse.ads = this.settings.toggleAds ? !this.mouse.ads : true;
    });
    document.addEventListener('mouseup', e => {
      if (e.button === 0) this.arsenal.trigger(false);
      if (e.button === 2 && !this.settings.toggleAds) this.mouse.ads = false;
    });
    document.addEventListener('contextmenu', e => e.preventDefault());
    document.addEventListener('wheel', e => { if (this.state === 'playing') this.arsenal.switchTo(this.arsenal.cur === 0 ? 1 : 0); });
    window.addEventListener('keydown', e => {
      if (e.code === 'Tab') e.preventDefault();
      if (this.state === 'playing' && ['Space', 'ControlLeft', 'KeyW', 'KeyS'].includes(e.code)) e.preventDefault();
      if (e.repeat) return;
      this.keys[e.code] = true;
      if (this.state === 'brief' && (e.code === 'Space' || e.code === 'Enter')) { this.begin(); return; }
      if (this.state !== 'playing') { if (e.code === 'Escape' && this.state === 'paused') this.resume(); return; }
      const A = this.arsenal;
      switch (e.code) {
        case 'KeyR': A.reload(); break;
        case 'Digit1': A.switchTo(0); break;
        case 'Digit2': A.switchTo(1); break;
        case 'KeyB': A.toggleMode(); break;
        case 'KeyC': this.player.crouchToggle = !this.player.crouchToggle; break;
        case 'KeyG': this.throwFlash(); break;
        case 'KeyF': this.interact(); break;
        case 'KeyV': this.kick(); break;
        case 'KeyT': this.flashlightOn = !this.flashlightOn; this.audio.click(2600, 0.3); break;
        case 'KeyP': if (TEST) this.pause(); break;
      }
    });
    window.addEventListener('keyup', e => { this.keys[e.code] = false; });
    window.addEventListener('blur', () => { this.keys = {}; this.arsenal.trigger(false); this.mouse.ads = false; });
  }

  lock() {
    if (TEST) return;
    const c = $('c');
    try { const p = c.requestPointerLock({ unadjustedMovement: true }); if (p && p.catch) p.catch(() => { try { c.requestPointerLock(); } catch (e) { } }); }
    catch (e) { try { c.requestPointerLock(); } catch (e2) { } }
  }

  // ---------------- Menu / flow ----------------
  buildMenu() {
    const tabs = document.querySelectorAll('.tab');
    tabs.forEach(t => t.onclick = () => {
      this.audio.init();
      tabs.forEach(x => x.classList.toggle('on', x === t));
      document.querySelectorAll('[data-panel]').forEach(p => p.classList.toggle('hidden', p.dataset.panel !== t.dataset.tab));
    });
    const seg = (el, items, cur, onPick) => {
      el.innerHTML = '';
      for (const [k, label] of items) {
        const b = document.createElement('button'); b.textContent = label; b.classList.toggle('on', k === cur);
        b.onclick = () => { this.audio.init(); this.audio.click(1800, 0.2); [...el.children].forEach(c => c.classList.toggle('on', c === b)); onPick(k); };
        el.appendChild(b);
      }
    };
    this.renderMissionCards();
    seg($('diff-seg'), Object.entries(DIFFICULTY).map(([k, d]) => [k, d.name]), this.settings.diff, k => { this.settings.diff = k; this.saveSettings(); });
    // Loadout
    const pc = $('primary-cards');
    const renderPrimary = () => {
      pc.innerHTML = '';
      for (const id of ['m4', 'mp5', 'm870']) {
        const w = WEAPONS[id];
        const c = document.createElement('button'); c.className = 'card' + (this.loadout.primary === id ? ' on' : '');
        c.innerHTML = `<h3>${w.name}</h3><p>${w.cal} · ${w.mag} rds · ${w.rpm} rpm</p><p style="margin-top:6px">${w.desc}</p>`;
        c.onclick = () => { this.audio.init(); this.loadout.primary = id; this.saveLoadout(); renderPrimary(); };
        pc.appendChild(c);
      }
      const w = WEAPONS[this.loadout.primary];
      $('wstats').innerHTML = Object.entries(w.stats).map(([k, v]) => `<span>${k.toUpperCase()}</span><div class="bar"><i style="width:${v * 100}%"></i></div>`).join('') +
        `<span>VELOCITY</span><span class="hint" style="color:var(--ink)">${w.velocity} m/s</span>`;
    };
    renderPrimary();
    seg($('optic-seg'), Object.entries(OPTICS).map(([k, o]) => [k, o.name]), this.loadout.optic, k => { this.loadout.optic = k; this.saveLoadout(); });
    const armorDesc = () => { $('armor-desc').textContent = ARMOR[this.loadout.armor].desc; };
    seg($('armor-seg'), Object.entries(ARMOR).map(([k, a]) => [k, a.name]), this.loadout.armor, k => { this.loadout.armor = k; this.saveLoadout(); armorDesc(); });
    armorDesc();
    seg($('flash-seg'), [[1, '1'], [2, '2'], [3, '3'], [4, '4']], this.loadout.flashbangs, k => { this.loadout.flashbangs = k; this.saveLoadout(); });
    // Settings
    const slider = (id, out, key, fmt, apply) => {
      const el = $(id), o = $(out);
      el.value = this.settings[key]; o.textContent = fmt(this.settings[key]);
      el.oninput = () => { this.settings[key] = parseFloat(el.value); o.textContent = fmt(this.settings[key]); apply && apply(); this.saveSettings(); };
    };
    slider('s-sens', 'o-sens', 'sens', v => v.toFixed(2), () => { $('p-sens').value = this.settings.sens; $('op-sens').textContent = this.settings.sens.toFixed(2); });
    slider('p-sens', 'op-sens', 'sens', v => v.toFixed(2), () => { $('s-sens').value = this.settings.sens; $('o-sens').textContent = this.settings.sens.toFixed(2); });
    slider('s-fov', 'o-fov', 'fov', v => v + '°');
    slider('s-vol', 'o-vol', 'volume', v => Math.round(v * 100) + '%', () => this.audio.setVolume(this.settings.volume));
    seg($('q-seg'), Object.entries(QUALITY).map(([k, q]) => [k, q.name]), this.settings.quality, k => { this.settings.quality = k; this.saveSettings(); this.buildComposer(); this.loadLevel(this.missionIdx); });
    const opts = $('opt-seg');
    const renderOpts = () => {
      opts.innerHTML = '';
      for (const [k, label] of [['voice', 'VOICE CALLOUTS'], ['autoReload', 'AUTO RELOAD'], ['toggleAds', 'TOGGLE AIM']]) {
        const b = document.createElement('button'); b.textContent = label + (this.settings[k] ? ' · ON' : ' · OFF'); b.classList.toggle('on', !!this.settings[k]);
        b.onclick = () => { this.settings[k] = !this.settings[k]; this.audio.voice = this.settings.voice; this.saveSettings(); renderOpts(); };
        opts.appendChild(b);
      }
    };
    renderOpts();
    $('deploy').onclick = () => { this.audio.init(); this.deploy(); };
    $('resume').onclick = () => this.resume();
    $('restart').onclick = () => { this.deploy(); };
    $('quit').onclick = () => this.showMenu();
    $('retry').onclick = () => this.deploy();
    $('next').onclick = () => { this.missionIdx = (this.missionIdx + 1) % MISSIONS.length; this.deploy(); };
    $('tomenu').onclick = () => this.showMenu();
    // Compass
    const labels = { 0: 'N', 45: 'NE', 90: 'E', 135: 'SE', 180: 'S', 225: 'SW', 270: 'W', 315: 'NW' };
    let html = '';
    for (let rep = 0; rep < 3; rep++) for (let d = 0; d < 360; d += 15) html += `<span class="${labels[d] ? 'c' : ''}">${labels[d] || '·'}</span>`;
    $('compass-strip').innerHTML = html;
  }

  renderMissionCards() {
    const mc = $('mission-cards'); mc.innerHTML = '';
    MISSIONS.forEach((m, i) => {
      const c = document.createElement('button'); c.className = 'card' + (i === this.missionIdx ? ' on' : '');
      const b = this.best[m.id];
      const bestTxt = b ? (m.env === 'range' ? `BEST ${b.badge} ${b.score}/${b.total}` : `BEST ${b.grade} · ${fmtTime(b.time)}`) : '';
      c.innerHTML = `<span class="tag">${m.env === 'night' ? 'NIGHT' : m.env === 'range' ? 'PRACTICE' : m.env === 'overcast' ? 'OVERCAST' : 'DAY'}</span><h3>${m.name}</h3><p>${m.sub}</p>${m.par ? `<p>PAR ${fmtTime(m.par)}</p>` : '<p>Free fire + qualification</p>'}<div class="best">${bestTxt}</div>`;
      c.onclick = () => { this.audio.init(); this.audio.click(1800, 0.2); this.loadLevel(i); this.renderMissionCards(); };
      mc.appendChild(c);
    });
  }

  saveSettings() { store.set('settings', this.settings); }
  saveLoadout() { store.set('loadout', this.loadout); }

  hideScreens() { for (const id of ['menu', 'brief', 'pause', 'results']) $(id).classList.add('hidden'); }

  showMenu() {
    if (document.pointerLockElement) document.exitPointerLock();
    this.hideScreens();
    $('hud').classList.add('hidden');
    $('menu').classList.remove('hidden');
    this.state = 'menu';
    this.renderMissionCards();
    this.arsenal.trigger(false);
  }

  deploy() {
    this.hideScreens();
    this.loadLevel(this.missionIdx);
    const P = this.player;
    P.health = 100;
    this.arsenal.equip(this.loadout.primary, this.loadout.optic);
    this.flashbangs = this.loadout.flashbangs;
    this.armor = ARMOR[this.loadout.armor];
    this.stats = { shots: 0, hits: 0, civHits: 0, damage: 0, flashes: 0, hitsTaken: 0, start: 0 };
    this.missionTime = 0; this.complete = false; this.whiteout = 0; this.dmgFlash = 0;
    this.camera.fov = this.settings.fov; this.camera.updateProjectionMatrix();
    const m = this.mission;
    $('brief-title').textContent = m.name;
    $('brief-sub').textContent = `${m.sub.toUpperCase()} · ${DIFFICULTY[this.settings.diff].name}${m.par ? ' · PAR ' + fmtTime(m.par) : ''}`;
    $('brief-list').innerHTML = m.brief.map(b => `<li>${b.replace(/^(TECHNIQUE:)/, '<b>$1</b>')}</li>`).join('');
    $('brief').classList.remove('hidden');
    this.state = 'brief';
  }

  begin() {
    this.hideScreens();
    $('hud').classList.remove('hidden');
    this.state = 'playing';
    this.audio.init();
    this.lock();
    this.tipQueue = [...this.mission.tips];
    this.tipT = 1.5;
    this.audio.say(this.mission.env === 'range' ? 'Range is hot' : 'Stack up');
  }

  pause() {
    if (this.state !== 'playing') return;
    this.state = 'paused';
    this.arsenal.trigger(false); this.keys = {}; this.mouse.ads = false;
    $('pause').classList.remove('hidden');
  }

  resume() {
    $('pause').classList.add('hidden');
    this.state = 'playing';
    this.lock();
  }

  // ---------------- Gameplay ----------------
  get diff() { return DIFFICULTY[this.settings.diff]; }

  objectivesDone() {
    if (!this.level || this.mission.env === 'range') return false;
    const allDown = this.level.targets.every(t => !t.hostile || t.neutralized);
    const hostage = !this.level.hostage || this.level.hostage.secured;
    return allDown && hostage;
  }

  interact() {
    const L = this.level, P = this.player;
    if (L.console && P.pos.distanceTo(L.console.pos) < 1.8) { L.startDrill(); return; }
    if (L.hostage && !L.hostage.secured && P.pos.distanceTo(L.hostage.group.position) < 1.8) {
      const roomClear = L.targets.every(t => !t.hostile || t.neutralized || t.room !== L.hostage.room);
      if (!roomClear) { this.toast('ROOM NOT CLEAR', 'var(--amber)'); return; }
      L.hostage.secured = true; L.hostage.lower();
      this.callout('HOSTAGE SECURE', 'Hostage secure');
      return;
    }
    const d = this.nearestDoor(1.7);
    if (d) d.use(P.pos.x, P.pos.z);
  }

  nearestDoor(maxD) {
    let best = null, bd = maxD;
    const P = this.player;
    for (const d of this.level.doors) {
      const dd = Math.hypot(d.cx - P.pos.x, d.cz - P.pos.z);
      if (dd < bd) { bd = dd; best = d; }
    }
    return best;
  }

  kick() {
    if (this.kickCooldown > 0) return;
    const d = this.nearestDoor(1.5);
    this.kickCooldown = 0.9;
    this.kickAnim = 1;
    if (d) {
      setTimeout(() => { if (this.state === 'playing') d.kick(this.player.pos.x, this.player.pos.z); }, 160);
      this.audio.say(Math.random() < 0.5 ? 'Breaching' : 'Breach');
    }
  }

  throwFlash() {
    if (this.flashbangs <= 0) { this.toast('NO FLASHBANGS'); return; }
    if (this.throwT > 0) return;
    this.flashbangs--; this.stats.flashes++;
    this.throwT = 0.55;
    this.audio.say('Flash out');
    setTimeout(() => {
      const cam = this.camera;
      const fwd = new THREE.Vector3(); cam.getWorldDirection(fwd);
      const right = new THREE.Vector3().crossVectors(fwd, cam.up).normalize();
      const pos = cam.position.clone().addScaledVector(fwd, 0.35).addScaledVector(right, -0.1).add(new THREE.Vector3(0, -0.1, 0));
      const vel = fwd.clone().multiplyScalar(10).add(new THREE.Vector3(0, 2.2, 0)).add(this.player.vel);
      const mesh = new THREE.Mesh(this.grenadeGeo, this.grenadeMat); mesh.castShadow = true;
      mesh.position.copy(pos); this.scene.add(mesh);
      this.grenades.push({ mesh, vel, fuse: 1.5, spin: new THREE.Vector3(8, 3, 5) });
      this.audio.throwSound();
    }, 200);
  }

  explodeFlash(g) {
    const p = g.mesh.position.clone(); p.y = Math.max(p.y, 0.15);
    this.scene.remove(g.mesh);
    this.fx.flashBurst(p);
    this.bangLight.position.copy(p); this.bangLight.intensity = 900;
    const stunned = this.level.flashAt(p);
    if (stunned) this.toast(`${stunned} HOSTILE${stunned > 1 ? 'S' : ''} STUNNED`, 'var(--cyan)');
    // Player exposure
    const eye = this.camera.position, d = eye.distanceTo(p);
    let k = 0;
    if (d < 14) {
      const dir = new THREE.Vector3().subVectors(p, eye).normalize();
      const ray = new THREE.Raycaster(eye, dir, 0, d - 0.1);
      if (!ray.intersectObjects(this.level.occluders, false).length) {
        const fwd = new THREE.Vector3(); this.camera.getWorldDirection(fwd);
        k = (1 - d / 14) * (0.25 + 0.75 * Math.max(0, fwd.dot(dir)));
        k = Math.min(1, k * 1.6);
      } else if (d < 4) k = 0.15;
    }
    if (k > 0.05) { this.whiteout = Math.max(this.whiteout, k * 4.5); }
    this.audio.flashbang(d, k);
    this.shake(0.8 * Math.max(0.2, 1 - d / 12));
  }

  onFire(slot, A) {
    const d = slot.def, P = this.player, cam = this.camera;
    this.audio.gunshot(d.kind);
    this.stats.shots++;
    this.recentShot = 1.2;
    const fwd = new THREE.Vector3(); cam.getWorldDirection(fwd);
    const right = new THREE.Vector3().crossVectors(fwd, cam.up).normalize();
    const up = new THREE.Vector3().crossVectors(right, fwd).normalize();
    const moveK = Math.min(1, P.speed / 4);
    let spread = THREE.MathUtils.lerp(d.hipSpread, d.adsSpread, A.ads) + d.moveSpread * moveK * (1 - A.ads * 0.6);
    if (P.crouch > 0.5) spread *= 0.8;
    for (let i = 0; i < d.pellets; i++) {
      let s = spread;
      if (d.pellets > 1) s += d.pelletSpread;
      const a = Math.random() * Math.PI * 2, r = Math.sqrt(Math.random()) * s;
      const dir = fwd.clone().addScaledVector(right, Math.cos(a) * r).addScaledVector(up, Math.sin(a) * r).normalize();
      this.bullets.push({ p: cam.position.clone(), v: dir.multiplyScalar(d.velocity), life: 1.6, def: d, origin: cam.position.clone() });
    }
    // Camera recoil
    let rk = 1 - A.ads * 0.3; if (P.crouch > 0.5) rk *= 0.8;
    const burstK = Math.min(1.4, 1 + A.burst * 0.02);
    this.recoil.qp += d.recoil.v * rk * burstK * (0.85 + Math.random() * 0.3);
    this.recoil.qy += (Math.random() - 0.35) * 2 * d.recoil.h * rk;
    this.recoil.last = this.time;
    // Muzzle light & smoke at the real muzzle position
    const mw = this.vmToWorld(slot.model.muzzle);
    this.muzzleLight.position.copy(mw); this.muzzleLight.intensity = d.kind === 'shotgun' ? 60 : 35;
    this.vmMuzzle.intensity = 4;
    this.fx.muzzleSmoke(mw, fwd);
  }

  // Convert a viewmodel-space object position into world space (through the main camera).
  vmToWorld(obj) {
    const p = new THREE.Vector3();
    obj.updateWorldMatrix(true, false);
    p.setFromMatrixPosition(obj.matrixWorld);
    p.z *= 1; // viewmodel camera sits at origin looking -Z, same convention as main camera
    return this.camera.localToWorld(p);
  }

  ejectCasing(slot) {
    const pos = this.vmToWorld(slot.model.eject);
    const local = new THREE.Vector3(1.6 + Math.random() * 0.6, 1.2 + Math.random() * 0.5, 0.2 + Math.random() * 0.3);
    const vel = local.applyQuaternion(this.camera.quaternion).add(this.player.vel);
    this.fx.ejectCasing(pos, vel, slot.def.kind === 'shotgun' ? 'shotgun' : slot.def.kind === 'rifle' ? 'rifle' : 'pistol');
  }

  hostileFires(from, hit, dist) {
    const toSrc = new THREE.Vector3().subVectors(from, this.camera.position);
    const fwd = new THREE.Vector3(); this.camera.getWorldDirection(fwd);
    const ang = Math.atan2(toSrc.x, toSrc.z) - Math.atan2(fwd.x, fwd.z);
    this.audio.hostileShot(dist, -Math.sin(ang));
    if (!hit) { this.audio.impact('concrete', 1.5, -Math.sin(ang) * 0.5); return; }
    const dmg = this.armor.dmg * (0.9 + Math.random() * 0.2);
    this.player.health -= dmg; this.stats.damage += dmg; this.stats.hitsTaken++;
    this.audio.playerHit();
    this.dmgFlash = 1; this.shake(0.35);
    // Direction indicator
    const el = document.createElement('div');
    el.style.transform = `rotate(${-ang}rad)`;
    $('dmgdir').appendChild(el);
    el.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 1600, easing: 'ease-out' }).onfinish = () => el.remove();
    if (this.player.health <= 0) { this.player.health = 0; this.finish(false, 'TAGGED BY HOSTILE — KIA'); }
  }

  shake(a) { this.shakeAmt = Math.min(1.5, this.shakeAmt + a); }

  toast(text, color = 'var(--ink)') {
    const t = $('toast'); t.textContent = text; t.style.color = color; t.style.opacity = 1;
    clearTimeout(this.toastTimer); this.toastTimer = setTimeout(() => t.style.opacity = 0, 1600);
  }

  callout(text, voice) {
    const c = $('callout'); c.textContent = text; c.style.opacity = 1;
    clearTimeout(this.calloutTimer); this.calloutTimer = setTimeout(() => c.style.opacity = 0, 2000);
    if (voice) this.audio.say(voice);
  }

  hitmark(color) {
    const h = $('hitmark'); h.style.color = color; h.style.opacity = 1; this.hitmarkT = 0.18;
  }

  drillResult(r) {
    this.callout(r.badge, r.badge === 'UNQUALIFIED' ? 'Unqualified' : r.badge.toLowerCase());
    this.toast(`QUAL SCORE ${r.score}/${r.total}${r.civHits ? ` · ${r.civHits} NO-SHOOT HIT` : ''}`, 'var(--accent)');
    const prev = this.best.range;
    if (!prev || r.score / Math.max(1, r.total) > prev.score / Math.max(1, prev.total)) { this.best.range = r; store.set('best', this.best); }
  }

  finish(success, reason) {
    if (this.complete) return;
    this.complete = true;
    if (document.pointerLockElement) document.exitPointerLock();
    this.state = 'results';
    this.arsenal.trigger(false);
    const m = this.mission, L = this.level, S = this.stats, t = this.missionTime;
    const hostiles = L.targets.filter(x => x.hostile), down = hostiles.filter(x => x.neutralized).length;
    const acc = S.shots ? Math.min(1, S.hits / S.shots) : 0;
    let grade = 'F';
    if (success) {
      if (S.civHits === 0 && S.hitsTaken === 0 && t <= m.par) grade = 'S';
      else if (S.civHits === 0 && S.hitsTaken <= 1 && t <= m.par * 1.3) grade = 'A';
      else if (S.civHits === 0) grade = 'B';
      else if (S.civHits <= 1) grade = 'C';
      else grade = 'D';
    }
    const score = Math.max(0, Math.round(down * 100 + acc * 400 + (success ? Math.max(0, m.par - t) * 8 : 0) - S.civHits * 300 - S.damage * 2 + (L.hostage && L.hostage.secured ? 300 : 0)));
    $('res-title').textContent = success ? 'MISSION COMPLETE' : 'MISSION FAILED';
    $('res-sub').textContent = success ? `${m.name} · ${DIFFICULTY[this.settings.diff].name}` : reason;
    const ge = $('res-grade'); ge.textContent = grade; ge.classList.toggle('f', grade === 'F' || grade === 'D');
    const prev = this.best[m.id];
    let newBest = false;
    if (success && (!prev || score > prev.score)) { this.best[m.id] = { grade, time: t, score }; store.set('best', this.best); newBest = true; }
    const rows = [
      ['TIME', fmtTime(t) + (m.par ? `  (par ${fmtTime(m.par)})` : '')],
      ['HOSTILES NEUTRALISED', `${down} / ${hostiles.length}`],
      ['ACCURACY', `${Math.round(acc * 100)}%  (${S.hits}/${S.shots})`],
      ['NO-SHOOT HITS', String(S.civHits)],
      ['TIMES TAGGED', String(S.hitsTaken)],
      ['FLASHBANGS USED', String(S.flashes)],
    ];
    if (L.hostage) rows.push(['HOSTAGE', L.hostage.secured ? 'RESCUED' : 'NOT RESCUED']);
    rows.push(['SCORE', score + (newBest ? '  NEW BEST' : '')]);
    $('res-table').innerHTML = rows.map(([a, b]) => `<span>${a}</span><span>${b}</span>`).join('');
    const coach = [];
    if (S.civHits) coach.push('Positive ID before the trigger. Look for the weapon in their hands, not just a shape in the doorway.');
    if (S.hitsTaken >= 2 && S.flashes === 0) coach.push('You took fire on entry. Flash the room first: stunned hostiles cannot engage for about four seconds.');
    if (S.hitsTaken >= 2) coach.push('Slice the pie. Lean around the frame and take one target at a time, not the whole room at once.');
    if (acc < 0.45 && S.shots > 10) coach.push('Slow is smooth, smooth is fast. Aim down sights and fire controlled pairs instead of spraying.');
    if (success && t > m.par) coach.push('Clean clear, but over par. Keep moving once a room is clear: the clock is the next threat.');
    if (!coach.length) coach.push(grade === 'S' ? 'Textbook. Try the next difficulty up.' : 'Solid run. Shave the time down for a higher grade.');
    $('res-coach').innerHTML = coach.slice(0, 3).map(c => `<div>${c}</div>`).join('');
    $('hud').classList.add('hidden');
    $('results').classList.remove('hidden');
    $('next').classList.toggle('hidden', !success);
    if (success) this.audio.say('All clear. Good work.');
  }

  // ---------------- Simulation ----------------
  updatePlayer(dt) {
    const P = this.player, k = this.keys, A = this.arsenal, L = this.level;
    // Look
    const zoom = 1 + (A.s.def.zoom - 1) * A.ads;
    const sens = 0.0021 * this.settings.sens / zoom;
    P.yaw -= this.mouse.dx * sens; P.pitch -= this.mouse.dy * sens;
    // Recoil application & recovery
    const R = this.recoil;
    const ap = R.qp * Math.min(1, dt * 28), ay = R.qy * Math.min(1, dt * 28);
    P.pitch += ap; P.yaw += ay; R.qp -= ap; R.qy -= ay; R.rp += ap * 0.6; R.ry += ay * 0.4;
    if (this.time - R.last > 0.11) {
      const rp = R.rp * Math.min(1, dt * 7), ry = R.ry * Math.min(1, dt * 7);
      P.pitch -= rp; P.yaw -= ry; R.rp -= rp; R.ry -= ry;
    }
    P.pitch = THREE.MathUtils.clamp(P.pitch, -1.5, 1.5);

    // Crouch
    const wantCrouch = P.crouchToggle || k.ControlLeft;
    P.crouch += ((wantCrouch ? 1 : 0) - P.crouch) * Math.min(1, dt * 9);
    // Lean
    const wantLean = (k.KeyE ? 1 : 0) - (k.KeyQ ? 1 : 0);
    P.lean += (wantLean - P.lean) * Math.min(1, dt * 9);

    // Move
    const fwdIn = (k.KeyW ? 1 : 0) - (k.KeyS ? 1 : 0), sideIn = (k.KeyD ? 1 : 0) - (k.KeyA ? 1 : 0);
    const ads = A.ads > 0.5;
    P.sprinting = !!k.ShiftLeft && fwdIn > 0 && !ads && P.crouch < 0.3 && !this.mouse.ads;
    if (P.sprinting && P.crouchToggle) P.crouchToggle = false;
    let speed = P.sprinting ? 5.6 : 3.3;
    if (P.crouch > 0.5) speed = 1.7;
    if (A.ads > 0.3) speed *= 0.62;
    speed *= this.armor ? this.armor.speed : 1;
    speed *= A.s.def.speed;
    const sy = Math.sin(P.yaw), cy = Math.cos(P.yaw);
    const wish = new THREE.Vector3(-sy * fwdIn + cy * sideIn, 0, -cy * fwdIn - sy * sideIn);
    if (wish.lengthSq() > 1) wish.normalize();
    wish.multiplyScalar(speed);
    const accel = wish.lengthSq() > 0 ? 11 : 13;
    P.vel.x += (wish.x - P.vel.x) * Math.min(1, dt * accel);
    P.vel.z += (wish.z - P.vel.z) * Math.min(1, dt * accel);
    const before = P.pos.clone();
    P.pos.x += P.vel.x * dt; P.pos.z += P.vel.z * dt;
    L.collide(P.pos, 0.28);
    const real = P.pos.clone().sub(before); real.y = 0;
    P.speed = real.length() / Math.max(dt, 1e-4);
    if (dt > 0) { P.vel.x = real.x / dt; P.vel.z = real.z / dt; }
    // Footsteps
    P.bob += P.speed * dt * (P.sprinting ? 1.9 : 2.3);
    P.step += P.speed * dt;
    const stride = P.sprinting ? 1.7 : P.crouch > 0.5 ? 0.9 : 1.35;
    if (P.step > stride) {
      P.step = 0;
      const onSlab = L.mission.env === 'range' ? (P.pos.z > -1.5 && P.pos.z < 5) : (P.pos.x > 0 && P.pos.z > 0 && P.pos.x < L.W && P.pos.z < L.H);
      this.audio.footstep(!onSlab, P.crouch > 0.5 ? 0.12 : P.sprinting ? 0.45 : 0.28);
    }
    // Hold breath while aiming
    const wantHold = k.ShiftLeft && A.ads > 0.8;
    if (wantHold && this.breath > 0 && !this.breathOut) { this.breathHold = true; this.breath -= dt / 4.5; if (this.breath <= 0) { this.breathOut = true; this.breath = 0; } }
    else { this.breathHold = false; this.breath = Math.min(1, this.breath + dt / 3.5); if (this.breath > 0.5) this.breathOut = false; }
  }

  updateCamera(dt) {
    const P = this.player, cam = this.camera, A = this.arsenal, L = this.level;
    const eyeH = THREE.MathUtils.lerp(1.66, 1.08, P.crouch);
    // Lean with wall check
    let lean = P.lean;
    const rx = Math.cos(P.yaw), rz = -Math.sin(P.yaw);
    if (L) {
      for (let i = 0; i < 5 && Math.abs(lean) > 0.01; i++) {
        if (!L.blocked(P.pos.x + rx * lean * 0.42, P.pos.z + rz * lean * 0.42, 0.14)) break;
        lean *= 0.6;
      }
    }
    this.effLean = lean;
    const bobK = Math.min(1, P.speed / 3.3) * (1 - (A ? A.ads : 0) * 0.75);
    cam.position.set(P.pos.x + rx * lean * 0.42, eyeH - Math.abs(lean) * 0.06 + Math.abs(Math.sin(P.bob)) * 0.035 * bobK, P.pos.z + rz * lean * 0.42);
    // Aim sway (bullets follow the reticle, so sway is applied to the camera itself)
    let sway = 0;
    if (A && A.ads > 0.5) sway = (this.breathHold ? 0.12 : 1) * (P.crouch > 0.5 ? 0.6 : 1) * (this.breathOut ? 2.2 : 1) * (1 + Math.min(1, P.speed / 3) * 2);
    const t = this.time;
    const sp = Math.sin(t * 1.1) * 0.0011 * sway + Math.sin(t * 2.3) * 0.0004 * sway;
    const syw = Math.cos(t * 0.7) * 0.0012 * sway + Math.sin(t * 1.9) * 0.0003 * sway;
    // Shake
    this.shakeAmt = Math.max(0, this.shakeAmt - dt * 2.5);
    const sh = this.shakeAmt * this.shakeAmt * 0.03;
    const kick = this.kickAnim ? Math.sin(this.kickAnim * Math.PI) * 0.08 : 0;
    cam.rotation.set(P.pitch + sp + (Math.random() - 0.5) * sh - kick, P.yaw + syw + (Math.random() - 0.5) * sh, -lean * 0.16 + (Math.random() - 0.5) * sh);
    cam.updateMatrixWorld();
  }

  updateBullets(dt) {
    const L = this.level, ray = new THREE.Raycaster();
    const dir = new THREE.Vector3(), nrm = new THREE.Vector3();
    for (let i = this.bullets.length - 1; i >= 0; i--) {
      const b = this.bullets[i];
      b.life -= dt;
      if (b.life <= 0) { this.bullets.splice(i, 1); continue; }
      // Sub-step so gravity curve is respected over long flights
      let remaining = dt, done = false;
      while (remaining > 0 && !done) {
        const h = Math.min(remaining, 0.02); remaining -= h;
        b.v.y -= 9.81 * h;
        const step = b.v.length() * h;
        dir.copy(b.v).normalize();
        ray.set(b.p, dir); ray.far = step;
        const hits = ray.intersectObjects(L.shootables, false);
        for (const hit of hits) {
          const r = this.resolveHit(hit, b, dir, nrm);
          if (r) { done = true; break; }
        }
        if (!done) b.p.addScaledVector(dir, step);
      }
      if (done || b.p.y < -1) this.bullets.splice(i, 1);
    }
  }

  resolveHit(hit, b, dir, nrm) {
    const ud = hit.object.userData || {};
    const L = this.level;
    const dist = hit.point.distanceTo(b.origin);
    nrm.set(0, 0, 1);
    if (hit.face) { nrm.copy(hit.face.normal).transformDirection(hit.object.matrixWorld); if (nrm.dot(dir) > 0) nrm.negate(); }
    if (ud.target) {
      const tg = ud.target;
      const info = tg.hitTest(hit);
      if (!info) return false; // passed through cut-out gap
      const drill = L.drill && L.drill.active ? L.drill : null;
      const res = tg.onHit(info, !!drill);
      this.fx.impact(hit.point, nrm, 'wood', dir);
      this.audio.impact('target', dist);
      if (res.already) return true;
      if (res.civ) {
        this.stats.civHits++; this.hitmark('#ffb341');
        this.toast('NO-SHOOT HIT', 'var(--red)');
        if (drill && drill.cur === tg) drill.civHits++;
        if (!this.civWarned) { this.civWarned = true; this.audio.say('Cease fire. Civilian.'); }
        return true;
      }
      this.stats.hits++;
      if (res.kill) {
        this.hitmark('#ff4b3e'); this.audio.hitConfirm(true);
        if (drill && drill.cur === tg) drill.hits++;
        if (res.zone === 'head') this.toast('HEADSHOT', 'var(--red)');
      } else { this.hitmark('#ffffff'); this.audio.hitConfirm(false); }
      return true;
    }
    if (ud.plate) { ud.plate.hit(hit); this.fx.impact(hit.point, nrm, 'steel', dir); this.audio.steelDing(dist, ud.plate.L > 0.6); this.hitmark('#cfe'); this.stats.hits++; return true; }
    if (ud.paper) { ud.paper.hit(hit); this.fx.impact(hit.point, nrm, 'wood', dir); this.stats.hits++; return true; }
    if (ud.door) {
      const door = ud.door;
      if (door.locked && b.def.kind === 'shotgun' && dist < 6) {
        door.kick(this.player.pos.x, this.player.pos.z, 2.2);
        this.toast('DOOR BREACHED', 'var(--accent)');
      } else door.angVel += 0.15 * door.awaySign(b.origin.x, b.origin.z);
      this.fx.decal(hit.point, nrm, door.pivot, ud.surf);
      this.fx.impact(hit.point, nrm, ud.surf === 'steel' ? 'steel' : 'wood', dir);
      this.audio.impact(ud.surf === 'steel' ? 'steel' : 'wood', dist);
      return true;
    }
    this.fx.decal(hit.point, nrm, null, ud.surf);
    this.fx.impact(hit.point, nrm, ud.surf || 'concrete', dir);
    if (dist > 2) this.audio.impact(ud.surf, dist);
    return true;
  }

  updateGrenades(dt) {
    const L = this.level;
    for (let i = this.grenades.length - 1; i >= 0; i--) {
      const g = this.grenades[i], m = g.mesh;
      g.fuse -= dt;
      if (g.fuse <= 0) { this.explodeFlash(g); this.grenades.splice(i, 1); continue; }
      g.vel.y -= 9.81 * dt;
      const p = m.position;
      for (const axis of ['x', 'z']) {
        const prev = p[axis];
        p[axis] += g.vel[axis] * dt;
        const tall = p.y < WALL_H;
        if (tall && this.grenadeBlocked(p)) { p[axis] = prev; g.vel[axis] *= -0.4; if (Math.abs(g.vel[axis]) > 1) this.audio.bounce(); }
      }
      p.y += g.vel.y * dt;
      if (p.y < 0.03) { p.y = 0.03; if (g.vel.y < -1) this.audio.bounce(); g.vel.y *= -0.3; g.vel.x *= 0.6; g.vel.z *= 0.6; }
      m.rotation.x += g.spin.x * dt; m.rotation.y += g.spin.y * dt; m.rotation.z += g.spin.z * dt;
      if (p.y < 0.05) g.spin.multiplyScalar(0.9);
    }
  }

  grenadeBlocked(p) {
    const L = this.level;
    if (L.blocked(p.x, p.z, 0.04)) {
      // Crates are short; grenades can fly over them.
      for (const b of L.colliders) {
        if (p.x > b.minX - 0.04 && p.x < b.maxX + 0.04 && p.z > b.minZ - 0.04 && p.z < b.maxZ + 0.04) {
          const isCrate = (b.maxX - b.minX) < 0.95 && (b.maxZ - b.minZ) < 0.95;
          if (!isCrate || p.y < 0.95) return true;
        }
      }
    }
    if (p.y < 2.1) {
      const a = new THREE.Vector2(), c = new THREE.Vector2();
      for (const d of L.doors) {
        d.segment(a, c);
        const abx = c.x - a.x, abz = c.y - a.y;
        const t = Math.max(0, Math.min(1, ((p.x - a.x) * abx + (p.z - a.y) * abz) / (abx * abx + abz * abz)));
        if (Math.hypot(p.x - (a.x + abx * t), p.z - (a.y + abz * t)) < 0.06) return true;
      }
    }
    return false;
  }

  updateLights(dt) {
    const cam = this.camera;
    this.muzzleLight.intensity *= Math.exp(-dt * 40);
    this.vmMuzzle.intensity *= Math.exp(-dt * 40);
    this.bangLight.intensity *= Math.exp(-dt * 9);
    // Weapon light
    const fl = this.flashlight;
    const on = this.flashlightOn && this.state !== 'menu';
    fl.intensity = on ? 70 : 0;
    this.vmLightGlow.intensity = on ? 0.25 : 0;
    if (on && this.arsenal.s) {
      const lp = this.vmToWorld(this.arsenal.s.model.light);
      const fwd = new THREE.Vector3(); cam.getWorldDirection(fwd);
      fl.position.copy(lp);
      fl.target.position.copy(cam.position).addScaledVector(fwd, 12);
      fl.target.updateMatrixWorld();
    }
    $('light-ind').classList.toggle('on', this.flashlightOn);
    if (this.shadowFollow) this.placeSun(new THREE.Vector3(this.player.pos.x, 0, this.player.pos.z - 15));
  }

  updateHUD(dt) {
    const A = this.arsenal, s = A.s, P = this.player;
    $('wname').textContent = s.def.name;
    $('wmode').textContent = s.def.modes[s.mode];
    $('wcount').innerHTML = `${s.mag}<small>${s.chambered ? '+1' : ''}</small>`;
    if (s.def.kind === 'shotgun') $('mags').innerHTML = `<span class="hint" style="color:var(--dim)">${s.loose} SHELLS</span>`;
    else {
      const key = s.spare.join(',');
      if (this._magKey !== key + s.def.id) { this._magKey = key + s.def.id; $('mags').innerHTML = s.spare.map(n => `<i><s style="height:${(n / s.def.mag) * 100}%"></s></i>`).join(''); }
    }
    let hint = '';
    if (A.reloading) hint = 'RELOADING';
    else if (!s.chambered && s.mag === 0) hint = s.def.kind === 'shotgun' ? (s.loose ? 'RELOAD [R]' : 'EMPTY') : (s.spare.length ? 'RELOAD [R]' : 'SWITCH TO SIDEARM [2]');
    else if (s.mag <= s.def.mag * 0.25 && s.def.kind !== 'shotgun') hint = 'LOW AMMO';
    $('reloadhint').textContent = hint;
    $('hp-num').textContent = Math.ceil(P.health);
    $('hp-bar').firstElementChild.style.width = P.health + '%';
    $('hp-bar').firstElementChild.style.background = P.health < 40 ? 'var(--red)' : 'var(--ink)';
    $('flash-num').textContent = this.flashbangs;
    $('armor-name').textContent = this.armor.short;
    $('lowhp').style.opacity = P.health < 50 ? (1 - P.health / 50) * 0.9 : 0;
    // Crosshair: hidden while aiming, spreads with movement
    const spread = 8 + (s.def.hipSpread * 300) + Math.min(1, P.speed / 4) * 18 + (A.cooldown > 0 ? 6 : 0);
    const cr = $('cross'); cr.style.opacity = A.ads > 0.4 || P.sprinting ? 0 : 1;
    const [a, b, c, d] = cr.children;
    a.style.top = (-spread - 8) + 'px'; b.style.top = spread + 'px'; c.style.left = (-spread - 8) + 'px'; d.style.left = spread + 'px';
    // Hit marker
    if (this.hitmarkT > 0) { this.hitmarkT -= dt; if (this.hitmarkT <= 0) $('hitmark').style.opacity = 0; }
    // Overlays
    this.dmgFlash = Math.max(0, this.dmgFlash - dt * 2.2); $('dmg').style.opacity = this.dmgFlash;
    this.whiteout = Math.max(0, this.whiteout - dt); $('whiteout').style.opacity = Math.min(1, this.whiteout);
    // Compass
    const deg = ((-THREE.MathUtils.radToDeg(P.yaw) % 360) + 360) % 360;
    const strip = $('compass-strip'), w = $('compass').clientWidth;
    strip.style.transform = `translateX(${w / 2 - (360 + deg) / 15 * 30 - 15}px)`;
    // Breath
    const br = $('breath'); br.style.opacity = A.ads > 0.8 && (this.breathHold || this.breath < 1) ? 1 : 0; br.firstElementChild.style.width = this.breath * 100 + '%';
    // Objective + timer
    const L = this.level, m = this.mission;
    let obj;
    if (m.env === 'range') obj = L.drill.active ? `Qualification: target ${Math.max(1, L.drill.idx + 1)}/20 · hits ${L.drill.hits}` : 'Free fire. Use the console at the firing line [F] to start qualification.';
    else {
      const hs = L.targets.filter(t => t.hostile), dn = hs.filter(t => t.neutralized).length;
      obj = `Neutralise hostiles ${dn}/${hs.length}`;
      if (L.hostage) obj += L.hostage.secured ? ' · Hostage secured' : ' · Rescue the hostage';
      if (this.objectivesDone() && L.extractPos) obj = 'Area secure. Move to extraction (green).';
    }
    $('obj-text').textContent = obj;
    $('timer').textContent = m.env === 'range' ? '' : fmtTime(this.missionTime, true);
    // Prompt
    let prompt = '';
    if (L.console && P.pos.distanceTo(L.console.pos) < 1.8 && !L.drill.active) prompt = '<kbd>[F]</kbd> START QUALIFICATION';
    else if (L.hostage && !L.hostage.secured && P.pos.distanceTo(L.hostage.group.position) < 1.8) prompt = '<kbd>[F]</kbd> SECURE HOSTAGE';
    else {
      const d = this.nearestDoor(1.7);
      if (d) prompt = d.locked ? '<kbd>[V]</kbd> KICK LOCKED DOOR' : (d.isOpen() ? '<kbd>[F]</kbd> CLOSE DOOR' : '<kbd>[F]</kbd> OPEN &nbsp; <kbd>[V]</kbd> KICK &nbsp; <kbd>[G]</kbd> FLASH');
    }
    if (this._prompt !== prompt) { this._prompt = prompt; $('prompt').innerHTML = prompt; }
    // Tips
    if (this.tipQueue && this.tipQueue.length) {
      this.tipT -= dt;
      if (this.tipT <= 0) {
        const tip = $('tip'); tip.textContent = this.tipQueue.shift(); tip.style.opacity = 1;
        setTimeout(() => tip.style.opacity = 0, 6000);
        this.tipT = 9;
      }
    }
  }

  frame() {
    const now = performance.now();
    let dt = Math.min(0.1, (now - this.last) / 1000); this.last = now;
    this.time += dt;
    const A = this.arsenal, P = this.player;
    if (this.state === 'playing') {
      this.missionTime += dt;
      this.recentShot = Math.max(0, this.recentShot - dt);
      this.kickCooldown = Math.max(0, this.kickCooldown - dt);
      if (this.kickAnim) { this.kickAnim -= dt * 3; if (this.kickAnim < 0) this.kickAnim = 0; }
      this.throwT = Math.max(0, this.throwT - dt);
      this.updatePlayer(dt);
      this.updateCamera(dt);
      A.update(dt, { ads: this.mouse.ads, sprinting: P.sprinting && P.speed > 3, lowered: this.throwT > 0 || (this.kickAnim > 0), lookDX: this.mouse.dx, lookDY: this.mouse.dy, bob: P.bob, moveAmt: Math.min(1, P.speed / 3.3), time: this.time, lean: this.effLean || 0 });
      const fov = this.settings.fov / (1 + (A.s.def.zoom - 1) * A.ads);
      if (Math.abs(this.camera.fov - fov) > 0.01) { this.camera.fov = fov; this.camera.updateProjectionMatrix(); }
      this.level.update(dt);
      this.updateBullets(dt);
      this.updateGrenades(dt);
      this.updateHUD(dt);
      // Completion checks
      const m = this.mission;
      if (m.env !== 'range' && !this.complete && this.objectivesDone()) {
        if (!this.level.extractPos) this.finish(true);
        else if (P.pos.distanceTo(this.level.extractPos) < 1.1) this.finish(true);
      }
    } else if (this.state === 'menu' || this.state === 'brief') {
      // Slow cinematic drift for the menu backdrop
      const L = this.level, t = this.time * 0.06;
      if (L) {
        const cx = L.mission.env === 'range' ? 0 : L.W / 2, cz = L.mission.env === 'range' ? -10 : L.H / 2;
        const rad = L.mission.env === 'range' ? 14 : Math.max(L.W, L.H) * 0.55;
        this.camera.position.set(cx + Math.cos(t) * rad, L.mission.env === 'range' ? 2.2 : 7, cz + Math.sin(t) * rad);
        this.camera.lookAt(cx, 0.8, cz - (L.mission.env === 'range' ? 25 : 0));
        if (this.state === 'brief') { this.player.yaw = THREE.MathUtils.degToRad(this.mission.yaw || 0); }
        this.camera.fov = 60; this.camera.updateProjectionMatrix();
        L.update(dt, false);
      }
      A.update(dt, { ads: false, sprinting: false, lowered: true, lookDX: 0, lookDY: 0, bob: 0, moveAmt: 0, time: this.time, lean: 0 });
    }
    this.mouse.dx = 0; this.mouse.dy = 0;
    A.holder.visible = this.state === 'playing' || this.state === 'paused';
    this.vmCamera.updateMatrixWorld();
    this.fx.update(dt, () => 0);
    this.updateLights(dt);
    this.composer.render(dt);
  }
}

// Preetham sky, toned down so the horizon isn't blown out under ACES.
function makeSky() {
  const s = new Sky();
  s.material.fragmentShader = s.material.fragmentShader.replace('gl_FragColor = vec4( retColor, 1.0 );', 'gl_FragColor = vec4( retColor * 0.5, 1.0 );');
  return s;
}

function fmtTime(t, tenths) {
  const m = Math.floor(t / 60), s = t - m * 60;
  return `${String(m).padStart(2, '0')}:${tenths ? s.toFixed(1).padStart(4, '0') : String(Math.floor(s)).padStart(2, '0')}`;
}

const game = new Game();
game.init().catch(err => {
  console.error(err);
  $('load-text').textContent = 'FAILED TO START: ' + (err && err.message ? err.message : err) + ' — try a browser with WebGL2 (Chrome, Edge, Firefox).';
});
