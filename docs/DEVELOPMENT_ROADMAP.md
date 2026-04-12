# EasySD Development Roadmap

Last updated: 2026-04-12

This file is the short planning view of the project. It should stay focused on current source-backed status and next work, not on historical debugging transcripts.

---

## Current Source-Backed State

The following points are directly supported by the current codebase:

- Cold boot auto-load path exists in the firmware: `setup()` waits for stable PHI2, then calls `TransferMenu()`.
- `TransferMenu()` prefers `EASYSD.PRG` from the SD card root and falls back to built-in `cartridgeData` if the file is not present.
- Directory handling uses firmware CWD as the source of truth, with `currentPath` kept as UI/debug state.
- PRG loading uses KernalBridge and the P2TK path for programs extending into `$C000+`.
- Long filenames and full path handling are supported by the current firmware and recent plugin-side fixes no longer assume a fixed 31-byte media filename.
- MusPlayer now opens `/PLUGINS/SIDPLAYER.PRG` explicitly.
- WavPlayer, MusPlayer, and CvdPlayer all contain the expected session-level protocol pieces (`PROT_StartTalking`, file/session cleanup, and the newer path handling), but source inspection alone does not prove final real-hardware reliability.

---

## Current Cautions

These are the areas where the source shows active complexity or recently changed behavior, but the repository does not currently provide a single unambiguous, final hardware-status source:

- WavPlayer remains one of the highest-risk plugins because of its timing-sensitive playback paths and multiple hardware modes.
- MusPlayer depends on the external SID player binary and symbol alignment in addition to the plugin code itself.
- CvdPlayer contains the newer EOF-driven NI-stream exit path, but this should still be treated as a path that benefits from dedicated hardware confirmation.
- MultiLoad support is present, but current repository docs do not establish one clean, final status statement for hardware behavior.

---

## Protocol Invariants Worth Preserving

The current source strongly suggests these rules remain critical for cartridge-facing plugins:

1. Start the cartridge session before file/cart operations.
2. Close opened files on all paths where open succeeded.
3. End the session on both success and failure exits.
4. Return to the menu only after session cleanup.

KernalBridge remains the clearest reference implementation for this pattern.

---

## Planned Refactoring — Arduino Side

### Goal
`CartApi.cpp` is still a monolithic file (currently ~1374 lines) and mixes protocol dispatch, TAP decoding, PRG loading,
streaming, hardware test, and string utilities. Splitting it improves navigability
and makes each concern testable and reviewable independently.

Flash/SRAM cost of splitting: **zero** — the linker sees the same compiled output
regardless of how many `.cpp` files the code is spread across.

### Planned modules (in priority order)

#### 1. `TapConverter.cpp` / `TapConverter.h` — HIGH PRIORITY
Extract the complete TAP→PRG decoder. Fully self-contained, no shared state.

Functions to move:
- `TapPulseClass` (struct/class)
- `TapPulseReader`
- `ClassifyTapPulseUnit()`
- `TapReadNextByte()`
- `TapFindCountdown()`
- `TapReadStandardBlock()`
- `MakeOutputPrgName()`
- `ConvertStandardTapToPrg()`

After extraction, `HandleInvokeWithName()` and `LoadAndLaunchFile()` each call
`TapConverter::Convert(sd, fileName, outPrg, sizeof(outPrg))`.

#### 2. `HwTest.cpp` / `HwTest.h` — EASY
Extract `HandleHwTest()` and any supporting data/helpers.
`CartApi::HandleApi()` delegates: `case COMMAND_HWTEST: HwTest::Run(cartInterface); break;`
Wrap in `#ifdef COMMAND_HWTEST` to allow conditional compilation.

#### 3. `PrgLoader.cpp` / `PrgLoader.h` — MEDIUM COMPLEXITY
Extract the PRG/CRT transfer layer. These functions depend on `workingFile` and
`cartInterface` — pass them as references/parameters.

Functions to move:
- `LoadAndLaunchFile()` — main load+execute entry point
- `SendHeader()` — constructs and transfers the 10-byte PRG header
- `SendLoaderStub()` — transfers the RAM bootstrap stub
- `TransferMenu()` — loads and launches the menu program

