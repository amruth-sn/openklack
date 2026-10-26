# OpenKlack

Satisfying mechanical-keyboard sound with every keystroke — a free, open-source
macOS menu bar app inspired by [Klack](https://tryklack.com/).

Native Swift + SwiftUI + AVAudioEngine. No Electron, no network, no analytics,
no keystroke logging. The whole app bundle is **~2 MB**.

> OpenKlack is an independent project, not affiliated with or endorsed by
> Klack or Henrik Ruscon. If you want the original (it's great), buy it —
> it's $4.99.

## Features

- **Six switch sets** — Japanese Black, Cream, Milky Yellow, Super Red,
  Cardboard, Oreo (see [ATTRIBUTION.md](ATTRIBUTION.md) for what was actually
  recorded)
- **Distinct keydown / keyup sounds**, with dedicated samples for space,
  return, backspace, and per-row variation across the board
- **Randomized pitch** on every stroke so no two keystrokes sound identical
- **Tone Pad** — drag to darken/brighten (EQ tilt) and lower/raise pitch;
  plus a pitch-randomization amount slider
- **Volume slider** with Soft / Balanced / Loud presets, independent of
  system volume
- **Stereo spread** — keys pan subtly by their physical position on the board
- **⌘⌃K** global hotkey to toggle sounds
- Mute modifier keys, function-key audibility toggle
- **Ding on return** (typewriter margin bell), **mouse click sounds**
- Output device picker (play through any device, independent of default)
- Haptic feedback (Force Touch trackpads)
- Keystroke stats (today / all-time), notification on switch change,
  launch at login
- Works with any keyboard — internal, external, whatever

## Install

```sh
git clone https://github.com/amruth-sn/openklack && cd openklack
make            # builds dist/OpenKlack.app
make run        # or: open dist/OpenKlack.app
```

Requires macOS 13+ to run; Xcode command-line tools to build.

On first launch, grant **Accessibility** permission
(System Settings → Privacy & Security → Accessibility).

> **After rebuilding:** the app is ad-hoc signed, and macOS ties the
> Accessibility grant to the exact binary hash. A rebuilt app shows as
> "granted" in System Settings but isn't actually trusted. Fix:
> `tccutil reset Accessibility dev.openklack.OpenKlack`, relaunch, and
> grant again. (Signing with a real developer identity avoids this —
> `make bundle CODESIGN_ID="Apple Development: you@example.com"`.) OpenKlack uses it
solely to hear key up/down events and play a sound — nothing is stored or
transmitted. The code that touches key events is ~90 lines in
[`KeyListener.swift`](Sources/OpenKlack/KeyListener.swift); audit it yourself.

## Klack parity

| Klack feature | OpenKlack |
|---|---|
| 6 switch sound sets | ✅ (2 are sonic stand-ins — see ATTRIBUTION.md) |
| Up/down keystroke samples | ✅ (Oreo is down-only; upstream source has no release samples) |
| Randomized pitching | ✅ |
| Tone Pad tuning | ✅ (EQ tilt × pitch offset) |
| Volume presets + slider | ✅ |
| Toggle hotkey ⌘⌃K | ✅ |
| Mute modifiers / function keys | ✅ |
| Ding on return | ✅ (synthesized) |
| Mouse click sounds | ✅ (synthesized) |
| Numpad support | ✅ |
| Output device selection | ✅ |
| Spatial audio | ◐ per-key stereo panning; no head-tracked 3D |
| Usage stats | ✅ today + all-time |
| Switch-change notifications | ✅ |
| Launch at login | ✅ |
| Haptic feedback | ✅ |
| Dynamic menu bar icon | ✅ (filled = on, outline = off) |
| AppleScript support | ❌ not yet |
| Sleep automation / idle mode | ❌ not yet |
| Menu bar icon opacity / click actions | ❌ not yet |

## Sounds

The catalog is built by [`scripts/build_sounds.py`](scripts/build_sounds.py)
from MIT-licensed sources ([tplai/kbsim](https://github.com/tplai/kbsim) and
the [mechvibes](https://github.com/hainguyents13/mechvibes) bundled packs),
plus two fully synthesized extras. Rebuild it any time with `make sounds`
(needs [uv](https://docs.astral.sh/uv/)).

### Adding your own switch set

Drop a folder into `Resources/Sounds/<your-pack>/` containing samples and a
`pack.json`:

```json
{
  "id": "my-pack",
  "name": "My Pack",
  "keys": {
    "default":   {"down": ["press/key1.wav", "press/key2.wav"], "up": ["release/key.wav"]},
    "space":     {"down": ["press/space.wav"], "up": ["release/space.wav"]},
    "enter":     {"down": ["press/enter.wav"]},
    "backspace": {"down": ["press/backspace.wav"]},
    "row0":      {"down": ["press/num_row.wav"]}
  }
}
```

`default` is required; `space`, `enter`, `backspace`, and `row0`–`row4`
(top row → bottom row) are optional and fall back to `default`. Arrays are
random-choice variants. WAV, MP3, CAF, AIFF, and M4A all work. Then
`make bundle`.

## Development

```sh
make test    # headless smoke test: decodes + plays every pack
swift build  # debug build
```

Architecture: `KeyListener` (NSEvent global monitors) → `AppState` (settings,
stats, routing) → `SoundEngine` (AVAudioEngine: 20-voice pool → per-voice
varispeed → submix → tilt EQ → main mix). Sample buffers are fully decoded
into memory at pack load, so playback is a single `scheduleBuffer` call —
effectively zero latency.

## License

MIT — see [LICENSE](LICENSE) and [ATTRIBUTION.md](ATTRIBUTION.md).
