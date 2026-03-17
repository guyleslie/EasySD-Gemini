# EasySD Plugin Development Guide

Plugins are standalone 6502 programs loaded from `/PLUGINS/` on the SD card.
When the user selects a file whose extension maps to a plugin, the menu loads
`/PLUGINS/<EXT>PLUGIN.PRG` to `$C000` and jumps to `$C000`.

---

## Plugin Binary Constraints

| Property | Value |
|----------|-------|
| Load address | `$C000` |
| Maximum size | ~12 KB (`$C000–$CFFF`) |
| Build output | `EasySD/build/plugins/<name>plugin.prg` |
| SD card path | `/PLUGINS/<EXT>PLUGIN.PRG` (e.g. `KOAPLUGIN.PRG`) |

---

## Required Include Chain

Every plugin must pull in the CartLib API. Include the highest-level wrapper needed:

```asm
; For most plugins (file I/O):
.include "../../Loader/CartLibStream.s"
.include "../../Loader/DebugStrings.s"
```

`CartLibStream.s` includes the full chain:
`CartLibStream.s → CartLibHi.s → CartLib.s → CartLibCommon.s → System.inc / EasySD.inc`

### Tier 2 — APIMacros (explicit include required)

```asm
; Add BEFORE the origin directive if you use #OPENFILE, #SETADDR, etc.
.include "../../Loader/DebugMacros.s"
.include "../../Loader/APIMacros.s"
```

`APIMacros.s` is **not** pulled in by `CartLibStream.s` — you must include it explicitly
at the top of any file that uses its macros.

---

## Entry / Exit Pattern

```asm
* = $C000
    JMP MAIN

MAIN:
    JSR SAVESTATE           ; save VIC + $01 registers
    ; ... plugin logic ...

EXIT:
    JSR RESTORESTATE        ; restore VIC + $01 for clean menu return
    JSR PROT_DisableDisplay
    JSR PROT_ExitToMenu
    JMP *                   ; never reached
```

`SAVESTATE` / `RESTORESTATE` save and restore: `$01`, `$DD00`, `$D011`, `$D016`,
`$D018`, `$D020`, `$D021`, `$D022`, `$D023`.

---

## File Open / Read / Close Pattern

```asm
    ; Open file (path in FILE_PATH_BUF, length 31, flags read=1)
    JSR PROT_DisableDisplay
    #OPENFILE FILE_PATH_BUF, #31, #01
    BCC file_opened
    JMP error_handler
file_opened:
    JSR PROT_EnableDisplay

    ; Get file size from FAT directory entry
    #SETADDR INFO_BUFFER, ZP_IRQ_API_DATA_LO
    JSR PROT_DisableDisplay
    JSR PROT_GetInfoForFile
    BCC size_ok
    JMP error_handler
size_ok:
    JSR PROT_EnableDisplay
    #EXTRACTFILESIZE INFO_BUFFER, ZP_LOADFILE_API_SIZE0

    ; Set load target and skip (0 = no header, 2 = skip PRG load address)
    LDA #<LOAD_TARGET
    STA ZP_IRQ_API_DATA_LO
    LDA #>LOAD_TARGET
    STA ZP_IRQ_API_DATA_HI
    LDA #2                  ; skip 2-byte PRG header
    STA ZP_LOADFILE_API_SKIP_LO
    LDA #0
    STA ZP_LOADFILE_API_SKIP_HI

    JSR PROT_DisableDisplay
    JSR LoadFileBySize
    BCC load_ok
    JMP error_handler
load_ok:

    JSR PROT_CloseFile
```

---

## ERROR_GATE Pattern

For plugins that call multiple file operations:

```asm
ERROR_GATE:
    BCC +           ; carry clear = success, skip error
    JMP PLUGIN_FAIL
+   RTS

PLUGIN_FAIL:
    JSR PROT_EnableDisplay
    ; display error message ...
    JSR RESTORESTATE
    JSR PROT_DisableDisplay
    JSR PROT_ExitToMenu
    JMP *
```

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
| CvdPlayer | not needed (uses NIStream) |

---

## Build

```bash
python Tools/build.py plugins     # build all plugins
python Tools/build.py release     # full build
```

Source convention: `EasySD/Plugins/<Name>/<Name>.s`
Output: `EasySD/build/plugins/<name>plugin.prg`