#### 4. `StringUtils.h` — LOW PRIORITY (may not be worth it)
`IsMatchLast()` and `StartsWith()` are two small inline helpers.
Option: keep in `CartApi.cpp`, or move to a shared inline header.

### What stays in CartApi.cpp
The protocol dispatch core:
- `HandleApi()` — the main `switch` dispatcher
- `GetArgumentsStatic()` / `GetArgumentsDynamic()` — argument receivers
- `HandleResponse()` / `HandleValueResponse()` — response senders
- `AwaitByte()` / `GetByte()` — low-level byte reception
- All `Handle*()` file, directory, MCU-internal-EEPROM, and stream handlers
- `Init()`, `SaveLastDir()`, `RestoreLastDir()`

---

## Planned Refactoring — C64 Assembly Side

### Goal
Better English comments, clearer structure. Module separation is limited by the 64tass
include chain — **no include guards exist**, so circular or duplicate includes cause
fatal errors. The current linear chain is safe and intentional:

```
CartLibStream.s → CartLibHi.s → CartLib.s → CartLibCommon.s → System.inc/EasySD.inc
```

### Decision: DO NOT split CartLibHi.s

Reasons:
1. Splitting requires a new umbrella include file and updating every plugin — high churn, low gain.
2. The VIC-display, directory, stream, and MCU-internal-EEPROM helpers are all part of one protocol-facing layer.
3. The current size alone does not justify structural churn.

### What IS worth doing in CartLibHi.s
- Improve English comments (many are outdated or missing)
- Document the protocol invariants (`PROT_StartTalking` / `PROT_EndTalking` contract)
  at the top of the file
- Add a clear section header for each functional group (file ops, dir ops, EEPROM, stream)

### Plugin template / checklist
To avoid future protocol bugs, add a plugin skeleton or checklist comment at the top
of CartLibHi.s or in a separate `PluginTemplate.s`:

```asm
; PLUGIN PROTOCOL CHECKLIST:
;   1. JSR PROT_StartTalking          — before ANY file/cart operation
;   2. #OPENFILE / file ops / etc.
;   3. JSR PROT_CloseFile             — on ALL paths where OPENFILE succeeded
;   4. JSR PROT_EndTalking            — on ALL exit paths (success AND error)
;   5. JSR PROT_ExitToMenu            — last call before JMP *
```

---

## Recommended Work Sequence

```
Phase 1 — Plugin validation and cleanup
  🔲 WavPlayer: hardware-focused validation of playback modes and timing-sensitive paths
  🔲 MusPlayer: verify SIDPLAYER.PRG asset flow and runtime symbol expectations
  🔲 CvdPlayer: confirm EOF-driven NI stream exit behavior on hardware
  🔲 MultiLoad: verify current hardware behavior and document it from source + test evidence

Phase 2 — Arduino CartApi.cpp refactor
  🔲 Extract TapConverter.cpp/.h
  🔲 Extract HwTest.cpp/.h
  🔲 Extract PrgLoader.cpp/.h
  🔲 (Optional) StringUtils.h

Phase 3 — C64 library comment cleanup
  🔲 CartLibHi.s: English comments, section headers, protocol invariant block
  🔲 Plugin protocol checklist / template
```

---

## Key Files Quick Reference

