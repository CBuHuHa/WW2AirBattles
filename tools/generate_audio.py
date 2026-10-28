#!/usr/bin/env python3
# generate_audio.py
# Purpose: Детерминированная генерация ПЛЕЙСХОЛДЕРНЫХ аудио-ассетов M3-D по GDD «Audio» +
#          таблица «Assets» (music_loop, sfx_combat, sfx_bomb, sfx_ui; source = placeholder).
#          Никаких внешних сэмплов, сети и ffmpeg: только stdlib (wave, struct, math, random,
#          array). Все звуки синтезируются аддитивно/шумом на месте.
# Output:  assets/audio/music_loop.wav + 8 SFX (mono, 22050 Hz, 16-bit PCM, пик −3 dBFS).
# Run:     python tools/generate_audio.py        (из любого каталога; корень = родитель tools/)
# Notes:   seed фиксирован → повторный запуск даёт побайтово те же WAV.
#          Файлы — плейсхолдеры: их можно заменить финальными WAV с теми же именами,
#          код (AudioManager) при этом не меняется. См. assets/audio/README.md.
# Author:  Game Feel Developer Agent

from __future__ import annotations

import array
import math
import random
import sys
import time
import wave
from pathlib import Path

# ─── Формат (GDD/промпт M3-D) ────────────────────────────────────────────────
SR = 22050
CHANNELS = 1
SAMPLE_WIDTH = 2          # 16-bit PCM
PEAK_DBFS = -3.0          # нормализация пика
SEED = 20261027           # детерминированность

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "assets" / "audio"

# ─── Музыкальная сетка: 120 BPM, 4/4, A minor, 32 такта = 64 с ───────────────
BPM = 120.0
BEAT = 60.0 / BPM         # 0.5 с
BAR = BEAT * 4.0          # 2.0 с
BARS = 32
TOTAL = BARS * BAR        # 64.0 с
FADE = 0.015              # 15 мс fade на стыке лупа (без щелчка)

# Аккорд → (низкая база MIDI, триада MIDI для подложки, триада MIDI для остинато).
CHORDS = {
    "Am": (45, (57, 60, 64), (45, 48, 52)),
    "F": (41, (53, 57, 60), (41, 45, 48)),
    "C": (48, (48, 52, 55), (48, 52, 55)),
    "G": (43, (43, 47, 50), (43, 47, 50)),
    "Dm": (50, (50, 53, 57), (50, 53, 57)),
    "E": (40, (40, 44, 47), (40, 44, 47)),
}
# 8 тактов × 4 фразы; финальный E → луп возвращается в Am.
PROGRESSION = [
    "Am", "F", "C", "G", "Am", "F", "E", "E",
    "Am", "F", "C", "G", "Dm", "F", "E", "Am",
    "Am", "F", "C", "G", "Am", "F", "E", "E",
    "Am", "F", "C", "G", "Dm", "Am", "E", "E",
]
# Мотив валторны (такт, доля, MIDI, длительность в долях) — 8-тактовая фраза.
HORN_MOTIF = [
    (0, 0.0, 64, 2.0), (1, 0.0, 62, 2.0), (2, 0.0, 60, 3.0), (3, 0.0, 59, 1.0),
    (4, 0.0, 57, 2.0), (5, 0.0, 60, 2.0), (6, 0.0, 59, 2.0), (7, 0.0, 64, 2.0),
    (8, 0.0, 64, 1.5), (8, 1.5, 65, 0.5), (9, 0.0, 64, 2.0), (10, 0.0, 62, 2.0),
    (11, 0.0, 60, 2.0), (12, 0.0, 62, 2.0), (13, 0.0, 64, 2.0), (14, 0.0, 59, 3.0),
    (15, 0.0, 57, 2.0),
]
# Остинато виолончели: индексы триада → 8 восьмых в такте.
OSTINATO = [0, 1, 2, 1, 0, 2, 1, 0]


# ─── Базовые помощники синтеза ───────────────────────────────────────────────
def midi_hz(note: int) -> float:
    return 440.0 * (2.0 ** ((note - 69) / 12.0))


def db_to_amp(db: float) -> float:
    return 10.0 ** (db / 20.0)


def amp_to_db(amp: float) -> float:
    return -200.0 if amp <= 1e-12 else 20.0 * math.log10(amp)


