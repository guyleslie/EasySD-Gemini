# EasySD Plugin Development Guide

Plugins are standalone 6502 programs loaded from `/PLUGINS/` on the SD card.
When the user selects a file whose extension maps to a plugin, the menu loads
`/PLUGINS/<EXT>PLUGIN.PRG` to `$C000` and jumps to `$C000`.

This guide is intentionally behavior-focused. Treat the current source code as the primary reference, and use this file as a compact checklist instead of a code dump.

---

## Plugin Binary Constraints

| Property | Value |
|----------|-------|
| Load address | `$C000` |
| Practical size target | Keep the plugin inside the `$C000` plugin area and verify the built binary |
| Build output | `EasySD/build/plugins/<name>plugin.prg` |
| SD card path | `/PLUGINS/<EXT>PLUGIN.PRG` (e.g. `KOAPLUGIN.PRG`) |

---

## Required Include Chain

Every plugin must pull in the CartLib API. For most file-oriented plugins, include the highest-level wrapper you need.

`CartLibStream.s` includes the full chain:
`CartLibStream.s → CartLibHi.s → CartLib.s → CartLibCommon.s → System.inc / EasySD.inc`

### Tier 2 — APIMacros (explicit include required)

`APIMacros.s` is **not** pulled in by `CartLibStream.s` — you must include it explicitly
at the top of any file that uses its macros.

---

## Entry / Exit Checklist

Typical current plugin flow:

1. Save machine state with `SAVESTATE`.
2. Start cartridge communication with `PROT_StartTalking` before cartridge file operations.
3. Open, inspect, load, stream, or play the selected content.
4. Close any opened file handle with `PROT_CloseFile` when appropriate.
5. End the cartridge session with `PROT_EndTalking` on normal and error exit paths.
6. Restore machine state with `RESTORESTATE`.
7. Return via `PROT_ExitToMenu`.

Exact structure varies by plugin, but the protocol contract above is the current invariant to preserve.

---

## File Handling Notes

- Use `#OPENFILE`, `#GETFILEINFO`, `#EXTRACTFILESIZE`, `#SETADDR`, and `#CLOSEFILE` where they fit the control flow.
- Do not assume a fixed 31-byte filename length in new code. Current firmware accepts dynamic filename lengths and null-terminated paths.
- `LoadFileBySize` remains the standard way to load plugin payloads into C64 memory.
- Some plugins use explicit `PROT_SetNameZ` + `PROT_OpenFile` sequences instead of `#OPENFILE` when that fits their control flow better.

---

## Error Handling Notes

- Preserve carry-based success/error flow consistently.
- Ensure `PROT_EndTalking` is not skipped on failure paths after a session has started.
- Ensure `PROT_CloseFile` is called on every path where file open succeeded.

---

## Zero Page Constraints

| Address | Reserved for | Rule |
|---------|-------------|------|
| `$FB/$FC` | `NAMELOW`/`NAMEHIGH` — navigation pointer | **Never use as temp** |
| `$FD/$FE` | `COLLOW`/`COLHIGH` — color RAM pointer | **Never use as temp** |
| `$80–$87` | `LoadFileBySize` API | Strictly reserved |
| `$90–$95` | `StreamLargeFile` | Reserved |

Use `$FB–$FE` only if you understand the constraints; prefer plugin-private RAM variables.

Full map: `EasySD/Loader/CartZpMap.inc`.

---

## APIMacros Reference

| Macro | Expands to | Parameters |
|-------|-----------|------------|
| `#OPENFILE buf, #len, #flags` | `LDX/LDY/LDA + JSR PROT_SetName + LDX + JSR PROT_OpenFile` | buf=address, len=filename length, flags=1 for read |
| `#SETADDR label, ZP_lo` | `LDA #<label / STA ZP_lo / LDA #>label / STA ZP_lo+1` | label=16-bit address, ZP_lo=ZP low byte |
| `#EXTRACTFILESIZE buf, dest` | 4× `LDA buf+28..31 / STA dest..dest+3` | buf=FAT entry, dest=4-byte size dest |
| `#GETFILEINFO buf` | `#SETADDR buf + LDY #0 + JSR PROT_GetInfoForFile` | buf=32-byte FAT entry buffer |
| `#CLOSEFILE` | `JSR PROT_CloseFile` | — |

---

## APIMacros Adoption Status

| Plugin | APIMacros |
|--------|-----------|
| KernalBridge (P2TK PRG loader) | adopted |
| WavPlayer | adopted |
| KoalaDisplayer | adopted |
| MusPlayer | adopted |
| PetsciiDisplayer | adopted |
| CvdPlayer | limited use; NI stream path is the primary concern |
| HWTest | not needed (direct NMI setup, no file I/O) |

---

## Build

```bash
python Tools/build.py plugins     # build all plugins
python Tools/build.py release     # full build
```

Source convention: `EasySD/Plugins/<Name>/<Name>.s`
Output: `EasySD/build/plugins/<name>plugin.prg`
