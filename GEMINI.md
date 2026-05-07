# EasySD Gemini - Developer Assistant Guide (GEMINI.md)

This document is for AI assistants working on the EasySD project. It covers rules, patterns, and
constraints that are not obvious from the code. Always check the code itself — this file describes
*why* things are done a certain way, not just what they are.

- **Current Version**: Post-v3.1.3 / v0.5-era firmware baseline (BASIC-first cold boot, PCB v3, 2026-04-18)
- **Current stable hardware baseline**: boot to BASIC ✅, SEL -> menu ✅, directory navigation ✅, PRG loading ✅
- **Current plugin status note**: the remaining known hardware fault is the plugin-class return path. Current bench tests for `CVID` clear the screen and fall through to top-line `READY.` instead of returning cleanly to the EasySD menu. Other non-PRG plugins should still be treated as not yet re-verified on the present hardware baseline. EasySD does not support multi-disk games.

---

## C64 Development Rules (64tass)

### 1. Linear Include Chain (no include guards in 64tass)
Always include the **highest-level wrapper** required by your code. Lower levels are transitively included.

```
CartLibStream.s → CartLibHi.s → CartLib.s → CartLibCommon.s → System.inc / EasySD.inc
```

Most plugins only need `CartLibStream.s`. Do NOT include multiple levels — it causes duplicate definition errors.

### 2. Macro Tiers — Critical Distinction

**Tier 1 — `SystemMacros.s`** (auto-included via CartLib.s line 16):
- `#SETBANK`, `#WAITFOR`, `#WAITVALUE`, `#SAVEREGS`/`#RESTOREREGS`, `#READCART`, `#READCART_MODULATED`
- Forward-referenceable: plugins can use them before CartLibStream.s is included (multi-pass assembly)
- 64tass macros ARE forward-referenceable in practice (verified)

**Tier 2 — `APIMacros.s`** (must be explicitly `#include`d at top of any file that uses them):
- `#OPENFILE`, `#GETFILEINFO`, `#EXTRACTFILESIZE`, `#CLOSEFILE`, `#SETADDR`
- Kept separate from SystemMacros.s to avoid duplicate macro errors (64tass fatal on duplicates)
- `SETADDR` is in APIMacros.s ONLY — not in SystemMacros.s

### 3. Naming Convention — PROT_ prefix
All CartLib function names use `PROT_` prefix (renamed from `IRQ_` in Sprint 16):
- `PROT_ExitToMenu`, `PROT_StartTalking`, `PROT_EndTalking`
- `PROT_OpenFile`, `PROT_CloseFile`, `PROT_GetInfoForFile`
- `PROT_DisableDisplay`, `PROT_EnableDisplay`
- ZP variables (`ZP_IRQ_*`) and `ROM_IRQ_HANDLER` intentionally kept with `IRQ_` prefix — they are NOT CartLib functions

### 4. Zero Page Usage — Single Source of Truth: `CartZpMap.inc`
All ZP labels use `ZP_` prefix. Never invent ZP addresses — always use the labels.

| Addresses | Reserved for | Notes |
|-----------|-------------|-------|
| `$64-$77` | Low-level communication | ZP_IRQ_DATA_LOW/HIGH, ZP_IRQ_STATUS |
| `$80-$87` | LoadFileBySize — **strictly reserved** | ZP_LF_SIZE0..3, ZP_LF_PAYLOAD_LO/HI — NEVER reuse |
| `$8B-$8E` | Handler scratch (copy ptr lo/hi, end addr temps) | Safe to use in plugins if not in handler context |
| `$90-$95` | StreamLargeFile | ZP_STREAM_TARGET_ADDR_LO/HI, ZP_STREAM_BYTES_REMAIN_0..3 |
| `$91-$93` | WavPlayer MK3 ZP_WAV_TIMERLO/BUF_READY/SILENCE | Overlaps STREAM_REMAIN0/1 — safe (MK3 ≠ StreamLargeFile) |
| `$FB/$FC` | NAMELOW/NAMEHIGH — nav indirect pointer | **NEVER use as temp** (SL_COLOR bug precedent) |
| `$FD/$FE` | COLLOW/COLHIGH — color RAM indirect pointer | **NEVER use as temp** |

Plugin-specific temporaries: use `$FB-$FE` range carefully. These are documented as "plugin range" but $FB/$FC/$FD are dangerous.

### 5. Plugin Conventions
- Entry: save VIC + CPU state (`SAVESTATE` pattern)
- Exit: `JSR PROT_ExitToMenu`
- Error handling: `ERROR_GATE` macro after file operations
- File loading: `LoadFileBySize` (via CartLibHi.s)
- Audio streaming: `JSR PROT_Stream` call (SafeStream dead abstraction was removed; `IRQ_Stream` only in `_archive/`)
- Location on SD card: `/PLUGINS/<EXT>PLUGIN.PRG` (e.g. `/PLUGINS/WAVPLUGIN.PRG`)
- Extension dispatch: `Filename.s` extracts extension → builds plugin path deterministically

