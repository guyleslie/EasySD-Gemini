# KernalBridge — KERNAL I/O Bridge for EasySD

## Overview

KernalBridge is a C64-side component that enables **unmodified BASIC programs** to use the EasySD SD card as if it were device 8 (a standard floppy drive). It does this by replacing five KERNAL I/O vectors with custom implementations that route all device 8 traffic through the EasySD cartridge API.

KernalBridge is built as `build/plugins/prgplugin.prg` for SD-card compatibility,
but in the current menu baseline ordinary `.PRG` selection does **not** invoke it.
Normal menu `.PRG` launches use the direct Arduino `LoadAndLaunchFile()` path plus
the C64 RAM `LoaderStub`. This document therefore describes the bridge
implementation itself, not the default `.PRG` menu path.

---

## Location in Codebase

```
EasySD/Loader/Bridges/KernalBridge/
├── KernalBridge.s        — active build target
└── KernalBridgeStub.s    — archived stub (not built)
```

Built output: `build/plugins/prgplugin.prg` (output name preserved for SD card compatibility).

---

## What It Does

KernalBridge patches five KERNAL I/O vectors so that any `OPEN`/`CLOSE`/`GET#` call
on device 8 made by a running BASIC program is routed through the EasySD cartridge API
instead of going to a real floppy drive. This allows unmodified BASIC programs that open
and read files at runtime to work with the SD card.

**The bridge is not the standard PRG loader.** Loading a `.PRG` file from the EasySD
menu always uses the direct `LoadAndLaunchFile()` + `LoaderStub` path; KernalBridge is
never invoked by the current menu dispatch. It is built and shipped as `PRGPLUGIN.PRG`
on the SD card, but no code path in the current firmware or menu calls it. Its value
would be in a future scenario where a BASIC program needs to read additional files from
the SD card during execution — that use case does not exist in the current system.

## Launch Paths

### Current ordinary `.PRG` menu path

```text
Menu PROGRAM dispatch
  └─ Arduino LoadAndLaunchFile()
       ├─ reads 2-byte PRG load header
       ├─ sends SendHeader() + SendLoaderStub()
       └─ LoaderStub decides BASIC RUN vs direct JMP
```

This direct path is where the hybrid BASIC/ML PRG launch fix lives (`LoaderStub.65s`).

### KernalBridge path

When KernalBridge itself is invoked, the flow is:

```
Menu system
  │
  ├─ Loads KernalBridge code to $C000
  ├─ Opens target PRG via EasySD API
  ├─ Reads PRG load address from 2-byte header
  ├─ Computes ENDADDRESS = STARTADDR + file size
  │
  ├─ [Normal path: ENDADDRESS ≤ $C002]
  │    ├─ Loads PRG body via LoadFileBySize
  │    ├─ Closes file, ends protocol session (CLOSEFILE, PROT_EndTalking)
  │    ├─ Reinitialises hardware: IOINIT ($FDA3), RESTOR ($FD15), CINT ($FF5B)
  │    ├─ Patches KERNAL I/O vectors (SETVECTORS)
  │    ├─ Reinitialises BASIC environment ($E453, $E3BF, $E422)
  │    ├─ Sets BASIC variable/end pointers ($2D–$30, $AE/$AF) to ENDADDRESS
  │    └─ Restores memory config ($01=$37) and jumps to $0840 (BASIC warm start)
  │
  └─ [P2TK path: ENDADDRESS > $C002 — PRG extends into $C000+]
       └─ (see "P2TK — Large Program Loader" section below)
```

After a normal-path launch, any device 8 file I/O the BASIC program performs is handled by the
bridge via the patched vectors. The P2TK path loads the program and jumps directly to it —
KERNAL vectors are NOT patched in that case, so no runtime file I/O is available.

### Replaced KERNAL vectors

| Vector | Replaced by | What it does |
|--------|-------------|--------------|
| `V_OPEN`   | `NEW_OPEN`   | Opens file on SD card, reads metadata |
| `V_CLOSE`  | `NEW_CLOSE`  | Closes the open file |
| `V_CHKIN`  | `NEW_CHKIN`  | Sets read direction for device 8 |
| `V_CHRIN`  | `NEW_CHRIN`  | Reads one byte; buffers 256 bytes per SD round-trip |
| `V_CLRCHN` | `NEW_CLRCHN` | Clears I/O channel (no-op for device 8) |

All five routines check `KERNAL_DEVICE_NUMBER` ($BA) first. If the device is not 8, they fall through to the original KERNAL routine (`K_OPEN`, `K_CHKIN`, etc.), so other devices continue to work normally.

---

## Protocol Invariants

Every file operation that contacts the Arduino **must** follow this pattern:

```
JSR PROT_StartTalking
  ... EasySD API calls ...
JSR PROT_EndTalking
```

