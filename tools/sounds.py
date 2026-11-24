# gera os sons do daemon (sintetizados, sem samples): python3 tools/sounds.py sounds/
import math, struct, sys, wave
SR = 44100
out = sys.argv[1]

def buf(sec): return [0.0] * int(SR * sec)

def boing(b, at, f0, f1, dur, amp):
    # blip com glide pra cima (pulinho)
    ph = 0.0; n = int(dur * SR); s0 = int(at * SR)
    for i in range(n):
        u = i / n
        f = f0 + (f1 - f0) * (1 - (1 - u) ** 2)
        ph += 2 * math.pi * f / SR
        env = min(1, i / (0.004 * SR)) * (1 - u) ** 2
        b[s0 + i] += amp * env * (math.sin(ph) + 0.15 * math.sin(2 * ph))

def bell(b, at, f, dur, amp, vib=0.0):
    parts = [(1, 1, 1), (2.0, .45, 1.6), (2.76, .22, 2.4), (5.4, .08, 4)]
    n = int(dur * SR); s0 = int(at * SR)
    for i in range(n):
        t = i / SR
        v = 1 + vib * math.sin(2 * math.pi * 5.5 * t) * min(1, t / 0.15)
        x = 0
        for r, a, d in parts:
            x += a * math.sin(2 * math.pi * f * r * v * t) * math.exp(-t * d * 4.5 / dur)
        b[s0 + i] += amp * x * min(1, i / (0.003 * SR))

def heh(b, at, f0, f1, dur, amp):
    # risadinha "he" com formantes (vogal e)
    F = [(500, 110, 1.0), (1850, 160, .55), (2600, 200, .25)]
    n = int(dur * SR); s0 = int(at * SR); ph = 0.0
    for i in range(n):
        u = i / n
        f = f0 + (f1 - f0) * u
        ph += 2 * math.pi * f / SR
        x = 0; h = 1
        while h * f < 3800:
            hf = h * f
            w = sum(g / (1 + ((hf - c) / bw) ** 2) for c, bw, g in F)
            x += w * math.sin(h * ph) / h ** 0.6
            h += 1
        env = min(1, i / (0.012 * SR)) * (1 - u) ** 1.6
        b[s0 + i] += amp * env * x * 0.35

def pluck(b, at, f, dur, amp):
    n = int(dur * SR); s0 = int(at * SR)
    for i in range(n):
        t = i / SR
        x = math.sin(2*math.pi*f*t) + .3*math.sin(4*math.pi*f*t) + .1*math.sin(6*math.pi*f*t)
        b[s0 + i] += amp * x * math.exp(-t * 9) * min(1, i / (0.002 * SR))

def save(b, name):
    peak = max(abs(x) for x in b) or 1
    g = 0.55 / peak
    # fade final
    for i in range(int(0.03 * SR)): b[-1 - i] *= i / (0.03 * SR)
    with wave.open(f"{out}/{name}.wav", "w") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, x * g)) * 32767)) for x in b))

# A: boing boing + sininho trítono
a = buf(1.8)
boing(a, 0.00, 700, 1300, 0.11, 0.8)
boing(a, 0.57, 850, 1500, 0.09, 0.55)
bell(a, 0.95, 659.25, 0.8, 0.45, vib=0.004)   # mi
bell(a, 0.95, 932.33, 0.8, 0.38, vib=0.004)   # lá# (trítono)
save(a, "daemon-a")

# B: A + risadinha "he he" descendo
b = buf(2.0)
boing(b, 0.00, 700, 1300, 0.11, 0.8)
boing(b, 0.57, 850, 1500, 0.09, 0.55)
bell(b, 0.95, 659.25, 0.8, 0.38, vib=0.004)
bell(b, 0.95, 932.33, 0.8, 0.32, vib=0.004)
heh(b, 1.12, 260, 215, 0.12, 0.9)
heh(b, 1.29, 235, 185, 0.15, 0.9)
save(b, "daemon-b")

# C: boing + arpejo do capeta descendo (trítonos) + plim agudo
c = buf(1.8)
boing(c, 0.00, 700, 1300, 0.11, 0.8)
boing(c, 0.57, 850, 1500, 0.09, 0.55)
for k, f in enumerate([880.0, 622.25, 440.0]):
    pluck(c, 0.95 + k * 0.11, f, 0.5, 0.6)
bell(c, 1.33, 1864.66, 0.4, 0.12)
save(c, "daemon-c")
print("ok")