### 6. Screen Code vs PETSCII vs ASCII — Critical Distinction
- **Screen RAM** needs screen codes: A-Z = `$01-$1A`, inverted = OR `$80`
- **PETSCII uppercase** A-Z = `$41-$5A` (completely different range — gives graphics chars in screen RAM)
- `.TEXT "ABC"` with `.enc "none"` outputs ASCII ($41,$42,$43) — wrong for screen RAM
- Fix: wrap screen data with `.enc "screen"` / `.enc "none"`
- Lowercase ASCII `$61-$7A` → screen codes `$01-$1A` via `SBC #$60` (NOT `SBC #$20`)
- PETMATE exports `!byte` values as screen codes (not PETSCII)

### 7. Binary Equivalence Refactor Rules
- Before any refactor: `cp file.prg /tmp/baseline.prg`, after: `cmp /tmp/baseline.prg file.prg && echo IDENTICAL`
- `#GETFILEINFO` CANNOT replace partial sequences where another instruction (e.g. `JSR PROT_DisableDisplay`) splits the pointer-setup from `LDY+JSR` — use `#SETADDR` + manual `LDY/JSR` instead

---

## Key C64 APIs

### LoadFileBySize (CartLibHi.s)
Standard way to load file content (max 64KB):
1. `#GETFILEINFO buffer_addr` — retrieves FAT directory entry (32 bytes); file size at offset 28..31
2. `#EXTRACTFILESIZE source_buf, dest_zp` — copies 4 bytes to ZP_LF_SIZE0..3
3. Set target address: `LDA #<dest` / `STA ZP_LF_PAYLOAD_LO` / `LDA #>dest` / `STA ZP_LF_PAYLOAD_HI`
4. `JSR LoadFileBySize`

### P2TK — Phase 2 Transfer Kernel (KernalBridge.s)
For PRGs that load into `$C000+` (trigger: `ENDADDRESS > $C002`):
- Phase 1: LoadFileBySize to `$C000`
- Phase 2: BVC stub at `$033B`, NMI→`$80AF`, `$01=$34` (all RAM)
- Phase 3 (if Phase2_pages=64): P3_HANDLER at `$036A` intercepts `$FFFA-$FFFF` → TAIL_BUF (`$03BB`)
- Data tables at `$C003`/`$C02A` (KernalBridge gap, always-readable RAM)
- No `CLOSEFILE` — intentional (file must stay open during P2TK)
- **Known issue**: MAIN + functions span `$C700-$D113`, with `$D000-$D113` in I/O space. Code execution from `$D000+` unreliable when `$01=$37`. Needs fix (shrink code below `$CFFF`).

---

## Arduino Firmware

### Architecture
- **Entry point**: `Arduino/EasySD/EasySD.ino` — setup/loop, SD init (3 attempts). IRQHack64-style cold boot: AVR does NOT hold C64 `/RESET`; the C64 cold-boots from its own RC reset while AVR initializes SD in parallel.
- **Command routing**: `CartApi.cpp` — all COMMAND_* handlers; new commands registered here
- **Directory navigation**: `DirFunction.cpp` — `currentPath[64]`, relative-path navigation
- **C64 communication**: `CartInterface.cpp` — NMI transfer, IO2 ISR, software serial receive
- **Pin definitions**: `CartInterface.h` — IO2=D3(INT1), EXROM=D2(PD2), NMI=D8, RESET=D9, SEL=A6, STATUS_LED=A7

Current firmware behavior from source:
- Cold boot is IRQHack64-style: `IOSetup()` drives `/RESET` HIGH from the start (no AVR-held reset). The C64 cold-boots to BASIC on its own ~50 ms RC reset; AVR runs `delay(300)` + SD init + `cartApi.Init()` in parallel. By the time the user can press SEL, runtime is ready.
- `TransferMenu()` is called only on explicit short `SEL` press, not automatically at boot.
- `CartApi::Init()` resets directory state to root via `dirFunc.ReInit()` and `dirFunc.Prepare()`.
- After PRG launch transfers, the firmware closes the file, disables the cartridge, re-initializes runtime state, and resumes listening.

### Command Numbers (CartApi.h)
```
COMMAND_OPEN_FILE=2, COMMAND_CLOSE_FILE=3, COMMAND_READ_FILE=78
COMMAND_GET_INFO_FOR_FILE=8, COMMAND_GET_PATH=9
COMMAND_READ_DIR=10, COMMAND_CHANGE_DIR=11
COMMAND_STREAM=25, COMMAND_NI_STREAM=26, COMMAND_READ_NEXT_CHUNK=27
COMMAND_END_TALKING=30, COMMAND_EXIT_TO_MENU=31
```

