# EasySD Gemini

**A modern, plugin-driven SD card interface for the Commodore 64.**

EasySD brings SD card support to the C64 through a cartridge combining an Arduino Nano/Pro Mini file server with a C64-side menu and plugin architecture. Browse FAT-formatted SD cards and load files directly on real hardware.

> Current version: **v3.1.1** (2026-02-28)

![EasySD Schematic v3](Schematic%20EasySD%20v3.png)

---

## Features

### File Browser
- Directory navigation up to 10 levels deep
- Cursor key navigation, inverse selection highlight, directory header row
- Supports 8.3 FAT filenames; SD card hot-swap via menu reset

### Plugin System

| Plugin | File type | Description |
|--------|-----------|-------------|
| **KernalBridge** | `.PRG` | Loads C64 programs; hooks KERNAL LOAD/SAVE for full BASIC compatibility |
| **TAP** | `.TAP` | Automatic TAP-to-PRG conversion — convert+run or save to SD |
| **KOA** | `.KOA` | Koala Painter full-screen graphics viewer |
| **PETG** | `.PET` | PETSCII art renderer |
| **WAV** | `.WAV` | Digital audio streaming (double-buffered, up to 16 KB/s) |
| **MUS** | `.MUS` | Compute's Sidplayer SID music playback |
| **CVID** | `.CVID` | CVID video playback (Bad Apple!! at ~10 KB/s) |

Plugins are standalone 6502 programs loaded from `/PLUGINS/` on the SD card.

### Hardware
- **Status LED** on pin A5 — 3 blinks = SD OK, 6 = SD fail
- **Cold boot retry** — automatic SD reinitialisation on startup
- **ISP programming** support (USBTinyISP) for blank-chip flashing

---

## Hardware Requirements

- **Commodore 64** (PAL or NTSC)
- **Arduino Nano 3.x** (ATmega328P, 32 KB flash, 2 KB SRAM)
- **SD card** — FAT16/FAT32 formatted, standard SPI module
- **EasySD cartridge PCB** (see schematic above)
- **10–100 µF electrolytic capacitor** across SD VCC/GND (required for SPI stability)
- **Status LED** on pin A5 (optional but recommended)

---

## Quick Start

### Prerequisites

