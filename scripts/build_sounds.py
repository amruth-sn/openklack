"""Build the OpenKlack sound catalog from permissively-licensed sources.

Run via: uv run --with soundfile,numpy scripts/build_sounds.py

Sources:
- tplai/kbsim (MIT) — per-key press/release MP3s for 5 switch sets.
- hainguyents13/mechvibes (MIT) — Everglide Oreo OGG sprite, sliced per its
  config.json offsets.
- Return-key ding — synthesized here from scratch (no external source).
"""

from __future__ import annotations

import json
import urllib.request
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parent.parent
SOUNDS = ROOT / "Resources" / "Sounds"

KBSIM_RAW = "https://raw.githubusercontent.com/tplai/kbsim/master/src/assets/audio"
MECHVIBES_RAW = "https://raw.githubusercontent.com/hainguyents13/mechvibes/main/src/audio"

KBSIM_LICENSE = """MIT License

Copyright (c) Thomas Lai

Audio samples from https://github.com/tplai/kbsim

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

MECHVIBES_LICENSE = KBSIM_LICENSE.replace(
    "Copyright (c) Thomas Lai", "Copyright (c) 2020 Nguyen Hai"
).replace(
    "Audio samples from https://github.com/tplai/kbsim",
    "Audio samples from https://github.com/hainguyents13/mechvibes (eg-oreo pack)",
)

# Klack switch name -> kbsim set. Stand-ins noted in ATTRIBUTION.md.
KBSIM_SETS = {
    "japanese-black": ("Japanese Black", "blackink", "Gateron Black Ink"),
    "cream": ("Cream", "cream", "NovelKeys Cream"),
    "super-red": ("Super Red", "redink", "Gateron Red Ink"),
    "milky-yellow": ("Milky Yellow", "alpaca", "Alpaca linear (stand-in)"),
    "cardboard": ("Cardboard", "topre", "Topre (dampened stand-in)"),
}

PRESS_FILES = ["GENERIC_R0", "GENERIC_R1", "GENERIC_R2", "GENERIC_R3",
               "GENERIC_R4", "SPACE", "ENTER", "BACKSPACE"]
RELEASE_FILES = ["GENERIC", "SPACE", "ENTER", "BACKSPACE"]


def fetch(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        return
    print(f"  GET {url}")
    temp = dest.with_name(dest.name + ".tmp")
    with urllib.request.urlopen(url, timeout=60) as resp:
        temp.write_bytes(resp.read())
    temp.replace(dest)


def kbsim_manifest(pack_id: str, name: str, real_switch: str) -> dict:
    def row(n: int) -> dict:
        return {"down": [f"press/GENERIC_R{n}.mp3"], "up": ["release/GENERIC.mp3"]}

    return {
        "id": pack_id,
        "name": name,
        "attribution": f"{real_switch} — samples from tplai/kbsim (MIT)",
        "license": "MIT",
        "keys": {
            "row0": row(0), "row1": row(1), "row2": row(2),
            "row3": row(3), "row4": row(4),
            "space": {"down": ["press/SPACE.mp3"], "up": ["release/SPACE.mp3"]},
            "enter": {"down": ["press/ENTER.mp3"], "up": ["release/ENTER.mp3"]},
            "backspace": {"down": ["press/BACKSPACE.mp3"], "up": ["release/BACKSPACE.mp3"]},
            "default": {
                "down": [f"press/GENERIC_R{n}.mp3" for n in range(5)],
                "up": ["release/GENERIC.mp3"],
            },
        },
    }


def build_kbsim_packs() -> None:
    for pack_id, (name, kbsim_set, real_switch) in KBSIM_SETS.items():
        print(f"pack {pack_id} <- kbsim/{kbsim_set}")
        pack_dir = SOUNDS / pack_id
        for f in PRESS_FILES:
            fetch(f"{KBSIM_RAW}/{kbsim_set}/press/{f}.mp3", pack_dir / "press" / f"{f}.mp3")
        for f in RELEASE_FILES:
            fetch(f"{KBSIM_RAW}/{kbsim_set}/release/{f}.mp3", pack_dir / "release" / f"{f}.mp3")
        (pack_dir / "pack.json").write_text(
            json.dumps(kbsim_manifest(pack_id, name, real_switch), indent=2))
        (pack_dir / "LICENSE").write_text(KBSIM_LICENSE)


# Mechvibes/iohook scancodes -> our key classes, for slicing the Oreo sprite.
OREO_SPECIALS = {57: "space", 28: "enter", 14: "backspace"}
OREO_ROWS = {
    "row0": [2, 3, 4, 5, 6, 7, 8, 9],       # number row
    "row1": [16, 17, 18, 19, 20, 21, 22],   # qwertyu
    "row2": [30, 31, 32, 33, 34, 35, 36],   # asdfghj
    "row3": [44, 45, 46, 47, 48, 49],       # zxcvbn
    "row4": [29, 42, 56, 54, 3675],         # modifiers
}
VARIANTS_PER_ROW = 4


def slice_oreo() -> None:
    print("pack oreo <- mechvibes/eg-oreo (sprite slice)")
    pack_dir = SOUNDS / "oreo"
    work = ROOT / "scripts" / ".cache" / "eg-oreo"
    fetch(f"{MECHVIBES_RAW}/eg-oreo/oreo.ogg", work / "oreo.ogg")
    fetch(f"{MECHVIBES_RAW}/eg-oreo/config.json", work / "config.json")

    config = json.loads((work / "config.json").read_text())
    if config.get("key_define_type", "single") != "single":
        raise SystemExit("eg-oreo config is no longer a single-sprite pack; "
                         "the offset slicing below only handles that layout")
    defines: dict[str, list[int] | None] = config["defines"]
    audio, sr = sf.read(work / "oreo.ogg", dtype="float32")
    if audio.ndim == 1:
        audio = audio[:, None]

    def cut(code: int) -> np.ndarray | None:
        span = defines.get(str(code))
        if not span:
            return None
        start = int(span[0] / 1000 * sr)
        length = int(span[1] / 1000 * sr)
        clip = audio[start:start + length].copy()
        if len(clip) < sr // 100:
            return None
        fade = min(int(0.005 * sr), len(clip))
        clip[-fade:] *= np.linspace(1, 0, fade)[:, None]
        peak = np.abs(clip).max()
        if peak < 1e-4:
            return None
        # Normalize toward -3 dBFS, boosting quiet slices at most 4x so the
        # pack sits at a similar loudness to the kbsim sets.
        return clip * min(4.0, 0.7 / peak)

    keys: dict[str, dict] = {}
    (pack_dir / "press").mkdir(parents=True, exist_ok=True)

    for code, cls in OREO_SPECIALS.items():
        clip = cut(code)
        if clip is None:
            continue
        rel = f"press/{cls}.wav"
        sf.write(pack_dir / rel, clip, sr, subtype="PCM_16")
        keys[cls] = {"down": [rel]}

    all_row_files: list[str] = []
    for cls, codes in OREO_ROWS.items():
        files = []
        for i, code in enumerate(codes):
            if len(files) >= VARIANTS_PER_ROW:
                break
            clip = cut(code)
            if clip is None:
                continue
            rel = f"press/{cls}_{i}.wav"
            sf.write(pack_dir / rel, clip, sr, subtype="PCM_16")
            files.append(rel)
        if files:
            keys[cls] = {"down": files}
            all_row_files.extend(files)
    keys["default"] = {"down": all_row_files or ["press/space.wav"]}

    manifest = {
        "id": "oreo",
        "name": "Oreo",
        "attribution": "Everglide Oreo — sliced from hainguyents13/mechvibes eg-oreo pack (MIT)",
        "license": "MIT",
        "gainDb": 0,
        "keys": keys,
    }
    (pack_dir / "pack.json").write_text(json.dumps(manifest, indent=2))
    (pack_dir / "LICENSE").write_text(MECHVIBES_LICENSE)


def synthesize_ding() -> None:
    """Typewriter-style bell, synthesized additively — original work, MIT."""
    print("extra: ding (synthesized)")
    sr = 48_000
    dur = 1.1
    t = np.linspace(0, dur, int(sr * dur), endpoint=False)
    base = 1244.5  # D#6-ish, classic margin-bell territory
    partials = [(1.0, 1.0, 6.0), (2.76, 0.55, 8.0), (5.40, 0.28, 11.0), (8.93, 0.12, 14.0)]
    tone = np.zeros_like(t)
    for ratio, amp, decay in partials:
        tone += amp * np.sin(2 * np.pi * base * ratio * t) * np.exp(-decay * t)
    strike = np.random.default_rng(7).normal(0, 1, len(t)) * np.exp(-t * 400) * 0.15
    ding = (tone + strike) * np.exp(-1.5 * t)
    ding /= np.abs(ding).max() * 2  # ~-6 dBFS
    out = SOUNDS / "_extras"
    out.mkdir(parents=True, exist_ok=True)
    sf.write(out / "ding.wav", np.column_stack([ding, ding]), sr, subtype="PCM_16")


def synthesize_mouse_clicks() -> None:
    """Short filtered noise ticks for mouse down/up — original work, MIT."""
    print("extras: mouse clicks (synthesized)")
    sr = 48_000
    rng = np.random.default_rng(11)
    out = SOUNDS / "_extras"
    out.mkdir(parents=True, exist_ok=True)
    for name, dur, decay, tone_hz, gain in [("click_down", 0.030, 260.0, 2900.0, 0.9),
                                            ("click_up", 0.024, 320.0, 3600.0, 0.7)]:
        t = np.linspace(0, dur, int(sr * dur), endpoint=False)
        noise = rng.normal(0, 1, len(t))
        # One-pole highpass to make it a crisp tick rather than a thud.
        hp = np.empty_like(noise)
        alpha = 0.88
        prev_x = prev_y = 0.0
        for i, x in enumerate(noise):
            prev_y = alpha * (prev_y + x - prev_x)
            prev_x = x
            hp[i] = prev_y
        body = 0.5 * np.sin(2 * np.pi * tone_hz * t)
        click = (hp * 0.8 + body) * np.exp(-decay * t)
        click *= gain / max(np.abs(click).max(), 1e-9) * 0.5
        sf.write(out / f"{name}.wav", np.column_stack([click, click]), sr, subtype="PCM_16")


def main() -> None:
    SOUNDS.mkdir(parents=True, exist_ok=True)
    build_kbsim_packs()
    slice_oreo()
    synthesize_ding()
    synthesize_mouse_clicks()
    total = sum(f.stat().st_size for f in SOUNDS.rglob("*") if f.is_file())
    print(f"done — catalog size: {total / 1_048_576:.1f} MB")


if __name__ == "__main__":
    main()