### Memory Constraints (ATmega328P — CRITICAL)
- **Flash**: 32768B max (no bootloader). Release: ~23708B (77%, ~7KB free). Debug: ~30684B (99%, 36B margin)
- **SRAM**: 2KB total, ~413B free at boot. Keep 300B+ minimum free.
- Monitor with `FreeStack()`. RAM threshold: `>400`=OK, `>300`=LOW, `≤300`=CRIT!

**Never use:**
- `strtok()` — static buffer corruption
- Arduino `String` class — costs ~1700B flash
- Unbounded `strcpy()` — always validate buffer sizes
- Local arrays >64B — stack overflow risk

### SdFat 2.x Patterns
```cpp
// Directory navigation — MUST use relative paths from root
sd.chdir();           // return to root first
sd.chdir("DIRNAME");  // then relative step
// NEVER: sd.chdir("/DIRNAME") — fails on nested paths

// File open/read
File f = sd.open("FILE.DAT", O_READ);
// File type (not deprecated SdFile), 1-param openNext()
while (f.openNext(&dir, O_READ)) { ... }

// Write pattern
File f = sd.open("FILE.DAT", O_WRONLY | O_CREAT);
size_t wr = f.write(buf, len);         // returns 0 on failure (NOT -1, it's size_t)
if (wr == 0 || f.getWriteError()) { f.clearWriteError(); /* handle */ }
f.sync();   // CRITICAL: flush to SD — data lost without this
f.close();

// SD recovery (after any SD error)
dirFunc.CloseDirHandle();
delay(50);
sd.begin(chipSelect, SPI_HALF_SPEED);
dirFunc.ForceReset();
```

**SdFat version note**: `openCwd()` and `vwd()` are NOT in SdFat 2.3.0 — check build log for version.
**SPI speed**: `SPI_HALF_SPEED` (8 MHz) — stable on breadboard (8/8 tests) and PCB v3. `SPI_QUARTER_SPEED` not needed.

### SD Error Codes
- `0x0D` = WRITE_DATA (card rejected write data — SPI noise)
- `0x19` = READ_TOKEN (bad read data token — SPI signal issue)
- `0x21` = WRITE_TIMEOUT (flash programming timeout)

### CartApi Conventions
- `GetArgumentsDynamic()` callers MUST null-terminate the filename buffer:
  ```cpp
  if (fileNameLength < MAX_ARGUMENTS_LENGTH) fileName[fileNameLength] = 0;
  else fileName[MAX_ARGUMENTS_LENGTH-1] = 0;
  ```
- Debug log format: `[LEVEL][CATEGORY] message` — e.g. `[INFO][SD] SD OK`, `[ERR][DIR] chdir failed`
- Categories: `SYS`, `SD`, `DIR`, `FILE`, `PROTO`, `PRG`, `ERR`, `STR`, `EE`, `API`
- `LOG_ENABLE_PRG` and `LOG_ENABLE_PROTO` are OFF by default (flash savings ~1.3KB)

### Hardware Notes (PCB v3)
- **Pin swap vs breadboard**: IO2=D3 (INT1), EXROM=D2 (PD2). Previously IO2=D2/INT0. PIND bitmask: IO2→0x08
- **SEL button**: A6 (analog-only — no `digitalRead`). Debounced in `EasySD.ino` with separate press/release thresholds. Release at or before the 1000 ms threshold → `TransferMenu()`. Release strictly after 1000 ms → `ResetNoCartridge()`.
- **Cold boot policy**: IRQHack64-style — AVR does NOT drive `/RESET` LOW during startup. C64 cold-boots from its own RC reset; AVR initializes SD in parallel. Menu is not auto-loaded on cold boot. **Verified co-required**: parasitic loads on the C64 power rail (Pi1541, IEC2SD on uEliteBoard64 (uni64.com)) must be removed for a stable cold boot.
- **STATUS_LED**: A7 (NC on PCB — LED is hardware-driven from cartridge 5V rail, always on when powered)
- **Data bus**: D4-D7 + A0-A3 (PORTD[4:7]/PORTC[0:3]) drive the C64 data bus only while the cartridge transfer path is enabled. Idle state must be true tristate (no AVR pull-ups left latched on the bus). IO1 is NOT connected.
- **EXROM glitch prevention**: Set `PORTD |= _BV(PD2)` HIGH *before* `DDRD |= _BV(PD2)` output. Otherwise ~1-2µs LOW glitch causes C64 freeze via ROML assertion.
- **CBM80 detection window**: Data bus pins must be INPUT (tristate) during CBM80 check so EEPROM drives bus undisturbed.
- **Transfer speeds**: NMI ~40 KB/s; IO2 streaming ~13.5 KB/s; CvdPlayer: NMI at STARTRASTER=241 via READCART_MODULATED
- **A5=IRQ, A4=PHI2**: A5 remains reserved; A4/PHI2 is actively read in firmware to synchronize cartridge visibility and bus-drive changes.
- **Bench hardware caveat**: On the current repeatedly re-seated test unit, intermittent cartridge-edge or module-header contact can mimic boot/reset firmware faults. In addition, a Nano 3.x can still pass ISP write/verify and yet fail in EasySD runtime use; bench testing has already shown one long-used Nano that would no longer bring up the C64 screen in EasySD while another Nano with the same firmware worked correctly. If touching the cartridge changes startup behavior, or if swapping only the Nano changes the result, treat that as hardware integrity first.