**All error exit paths must call `PROT_EndTalking` before returning.** Leaving the protocol session open corrupts subsequent operations — both within the same BASIC program and after return to the menu.

---

## Memory Layout

KernalBridge is loaded to `$C000` (Type A, cartridge high memory region).

```
$C000          JMP MAIN                  — entry point
$C003–$C029    P3_TAIL_CODE (39 bytes)   — Phase 3 data table (tail-write code)
$C02A–$C05D    P3_HANDLER   (52 bytes)   — Phase 3 data table (NMI handler)
$C05E–$C05F    (unused, 2 bytes)
$C060–$C17D    data variables            — see table below
$C17E–$C6FF    (unused gap, zero-filled)
$C700          MAIN                      — PRG load and launch logic
$C700–~$D113   bridge routines, CartLib  — code extends past $D000 (known issue)
```

**Data variables at `$C060` (explicit `*=$C060` directive in source):**

| Address | Symbol | Size | Purpose |
|---------|--------|------|---------|
| `$C060` | `HEXTOSCREEN` | 16 B | nibble → screen-code lookup table |
| `$C070` | `GENERALBUFFER` | 256 B | dual-use: FAT entry buffer / 256-byte read cache |
| `$C170` | `FILELENGTH` | 4 B | 32-bit size of initial PRG |
| `$C174` | `STARTADDRESSLO/HI` | 2 B | PRG load address |
| `$C176` | `ENDADDRESSLO/HI` | 2 B | PRG end address (STARTADDR + FILELENGTH) |
| `$C178` | `OPENEDFILELENGTH` | 4 B | 32-bit size of currently open file (runtime) |
| `$C17C` | `FILEINDEXLOW/HIGH` | 2 B | read position within open file |

Variables were relocated from `$D000+` to `$C060–$C17D` to ensure reliable reads on real
hardware (reads from `$D000+` with `$01=$37` return VIC-II/SID register values, not RAM).

The P3 data tables at `$C003`/`$C02A` are only active when Phase 3 is triggered
(Phase2_pages = 64). They must live below `$D000` for the same reason.

The 256-byte `GENERALBUFFER` serves a dual purpose:
- During launch: holds file metadata (FAT entry, size)
- During BASIC execution: read buffer for `NEW_CHRIN` (one SD round-trip = 256 bytes)

`NEW_CHRIN` only calls the SD card when `FILEINDEXLOW == 0` (buffer exhausted). For all other bytes it serves from `GENERALBUFFER` directly, minimising protocol overhead.

---

## Dependencies

```
KernalBridge.s
  └─ DebugMacros.s          — debug-mode print macros (DEBUG=1 only)
  └─ CartLibStream.s        — full EasySD API stack
      └─ CartZpMap.inc      — Zero Page register map
      └─ CartLibHi.s        — LoadFileBySize, PROT_OpenFile, etc.
          └─ CartLib.s      — low-level PROT_StartTalking / PROT_Send
              └─ CartLibCommon.s
                  └─ Common/System.inc   — C64 hardware addresses
                  └─ Common/EasySD.inc   — EasySD command codes, cartridge status
  └─ DebugStrings.s         — status string data (DEBUG=1 only)
```

---

---

## P2TK — Large Program Loader

KernalBridge includes a three-phase loader (`DO_P2TK`) for PRGs whose payload extends into
`$C000+` — which would normally overwrite the running KernalBridge code during loading.

### Trigger

`ENDADDRESS > $C002`, where `ENDADDRESS = STARTADDR + file_size` (computed before any loading).
Typical cases: large games and demos that fill most of the C64 address space.

### Phase 1 — Load STARTADDR .. $BFFF

Uses `LoadFileBySize` with `SIZE = $C000 - STARTADDR` (skipping the 2-byte PRG header).
This is a normal EasySD transfer that fills everything below `$C000`.

### Phase 2 — NMI-driven transfer of $C000 .. ENDADDRESS

KernalBridge cannot stay resident at `$C000` during Phase 2 — Phase 2 will overwrite it.
Before jumping away, the code sets up everything in low RAM and switches memory config.

**Setup (still running from `$C000`):**
1. Compute `Phase2_pages = ceil((ENDADDRESS - $C002) / 256)`
2. Write 8-byte BVC wait-stub to `$033B` (FILE_PATH_BUF area — safe, never written by Phase 1/2)
3. Write 7-byte Launcher to `$0334`: `LDA #$37 / STA $01 / JMP STARTADDR`
4. [Phase 3 setup if applicable — see below]
5. Write hardware NMI vector `$FFFA/$FFFB` → `$80AF` (CARTRIDGENMIHANDLERX1 in cartridge ROM)
6. Set `$01 = $34` (all RAM: I/O still visible, `$E000-$FFFF` writable as RAM)
7. `JMP $033B` — jump to wait-stub; KernalBridge code is now unreachable

