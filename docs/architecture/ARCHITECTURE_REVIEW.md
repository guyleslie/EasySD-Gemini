# EasySD Architecture Review

This file is a concise architecture note derived from the current source layout. It is not intended to be a praise document or a historical evaluation transcript.

---

## High-Level Model

EasySD is split into two cooperating sides:

- **C64 side**: menu, loaders, protocol library, and file-type plugins in 6502 assembly.
- **Arduino side**: SD card access, command dispatch, stream handling, and menu transfer.

The C64 initiates operations. The Arduino responds, manages filesystem access, and pushes data back to the C64 through the cartridge interface.

---

## Cold Boot Sequence

EasySD uses **IRQHack64-style** cold boot: the AVR does NOT hold the C64 in reset.
`IOSetup()` drives `/RESET` HIGH from the start, EXROM HIGH (cartridge hidden), and
leaves the data bus as INPUT (tristate). The C64 cold-boots to BASIC on its own
RC reset (~50 ms) while `setup()` runs `delay(300)` + `initSD()` + `cartApi.Init()`
in parallel. By the time the user can press SEL, runtime is ready.

Sequence in `setup()`:

1. `cartInterface.Init()` → `IOSetup()`: `/RESET=HIGH`, EXROM=HIGH, NMI=HIGH (deasserted), IO2/PHI2 INPUT, data bus tristate.
2. `delay(300)` — SD card power-up settling time (SD Physical Layer spec § 6.4.1).
3. `initSD()` — up to 3 attempts with 200 ms retry.
4. On success: `cartApi.Init()` → `dirFunc.ReInit()` + `Prepare()`; `runtimeReady = true`.
5. On failure: log error; the C64 is already in BASIC, SEL can retry SD init.

There is no boot state machine and no `ReleaseColdBootToBasic()` call any more —
both were removed when the IRQHack64-style cold boot was adopted on 2026-05-02.
See `docs/COLD_BOOT_FAILURE_RETROSPECTIVE.md` for the diagnostic history.

> **EXROM at boot:** `IOSetup()` latches EXROM HIGH *before* enabling the EXROM
> output pin (`PORTD |= _BV(PD2)` then `DDRD |= _BV(PD2)`) — no /EXROM glitch.
> The C64 sees no cartridge until `EnableExromOnly()` is called from `TransferMenu()`.

> **Hardware co-requirement:** parasitic loads on the C64 power rail (Pi1541,
> IEC2SD, etc.) can destabilize cold boot independently of firmware. Verified on
> uEliteBoard64 (uni64.com) — removing a Pi1541 from the C64 power was a co-required fix
> alongside the IRQHack64-style boot.

SEL button (A6, analog-only, 10 kΩ pull-up to +5V):

- Short press (12 ms – 1 000 ms): `TransferMenu()` — loads and runs the EasySD menu
- Long press (> 1 000 ms): `ResetNoCartridge()` — resets C64 with no cartridge active
- Boot guard: first 500 ms after release is ignored to prevent false triggers during SD init

---

## Communication Layers

### C64 to Arduino

The C64 sends commands through the CartLib protocol layer. Current public-facing routines use the `PROT_` prefix.

Examples:

- `PROT_StartTalking`
- `PROT_EndTalking`
- `PROT_OpenFile`
- `PROT_CloseFile`
- `PROT_ExitToMenu`

### Arduino to C64

The Arduino sends bulk data back mainly through the NMI-based transfer path. The C64-side `TransferHandler` remains a central part of this mechanism.

For media-oriented paths, the project also uses streaming variants such as IO2-triggered transfer and the NI-stream path used by CvdPlayer.

---

## Directory State Model

The current source treats the firmware current working directory as the real filesystem state.

- `DirFunction::ResyncDirFromCwd()` reopens the directory handle from CWD.
- `currentPath` is retained for UI/debug use.
- Directory operations update both the firmware CWD and the display-oriented path string, but the CWD is the authoritative source.

This is the model described by the current implementation and by `DIRECTORY_LIFECYCLE_INVARIANT.md`. Older descriptions that treat `currentPath` itself as the sole filesystem truth should not be preferred.

