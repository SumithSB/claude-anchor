#!/usr/bin/env python3
"""Synthesises the tour soundtrack (stdlib only, no samples) from the cue times render.js exports.

    python3 audio.py <frames>/cues.json out.wav

Layers: a soft ambient pad, UI clicks, a chain rattle + whoosh while the anchor is dragged, a wooden/metal
clunk when it lands, chimes for fresh windows, airy whooshes on panel opens. The mix is then normalised
to -16 LUFS (true peak -1.5 dBTP) with ffmpeg's two-pass loudnorm.
"""
import json, math, random, struct, subprocess, sys, wave

SR = 44100
random.seed(7)
cues = json.load(open(sys.argv[1]))
out_path = sys.argv[2]
N = int(cues["total"] * SR)
L = [0.0] * N
R = [0.0] * N


def add(t0, samples, gain=1.0, pan=0.0):
    """Mix a mono buffer in at t0 seconds; pan -1 (left) .. 1 (right), constant power."""
    i0 = int(t0 * SR)
    gl, gr = math.cos((pan + 1) * math.pi / 4) * gain, math.sin((pan + 1) * math.pi / 4) * gain
    for k, v in enumerate(samples):
        i = i0 + k
        if 0 <= i < N:
            L[i] += v * gl
            R[i] += v * gr


def lowpass(x, fc):
    a = 1 - math.exp(-2 * math.pi * fc / SR)
    y, s = [], 0.0
    for v in x:
        s += a * (v - s)
        y.append(s)
    return y


def noise(n):
    return [random.uniform(-1, 1) for _ in range(n)]


def env(n, attack, decay):
    """Exponential decay with a short linear attack (seconds); no clicks at the edges."""
    a = max(1, int(attack * SR))
    return [(k / a if k < a else 1.0) * math.exp(-(k - a) / (decay * SR)) for k in range(n)]


# --- ambient pad: D major add9, slow breathing, fades in and out -------------------------------------
def pad():
    end = cues["end"]
    chord_a = [146.83, 220.00, 293.66, 329.63, 369.99]      # D3 A3 D4 E4 F#4
    chord_b = [146.83, 196.00, 293.66, 329.63, 392.00]      # D3 G3 D4 E4 G4 (end card lift)
    for v, (fa, fb) in enumerate(zip(chord_a, chord_b)):
        for ch, det in ((L, -0.6), (R, 0.6)):
            ph = random.random() * 6.28
            lfo_rate, lfo_ph = 0.07 + 0.03 * v, random.random() * 6.28
            amp = 0.03 / (1 + 0.35 * v)
            for i in range(N):
                t = i / SR
                k = min(1.0, max(0.0, (t - end + 0.4) / 1.2))   # glide into the end chord
                f = fa + (fb - fa) * k + det
                ph += 2 * math.pi * f / SR
                fade = min(1.0, t / 2.0) * min(1.0, (cues["total"] - t) / 1.6)
                breath = 0.75 + 0.25 * math.sin(2 * math.pi * lfo_rate * t + lfo_ph)
                ch[i] += amp * fade * breath * (math.sin(ph) + 0.18 * math.sin(2 * ph))


# --- one-shots -------------------------------------------------------------------------------------
def click():
    n = int(0.05 * SR)
    e = env(n, 0.001, 0.008)
    tone = [math.sin(2 * math.pi * 1800 * k / SR) for k in range(n)]
    nz = lowpass(noise(n), 3500)
    return [e[k] * (0.6 * tone[k] + 0.8 * nz[k]) for k in range(n)]


def tick(f):
    """A tiny metallic chain-link tick: inharmonic partials, very short."""
    n = int(0.03 * SR)
    e = env(n, 0.0008, 0.006)
    return [e[k] * (math.sin(2 * math.pi * f * k / SR) + 0.6 * math.sin(2 * math.pi * f * 1.47 * k / SR)
                    + 0.3 * math.sin(2 * math.pi * f * 2.09 * k / SR)) / 1.9 for k in range(n)]


def whoosh(dur, peak_fc=1800):
    n = int(dur * SR)
    x = noise(n)
    y, s1, s2 = [], 0.0, 0.0
    for k in range(n):
        p = k / n
        shape = math.sin(math.pi * p) ** 2
        fc = 300 + peak_fc * shape
        a = 1 - math.exp(-2 * math.pi * fc / SR)
        s1 += a * (x[k] - s1)
        s2 += a * (s1 - s2)
        y.append(s2 * shape)
    return y


