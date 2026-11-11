// Synthesized audio: gunshots, mechanics, steel, doors, flashbangs. No sample files needed.
export class AudioSys {
  constructor() {
    this.ctx = null;
    this.volume = 0.8;
    this.voice = true;
    this.lastVoice = 0;
  }

  init() {
    if (this.ctx) { if (this.ctx.state === 'suspended') this.ctx.resume(); return; }
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    const ctx = this.ctx = new AC();
    this.master = ctx.createGain(); this.master.gain.value = this.volume;
    this.muffle = ctx.createBiquadFilter(); this.muffle.type = 'lowpass'; this.muffle.frequency.value = 20000;
    this.comp = ctx.createDynamicsCompressor();
    this.comp.threshold.value = -12; this.comp.ratio.value = 5; this.comp.attack.value = 0.002; this.comp.release.value = 0.15;
    this.master.connect(this.muffle); this.muffle.connect(this.comp); this.comp.connect(ctx.destination);
    this.verb = ctx.createConvolver();
    this.verbGain = ctx.createGain(); this.verbGain.gain.value = 0.3;
    this.verb.connect(this.verbGain); this.verbGain.connect(this.master);
    const len = ctx.sampleRate * 2;
    this.noiseBuf = ctx.createBuffer(1, len, ctx.sampleRate);
    const d = this.noiseBuf.getChannelData(0);
    for (let i = 0; i < len; i++) d[i] = Math.random() * 2 - 1;
    this.setReverb(1.0, 0.3);
  }

  setVolume(v) { this.volume = v; if (this.master) this.master.gain.value = v; }

  // Indoor rooms: short dense tail. Open range: long sparse echo.
  setReverb(decay, wet) {
    if (!this.ctx) return;
    const ctx = this.ctx, sr = ctx.sampleRate, len = Math.floor(sr * decay);
    const buf = ctx.createBuffer(2, len, sr);
    for (let ch = 0; ch < 2; ch++) {
      const d = buf.getChannelData(ch);
      for (let i = 0; i < len; i++) {
        const t = i / len;
        d[i] = (Math.random() * 2 - 1) * Math.pow(1 - t, 2.6) * (i < sr * 0.004 ? i / (sr * 0.004) : 1);
      }
      // Discrete early reflections
      for (let k = 0; k < 6; k++) {
        const at = Math.floor(sr * (0.008 + Math.random() * decay * 0.12));
        if (at < len) d[at] += (Math.random() > 0.5 ? 1 : -1) * 0.6 * (1 - k / 6);
      }
    }
    this.verb.buffer = buf;
    this.verbGain.gain.value = wet;
  }

  out(pan = 0, vol = 1, wet = 1) {
    const ctx = this.ctx;
    const g = ctx.createGain(); g.gain.value = vol;
    let node = g;
    if (pan && ctx.createStereoPanner) {
      const p = ctx.createStereoPanner(); p.pan.value = Math.max(-1, Math.min(1, pan));
      g.connect(p); node = p;
    }
    node.connect(this.master);
    if (wet > 0) { const s = ctx.createGain(); s.gain.value = wet; node.connect(s); s.connect(this.verb); }
    return g;
  }

  noise(dest, t, { type = 'lowpass', freq = 1000, q = 0.7, gain = 1, attack = 0.001, decay = 0.1, sweepTo = 0 }) {
    const ctx = this.ctx;
    const src = ctx.createBufferSource(); src.buffer = this.noiseBuf;
    const f = ctx.createBiquadFilter(); f.type = type; f.frequency.setValueAtTime(freq, t); f.Q.value = q;
    if (sweepTo) f.frequency.exponentialRampToValueAtTime(sweepTo, t + decay);
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(gain, t + attack);
    g.gain.exponentialRampToValueAtTime(0.0001, t + attack + decay);
    src.connect(f); f.connect(g); g.connect(dest);
    src.start(t, Math.random() * 1.5, attack + decay + 0.05);
  }

  tone(dest, t, { freq = 440, to = 0, type = 'sine', gain = 0.5, attack = 0.002, decay = 0.2 }) {
    const ctx = this.ctx;
    const o = ctx.createOscillator(); o.type = type;
    o.frequency.setValueAtTime(freq, t);
    if (to) o.frequency.exponentialRampToValueAtTime(to, t + attack + decay);
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(gain, t + attack);
    g.gain.exponentialRampToValueAtTime(0.0001, t + attack + decay);
    o.connect(g); g.connect(dest);
    o.start(t); o.stop(t + attack + decay + 0.05);
  }

