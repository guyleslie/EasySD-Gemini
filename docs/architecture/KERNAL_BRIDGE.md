# KernalBridge — KERNAL I/O Bridge for EasySD

## Overview

KernalBridge is a C64-side component that enables **unmodified BASIC programs** to use the EasySD SD card as if it were device 8 (a standard floppy drive). It does this by replacing five KERNAL I/O vectors with custom implementations that route all device 8 traffic through the EasySD cartridge API.

This is **not a plugin**. It is never invoked by user selection from the menu. It is a bridge layer launched by the menu system as part of the PRG launch sequence.

---

## Location in Codebase

```
IRQHack64/Loader/Bridges/KernalBridge/
├── KernalBridge.s        — active build target
└── KernalBridgeStub.s    — archived stub (not built)
```

Built output: `build/plugins/prgplugin.prg` (output name preserved for SD card compatibility).

---

## What It Does

### Launch sequence

```
Menu system
  │
  ├─ Loads KernalBridge code to $C000
  ├─ Opens target PRG via EasySD API
  ├─ Reads PRG load address from 2-byte header
  ├─ Loads PRG body to its load address (via LoadFileBySize)
  ├─ Closes file, ends protocol session
  ├─ Calls RESTOR ($FD15) — reinitialises KERNAL RAM vectors
  ├─ Calls SETVECTORS — patches 5 vectors with bridge routines
  └─ Jumps to loaded PRG (BASIC or machine language)
```

After this point, any file I/O the BASIC program performs on device 8 is handled by the bridge.

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
JSR IRQ_StartTalking
  ... EasySD API calls ...
JSR IRQ_EndTalking
```

**All error exit paths must call `IRQ_EndTalking` before returning.** Leaving the protocol session open corrupts subsequent operations — both within the same BASIC program and after return to the menu.

---

## Memory Layout

KernalBridge is loaded to `$C000` (Type A, cartridge high memory region).

```
$C000          JMP MAIN          — entry point
$C003–$C6FF    (gap)
$C700          MAIN              — PRG load and launch logic
$C700+         bridge routines, data buffers
```

The 256-byte `GENERALBUFFER` at the end of the image serves dual purpose:
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
      └─ CartLibHi.s        — LoadFileBySize, IRQ_OpenFile, etc.
          └─ CartLib.s      — low-level IRQ_StartTalking / IRQ_Send
              └─ CartLibCommon.s
                  └─ Common/System.inc   — C64 hardware addresses
                  └─ Common/EasySD.inc   — EasySD command codes, cartridge status
  └─ DebugStrings.s         — status string data (DEBUG=1 only)
```

---

## Known Limitations

- **Sequential access only.** No random seek, no relative files.
- **Device 8 only.** Other logical file numbers fall through to KERNAL.
- **16-bit file size.** `FILEINDEX` and `OPENEDFILELENGTH` are 2 bytes — files larger than 64 KB are not supported via the KERNAL bridge interface.
- **One file at a time.** Only one file can be open simultaneously.
- **Vectors are not restored on exit.** The patch is one-way. After the BASIC program ends and the user returns to the menu, the menu performs a full KERNAL reinitialisation.
