# EasySD Architecture Review

This file is a concise architecture note derived from the current source layout. It is not intended to be a praise document or a historical evaluation transcript.

---

## High-Level Model

EasySD is split into two cooperating sides:

- **C64 side**: menu, loaders, protocol library, and file-type plugins in 6502 assembly.
- **Arduino side**: SD card access, command dispatch, stream handling, menu transfer, and MCU-internal-EEPROM support.

The C64 initiates operations. The Arduino responds, manages filesystem access, and pushes data back to the C64 through the cartridge interface.

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
- PRG loading for larger memory ranges uses KernalBridge and the P2TK path.
- `TransferMenu()` on the Arduino side resets directory state, prefers `EASYSD.PRG` from the SD root if present, and otherwise falls back to the built-in payload stored in `cartridgeData`.

Important artifact distinction:

- `IRQLoaderRom.bin` is the build output used for programming the cartridge ROML chip.
- `easysd.prg` is the menu program that can be loaded from the SD card root.

---

## Plugin Dispatch Model

The menu dispatches file types to plugins stored under `/PLUGINS/`.

Examples:

- `KOAPLUGIN.PRG`
- `PETGPLUGIN.PRG`
- `WAVPLUGIN.PRG`
- `MUSPLUGIN.PRG`
- `CVDPLUGIN.PRG`

MusPlayer also depends on `/PLUGINS/SIDPLAYER.PRG`.

The exact hardware reliability of each plugin should not be inferred from this file alone. That must be established from source plus current test evidence.

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

The repository contains both hardware-oriented and emulator-oriented validation paths.

- VICE-side tests exist for menu behavior.
- Some plugins have dedicated debug assets such as `WavPlayerViceTest.s`.
- Source contains hardware-sensitive paths where code inspection alone is not enough to declare final reliability.

---

## Boundaries and Terminology

- The **cartridge ROML chip** is the external cartridge memory device on the PCB.
- The **MCU internal EEPROM** is the ATmega328P built-in EEPROM used by firmware.

These two must not be conflated in documentation or code comments.
