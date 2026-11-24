# Sons do Sísifo (sintetizados, sem samples): python3 tools/sons_sisifo.py sounds/
# Tema: a pedra, o morro, o topo e a volta.
import math, random, struct, sys, wave

SR = 44100
OUT = sys.argv[1] if len(sys.argv) > 1 else 'sounds'
random.seed(7)


def buf(sec):
    return [0.0] * int(SR * sec)


def lowpass(x, fc):
    a = math.exp(-2 * math.pi * fc / SR)
    y, out = 0.0, []
    for v in x:
        y = (1 - a) * v + a * y
        out.append(y)
    return out


def highpass(x, fc):
    lp = lowpass(x, fc)
    return [v - l for v, l in zip(x, lp)]


def noise(n):
    return [random.uniform(-1, 1) for _ in range(n)]


def add(b, at, sig, amp=1.0):
    s0 = int(at * SR)
    for i, v in enumerate(sig):
        if s0 + i < len(b):
            b[s0 + i] += amp * v


def thud(dur=0.45, f0=95, f1=42, body=1.0, grit=0.5):
    """pancada de pedra pesada: grave que cai + poeirinha"""
    n = int(dur * SR)
    out, ph = [], 0.0
    nz = lowpass(noise(n), 900)
    for i in range(n):
        u = i / n
        f = f1 + (f0 - f1) * math.exp(-u * 9)
        ph += 2 * math.pi * f / SR
        env = min(1, i / (0.002 * SR)) * math.exp(-u * 7)
        out.append(body * env * math.sin(ph) + grit * nz[i] * math.exp(-u * 22))
    return out


def knock(f=820, dur=0.09, amp=1.0):
    """toque seco em pedra: dois parciais inarmônicos bem curtos + clique"""
    n = int(dur * SR)
    out = []
    cl = highpass(noise(n), 2500)
    for i in range(n):
        t = i / SR
        e = math.exp(-t * 55)
        v = 0.7 * math.sin(2 * math.pi * f * t) + 0.35 * math.sin(2 * math.pi * f * 2.31 * t) * math.exp(-t * 30)
        out.append(amp * (e * v + 0.5 * cl[i] * math.exp(-t * 400)))
    return out


def chime(f=880, dur=0.9, amp=0.5):
    """sininho de pedra (marimba de rocha) pro "chegou no topo" """
    n = int(dur * SR)
    out = []
    for i in range(n):
        t = i / SR
        v = (math.sin(2 * math.pi * f * t) * math.exp(-t * 4.5)
             + 0.45 * math.sin(2 * math.pi * f * 3.98 * t) * math.exp(-t * 11)
             + 0.2 * math.sin(2 * math.pi * f * 1.5 * t) * math.exp(-t * 6))
        out.append(amp * v * min(1, i / (0.003 * SR)))
    return out


def rumble(dur=1.2, fc=180, bumps=9, amp=1.0, descer=True):
    """pedra rolando: ronco grave com batidinhas irregulares"""
    n = int(dur * SR)
    r = lowpass(lowpass(noise(n), fc), fc * 1.4)
    pico = max(abs(v) for v in r) or 1
    r = [v / pico for v in r]
    marcas = sorted(random.uniform(0.04, dur - 0.08) for _ in range(bumps))
    out = []
    for i in range(n):
        t = i / SR
        u = t / dur
        env = min(1, t / 0.08) * (1 - u) ** (1.4 if descer else 0.6)
        mod = 0.55 + 0.45 * math.sin(2 * math.pi * (7 + 3 * u) * t + 1.3 * math.sin(2 * math.pi * 2.1 * t))
        out.append(amp * env * mod * r[i])
    for m in marcas:
        add(out, m, thud(0.12, 140, 70, 0.5, 0.6), 0.5 * (1 - m / dur))
    return out


def echo(x, delays=((0.19, 0.45), (0.41, 0.25), (0.66, 0.12))):
    extra = int((max(d for d, _ in delays) + 0.05) * SR)
    out = x + [0.0] * extra
    for d, g in delays:
        lp = lowpass(x, 1200)
        add(out, d, lp, g)
    return out


def finalizar(b, nome, pico=0.89):
    m = max(abs(v) for v in b) or 1
    b = [v / m * pico for v in b]
    fade = int(0.02 * SR)
    for i in range(fade):
        b[-1 - i] *= i / fade
    with wave.open(f'{OUT}/{nome}.wav', 'w') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b''.join(struct.pack('<h', int(max(-1, min(1, v)) * 32767)) for v in b))
    print(nome, f'{len(b) / SR:.2f}s')


# 1 pedra rolando morro abaixo (a caixa encheu de novo)
b = buf(1.5); add(b, 0, rumble(1.35, 170, 10)); add(b, 1.28, thud(0.2, 90, 50, 0.6, 0.3), 0.5)
finalizar(b, 'pedra-rolando')

# 2 chegou no topo: pancada firme + sininho de pedra subindo
b = buf(1.3); add(b, 0, thud(0.4, 110, 48, 1.0, 0.45)); add(b, 0.16, chime(660, 0.8, 0.35)); add(b, 0.27, chime(990, 0.9, 0.3))
finalizar(b, 'pedra-topo')

# 3 toque na pedra: dois toques secos (o mais discreto)
b = buf(0.45); add(b, 0, knock(760)); add(b, 0.13, knock(980, amp=0.8))
finalizar(b, 'toque-pedra')

# 4 rachadura: estalo + pedrinhas caindo
b = buf(1.0)
add(b, 0, [v * math.exp(-i / (0.012 * SR)) for i, v in enumerate(highpass(noise(int(0.06 * SR)), 1800))], 1.0)
add(b, 0.01, thud(0.18, 180, 90, 0.5, 0.2), 0.6)
t = 0.08
while t < 0.85:
    add(b, t, knock(random.uniform(1400, 2600), 0.04, random.uniform(0.15, 0.4) * (1 - t)), 1.0)
    t += random.uniform(0.03, 0.09)
finalizar(b, 'rachadura')

# 5 eco do morro: pancada grave lá embaixo e o morro respondendo
b = echo(thud(0.5, 80, 38, 1.0, 0.35))
finalizar(b, 'eco-morro')

# 6 empurrão: arrasto (atrito de pedra) subindo e um tum no fim
n = int(0.7 * SR)
arr = lowpass(noise(n), 700)
arr = [v * min(1, i / (0.15 * SR)) * (0.6 + 0.4 * math.sin(2 * math.pi * 11 * i / SR)) for i, v in enumerate(arr)]
b = buf(1.15); add(b, 0, arr, 1.6); add(b, 0.68, thud(0.45, 100, 45, 1.0, 0.4))
finalizar(b, 'empurrao')