| File | Purpose |
|------|---------|
| `Arduino/EasySD/CartApi.cpp` | Protocol dispatcher — ~1374 lines, primary refactor target |
| `Arduino/EasySD/CartApi.h` | Command codes (COMMAND_*), response codes, class declaration |
| `Arduino/EasySD/CartInterface.cpp` | Hardware I/O: TransmitByteFast, SetPage, NmiLow/High |
| `Arduino/EasySD/DirFunction.cpp` | SD directory navigation, `currentPath[64]`, FindByPrefix |
| `EasySD/Loader/CartLib.s` | PROT_StartTalking, PROT_EndTalking, PROT_Send — low-level serial |
| `EasySD/Loader/CartLibHi.s` | All high-level protocol functions: OpenFile, Stream, ExitToMenu, etc. |
| `EasySD/Loader/CartLibStream.s` | 32-bit streaming wrapper (top of include chain) |
| `EasySD/Loader/APIMacros.s` | Tier-2 macros: #OPENFILE, #CLOSEFILE, #GETFILEINFO, #SETADDR |
| `EasySD/Loader/SystemMacros.s` | Tier-1 macros: #SETBANK, #WAITFOR, #READCART, etc. |
| `EasySD/Plugins/KoalaDisplayer/KoalaDisplayer.s` | KOA plugin |
| `EasySD/Plugins/PetsciiDisplayer/PetsciiDisplayer.s` | PET plugin |
| `EasySD/Plugins/CvdPlayer/CvdPlayer.s` | CVD plugin with EOF-based NI-stream exit logic in source |
| `EasySD/Plugins/WavPlayer/WavPlayerViceTest.s` | VICE-only audio pipeline test for WAV playback path |
| `EasySD/Plugins/WavPlayer/WavPlayer.s` | WAV plugin |
| `EasySD/Plugins/MusPlayer/MusPlayer.s` | MUS plugin with `/PLUGINS/SIDPLAYER.PRG` dependency |
| `EasySD/Loader/Bridges/KernalBridge/KernalBridge.s` | Reference plugin — correct protocol usage |
| `EasySD/Loader/CartZpMap.inc` | Zero page allocation — single source of truth |

---

## Protocol Command Reference

| Command | Value | Arduino handler | Notes |
|---------|-------|-----------------|-------|
| COMMAND_OPEN_FILE | 2 | HandleOpenFile | flags in X, filename dynamic |
| COMMAND_CLOSE_FILE | 3 | HandleCloseFile | closes workingFile |
| COMMAND_WRITE_FILE | 4 | HandleWriteFile | 32-byte payload |
| COMMAND_DELETE_FILE | 5 | HandleDeleteFile | |
| COMMAND_SEEK_FILE | 6 | HandleSeekFile | 16-bit |
| COMMAND_LONG_SEEK_FILE | 7 | HandleLongSeekFile | 32-bit |
| COMMAND_GET_INFO_FOR_FILE | 8 | HandleGetInfoForFile | returns 256 bytes; size at [28..31] |
| COMMAND_GET_PATH | 9 | HandleGetPath | returns 64-byte CWD string |
| COMMAND_READ_DIR | 10 | HandleReadDirectory | 32 bytes per entry |
| COMMAND_CHANGE_DIR | 11 | HandleChangeDirectory | |
| COMMAND_DELETE_DIR | 12 | HandleDeleteDirectory | |
| COMMAND_CREATE_DIR | 13 | HandleCreateDirectory | |
| COMMAND_GOTO_PATH | 14 | HandleGotoPath | MultiLoad absolute path |
| COMMAND_READ_EEPROM | 15 | HandleReadEeprom | |
| COMMAND_SEEK_EEPROM | 16 | HandleSeekEeprom | |
| COMMAND_WRITE_EEPROM | 17 | HandleWriteEeprom | |
| COMMAND_INVOKE_WITH_NAME | 23 | HandleInvokeWithName | loads + launches plugin/prg |
| COMMAND_STREAM | 25 | HandleStream | IRQ double-buffered, IO2 sync |
| COMMAND_NI_STREAM | 26 | HandleNonInterruptedStream | exits on SEL low only |
| COMMAND_READ_NEXT_CHUNK | 27 | HandleReadNextChunk | MK3 WAV path, 22133 Hz |
| COMMAND_END_TALKING | 30 | HandleEndTalking | sent by PROT_EndTalking |
| COMMAND_EXIT_TO_MENU | 31 | HandleEndTalking+TransferMenu | sent by PROT_ExitToMenu |
| COMMAND_HWTEST | 32 | HandleHwTest | data bus diagnostic |
| COMMAND_READ_FILE | 78 | HandleReadFile | 16-byte chunks |