def silence(seconds: float) -> list[float]:
    return [0.0] * int(round(seconds * SR))


def add_tone(buf, start, dur, freq, amp=1.0, partials=((1.0, 1.0),),
             attack=0.008, release=0.08, decay=0.0, pitch_drop=0.0,
             pitch_time=0.05, vibrato=0.0, vibrato_rate=5.0):
    """Добавить в buf тон с накоплением фазы (поддерживает глиссандо/вибрато)."""
    begin = int(round(start * SR))
    count = int(round(dur * SR))
    if begin < 0:
        begin = 0
    count = min(count, len(buf) - begin)
    if count <= 0:
        return
    attack_n = max(1, int(attack * SR))
    release_n = max(1, int(release * SR))
    two_pi = 2.0 * math.pi
    phase = 0.0
    for i in range(count):
        t = i / SR
        f = freq
        if pitch_drop:
            f *= 1.0 + pitch_drop * math.exp(-t / pitch_time)
        if vibrato:
            f *= 1.0 + vibrato * math.sin(two_pi * vibrato_rate * t)
        phase += two_pi * f / SR
        env = 1.0
        if i < attack_n:
            env = i / attack_n
        left = count - i
        if left < release_n:
            env *= left / release_n
        if decay:
            env *= math.exp(-t / decay)
        s = 0.0
        for mult, weight in partials:
            s += weight * math.sin(phase * mult)
        buf[begin + i] += amp * env * s


def add_noise(buf, start, dur, amp, rng, attack=0.002, release=0.01, decay=0.0,
              lowpass=0.0, highpass=0.0):
    """Шумовой слой с однополюсными ФВЧ/ФНЧ (приближение, без scipy)."""
    begin = int(round(start * SR))
    count = int(round(dur * SR))
    if begin < 0:
        begin = 0
    count = min(count, len(buf) - begin)
    if count <= 0:
        return
    attack_n = max(1, int(attack * SR))
    release_n = max(1, int(release * SR))
    lp = 0.0
    hp = 0.0
    lp_a = 1.0 - math.exp(-2.0 * math.pi * lowpass / SR) if lowpass > 0 else 1.0
    hp_a = 1.0 - math.exp(-2.0 * math.pi * highpass / SR) if highpass > 0 else 1.0
    for i in range(count):
        t = i / SR
        x = rng.uniform(-1.0, 1.0)
        if lowpass > 0:
            lp += lp_a * (x - lp)
            x = lp
        if highpass > 0:
            hp += hp_a * (x - hp)
            x -= hp
        env = 1.0
        if i < attack_n:
            env = i / attack_n
        left = count - i
        if left < release_n:
            env *= left / release_n
        if decay:
            env *= math.exp(-t / decay)
        buf[begin + i] += amp * env * x


