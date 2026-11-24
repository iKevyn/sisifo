# sons 8-bit de monstrinhos (sintetizados do zero, inspirados; sem samples): python3 tools/sounds8bit.py sounds/
import math, random, struct, sys, wave
SR = 44100
out = sys.argv[1]
random.seed(7)

def buf(sec): return [0.0] * int(SR * sec)

def pulse(ph, duty=0.5):
    return 1.0 if (ph % 1.0) < duty else -1.0

def tri(ph):
    x = ph % 1.0
    return 4 * x - 1 if x < 0.5 else 3 - 4 * x

class Noise:
    """LFSR estilo NES; rate = quantas vezes por segundo o ruído muda"""
    def __init__(self, short=False):
        self.r = 1; self.short = short; self.acc = 0.0; self.v = 1.0
    def step(self, rate):
        self.acc += rate / SR
        while self.acc >= 1:
            self.acc -= 1
            bit = (self.r ^ (self.r >> (6 if self.short else 1))) & 1
            self.r = (self.r >> 1) | (bit << 14)
            self.v = 1.0 if self.r & 1 else -1.0
        return self.v

def voice(b, at, dur, fn, amp=1.0):
    """fn(t, u) -> amostra; t = segundos desde o começo, u = 0..1"""
    s0 = int(at * SR); n = int(dur * SR)
    for i in range(n):
        if s0 + i >= len(b): break
        b[s0 + i] += amp * fn(i / SR, i / n)

def sweep(f0, f1, u, curve=1.0):
    return f0 * (f1 / f0) ** (u ** curve)

def env_ad(u, a=0.03, p=1.5):
    return min(1, u / a) * (1 - u) ** p

def crush(b):
    # 8-bit: segura amostra a cada 4 (≈11 kHz) e quantiza em 16 níveis
    out_ = []; hold = 0.0
    for i, x in enumerate(b):
        if i % 4 == 0: hold = round(max(-1, min(1, x)) * 7.5) / 7.5
        out_.append(hold)
    return out_

def save(b, name, gain=0.5):
    peak = max(abs(x) for x in b) or 1
    b = [x / peak for x in b]
    b = crush(b)
    for i in range(int(0.02 * SR)): b[-1 - i] *= i / (0.02 * SR)
    with wave.open(f"{out}/{name}.wav", "w") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(x * gain * 32767)) for x in b))

def osc(freq_fn, wave_fn):
    st = {"ph": 0.0}
    def f(t, u):
        st["ph"] += freq_fn(t, u) / SR
        return wave_fn(st["ph"], t, u)
    return f

# ---------- ENDERMAN: vwoop de teleporte + gemido distorcido + vwoop curto
b = buf(1.9)
def vwoop(scale=1.0):
    return osc(lambda t, u: (sweep(180, 1100, u / 0.4, 0.7) if u < 0.4 else sweep(1100, 120, (u - 0.4) / 0.6, 0.6)) * (1 + 0.06 * math.sin(2 * math.pi * 22 * t)) * scale,
               lambda ph, t, u: pulse(ph, 0.25) * env_ad(u, 0.05, 1.2))
voice(b, 0.0, 0.42, vwoop(), 0.8)
moan = osc(lambda t, u: (300 - 140 * u) * (1 + 0.09 * math.sin(2 * math.pi * 6.5 * t) + 0.04 * math.sin(2 * math.pi * 31 * t)),
           lambda ph, t, u: (0.6 * pulse(ph, 0.5) + 0.4 * tri(ph * 0.5)) * min(1, u / 0.1) * (1 - u) ** 0.8)
voice(b, 0.5, 0.95, moan, 0.55)
nz = Noise(short=True)
voice(b, 0.5, 0.95, lambda t, u: nz.step(3000 - 2000 * u) * 0.12 * (1 - u), 1)
voice(b, 1.5, 0.32, vwoop(1.3), 0.6)
save(b, "mob-enderman")

