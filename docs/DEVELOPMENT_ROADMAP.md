# EasySD Development Roadmap

Last updated: 2026-04-25 (post 0.7 cleanup, HEAD `5c40c70`)

This file is the short planning view of the project. It tracks the current source-backed
state and the next planned work. Historical debugging transcripts live under `docs/archive/`.

---

## Current Source-Backed State (verified on PCB v3 hardware)

The following are directly supported by the current codebase and confirmed on real hardware
during the 0.7 cleanup pass:

- Cold boot does not auto-load the menu. `setup()` initializes SD/runtime, then calls
  `ReleaseColdBootToBasic()` so the C64 comes up in BASIC. The release path issues a
  release HIGH, a 50ms HIGH dwell, then a warm-style `ResetC64()` pulse — the C64
  boots from the second (short) rising edge, which is the verified-good warm-reset edge.
  Menu transfer happens only on an explicit short `SEL` press in `loop()`.
- `TransferMenu()` prefers `EASYSD.PRG` from the SD card root and falls back to built-in
  `cartridgeData` if the file is not present.
- Directory handling uses the firmware CWD as the source of truth, with `currentPath` kept
  as UI/debug state. `DirFunction::ResyncDirFromCwd()` resynchronizes after every chdir.
- Menu navigation uses `COMMAND_CHANGE_DIR_INDEX` for visible-row directory changes,
  avoiding stale-name and deep-stack issues on the Arduino side.
- PRG loading uses KernalBridge and the P2TK path for programs extending into `$C000+`.
- PRG launch returns the Arduino side to a clean baseline by closing the file, disabling
  the cartridge, calling `Init()`, and starting listening again.
- Long filenames and full path handling work; recent plugin-side fixes no longer assume a
  fixed 31-byte media filename.
- **Sima MultiLoad PRG bundles** (created via `Tools/create_multiload.py` without resident
  chaining) run from `MULTILOAD/GAMENAME/` folders and are **verified working** on real HW.

---

## Known Issues (out of scope for 0.7 release)

- **MultiLoad EASYLOAD.PRG chain** — hangs after MAIN's `JMP ($008B)` with a distinctive
  fingerprint: outer border = black, inner area = blue. The colors come from the loaded
  first part starting up, not from MultiLoad MAIN. So MAIN finishes cleanly and the game
  begins executing, then dies on the first `LOAD "...",8,x` through the resident hook.
  Suspected root cause: `RL_STUB` at `$033C` (cassette buffer) is wiped by games that
  nullify `$0200-$03FF` during init.
- **WavPlayer / KoalaDisplayer / PetsciiDisplayer / CvdPlayer / HWTest** — fail on real
  hardware with various symptoms. Not re-verified on the current firmware baseline.

These are tracked in detail in `docs/PLUGIN_HARDWARE_BUGS.md`.

---

## Protocol Invariants Worth Preserving

These rules are critical for cartridge-facing plugins:

1. Start the cartridge session before file/cart operations (`PROT_StartTalking`).
2. Close opened files on all paths where open succeeded (`PROT_CloseFile`).
3. End the session on both success and failure exits (`PROT_EndTalking`).
4. Return to the menu only after session cleanup (`PROT_ExitToMenu`).

`KernalBridge` is the clearest reference implementation for this pattern.

---

## Planned Refactoring — Arduino Side (low priority)

`CartApi.cpp` (~1452 lines) mixes protocol dispatch, PRG loading, streaming, hardware test,
and string utilities. Splitting it improves navigability and makes each concern testable
independently. Flash/SRAM cost of splitting: zero — the linker sees the same compiled
output regardless of how many `.cpp` files the code is spread across.

**Rule per phase:** must produce identical HEX output, one phase per commit, build verified
before/after.

### Planned modules (in priority order)

| Phase | Module | Complexity | What moves out |
|-------|--------|------------|----------------|
| 1 | `HwTest.cpp/.h` | Trivial | `HandleHwTest()` and supporting helpers (~80 lines). Wrap in `#ifdef COMMAND_HWTEST` for conditional compilation. |
| 2 | `PrgLoader.cpp/.h` | Medium | `LoadAndLaunchFile`, `SendHeader`, `SendLoaderStub`, `TransferMenu`. Pass `workingFile` and `cartInterface` as references. |
| 3 (optional) | `StringUtils.h` | Trivial | `IsMatchLast`, `StartsWith` inline helpers — only if needed. |

A previously planned `TapConverter.cpp` phase is **obsolete**: TAP-to-PRG support was fully
removed in 2026-04 (commits `d42fcb8`, `8dfcf55`).

### What stays in CartApi.cpp

The protocol dispatch core: `HandleApi()`, `GetArgumentsStatic/Dynamic()`, `HandleResponse/
HandleValueResponse()`, `AwaitByte()/GetByte()`, all `Handle*()` file/dir/stream handlers,
and `Init()`.

---

## Planned Refactoring — C64 Assembly Side

### Decision: do NOT split `CartLibHi.s`

Reasons:
1. Splitting requires a new umbrella include file and updating every plugin — high churn,
   low gain.
2. The VIC-display, directory, and stream helpers are all part of one protocol-facing layer.
3. The current size alone does not justify structural churn.

### What IS worth doing in `CartLibHi.s`