  gunshot(kind) {
    if (!this.ctx) return;
    const t = this.ctx.currentTime, p = 0.9 + Math.random() * 0.2;
    const P = {
      rifle: { crack: 1.0, crackF: 1800, body: 1.3, bodyF: 1100, boom: 1.0, boomF: 140, tail: 0.22 },
      smg: { crack: 0.55, crackF: 1500, body: 1.0, bodyF: 900, boom: 0.7, boomF: 120, tail: 0.15 },
      pistol: { crack: 0.7, crackF: 1600, body: 1.0, bodyF: 1000, boom: 0.8, boomF: 130, tail: 0.17 },
      shotgun: { crack: 0.8, crackF: 1200, body: 1.6, bodyF: 700, boom: 1.6, boomF: 95, tail: 0.32 },
    }[kind];
    const o = this.out(0, 0.9, 1.4);
    this.noise(o, t, { type: 'highpass', freq: P.crackF * p, gain: P.crack, decay: 0.045 });
    this.noise(o, t, { type: 'bandpass', freq: P.bodyF * p, q: 0.6, gain: P.body, decay: P.tail, sweepTo: 300 });
    this.tone(o, t, { freq: P.boomF * p, to: 38, gain: P.boom, decay: P.tail * 0.9 });
    this.noise(o, t + 0.012, { type: 'bandpass', freq: 3200, q: 3, gain: 0.12, decay: 0.03 });
  }

  dryFire() { if (!this.ctx) return; const o = this.out(0, 0.5, 0.2); this.noise(o, this.ctx.currentTime, { type: 'bandpass', freq: 2600, q: 4, gain: 0.6, decay: 0.03 }); }

  click(freq = 2000, vol = 0.4, delay = 0) {
    if (!this.ctx) return;
    const o = this.out(0, vol, 0.2), t = this.ctx.currentTime + delay;
    this.noise(o, t, { type: 'bandpass', freq, q: 3, gain: 1, decay: 0.035 });
    this.noise(o, t + 0.012, { type: 'bandpass', freq: freq * 0.6, q: 2, gain: 0.5, decay: 0.05 });
  }

  magOut() { this.click(1400, 0.5); }
  magIn() { this.click(1800, 0.6); this.click(900, 0.4, 0.03); }
  boltRelease() { this.click(2400, 0.6); this.click(1200, 0.5, 0.02); }
  pump() { this.click(1100, 0.6); this.click(1600, 0.6, 0.16); }
  shellIn() { this.click(1300, 0.45); }
  switchWeapon() { this.click(800, 0.3); this.click(1400, 0.25, 0.08); }
  modeSwitch() { this.click(3000, 0.4); }

  steelDing(dist = 10, big = false, pan = 0) {
    if (!this.ctx) return;
    const t = this.ctx.currentTime + dist / 343;
    const vol = Math.min(1, 6 / (dist + 2)) * 0.8;
    const o = this.out(pan, vol, 1.2);
    const base = (big ? 420 : 640) * (0.95 + Math.random() * 0.1);
    for (const [m, gn, dc] of [[1, 0.5, 1.1], [2.76, 0.3, 0.7], [5.4, 0.2, 0.45], [8.93, 0.1, 0.25]]) {
      this.tone(o, t, { freq: base * m, gain: gn, decay: dc, attack: 0.001 });
    }
    this.noise(o, t, { type: 'highpass', freq: 3000, gain: 0.4, decay: 0.02 });
  }

  impact(surf, dist = 5, pan = 0) {
    if (!this.ctx) return;
    const t = this.ctx.currentTime;
    const o = this.out(pan, Math.min(0.6, 4 / (dist + 2)), 0.6);
    if (surf === 'wood' || surf === 'target') this.noise(o, t, { type: 'bandpass', freq: 700, q: 1.5, gain: 0.8, decay: 0.06 });
    else if (surf === 'dirt') this.noise(o, t, { type: 'lowpass', freq: 600, gain: 0.5, decay: 0.08 });
    else this.noise(o, t, { type: 'bandpass', freq: 2200, q: 1, gain: 0.6, decay: 0.04 });
  }

  casing(shell = false) {
    if (!this.ctx) return;
    const t = this.ctx.currentTime, o = this.out((Math.random() - 0.3) * 0.6, 0.12, 0.3);
    if (shell) { this.noise(o, t, { type: 'bandpass', freq: 900, q: 2, gain: 0.8, decay: 0.05 }); return; }
    const f = 4200 + Math.random() * 2500;
    this.tone(o, t, { freq: f, gain: 0.5, decay: 0.07 });
    this.tone(o, t, { freq: f * 1.47, gain: 0.3, decay: 0.05 });
  }

  footstep(gravel, vol) {
    if (!this.ctx) return;
    const t = this.ctx.currentTime, o = this.out(0, vol, 0.4);
    if (gravel) {
      this.noise(o, t, { type: 'bandpass', freq: 1800 + Math.random() * 600, q: 0.8, gain: 0.5, decay: 0.09 });
      this.noise(o, t, { type: 'lowpass', freq: 300, gain: 0.5, decay: 0.06 });
    } else {
      this.noise(o, t, { type: 'lowpass', freq: 500 + Math.random() * 200, gain: 0.8, decay: 0.06 });
      this.noise(o, t, { type: 'highpass', freq: 3500, gain: 0.08, decay: 0.03 });
    }
  }

  doorOpen() {
    if (!this.ctx) return;
    const t = this.ctx.currentTime, o = this.out(0, 0.35, 0.5);
    this.click(900, 0.4);
    this.tone(o, t + 0.05, { freq: 180, to: 260, type: 'sawtooth', gain: 0.06, decay: 0.45, attack: 0.08 });
  }

