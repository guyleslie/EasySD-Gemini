# EasySD Development Roadmap

Last updated: 2026-04-10

This document captures the current state of the project, the root causes of known bugs,
architectural decisions, and the planned sequence of work. Intended as a hand-off document
between development sessions.

---

## Current Hardware Status (PCB v3, 2026-04-10)

| Feature | Status | Notes |
|---------|--------|-------|
| Cold boot auto-load (menu appears) | ✅ | |
| Directory navigation, scroll indicators | ✅ | |
| PRG loading — all lengths | ✅ | KernalBridge + P2TK for $C000+ programs |
| LFN filenames with spaces | ✅ | BUG-E fixed |
| Long filenames >31 chars | ✅ | BUG-G fixed |
| HWTest plugin | ✅ | Signal diagnostic |
| MultiLoad (Last Ninja 2 etc.) | ⚠️ | GETFILEINFO fix applied, hardware test pending |
| KoalaDisplayer (.KOA) | 🔧 | Protocol fix applied (2026-04-10), test pending |
| PetsciiDisplayer (.PET) | 🔧 | Protocol fix applied (2026-04-10), test pending |
| WavPlayer (.WAV) | ❌ | StartTalking present, failure reason TBD |
| MusPlayer (.MUS) | ❌ | StartTalking present, failure reason TBD |
| CvdPlayer (.CVD) | ❌ | NI stream exit path broken, see below |

---

## Root Cause Analysis: Plugin Failures

### The Core Protocol Invariant

Every plugin that communicates with the cartridge MUST follow this pattern — without
exception. KernalBridge (the working PRG loader) is the reference implementation:

```asm
JSR PROT_StartTalking      ; 1. Send 3-byte handshake — synchronises the Arduino
                           ;    into command-receive mode. MUST come first.

; ... file operations: #OPENFILE, PROT_GetInfoForFile, LoadFileBySize, etc. ...

JSR PROT_CloseFile         ; Close any open file handle
JSR PROT_EndTalking        ; 2. Send END_TALKING cmd, reset cartridge bank.
                           ;    MUST be called on ALL exit paths (success AND error).
JSR PROT_ExitToMenu        ; 3. Send EXIT_TO_MENU cmd — Arduino calls TransferMenu().
```

**Why PROT_StartTalking is mandatory:**
The Arduino calls `cartInterface.StartListening()` after every plugin transfer. This waits
for the 3-byte handshake from the C64. Without it, the Arduino is listening but not
synchronised — it will silently discard or misinterpret all subsequent command bytes.
Result: `#OPENFILE` fails, `PROT_ExitToMenu` fails, the C64 hangs forever.

**Why PROT_EndTalking must be on every exit path:**
`PROT_EndTalking` sends cmd 30 (END_TALKING) and then executes `#SETBANK PP_CONFIG_DEFAULT`
which resets the cartridge memory map. Without it, the cartridge remains in an active
state, corrupting subsequent operations.

**File handle cleanup rule:**
`PROT_CloseFile` must be called before `PROT_EndTalking` on any path where a file was
successfully opened (i.e. `#OPENFILE` returned carry clear). On paths where `#OPENFILE`
failed (carry set), no close is needed.

---

### Bug Log: KoalaDisplayer and PetsciiDisplayer (FIXED 2026-04-10)

**KoalaDisplayer:**
- Missing `JSR PROT_StartTalking` at `ALTENTRY` — all protocol calls failed silently
- Missing `JSR PROT_CloseFile` in `ERRORREADING` and `ERROR_BADSIZE` paths
- Missing `JSR PROT_EndTalking` in `EXITFAIL` before `PROT_ExitToMenu`

**PetsciiDisplayer (had an additional critical bug):**
- Missing `JSR PROT_StartTalking` at `ALTENTRY`
- **Critical:** `BCC +` after `LoadFileBySize` — the `+` anonymous label pointed
  directly at `ERRORREADING`. Both the success path and the error path jumped to the
  same error handler. Even a perfect file load would show "READING FAILED" and exit.
  Fixed by adding explicit `LOAD_SUCCESS` label with `CloseFile → DisplayPicture → INPUT_GET`.
- Missing `JSR PROT_CloseFile` in `ERRORREADING` and `ERROR_BADSIZE`
- Missing `JSR PROT_EndTalking` in `EXITFAIL`

Commit: `b3454ed`

---

### Bug: CvdPlayer — NI Stream Exit Path (NOT YET FIXED)

CvdPlayer correctly calls `PROT_StartTalking`. Its main failure is the exit mechanism.

**How NI streaming works:**
1. C64 calls `JSR PROT_NIStream` with A=50 — this sends `COMMAND_NI_STREAM` to the Arduino.
2. Arduino enters `HandleNonInterruptedStream()` — an infinite loop that streams data
   synchronised to IO2 falling edges, until the physical **SEL button** is pressed.
3. C64 NMI handlers (`NMI.s`) receive 8 bytes per NMI fire via `READCART_MODULATED`.

