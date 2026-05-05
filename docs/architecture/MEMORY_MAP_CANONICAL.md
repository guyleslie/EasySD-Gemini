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

## Direct PRG Launcher (current menu path)

Ordinary menu `.PRG` selections currently do **not** use KernalBridge. The Arduino
copies `LoaderStub` to low RAM, then streams the selected PRG payload to its load
address.

| Address | Content |
|---------|---------|
| `$033C-$040C` | `LoaderStub` — 209-byte RAM launcher used by direct `.PRG` start |
| `$0400-$040C` | Temporary overlap with the first 13 bytes of screen RAM during launch |

`LoaderStub` restores the normal memory map, then `SHOULD_RUN_BASIC` inspects the
loaded content and decides the launch method:
- Standard BASIC PRG at `$0801`: `CLR` + `RUN`.
- Hybrid PRG loaded below `$0801` but with a valid tokenized BASIC `SYS` stub at
  `$0801`: also `CLR` + `RUN` (covers Beach Head-style files).
- Machine-language PRG at any other address: jump directly to the load address.

---

## KernalBridge Memory Layout

KernalBridge is loaded at `$C000` like a plugin but does not return to the menu — it
launches PRG files via a full KERNAL/BASIC reinitialisation followed by a warm-start
jump. It is **not invoked by the current menu `.PRG` dispatch**; the direct
`LoaderStub` path (above) handles all `.PRG` selections. KernalBridge's sole
additional value over `LoaderStub` is patching the KERNAL I/O vectors so a running
BASIC program can subsequently `OPEN`/`GET#` files from the SD card.

| Address | Content |
|---------|---------|
| `$C000` | `JMP MAIN` |
| `$C003–$C05D` | P2TK Phase 3 data tables (tail-write protection) |
| `$C060–$C17D` | Data variables (GENERALBUFFER, FILELENGTH, addresses) |
| `$C700+` | Main code + bridge routines |

Known issue: code extends past `$D000` into I/O space. See `KERNAL_BRIDGE.md`.

---

## Reference Files

| File | Role |
|------|------|
| `EasySD/Loader/CartZpMap.inc` | Zero Page allocation (single source of truth) |
| `EasySD/Loader/Common/CartMemoryMap.inc` | Optional high-memory symbols |
| `EasySD/Loader/Common/System.inc` | Cartridge ROM / loader address constants |