# ---------- CREEPER: pavio chiando subindo + tic-tac + pff
b = buf(1.7)
nz = Noise()
voice(b, 0.0, 1.25, lambda t, u: nz.step(1500 + 14000 * u ** 1.4) * (0.15 + 0.85 * u ** 1.2) * (0.75 + 0.25 * pulse(t * (8 + 20 * u), 0.5)), 0.9)
nz2 = Noise()
voice(b, 1.3, 0.35, lambda t, u: nz2.step(9000 - 8000 * u) * (1 - u) ** 3, 0.7)
voice(b, 1.3, 0.2, osc(lambda t, u: sweep(220, 70, u), lambda ph, t, u: pulse(ph) * (1 - u) ** 2), 0.4)
save(b, "mob-creeper")

# ---------- ZUMBI: uh... uhh... uuurgh
b = buf(1.8)
def groan(f0, f1, dur, at, amp):
    g = osc(lambda t, u: sweep(f0, f1, u) * (1 + 0.05 * math.sin(2 * math.pi * 9 * t)), lambda ph, t, u: pulse(ph, 0.4) * env_ad(u, 0.08, 1.0))
    voice(b, at, dur, g, amp)
    n_ = Noise(short=True)
    voice(b, at, dur, lambda t, u: n_.step(f0 * 6) * 0.18 * env_ad(u, 0.08, 1.0), amp)
groan(150, 130, 0.22, 0.0, 0.7)
groan(140, 115, 0.28, 0.57, 0.75)
groan(135, 70, 0.75, 0.98, 0.9)
save(b, "mob-zumbi")

# ---------- ESQUELETO: chocalho de ossos nos pulos + tec-tec
b = buf(1.5)
def clack(at, pitch, amp=0.8):
    n_ = Noise(short=True)
    voice(b, at, 0.045, lambda t, u: n_.step(pitch) * (1 - u) ** 2, amp)
    voice(b, at, 0.04, osc(lambda t, u: pitch / 9, lambda ph, t, u: pulse(ph, 0.125) * (1 - u) ** 3), amp * 0.6)
for k in range(5): clack(0.00 + k * 0.05, random.choice([7000, 9000, 11000]), 0.7 - k * 0.08)
for k in range(4): clack(0.57 + k * 0.05, random.choice([7000, 9000, 11000]), 0.6 - k * 0.08)
for k, p in enumerate([12000, 8000, 12000, 6000]): clack(0.98 + k * 0.11, p, 0.9)
save(b, "mob-esqueleto")

# ---------- GHAST: choro agudo com eco
b = buf(2.0)
def cry(at, amp):
    c = osc(lambda t, u: (sweep(520, 980, u / 0.35, 0.8) if u < 0.35 else sweep(980, 430, (u - 0.35) / 0.65)) * (1 + 0.035 * math.sin(2 * math.pi * 11 * t)),
            lambda ph, t, u: pulse(ph, 0.125) * env_ad(u, 0.05, 1.1))
    voice(b, at, 0.75, c, amp)
cry(0.0, 0.8); cry(0.22, 0.32); cry(0.44, 0.14)
cry(1.0, 0.45); cry(1.22, 0.18)
save(b, "mob-ghast")

# ---------- SLIME: boing molenga em cada pulo + splat
b = buf(1.4)
def squish(at, f0, f1, dur, amp):
    voice(b, at, dur, osc(lambda t, u: sweep(f0, f1, u, 0.6), lambda ph, t, u: pulse(ph, 0.5) * env_ad(u, 0.02, 2.0)), amp)
    n_ = Noise(short=True)
    voice(b, at, dur * 0.5, lambda t, u: n_.step(2500) * 0.25 * (1 - u) ** 2, amp)
squish(0.0, 520, 160, 0.2, 0.8)
squish(0.57, 600, 190, 0.17, 0.6)
squish(0.95, 260, 60, 0.32, 0.9)
voice(b, 1.12, 0.22, osc(lambda t, u: sweep(700, 1300, u), lambda ph, t, u: pulse(ph, 0.25) * env_ad(u, 0.02, 2)), 0.35)
save(b, "mob-slime")
print("ok")