- Improve English comments (some are outdated or missing).
- Document the `PROT_StartTalking` / `PROT_EndTalking` contract at the top of the file.
- Add a clear section header for each functional group (file ops, dir ops, stream).

### Plugin checklist comment

Add a plugin skeleton or checklist at the top of `CartLibHi.s` (or in a separate
`PluginTemplate.s`) to make the protocol invariant impossible to miss:

```asm
; PLUGIN PROTOCOL CHECKLIST:
;   1. JSR PROT_StartTalking          — before ANY file/cart operation
;   2. #OPENFILE / file ops / etc.
;   3. JSR PROT_CloseFile             — on ALL paths where OPENFILE succeeded
;   4. JSR PROT_EndTalking            — on ALL exit paths (success AND error)
;   5. JSR PROT_ExitToMenu            — last call before JMP *
```

---

## Recommended Work Sequence (post-0.7)

```
Phase 1 — EASYLOAD chain debug (highest value)
  🔲 Add canary byte at $033F to test the "RL_STUB wiped" hypothesis
  🔲 If confirmed, relocate RL_STUB out of $0200-$03FF (e.g. $C000+ via bridge)
  🔲 Add C64-side timeout to RL_WaitProcessing to mirror Arduino's 200 ms reset

Phase 2 — Media plugin re-verification
  🔲 WavPlayer: hardware-focused validation of playback modes
  🔲 KoalaDisplayer / PetsciiDisplayer: simple display path
  🔲 CvdPlayer: confirm EOF-driven NI-stream exit on hardware
  🔲 HWTest: data bus diagnostic on current firmware

Phase 3 — Arduino CartApi.cpp refactor (only if maintenance burden grows)
  🔲 Extract HwTest.cpp/.h
  🔲 Extract PrgLoader.cpp/.h

Phase 4 — C64 library comment cleanup
  🔲 CartLibHi.s: English comments, section headers, protocol invariant block
  🔲 Plugin protocol checklist / template
```

---

## Key Files Quick Reference

| File | Purpose |
|------|---------|
| `Arduino/EasySD/CartApi.cpp` | Protocol dispatcher — ~1452 lines, primary refactor target |
| `Arduino/EasySD/CartApi.h` | Command codes (COMMAND_*), response codes, class declaration |
| `Arduino/EasySD/CartInterface.cpp` | Hardware I/O: TransmitByteFast, SetPage, NmiLow/High |
| `Arduino/EasySD/DirFunction.cpp` | SD directory navigation, `currentPath[64]`, FindByPrefix |
| `EasySD/Loader/CartLib.s` | PROT_StartTalking, PROT_EndTalking, PROT_Send — low-level serial |
| `EasySD/Loader/CartLibHi.s` | High-level protocol: OpenFile, Stream, ExitToMenu, etc. |
| `EasySD/Loader/CartLibStream.s` | 32-bit streaming wrapper (top of include chain) |
| `EasySD/Loader/APIMacros.s` | Tier-2 macros: #OPENFILE, #CLOSEFILE, #GETFILEINFO, #SETADDR |
| `EasySD/Loader/SystemMacros.s` | Tier-1 macros: #SETBANK, #WAITFOR, #READCART, etc. |
| `EasySD/Loader/CartZpMap.inc` | Zero page allocation — single source of truth |
| `EasySD/Loader/Bridges/KernalBridge/KernalBridge.s` | Reference plugin — correct protocol usage |
| `EasySD/Loader/Bridges/MultiLoad/MultiLoad.s` | MultiLoad MAIN (sima bundle works, EASYLOAD chain hangs post-JMP) |
| `EasySD/Loader/ResidentLoader.s` | RL_STUB / RL_HANDLER for EASYLOAD chain (suspect for the chain hang) |
| `EasySD/Plugins/KoalaDisplayer/KoalaDisplayer.s` | KOA plugin |
| `EasySD/Plugins/PetsciiDisplayer/PetsciiDisplayer.s` | PET plugin |
| `EasySD/Plugins/CvdPlayer/CvdPlayer.s` | CVD plugin with EOF-based NI-stream exit logic |
| `EasySD/Plugins/WavPlayer/WavPlayer.s` | WAV plugin |
| `Tools/build.py` | Unified build system |
| `Tools/create_multiload.py` | MultiLoad bundle generator |

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
| COMMAND_SET_PORT | 20 | HandleSetPort | set IO port value |
| COMMAND_INVOKE_WITH_NAME | 23 | HandleInvokeWithName | loads + launches plugin/prg |
| COMMAND_STREAM | 25 | HandleStream | IRQ double-buffered, IO2 sync |
| COMMAND_NI_STREAM | 26 | HandleNonInterruptedStream | exits on SEL low only |
| COMMAND_READ_NEXT_CHUNK | 27 | HandleReadNextChunk | MK3 WAV path, 22133 Hz |
| COMMAND_END_TALKING | 30 | HandleEndTalking | sent by PROT_EndTalking |
| COMMAND_EXIT_TO_MENU | 31 | HandleEndTalking + TransferMenu | sent by PROT_ExitToMenu |
| COMMAND_HWTEST | 32 | HandleHwTest | data bus diagnostic |
| COMMAND_CHANGE_DIR_INDEX | 33 | HandleChangeDirectoryIndex | menu: change dir by visible entry index |
| COMMAND_READ_FILE | 78 | HandleReadFile | 16-byte chunks |