def clunk():
    n = int(0.6 * SR)
    out = [0.0] * n
    ph = 0.0
    for k in range(n):                       # soft low thud with a pitch drop
        t = k / SR
        ph += 2 * math.pi * (70 + 55 * math.exp(-t / 0.04)) / SR
        out[k] += 0.9 * math.sin(ph) * (min(1, t / 0.003)) * math.exp(-t / 0.09)
    knock = lowpass(lowpass(noise(int(0.08 * SR)), 900), 900)   # wooden body
    for k, v in enumerate(knock):
        out[k] += 1.6 * v * math.exp(-k / (0.018 * SR))
    for f, a, d in ((830, 0.10, 0.25), (1310, 0.07, 0.18), (2270, 0.04, 0.1)):   # faint metal ring
        for k in range(n):
            t = k / SR
            out[k] += a * math.sin(2 * math.pi * f * t) * min(1, t / 0.004) * math.exp(-t / d)
    return out


def chime(notes=(659.25, 987.77), gap=0.11, dur=1.6):
    n = int((dur + gap * len(notes)) * SR)
    out = [0.0] * n
    for j, f in enumerate(notes):
        o = int(j * gap * SR)
        for k in range(n - o):
            t = k / SR
            e = min(1, t / 0.006) * math.exp(-t / 0.55)
            out[o + k] += e * (math.sin(2 * math.pi * f * t) + 0.25 * math.sin(2 * math.pi * f * 2.76 * t) * math.exp(-t / 0.15)) / 1.25
    return out


def rattle(t0, t1):
    """Chain ticks while dragging (denser in the middle) over a soft airy whoosh."""
    dur = t1 - t0
    add(t0, whoosh(dur, 1400), 0.14, 0.25)
    t = t0
    while t < t1:
        p = (t - t0) / dur
        density = 10 + 26 * math.sin(math.pi * p)
        add(t, tick(random.uniform(2600, 4200)), 0.08 + 0.07 * math.sin(math.pi * p), random.uniform(-0.1, 0.6))
        t += random.expovariate(density)


pad()
c = click()
for t in cues["clicks"]:
    add(t, c, 0.16, 0.3)
add(cues["grab"], c, 0.12, 0.35)
add(cues["release"], c, 0.08, 0.4)
rattle(cues["grab"] + 0.05, cues["release"])
add(cues["land"], clunk(), 0.30, 0.45)
for t in cues["fresh"]:
    add(t, chime(), 0.10, 0.35)
for t in cues["whoosh"]:
    add(t, whoosh(0.45, 2200), 0.08, 0.2)
s0, s1 = cues["spin"]
t = s0
while t < s1:                                # refresh spinner: a few faint ticks
    add(t, tick(2400), 0.035, 0.45)
    t += 0.09
add(cues["end"] + 0.15, chime((587.33, 739.99, 880.0), 0.16, 2.2), 0.09, 0.0)   # D5 F#5 A5

raw = out_path + ".raw.wav"
with wave.open(raw, "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    peak = max(1e-9, max(max(abs(v) for v in L), max(abs(v) for v in R)))
    g = 0.7 / peak                            # headroom; loudnorm sets the final level
    w.writeframes(b"".join(struct.pack("<hh", int(L[i] * g * 32767), int(R[i] * g * 32767)) for i in range(N)))

# two-pass loudnorm to -16 LUFS, linear (no pumping)
ff = "ffmpeg"
p = subprocess.run([ff, "-hide_banner", "-i", raw, "-af", "loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"],
                   capture_output=True, text=True)
m = json.loads(p.stderr[p.stderr.rindex("{"):p.stderr.rindex("}") + 1])
af = ("loudnorm=I=-16:TP=-1.5:LRA=11:linear=true:measured_I={input_i}:measured_TP={input_tp}:"
      "measured_LRA={input_lra}:measured_thresh={input_thresh}:offset={target_offset}").format(**m)
subprocess.run([ff, "-y", "-hide_banner", "-loglevel", "error", "-i", raw, "-af", af, "-ar", str(SR), out_path], check=True)
subprocess.run(["rm", "-f", raw])
print("wrote", out_path, "input", m["input_i"], "LUFS ->", -16)
