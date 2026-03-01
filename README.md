# EasySD Gemini

**A modern, plugin-driven SD card interface for the Commodore 64.**

EasySD brings SD card support to the C64 through a cartridge-based system combining an Arduino Nano/Pro Mini "file server" with a C64-side menu and plugin architecture. Browse directories and load files directly from a standard FAT-formatted SD card.

![EasySD Schematic](Schematic%20EasySD%20v3.png)

## Features

- **SD Card File Browser** - Navigate directories and select files from FAT-formatted SD cards
  - Cursor key navigation, inverse selection highlight, directory header row
- **Plugin System** - Extensible file type support through dedicated plugins:
  - **PRG** - Launch C64 programs with KERNAL hooking for BASIC LOAD compatibility
  - **TAP** - Automatic TAP-to-PRG conversion (convert+run or save to SD)
  - **KOA** - Display Koala Painter graphics
  - **PETG** - Render PETSCII art
  - **WAV** - Stream and play digital audio (double-buffered)
  - **MUS** - Play Compute's Sidplayer SID music files
  - **CVID** - Play Bad Apple!! CVID video files
- **Status LED** - Visual boot and SD health indicator on pin A5 (3 blinks = OK, 6 = fail)
- **Production-Ready** - Reliable directory navigation, cold boot retry, memory-safe operations
- **SdFat 2.x** - Modern SD card library with full API compliance

## Hardware Requirements

- **Commodore 64** (PAL or NTSC)
- **Arduino Nano 3.x** (ATmega328P)
- **SD card module** (SPI interface)
- **EasySD cartridge PCB** (see schematic above for circuit design)
- **Status LED** on pin A5 (optional but recommended)

## Quick Start

### Prerequisites

- **Python 3.7+** - Build system
- **64tass** - 6502 cross-assembler (in PATH)
- **petcat** (from VICE) - BASIC stub generation (in PATH)
- **arduino-cli** - Arduino compilation and upload

### Build & Flash

```bash
# First-time Arduino setup (install libraries)
python Tools/build.py arduino-setup

# Full release build (C64 + Arduino)
python Tools/build.py release

# Upload firmware to Arduino (USB serial)
python Tools/build.py arduino-upload COM4

# Or: upload via ISP programmer (USBTinyISP)
python Tools/build.py arduino-upload-isp

# Or: debug build for development
python Tools/build.py debug-arduino
```

See [Tools/README.md](Tools/README.md) for all build commands and options.

## Project Structure

```
EasySD Gemini/
├── Arduino/IRQHack64/     # Arduino firmware (C++, SdFat 2.x)
├── IRQHack64/             # C64 assembly source (6502, 64tass)
│   ├── Loader/            # Cartridge ROM & communication library
│   ├── Menus/EasySD/      # Main file browser menu
│   └── Plugins/           # File-type plugins
├── Tools/                 # Python build system
├── docs/                  # Documentation
│   ├── architecture/      # Technical architecture docs
│   ├── plugins/           # Plugin documentation
│   ├── sprints/           # Development sprint records
│   ├── arduino/           # Arduino-specific docs
│   └── build/             # Build system docs
└── Archive/               # Historical reference & legacy files
```

## Documentation

| Document | Description |
|----------|-------------|
| [CLAUDE.md](CLAUDE.md) | Developer guide for AI-assisted development |
| [GEMINI.md](GEMINI.md) | Detailed AI developer guide with architectural rules |
| [CHANGELOG.md](CHANGELOG.md) | Complete version history |
| [docs/build/](docs/build/) | Build system documentation |
| [docs/architecture/](docs/architecture/) | Technical architecture docs |
| [docs/plugins/](docs/plugins/) | Plugin documentation |
| [docs/testing/VICE_MENU_TEST.md](docs/testing/VICE_MENU_TEST.md) | Automated VICE C64 menu test suite |

## Architecture Overview

The system is split into two cooperating halves:

**Arduino Firmware** manages the SD card, FAT filesystem, directory navigation, file streaming, and TAP conversion. Communication uses a custom protocol: software serial (C64 → Arduino) and NMI-driven byte transfer (Arduino → C64).

**C64 Software** provides the cartridge ROM with communication library, the file browser menu, and the plugin system. Plugins are standalone 6502 programs loaded from `/PLUGINS/` on the SD card.

Key design principles:
- Strict linear include hierarchy (no duplicate definitions in 64tass)
- Centralized Zero Page map (`CartZpMap.inc`) as single source of truth
- Centralized APIs: `LoadFileBySize`, `SafeStream`, `StreamLargeFile`
- State save/restore pattern for all plugins

## Credits

EasySD Gemini is based on the original **IRQHack64/EasySD** project. This fork adds SdFat 2.x support, a Python build system, production-quality directory navigation, and extensive documentation.

## License

See original project for license terms.

---

*Current version: v3.1.1 (2026-02-28)*