| Tool | Purpose |
|------|---------|
| Python 3.7+ | Build system |
| [64tass](https://sourceforge.net/projects/tass64/) | 6502 cross-assembler (must be in PATH) |
| `petcat` (VICE) | BASIC stub generation (must be in PATH) |
| `arduino-cli` | Arduino compilation and upload |

Install arduino-cli: `winget install Arduino.ArduinoCLI`

### Build & Flash

```bash
# First-time setup: install Arduino libraries
python Tools/build.py arduino-setup

# Full release build (C64 + Arduino)
python Tools/build.py release

# Upload firmware via USB serial
python Tools/build.py arduino-upload COM4

# Upload via ISP programmer (blank chip)
python Tools/build.py arduino-upload-isp --isp-sck 100

# Debug build for VICE emulator (no Arduino needed)
python Tools/build.py debug-vice
```

See [Tools/README.md](Tools/README.md) for all build targets and options.

---

## Architecture

EasySD consists of two cooperating halves connected through the C64 expansion port.

### Arduino Firmware (`Arduino/EasySD/`)

Manages the SD card, FAT filesystem, directory navigation, file streaming, and TAP conversion. Entry point: `EasySD.ino`. Command routing: `CartApi.cpp`. Directory logic: `DirFunction.cpp`.

**ATmega328P constraints:** 2 KB SRAM (~415 bytes free at boot). No dynamic allocation, no Arduino `String` class, all buffers statically sized.

### C64 Software (`EasySD/`)

Cartridge ROM with communication library (`Loader/`), file browser menu (`Menus/EasySD/`), and plugin system (`Plugins/`). Built with 64tass assembler.

**Include hierarchy** (strict linear chain):
```
CartLibStream.s → CartLibHi.s → CartLib.s → CartLibCommon.s → System.inc / EasySD.inc
```

**Two-tier macro system:**
- Tier 1 — `SystemMacros.s`: hardware access patterns (`SETBANK`, `WAITFOR`, `SAVEREGS`, `READCART_MODULATED`) — arrives via the include chain
- Tier 2 — `APIMacros.s`: file API helpers (`OPENFILE`, `GETFILEINFO`, `EXTRACTFILESIZE`) — explicit include at plugin top

### Data Transfer Mechanisms

Two distinct protocols share the expansion port signals:

| Mechanism | Trigger | Data path | Rate | Used by |
|-----------|---------|-----------|------|---------|
| **NMI transfer** | Arduino asserts /NMI (D8) | ROML latch → `$80AB` | ~40 KB/s | File loading (menu, plugins, KernalBridge) |
| **IO2 streaming** | C64 reads `$DF00` → /IO2 pulse | Arduino ISR → IO1 latch → `$DE00` | ~13.5 KB/s | WavPlayer, CvidPlayer |

See [docs/architecture/CARTRIDGE_PROTOCOL.md](docs/architecture/CARTRIDGE_PROTOCOL.md) for full hardware and timing details.

---

## Project Structure

```
EasySD Gemini/
├── Arduino/EasySD/             # Arduino firmware (C++, SdFat 2.x)
│   ├── EasySD.ino              # Entry point
│   ├── CartApi.cpp             # Command routing
│   └── DirFunction.cpp         # Directory navigation
├── EasySD/                     # C64 assembly source (6502, 64tass)
│   ├── Loader/                 # Cartridge ROM & communication library
│   │   ├── Bridges/KernalBridge/ # KERNAL bridge plugin
│   │   ├── CartLib.s           # NMI transfer, IRQ handlers
│   │   ├── CartLibStream.s     # IO2 streaming, SafeStream
│   │   ├── CartZpMap.inc       # Zero page allocation (single source of truth)
│   │   └── SystemMacros.s      # Tier 1 assembly macros
│   ├── Menus/EasySD/           # Main file browser menu
│   └── Plugins/                # File-type plugins (KOA, WAV, MUS, CVID, TAP)
├── Tools/                      # Python build system + test tools
├── docs/                       # Documentation
│   ├── architecture/           # Technical architecture docs
│   ├── build/                  # Build system docs
│   ├── testing/                # Test suite docs
│   ├── arduino/                # Arduino API docs
│   ├── plugins/                # Plugin docs
│   └── archive/                # Superseded documents
└── Archive/                    # Historical reference & legacy files
```

---

## Documentation

| Document | Description |
|----------|-------------|
| [docs/architecture/CARTRIDGE_PROTOCOL.md](docs/architecture/CARTRIDGE_PROTOCOL.md) | Hardware signals, transfer mechanisms, timing |
| [docs/architecture/MACRO_ARCHITECTURE.md](docs/architecture/MACRO_ARCHITECTURE.md) | Two-tier macro system |
| [docs/build/BUILD_SYSTEM.md](docs/build/BUILD_SYSTEM.md) | Build system deep-dive |
| [docs/testing/VICE_MENU_TEST.md](docs/testing/VICE_MENU_TEST.md) | Automated VICE C64 menu test suite |
| [docs/arduino/DIR_NAVIGATION_API.md](docs/arduino/DIR_NAVIGATION_API.md) | Directory navigation API reference |
| [CHANGELOG.md](CHANGELOG.md) | Version history |
| [CLAUDE.md](CLAUDE.md) | AI developer guide (Claude Code) |
| [GEMINI.md](GEMINI.md) | AI developer guide (Gemini) |

---

## Credits

EasySD Gemini is based on the original **IRQHack64/EasySD** project. This fork adds SdFat 2.x support, a Python build system, KernalBridge plugin architecture, production-quality directory navigation, a two-tier macro system, and extensive documentation.

## License

See original project for license terms.