**The broken exit path (STOP key):**
```asm
StopPressed:
    SEI                    ; Stops NMI handlers — no more IO2 pulses from C64
    STA $D01A              ; Disable raster IRQ
    JSR PROT_CloseFile     ; BUG: Arduino is still in NI stream loop, not command mode
    JSR PROT_ExitToMenu    ; BUG: same — Arduino cannot receive this command
```

The Arduino's NI stream loop only exits on `!selRead()` (physical SEL button press).
When the C64 stops firing NMIs (SEI), the Arduino spins forever waiting for IO2.
`PROT_CloseFile` and `PROT_ExitToMenu` try to send commands on the serial channel —
but the Arduino is not listening for commands, it's waiting for IO2 edges. Deadlock.

**Correct exit sequence for NI streaming:**
The physical SEL button press is the only way to terminate the NI stream from the Arduino
side. After the user presses SEL:
1. Arduino exits `HandleNonInterruptedStream()`, calls `cartInterface.StartListening()`
2. C64 code (if it detects GAME line going low) calls `JSR PROT_StartTalking` again
3. Then `JSR PROT_CloseFile` → `JSR PROT_EndTalking` → `JSR PROT_ExitToMenu`

**Required fix:**
- Detect GAME line ($DD00 bit) going low as the exit trigger instead of STOP key
- OR restructure the streaming loop so the C64 counts frames and terminates gracefully
- `ERROR_OPENING_FILE` also needs `PROT_EndTalking` before `PROT_ExitToMenu`

---

### Bug: WavPlayer and MusPlayer (NOT YET INVESTIGATED)

Both call `PROT_StartTalking` correctly. Failure reason unknown — needs hardware debug
with border color tracing (`--ml-debug-borders` build) to isolate the hang stage.

**WavPlayer:** Very complex (1300+ lines), multiple playback modes (SID, DigiMax, MK3).
May have timing issues with the double-buffered streaming on real hardware.

**MusPlayer:** Depends on loading `SIDPLAYER.PRG` from the SD card at `$9000`.
If the player binary is missing, incorrect format, or its entry point symbols
(`PLAYER_INSTALL`, `PLAYER_INIT_SONG`, etc.) do not match the loaded binary,
the plugin will crash after loading. The `ComputePlayerSymbols.inc` file provides
these addresses — verify it matches the actual SIDPLAYER.PRG on the SD card.

---

## Planned Refactoring — Arduino Side

### Goal
`CartApi.cpp` is 1585 lines and mixes protocol dispatch, TAP decoding, PRG loading,
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
- All `Handle*()` file, directory, EEPROM, stream handlers
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
1. Splitting requires a new umbrella include file and updating every plugin — high churn,
   low gain.
2. The "alien" routines (VIC display on/off, EEPROM access) are all protocol commands
   (`COMMAND_*` bytes sent to Arduino) — they belong in the same protocol layer.
3. 633 lines is not large for an embedded ASM library file.

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
Phase 1 — Plugin bug fixes (in progress)
  ✅ KoalaDisplayer: StartTalking + EndTalking + CloseFile paths
  ✅ PetsciiDisplayer: StartTalking + BCC label fix + EndTalking + CloseFile paths
  🔲 CvdPlayer: NI stream exit redesign (GAME line detection)
  🔲 WavPlayer: hardware debug with border colors
  🔲 MusPlayer: verify SIDPLAYER.PRG + ComputePlayerSymbols.inc alignment

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
| `Arduino/EasySD/CartApi.cpp` | Protocol dispatcher — 1585 lines, primary refactor target |
| `Arduino/EasySD/CartApi.h` | Command codes (COMMAND_*), response codes, class declaration |
| `Arduino/EasySD/CartInterface.cpp` | Hardware I/O: TransmitByteFast, SetPage, NmiLow/High |
| `Arduino/EasySD/DirFunction.cpp` | SD directory navigation, `currentPath[64]`, FindByPrefix |
| `EasySD/Loader/CartLib.s` | PROT_StartTalking, PROT_EndTalking, PROT_Send — low-level serial |
| `EasySD/Loader/CartLibHi.s` | All high-level protocol functions: OpenFile, Stream, ExitToMenu, etc. |
| `EasySD/Loader/CartLibStream.s` | 32-bit streaming wrapper (top of include chain) |
| `EasySD/Loader/APIMacros.s` | Tier-2 macros: #OPENFILE, #CLOSEFILE, #GETFILEINFO, #SETADDR |
| `EasySD/Loader/SystemMacros.s` | Tier-1 macros: #SETBANK, #WAITFOR, #READCART, etc. |
| `EasySD/Plugins/KoalaDisplayer/KoalaDisplayer.s` | KOA plugin (fixed) |
| `EasySD/Plugins/PetsciiDisplayer/PetsciiDisplayer.s` | PET plugin (fixed) |
| `EasySD/Plugins/CvdPlayer/CvdPlayer.s` | CVD plugin (NI stream exit still broken) |
| `EasySD/Plugins/WavPlayer/WavPlayer.s` | WAV plugin (failure TBD) |
| `EasySD/Plugins/MusPlayer/MusPlayer.s` | MUS plugin (SIDPLAYER.PRG dependency) |
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