**Transfer (`$C000+` filled via NMI):**
- `TransferHandler` (at `$80AF` in cartridge ROML, always visible regardless of `$01`) handles
  each NMI: reads one byte from `$80AB` (cartridge bank), writes it via `STA ($6C),Y`.
- Arduino pulses `/NMI` once per byte. When all pages are done, TransferHandler sets
  `ZP_IRQ_STATE_WAITHANDLE = $64`.
- The BVC loop at `$033B` detects the done flag and falls through to Launcher.

**Launcher (`$0334`):**
- `LDA #$37 / STA $01` — restore default memory map (KERNAL+BASIC+I/O visible)
- `JMP STARTADDR` — hand control to the loaded program

**Note:** `CLOSEFILE` and `PROT_EndTalking` are NOT called before Phase 2 — intentional protocol
leak. The Arduino returns to `SoftStartListening` and all state resets on the next C64 reset.

### Phase 3 — Tail-Write Protection (Phase2_pages = 64 only)

When `Phase2_pages = 64`, the last transfer page is `$FF00-$FFFF`. At `Y=$FA` the NMI handler
writes to `$FFFA/$FFFB` — the active NMI vector — with partially-transferred data, causing the
next NMI to jump to a garbage address → crash.

**Solution (active only when Phase2_pages = 64):**
- Two data tables stored in the KernalBridge binary gap at `$C003-$C05C` (always-accessible
  RAM) are pre-copied to the FILE_PATH_BUF area before Phase 2 starts:
  - `P3_HANDLER` (52 bytes, copied to `$036A`): replacement NMI handler that behaves normally
    for `$C000-$FFF9` but intercepts `Y >= $FA` on the last page, saving bytes `$FFFA-$FFFF`
    to `TAIL_BUF ($03BB-$03C0)` instead of writing them directly.
  - `P3_TAIL_CODE` (39 bytes, copied to `$0343`): runs after transfer; copies
    `TAIL_BUF → $FFFA-$FFFF`, then jumps to Launcher.
- NMI vector is set to `$036A` (P3_HANDLER) instead of `$80AF`.
- BVC loop JMP target is changed from `$0334` (Launcher) to `$0343` (P3_TAIL_CODE).

**FILE_PATH_BUF area layout (with Phase 3 active):**
```
$0334-$033A   Launcher        7 bytes   LDA #$37 / STA $01 / JMP STARTADDR
$033B-$0342   BVC wait-stub   8 bytes   CLV / BIT $64 / BVC loop / JMP $0343
$0343-$0369   P3_TAIL_CODE   39 bytes   copy TAIL_BUF → $FFFA-$FFFF / JMP $0334
$036A-$039D   P3_HANDLER     52 bytes   NMI handler with tail-byte interception
$03BB-$03C0   TAIL_BUF        6 bytes   saved bytes for $FFFA-$FFFF
```

### Maximum Loadable Range

| Phase | STARTADDR | ENDADDRESS |
|-------|-----------|------------|
| Normal | any | ≤ $C002 (up to ~$BFFF) |
| P2TK (Phase 2) | ≥ $0801 | ≤ $EFFF |
| P2TK (Phase 3) | ≥ $0801 | $FFFF (full address space) |

---

## Cassette-buffer Reuse

Phase 2 writes the BVC wait-stub to `$033B–$0342` (inside the cassette buffer /
`FILE_PATH_BUF` area). KernalBridge writes that area and immediately jumps to
`$033B`; afterwards KernalBridge code is unreachable. The MultiLoad resident-loader
hook that previously also lived in this region has been removed.

---

## Known Limitations

- **Sequential access only.** No random seek, no relative files.
- **Device 8 only.** Other logical file numbers fall through to KERNAL.
- **16-bit file size.** `FILEINDEX` and `OPENEDFILELENGTH` are 2 bytes — files larger than 64 KB are not supported via the KERNAL bridge interface.
- **One file at a time.** Only one file can be open simultaneously.
- **Vectors are not restored on exit.** The patch is one-way. After the BASIC program ends and the user returns to the menu, the menu performs a full KERNAL reinitialisation.
- **Code extends past `$D000`.** The bridge routines span `$C700–~$D113`. With `$01=$37`, `$D000–$DFFF` is I/O space on real C64 hardware — instruction fetches from those addresses return VIC-II/SID register bytes, not the stored code. This has not caused test failures in practice (VICE and breadboard). A proper fix requires reducing the binary below 4 KB. Note: data variables were already relocated from `$D000+` to `$C060–$C17D` (see Memory Layout) — they read reliably. Only the code region remains above `$D000`.
- **No runtime I/O after P2TK.** PRGs loaded via the P2TK path receive no patched KERNAL vectors. The loaded program cannot open or read files during execution.
