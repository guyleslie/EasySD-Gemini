# EasySD – KernalBridge (KERNAL I/O Bridge / P2TK Loader)

Routes device 8 KERNAL I/O (`OPEN`/`CLOSE`/`GET#`) through EasySD so unmodified BASIC
programs can read files from the SD card at runtime. Also handles PRG files whose
payload extends into or above the `$C000` plugin window via the Phase 2 Transfer
Kernel (P2TK).

---

## Overview

Important: in the current menu baseline, ordinary `.PRG` selections do **not**
load `/PLUGINS/PRGPLUGIN.PRG`. The menu dispatches `.PRG` files to the direct
`PROGRAM` path (`LoadAndLaunchFile()` + `LoaderStub`). This document describes
KernalBridge itself: the separate `PRGPLUGIN.PRG` bridge artifact and its P2TK
behavior when that bridge path is used.

When KernalBridge is invoked, it:

1. Opens the selected PRG file and reads its 2-byte load address.
2. Loads the payload to the load address using `LoadFileBySize`.
3. If the file's end address exceeds `$C002`, activates P2TK (see below) to handle
   the portion that overlaps the plugin window. KERNAL vectors are NOT patched on
   the P2TK path.
4. On the normal path (no P2TK): closes the file, reinitialises hardware
   (IOINIT/RESTOR/CINT), patches five KERNAL I/O vectors (`SETVECTORS`), reinitialises
   the BASIC environment, and jumps to `$0840` (BASIC warm start). The loaded program
   is now in RAM and any subsequent device 8 file I/O is handled by the bridge.

---

## P2TK — Phase 2 Transfer Kernel

Normal loading fails when a PRG file needs to overwrite `$C000–$CFFF` because the
plugin binary is running from that area. P2TK solves this with a three-phase approach:

| Phase | Action |
|-------|--------|
| Phase 1 | Load bytes from load address up to `$BFFF` normally |
| Phase 2 | A small stub at `$033B` takes over; the plugin window is overwritten page by page via NMI |
| Phase 3 | If the file fills `$FF00–$FFFF` (NMI vector area), a separate handler saves those tail bytes and copies them after the transfer |

**Trigger condition:** `ENDADDRESS > $C002`

### Phase 2 Stub Address

The BVC wait-stub lives at `$033B` (which is `FILE_PATH_BUF`). This area is safe
to use during Phase 2 because menu navigation is not active while loading a PRG.

### NMI Vector Under $01=$34

During Phase 2, `$01` is set to `$34` (all RAM, `$D000–$FFFF` writable). The NMI
vector at `$FFFA/$FFFB` therefore reads from RAM. KernalBridge writes the Phase 2
NMI handler address there before handing off.

Phase 3 handler (`P3_HANDLER`) and tail code (`P3_TAIL_CODE`) are stored at
`$C003`/`$C02A` — the gap in the KernalBridge entry jump — which is always-readable
RAM, safely outside the main plugin code range.

---

## Memory Layout — KernalBridge Data Variables

All data variables were relocated to the `$C060–$C17D` gap to avoid collision with plugin code:

| Address | Symbol | Purpose |
|---------|--------|---------|
| `$C060` | `HEXTOSCREEN` | Hex-to-screen conversion table |
| `$C070` | `GENERALBUFFER` | General I/O buffer |
| `$C170` | `FILELENGTH` | 32-bit file size from FAT entry |
| `$C174` | `STARTADDRESS` | PRG load address (2 bytes) |
| `$C176` | `ENDADDRESS` | PRG end address (P2TK trigger) |
| `$C178` | `OPENEDFILELENGTH` | Opened file length |
| `$C17C` | `FILEINDEX` | File index |

---

## API Calls Used

| Call | Purpose |
|------|---------|
| `PROT_StartTalking` | Begin Arduino session |
| `PROT_OpenFile` | Open the selected PRG file |
| `PROT_GetInfoForFile` | Get FAT directory entry (file size at offset 28) |
| `PROT_ReadFileNoCallback` | Read one page into `GENERALBUFFER` (extracts 2-byte PRG load address) |
| `LoadFileBySize` | Load the PRG payload (Phase 1, or full load on normal path) |
| `PROT_CloseFile` | Close file (Phase 1 only; intentionally omitted during P2TK) |
| `PROT_EndTalking` | End Arduino session (Phase 1 only) |
| `PROT_ExitToMenu` | Return to menu on error |

Macros: `#OPENFILE`, `#SETADDR`, `#EXTRACTFILESIZE`, `#GETFILEINFO`, `#CLOSEFILE` (Tier 2).

---

## Known Limitations

| Limitation | Detail |
|-----------|--------|
| Code extends `$C700–$D113` | Main + functions reach into the I/O space (`$D000+`). Code execution from `$D000+` can be unreliable when `$01=$37`. Future fix: shrink below `$CFFF`. |
| PRG load address = `$C000` | Plugin overwrites itself on load — handled by P2TK |
| Single-file only | Each PRG is loaded as a single file. |

---

## Source and Build

| Item | Path |
|------|------|
| Source | `EasySD/Loader/Bridges/KernalBridge/KernalBridge.s` |
| Architecture doc | `docs/architecture/KERNAL_BRIDGE.md` |
| Build output | `EasySD/build/plugins/prgplugin.prg` |
| SD card path | `/PLUGINS/PRGPLUGIN.PRG` |

```bash
python Tools/build.py plugins
```