### EEPROM
- Last-directory persistence is not an active feature.
- Startup begins from root; the firmware does not preserve any session-local path across launches.
- The MCU EEPROM is currently reserved for future use and must not be documented as a live boot/navigation dependency.

---

## WavPlayer MK3 Summary
See `memory/wavplayer_detail.md` for full CIA timing and rate calibration details.

- **Modes**: PLAYTYPE 0-6. Modes 3-6 are DigiMax MK3 NMI-buffered (auto-detected)
  - PLAYTYPE_MK3=3 (11025 Hz mono), PLAYTYPE_MK3_22K=4 (22050 Hz mono), PLAYTYPE_MK3_STEREO=5 (11025 Hz stereo), PLAYTYPE_MK3_STEREO_OS=6 (11025 Hz stereo 4× oversample)
- **CIA rate rule**: CIA 6526 timer N+1 period → 985248/(N+1) Hz. Timer=89 → 10947 Hz; timer=44 → 21894 Hz
- **MK3 calibration**: OCR1A must be slightly slower than C64 CIA rate to prevent FIFO drain
  - Mode3: OCR1A=1461 (10944 Hz). Mode4: OCR1A=730 (21888 Hz)
- **TransmitByteFastMK3**: 35µs inter-byte delay → 22133 Hz fill rate (needs hardware verification)
- **ZP overlap**: $91-$93 (WAV_TIMERLO/BUF_READY/SILENCE) overlaps STREAM_API_REMAIN0/1 — safe (MK3 and StreamLargeFile never concurrent)

---

## Build & Test Quick Reference

```bash
python Tools/build.py release                    # full build (C64 + Arduino release artifacts)
python Tools/build.py plugins                    # plugins only
python Tools/build.py arduino-compile --debug    # Arduino debug firmware (SERIAL ON)
python Tools/build.py arduino-upload-isp --debug # ISP upload, debug firmware
python Tools/build.py arduino-monitor COM4       # serial monitor (57600 baud)
deploy-debug.bat                                 # full hardware debug deploy (C64 release + Arduino debug + SD copy)
deploy-release.bat                               # full release deploy
```

**Serial debug**: real C64 + Arduino at 57600 baud. All output is event-driven `[LEVEL][CATEGORY]` log lines. The interactive `h`/`m`/`d`/`l`/`p`/`r`/`T`/`F`/`G`/`B` commands and the on-device self-test / protocol-test suites have been removed.

---

## Important File Paths

| File | Purpose |
|------|---------|
| `EasySD/Loader/CartZpMap.inc` | ZP allocation (single source of truth) |
| `EasySD/Loader/SystemMacros.s` | Tier 1 macros (auto-included via CartLib.s) |
| `EasySD/Loader/APIMacros.s` | Tier 2 macros (explicit include required) |
| `EasySD/Loader/Common/EasySD.inc` | EasySD-specific constants |
| `EasySD/Loader/Common/System.inc` | Standard C64 addresses and KERNAL vectors |
| `EasySD/Menu/EasySD/EasySDMenu.s` | Main menu (entry $0801) |
| `EasySD/Loader/Bridges/KernalBridge/KernalBridge.s` | P2TK PRG loader |
| `Arduino/EasySD/EasySD.ino` | Arduino entry point |
| `Arduino/EasySD/CartApi.cpp` | Command routing |
| `Arduino/EasySD/DirFunction.cpp` | Directory navigation |
| `Arduino/EasySD/CartInterface.h` | Pin definitions |
| `Arduino/EasySD/EasySDLog.h` | Logging macros + category flags |
| `Tools/build.py` | Unified build system |
| `docs/architecture/CARTRIDGE_PROTOCOL.md` | Protocol specification (accurate) |
| `docs/architecture/TIMING.md` | Transfer timing reference |
| `docs/plugins/` | Per-plugin documentation (updated Sprint 16) |
| `docs/arduino/PCB_BRINGUP_NOTES.md` | PCB v3 hardware bringup |

---

**Last Updated**: 2026-04-18 — PCB v3 validated, BASIC-first cold boot, plugin debugging next
