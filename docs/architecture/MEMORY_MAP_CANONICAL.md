# EasySD Memory Map

This document describes how the C64 address space is used by EasySD plugins and bridges.

---

## C64 Address Space Overview

| Address Range | Used By | Notes |
|---------------|---------|-------|
| `$0400–$07FF` | Screen memory | Do not use for buffers while display is active |
| `$080E–$0FFF` | Menu program (resident) | Plugins must not overwrite this region |
| `$8000–$9FFF` | Cartridge ROML | EasySD loader ROM, always mapped via /EXROM |
| `$C000+` | Plugin code + data | Standard plugin load address |
| `$D000–$DFFF` | I/O (VIC/SID/CIA) | Visible when $01=$37 or $35; code must not execute here |
| `$DE00` | IO1 data port | Streaming data read (`STREAM_DATA_PORT`) |
| `$DF00` | IO2 trigger | /IO2 pulse on read (`MODULATION_ADDRESS`) |

---

## Plugin Memory Model

All current plugins are **Type A**: loaded at `$C000` by the menu, coexist with menu code in RAM, and return to menu via `JSR PROT_ExitToMenu`.

### Layout

```
$C000   JMP Main              ; entry point (mandatory)
$C003+  code, data, buffers   ; assembler auto-places everything after entry
```

The assembler places buffers after code automatically. No fixed buffer addresses are required — the CartLib API uses ZP pointers (`ZP_IRQ_API_DATA_LO/HI`) to locate buffers at runtime.

### Typical buffer locations (auto-placed)

| Plugin | Buffer | Address | Size |
|--------|--------|---------|------|
| KernalBridge | GENERALBUFFER | $C070 | 256 B |
| KoalaDisplayer | READBUFFER | $C770 | variable |
| PetsciiDisplayer | READBUFFER | $C672 | variable |
| WavPlayer | READBUFFER | $C700 | variable |

### Buffer rules

- Must not overlap plugin code, screen memory, menu region, or ROM
- Content is volatile — invalid after API calls return
- Use `#SETADDR buffer, ZP_IRQ_API_DATA_LO` to pass buffer address to API
- Compile-time overflow check recommended: `.if * > $D000`

### Plugin requirements

1. Entry point at `*=$C000`
2. Include `APIMacros.s` for Tier 2 macros
3. Follow the protocol sequence (StartTalking → file ops → CloseFile → EndTalking → ExitToMenu)
4. Do not overwrite `$080E–$0FFF` (menu) or `$D000+` (I/O)

---

## KernalBridge Memory Layout

KernalBridge is loaded at `$C000` like a plugin but does not return to menu — it launches PRG files.

| Address | Content |
|---------|---------|
| `$C000` | `JMP MAIN` |
| `$C003–$C05D` | P2TK Phase 3 data tables (tail-write protection) |
| `$C060–$C17D` | Data variables (GENERALBUFFER, FILELENGTH, addresses) |
| `$C700+` | Main code + bridge routines |

Known issue: code extends past `$D000` into I/O space. See `KERNAL_BRIDGE.md`.

---

## ResidentLoader Memory (MultiLoad)

MultiLoad installs a resident hook that persists after the menu exits. These regions are outside the `$C000+` plugin range and are only active during multi-load game execution.

| Address | Symbol | Content |
|---------|--------|---------|
| `$0330/$0331` | `V_LOAD` | Kernal LOAD vector, patched to `$033C` |
| `$033C–$035B` | `RL_STUB` | Resident stub (~38 bytes): device check, save regs, call handler |
| `$0368–$036A` | `RL_NMI_REDIRECT` | `JMP ($0318)` — written to `$FFFA/$FFFB` for NMI dispatch |
| `$036B–$036C` | `RL_ORIG_VEC` | Backup of original `$0330/$0331` |
| `$036D` | `RL_SAVED_01` | Saved processor port during hook |
| `$036E/$036F` | `RL_SAVED_X/Y` | Saved X/Y registers (SA=0 support) |
| `$E800` | `RL_HANDLER` | Handler entry (under Kernal ROM, $01=$35) |
| `$E840` | `RL_DIR_PATH` | Game directory path buffer (64 B) |
| `$E880` | `RL_FNAME_BUF` | Filename buffer (36 B) |
| `$E8A4` | `RL_FILEINFO_BUF` | FAT entry buffer (32 B) |
| `$E8C4` | `RL_HDR_BUF` | First-page read buffer (256 B) |

`$033C` is dual-use: `FILE_PATH_BUF` during menu operation, `RL_STUB` during game execution. The two uses are mutually exclusive.

Writes to `$E800` always reach RAM regardless of `$01` banking. The handler is only reachable with `$01=$35`.

Constants defined in `EasySD/Loader/Common/System.inc`.

---

## Reference Files

| File | Role |
|------|------|
| `EasySD/Loader/CartZpMap.inc` | Zero Page allocation (single source of truth) |
| `EasySD/Loader/Common/CartMemoryMap.inc` | Optional high-memory symbols |
| `EasySD/Loader/Common/System.inc` | ResidentLoader address constants |