def fade_edges(buf, seconds):
    n = min(int(round(seconds * SR)), len(buf) // 2)
    for i in range(n):
        g = i / n
        buf[i] *= g
        buf[-1 - i] *= g


def normalize(buf, peak_db=PEAK_DBFS):
    peak = max((abs(x) for x in buf), default=0.0)
    if peak <= 1e-12:
        return 0.0
    gain = db_to_amp(peak_db) / peak
    for i, x in enumerate(buf):
        buf[i] = x * gain
    return gain


def wav_write(path: Path, buf) -> int:
    ints = array.array("h", (int(max(-1.0, min(1.0, x)) * 32767) for x in buf))
    if sys.byteorder == "big":
        ints.byteswap()
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(CHANNELS)
        wf.setsampwidth(SAMPLE_WIDTH)
        wf.setframerate(SR)
        wf.writeframes(ints.tobytes())
    return len(ints) * SAMPLE_WIDTH


def stats(buf):
    peak = max((abs(x) for x in buf), default=0.0)
    rms = math.sqrt(sum(x * x for x in buf) / max(1, len(buf)))
    return peak, rms


# ─── Музыка ──────────────────────────────────────────────────────────────────
def build_music() -> list[float]:
    buf = silence(TOTAL)
    rng = random.Random(SEED)

    # 1) Дрон низких струн: база аккорда на октаву ниже + квинта, с мягкой атакой.
    for bar_index in range(BARS):
        root_midi = CHORDS[PROGRESSION[bar_index]][0]
        start = bar_index * BAR
        for note_offset, amp, detune in ((-12, 0.085, 0.0), (-5, 0.055, 0.0015)):
            freq = midi_hz(root_midi + note_offset)
            add_tone(buf, start, BAR * 1.05, freq, amp,
                     partials=((1.0, 1.0), (2.0, 0.22), (3.0, 0.10)),
                     attack=0.22, release=0.42)
            add_tone(buf, start, BAR * 1.05, freq * (1.0 + detune), amp * 0.5,
                     partials=((1.0, 1.0),), attack=0.22, release=0.42)

    # 2) Виолончельное остинато: 8 восьмых в такте, стаккато, маршевый пульс.
    for bar_index in range(BARS):
        triad = CHORDS[PROGRESSION[bar_index]][2]
        for step, index in enumerate(OSTINATO):
            start = bar_index * BAR + step * (BEAT / 2.0)
            accent = 0.16 if step % 4 == 0 else 0.115
            add_tone(buf, start, 0.20, midi_hz(triad[index]), accent,
                     partials=((1.0, 1.0), (2.0, 0.45), (3.0, 0.26), (4.0, 0.12)),
                     attack=0.008, release=0.055, decay=0.55)

    # 3) Литавры на сильных долях: такт 1 — база, такт 3 — квинта.
    for bar_index in range(BARS):
        root_midi = CHORDS[PROGRESSION[bar_index]][0]
        for beat, offset in ((0.0, -12), (2.0, -5)):
            start = bar_index * BAR + beat * BEAT
            add_tone(buf, start, 0.9, midi_hz(root_midi + offset), 0.28,
                     partials=((1.0, 1.0), (1.5, 0.28), (2.0, 0.18)),
                     attack=0.004, release=0.18, decay=0.32, pitch_drop=0.55,
                     pitch_time=0.07)
            add_noise(buf, start, 0.12, 0.07, rng, attack=0.002, release=0.05,
                      decay=0.045, lowpass=150.0)

    # 4) Малый барабан: маршевые доли 2 и 4 + редкие 16-е «дроби».
    for bar_index in range(BARS):
        for beat in (1.0, 3.0):
            start = bar_index * BAR + beat * BEAT
            add_noise(buf, start, 0.10, 0.085, rng, attack=0.001, release=0.02,
                      decay=0.028, highpass=1200.0)
            add_tone(buf, start, 0.05, 195.0, 0.05,
                     partials=((1.0, 1.0), (1.6, 0.4)), attack=0.001, release=0.02,
                     decay=0.02)
        if bar_index % 8 == 7:
            for step in range(4):
                start = bar_index * BAR + (3.5 + step * 0.125) * BEAT
                add_noise(buf, start, 0.06, 0.045, rng, attack=0.001, release=0.015,
                          decay=0.018, highpass=1500.0)

    # 5) Сдержанный мотив валторны: две 8-тактовые фразы.
    for phrase in range(2):
        for bar_index, beat, note, beats in HORN_MOTIF:
            start = (bar_index + phrase * 16) * BAR + beat * BEAT
            add_tone(buf, start, beats * BEAT * 0.98, midi_hz(note),
                     0.105 if phrase == 0 else 0.095,
                     partials=((1.0, 1.0), (2.0, 0.32), (3.0, 0.14)),
                     attack=0.11, release=0.22, vibrato=0.004, vibrato_rate=4.8)

    # 6) Тихая подложка: триада по такту, две расстроенные синусоиды (лёгкое биение).
    for bar_index in range(BARS):
        pad_notes = CHORDS[PROGRESSION[bar_index]][1]
        start = bar_index * BAR
        for note in pad_notes:
            freq = midi_hz(note)
            add_tone(buf, start, BAR + 0.3, freq, 0.038,
                     partials=((1.0, 1.0),), attack=0.45, release=0.55)
            add_tone(buf, start, BAR + 0.3, freq * 1.0035, 0.024,
                     partials=((1.0, 1.0),), attack=0.55, release=0.55)

    # Точный луп: 64.000 с, короткий fade 15 мс по краям (первый/последний сэмпл = 0).
    fade_edges(buf, FADE)
    normalize(buf)
    return buf


# ─── SFX ─────────────────────────────────────────────────────────────────────
def sfx_player_shot(rng):
    buf = silence(0.06)
    add_noise(buf, 0.0, 0.05, 0.55, rng, attack=0.0008, release=0.012,
              decay=0.014, highpass=2200.0)
    add_tone(buf, 0.0, 0.055, 1500.0, 0.42, partials=((1.0, 1.0), (2.0, 0.22)),
             attack=0.0008, release=0.015, decay=0.016, pitch_drop=-0.35,
             pitch_time=0.02)
    add_tone(buf, 0.0, 0.02, 700.0, 0.18, partials=((1.0, 1.0),),
             attack=0.0005, release=0.008, decay=0.008)
    return buf


def sfx_enemy_hit(rng):
    buf = silence(0.05)
    add_tone(buf, 0.0, 0.045, 2650.0, 0.42, partials=((1.0, 1.0),),
             attack=0.0006, release=0.012, decay=0.013)
    add_tone(buf, 0.0, 0.04, 3950.0, 0.28, partials=((1.0, 1.0),),
             attack=0.0006, release=0.010, decay=0.009)
    add_noise(buf, 0.0, 0.04, 0.30, rng, attack=0.0006, release=0.010,
              decay=0.010, highpass=3000.0)
    return buf


def sfx_player_hit(rng):
    buf = silence(0.20)
    add_tone(buf, 0.0, 0.19, 120.0, 0.75,
             partials=((1.0, 1.0), (2.0, 0.35), (3.0, 0.18)),
             attack=0.001, release=0.06, decay=0.065, pitch_drop=-0.55,
             pitch_time=0.055)
    add_noise(buf, 0.0, 0.16, 0.42, rng, attack=0.001, release=0.05,
              decay=0.075, lowpass=420.0)
    add_noise(buf, 0.0, 0.05, 0.18, rng, attack=0.0008, release=0.02,
              decay=0.02, highpass=1800.0)
    return buf


def sfx_enemy_explosion(rng):
    buf = silence(0.42)
    add_noise(buf, 0.0, 0.34, 0.70, rng, attack=0.003, release=0.10,
              decay=0.115, lowpass=900.0)
    add_noise(buf, 0.0, 0.40, 0.50, rng, attack=0.004, release=0.14,
              decay=0.18, lowpass=210.0)
    add_tone(buf, 0.0, 0.36, 78.0, 0.55,
             partials=((1.0, 1.0), (2.0, 0.25)),
             attack=0.002, release=0.12, decay=0.16, pitch_drop=-0.45,
             pitch_time=0.12)
    add_noise(buf, 0.0, 0.06, 0.25, rng, attack=0.001, release=0.02,
              decay=0.022, highpass=2500.0)
    return buf


def sfx_bomb(rng):
    buf = silence(1.0)
    add_tone(buf, 0.0, 0.95, 72.0, 0.85,
             partials=((1.0, 1.0), (2.0, 0.30), (3.0, 0.12)),
             attack=0.002, release=0.30, decay=0.36, pitch_drop=-0.58,
             pitch_time=0.22)
    add_noise(buf, 0.0, 0.90, 0.65, rng, attack=0.004, release=0.32,
              decay=0.40, lowpass=190.0)
    add_noise(buf, 0.0, 0.80, 0.42, rng, attack=0.006, release=0.30,
              decay=0.55, lowpass=62.0)
    add_noise(buf, 0.0, 0.09, 0.30, rng, attack=0.001, release=0.03,
              decay=0.03, highpass=2000.0)
    return buf


def sfx_pickup(rng):
    buf = silence(0.23)
    add_tone(buf, 0.0, 0.10, 720.0, 0.45, partials=((1.0, 1.0), (2.0, 0.30)),
             attack=0.004, release=0.03, decay=0.09)
    add_tone(buf, 0.095, 0.13, 1080.0, 0.45, partials=((1.0, 1.0), (2.0, 0.30)),
             attack=0.004, release=0.05, decay=0.11)
    add_tone(buf, 0.095, 0.13, 1620.0, 0.14, partials=((1.0, 1.0),),
             attack=0.004, release=0.05, decay=0.09)
    return buf


def sfx_boss_alarm(rng):
    buf = silence(1.1)
    step = 0.1375
    for i in range(8):
        freq = 440.0 if i % 2 == 0 else 620.0
        add_tone(buf, i * step, step * 0.98, freq, 0.34,
                 partials=((1.0, 1.0), (2.0, 0.28), (3.0, 0.14)),
                 attack=0.008, release=0.03, vibrato=0.006, vibrato_rate=6.0)
        add_tone(buf, i * step, step * 0.98, freq * 0.5, 0.10,
                 partials=((1.0, 1.0),), attack=0.010, release=0.03)
    add_noise(buf, 0.0, 1.05, 0.05, rng, attack=0.05, release=0.10,
              lowpass=900.0)
    return buf


def sfx_ui_click(rng):
    buf = silence(0.04)
    add_tone(buf, 0.0, 0.035, 1750.0, 0.55, partials=((1.0, 1.0),),
             attack=0.0005, release=0.010, decay=0.008)
    add_noise(buf, 0.0, 0.02, 0.22, rng, attack=0.0005, release=0.006,
              decay=0.005, highpass=4000.0)
    return buf


SFX_BUILDERS = [
    ("player_shot", sfx_player_shot, 0.05, 0.07),
    ("enemy_hit", sfx_enemy_hit, 0.05, 0.05),
    ("player_hit", sfx_player_hit, 0.20, 0.20),
    ("enemy_explosion", sfx_enemy_explosion, 0.35, 0.45),
    ("bomb", sfx_bomb, 0.90, 1.10),
    ("pickup", sfx_pickup, 0.20, 0.25),
    ("boss_alarm", sfx_boss_alarm, 1.00, 1.20),
    ("ui_click", sfx_ui_click, 0.03, 0.05),
]


# ─── Отчёт ───────────────────────────────────────────────────────────────────
def print_report(rows, total_bytes):
    print("")
    print(f"{'file':<22}{'dur, s':>8}{'peak dBFS':>11}{'rms dBFS':>10}{'bytes':>10}")
    print("-" * 62)
    for name, dur, peak, rms, size in rows:
        print(f"{name:<22}{dur:>8.3f}{amp_to_db(peak):>11.2f}{amp_to_db(rms):>10.2f}{size:>10}")
    print("-" * 62)
    print(f"total: {total_bytes} bytes ({total_bytes / (1024 * 1024):.2f} MiB)")


def main() -> int:
    started = time.time()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    rows = []
    total_bytes = 0

    music = build_music()
    assert len(music) == int(round(TOTAL * SR)), f"music length {len(music)} != {TOTAL * SR}"
    music_path = OUT_DIR / "music_loop.wav"
    size = wav_write(music_path, music)
    peak, rms = stats(music)
    rows.append(("music_loop.wav", len(music) / SR, peak, rms, size))
    total_bytes += size
    first, last = music[0], music[-1]
    seam_ok = abs(first) < 1e-4 and abs(last) < 1e-4
    print(f"music_loop.wav: {len(music)} samples = {len(music) / SR:.3f} s, "
          f"bars={BARS} @ {BPM:.0f} BPM, loop seam first={first:+.6f} last={last:+.6f} "
          f"({'OK' if seam_ok else 'WARN: щелчок на стыке'})")

    for index, (name, builder, min_dur, max_dur) in enumerate(SFX_BUILDERS):
        rng = random.Random(SEED + 101 * (index + 1))
        buf = builder(rng)
        fade_edges(buf, 0.002)   # 2 мс по краям — без щелчков на старте/хвосте
        normalize(buf)
        peak, rms = stats(buf)
        path = OUT_DIR / f"{name}.wav"
        size = wav_write(path, buf)
        total_bytes += size
        rows.append((f"{name}.wav", len(buf) / SR, peak, rms, size))
        dur = len(buf) / SR
        if not (min_dur - 0.001 <= dur <= max_dur + 0.001):
            print(f"WARN  {name}: длительность {dur:.3f} с вне диапазона "
                  f"{min_dur:.2f}–{max_dur:.2f} с")

    print_report(rows, total_bytes)
    print(f"peak target: {PEAK_DBFS:.1f} dBFS, format: mono {SR} Hz 16-bit PCM, "
          f"seed={SEED}, elapsed={time.time() - started:.1f} s")
    if total_bytes > 4 * 1024 * 1024:
        print("WARN  суммарный размер > 4 МБ")
        return 1
    print(f"OK  files written to {OUT_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