---

## File Loading and Menu Transfer

- `LoadFileBySize` remains the standard high-level file loading path on the C64 side.
- Ordinary menu `.PRG` launches currently use the direct Arduino
  `LoadAndLaunchFile()` path plus the C64 RAM `LoaderStub`.
- `LoaderStub` now decides between BASIC `RUN` and direct `JMP` from the loaded
  content, not only from the PRG load address. This covers both normal `$0801`
  BASIC PRGs and hybrid files that load below `$0801` but still carry a BASIC
  `SYS` stub at `$0801`.
- KernalBridge/P2TK remains a separate bridge path for large/self-overwriting
  PRG workflows; it is not the default ordinary `.PRG` menu route.
- `TransferMenu()` on the Arduino side resets directory state, prefers `EASYSD.PRG` from the SD root if present, and otherwise falls back to the built-in payload stored in `cartridgeData`.

Important artifact distinction:

- `IRQLoaderRom.bin` is the build output used for programming the cartridge ROML chip.
- `easysd.prg` is the menu program that can be loaded from the SD card root.

---

## Plugin Dispatch Model

The menu dispatches non-PRG file types to plugins stored under `/PLUGINS/`. The dispatch
logic in `EasySDMenu.s` first checks the file extension via `CHECKFILENAME` / `ISPRG`:

- **`.PRG` files** always take the `PROGRAM` branch (`BCC PROGRAM`), which calls
  `PROT_InvokeWithName` → Arduino `LoadAndLaunchFile()` → `LoaderStub`. They never
  reach the `PLUGIN` branch. `PRGPLUGIN.PRG` (KernalBridge) is **not** invoked by
  this path.
- **All other extensions** take the `PLUGIN` branch. The menu constructs the plugin
  path as `/PLUGINS/<EXT>PLUGIN.BIN` (preferred) then `/PLUGINS/<EXT>PLUGIN.PRG`
  (fallback), where `<EXT>` is the first three characters of the file extension.

Active plugins and their SD card filenames:

| Extension | SD card file | Build output |
|-----------|-------------|---------------|
| `.KOA` | `KOAPLUGIN.PRG` | `koaplugin.prg` |
| `.PET` | `PETPLUGIN.PRG` | `petgplugin.prg` (note: legacy build name mismatch — SD card file must be named `PETPLUGIN.PRG`) |
| `.WAV` | `WAVPLUGIN.PRG` | `wavplugin.prg` |
| `.CVD` | `CVDPLUGIN.PRG` | `cvdplugin.prg` |
| `.HWT` | `HWTPLUGIN.PRG` | `hwtplugin.prg` |

`BOOTPLUGIN.PRG` (MultiLoad) is triggered separately and is not part of the extension-based dispatch above.

The exact hardware reliability of each plugin must be established from source plus current test evidence; see `docs/PLUGIN_HARDWARE_BUGS.md`.

---

## Macro and Include Structure

The active include chain is linear and intentionally shallow from the plugin point of view:

```text
CartLibStream.s -> CartLibHi.s -> CartLib.s -> CartLibCommon.s -> Common/System.inc + Common/EasySD.inc
```

Macro usage is split into two levels:

- **Tier 1**: system and hardware-facing macros included through the CartLib chain.
- **Tier 2**: API helper macros from `APIMacros.s`, included explicitly where needed.

---

## Testing and Debugging Notes

The supported validation path is real C64 hardware with the Arduino connected over USB for serial logs.

- `deploy-debug.bat` builds release C64 software and Arduino debug firmware.
- `python Tools/build.py arduino-monitor COM4` shows live firmware logs during real C64 operation.
- Source contains hardware-sensitive paths where code inspection alone is not enough to declare final reliability.

---

## Boundaries and Terminology

- The **cartridge ROML chip** is the external cartridge memory device on the PCB.
- The **MCU internal EEPROM** is the ATmega328P built-in EEPROM used by firmware.

These two must not be conflated in documentation or code comments.
