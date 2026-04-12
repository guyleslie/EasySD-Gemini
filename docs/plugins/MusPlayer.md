# EasySD – MusPlayer Plugin

Plays Compute!'s Gazette SID Player `.MUS` music files on the C64 from an SD card.

---

## Overview

The plugin loads two files:

1. **`SIDPLAYER.PRG`** — external SID player engine (must be on SD card, assembled for `$9000`)
2. The selected `.MUS` file — music data loaded to `$8000`

The plugin auto-detects whether the `.MUS` file has a 2-byte PRG header (skip 2) or is raw (skip 0).

---

## File Format — MUS

| Property | Value |
|----------|-------|
| Extension | `.MUS` |
| Format | Compute!'s Gazette SID Player format |
| Size | Variable (header contains voice lengths) |
| Variants | RAW (no header) or PRG-wrapped (2-byte load address prepended) |

**MUS header structure** (at file offset 0 for RAW, offset 2 for PRG):

| Offset | Size | Content |
|--------|------|---------|
| 0 | 2 bytes | Voice 1 data length |
| 2 | 2 bytes | Voice 2 data length |
| 4 | 2 bytes | Voice 3 data length |
| 6+ | N bytes | Voice data (3 voices concatenated) |

The plugin validates that `6 + v1_len + v2_len + v3_len ≤ payload_size`.

---

## Required SD Card Files

| SD path | Description |
|---------|-------------|
| `/PLUGINS/MUSPLUGIN.PRG` | This plugin binary |
| `/PLUGINS/SIDPLAYER.PRG` | SID player engine (assembled for `$9000`) |
| `<any path>/<song>.MUS` | Music file selected from menu |

`SIDPLAYER.PRG` is expected to have a standard 2-byte PRG load header (`$00 $90`).

In this repository the canonical binary is `Tools/ComputeSidPlayer.prg`, and
`python Tools/build.py plugins` stages it automatically as `build/plugins/sidplayer.prg`.

---

## Memory Layout (C64 side)

| Address | Content |
|---------|---------|
| `$8000–$9FFF` | Song data (`.MUS` payload) |
| `$9000–$BFFF` | SID player engine (`SIDPLAYER.PRG` payload, skip 2) |

Note: The SID player is loaded first, then the song data. `$8000` and `$9000` partially overlap
only if the song exceeds 4 KB — in practice, most `.MUS` files are much smaller.

---

## API Calls Used

| Call | Purpose |
|------|---------|
| `PROT_StartTalking` | Wake Arduino at plugin init |
| `PROT_OpenFile` | Open `SIDPLAYER.PRG` then the `.MUS` file |
| `PROT_ReadFileNoCallback` | Read first page (256 bytes) for header sniffing |
| `PROT_GetInfoForFile` | Get exact file size from FAT entry |
| `LoadFileBySize` | Load file payload |
| `PROT_CloseFile` | Close file after load |
| `PROT_EndTalking` | End Arduino session at shutdown |
| `PROT_ExitToMenu` | Return to EasySD menu |

Macros: `#OPENFILE`, `#SETADDR`, `#EXTRACTFILESIZE` (Tier 2).

CIA1 Timer A is set up for SID player timing (player provides `$DC04`/`$DC05` values).

---

## Controls

| Key | Action |
|-----|--------|
| SPACE | Stop playback and exit to menu |
| RUN/STOP | Stop playback and exit to menu |

---

## Known Limitations

- `/PLUGINS/SIDPLAYER.PRG` must be present on the SD card. If not found, the plugin exits with an error.
- The SID player engine is not bundled — it must be obtained separately and placed on the SD card.
- Stereo or multi-SID songs are not supported (single SID chip only).
- CIA1 Timer A is reconfigured for playback; other timer-dependent code will be affected.

---

## Source and Build

| Item | Path |
|------|------|
| Source | `EasySD/Plugins/MusPlayer/MusPlayer.s` |
| Player symbols | `EasySD/Plugins/MusPlayer/ComputePlayerSymbols.inc` |
| Build output | `EasySD/build/plugins/musplugin.prg` |
| SD card path | `/PLUGINS/MUSPLUGIN.PRG` |

```bash
python Tools/build.py plugins
```