  doorKick() {
    if (!this.ctx) return;
    const t = this.ctx.currentTime, o = this.out(0, 1, 1.2);
    this.noise(o, t, { type: 'lowpass', freq: 400, gain: 1.6, decay: 0.25 });
    this.noise(o, t, { type: 'bandpass', freq: 1300, q: 1, gain: 0.9, decay: 0.12 });
    this.tone(o, t, { freq: 90, to: 40, gain: 0.9, decay: 0.2 });
    this.noise(o, t + 0.28, { type: 'lowpass', freq: 700, gain: 0.8, decay: 0.18 });
  }

  doorThud() {
    if (!this.ctx) return;
    const o = this.out(0, 0.6, 0.6);
    this.noise(o, this.ctx.currentTime, { type: 'lowpass', freq: 300, gain: 1, decay: 0.12 });
  }

  targetFall(dist = 5) {
    if (!this.ctx) return;
    const o = this.out(0, Math.min(0.7, 5 / (dist + 2)), 0.8);
    this.noise(o, this.ctx.currentTime + 0.05, { type: 'lowpass', freq: 500, gain: 1, decay: 0.15 });
    this.click(600, 0.4, 0.0);
  }

  popUp() {
    if (!this.ctx) return;
    const t = this.ctx.currentTime, o = this.out(0, 0.35, 0.6);
    this.tone(o, t, { freq: 120, to: 220, type: 'sawtooth', gain: 0.1, decay: 0.25, attack: 0.02 });
    this.click(700, 0.3, 0.25);
  }

  // MILES laser-tag hit on the player: alarm beeps + thump.
  playerHit() {
    if (!this.ctx) return;
    const t = this.ctx.currentTime, o = this.out(0, 0.6, 0.1);
    this.tone(o, t, { freq: 2300, type: 'square', gain: 0.15, decay: 0.08 });
    this.tone(o, t + 0.12, { freq: 2300, type: 'square', gain: 0.15, decay: 0.08 });
    this.noise(o, t, { type: 'lowpass', freq: 200, gain: 1.2, decay: 0.15 });
  }

  hostileShot(dist, pan) {
    if (!this.ctx) return;
    const t = this.ctx.currentTime, o = this.out(pan, Math.min(0.8, 8 / (dist + 3)), 1.3);
    this.noise(o, t, { type: 'bandpass', freq: 1000, q: 0.7, gain: 1.0, decay: 0.15 });
    this.tone(o, t, { freq: 120, to: 40, gain: 0.7, decay: 0.15 });
  }

  hitConfirm(kill) {
    if (!this.ctx) return;
    const o = this.out(0, 0.25, 0);
    this.tone(o, this.ctx.currentTime, { freq: kill ? 1500 : 2200, type: 'triangle', gain: 0.4, decay: 0.05 });
  }

  beep(freq = 880, dur = 0.12, vol = 0.3) {
    if (!this.ctx) return;
    const o = this.out(0, vol, 0);
    this.tone(o, this.ctx.currentTime, { freq, type: 'square', gain: 0.25, decay: dur });
  }

  flashbang(dist, affected) {
    if (!this.ctx) return;
    const t = this.ctx.currentTime, o = this.out(0, Math.min(1.4, 14 / (dist + 3)), 1.6);
    this.noise(o, t, { type: 'lowpass', freq: 4000, gain: 2.5, decay: 0.9, sweepTo: 200 });
    this.noise(o, t, { type: 'highpass', freq: 2500, gain: 1.4, decay: 0.08 });
    this.tone(o, t, { freq: 70, to: 25, gain: 1.6, decay: 0.7 });
    if (affected > 0) {
      const ring = this.out(0, 0.07 * affected, 0);
      this.tone(ring, t, { freq: 3700, gain: 1, attack: 0.05, decay: 3.5 * affected + 0.5 });
      const f = this.muffle.frequency;
      f.cancelScheduledValues(t);
      f.setValueAtTime(350, t);
      f.exponentialRampToValueAtTime(20000, t + 4.5 * affected + 0.5);
    }
  }

  throwSound() {
    if (!this.ctx) return;
    this.click(500, 0.3);
    this.noise(this.out(0, 0.2, 0.2), this.ctx.currentTime, { type: 'bandpass', freq: 600, gain: 0.5, decay: 0.2 });
  }

  bounce() { if (!this.ctx) return; this.click(500 + Math.random() * 300, 0.35); }

  say(text) {
    if (!this.voice || !window.speechSynthesis) return;
    const now = performance.now();
    if (now - this.lastVoice < 700) return;
    this.lastVoice = now;
    try {
      const u = new SpeechSynthesisUtterance(text);
      u.rate = 1.15; u.pitch = 0.8; u.volume = Math.min(1, this.volume + 0.1);
      speechSynthesis.cancel();
      speechSynthesis.speak(u);
    } catch (e) { /* speech not available */ }
  }
}
