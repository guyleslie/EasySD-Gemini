# EasySD Gemini

**Load programs, music, graphics and video on your Commodore 64 — straight from an SD card.**

EasySD is a cartridge for the Commodore 64 that turns any FAT-formatted SD card into a file library. Plug it into the expansion port, browse your files with cursor keys, and load them instantly. No tape drive, no disk drive, no fuss.

> Current version: **v3.1.3** (2026-03-09)

![EasySD v3 PCB](PCB%20EasySd%20v3%20.png)

*EasySD v3 PCB render: Arduino Nano (blue, top), DIP-28 EEPROM socket (bottom), MicroSD slot (top left), MENU/RESET button (top right), and the C64 expansion port edge connector.*

---

## Schematic

![EasySD Schematic v3](Schematic%20EasySD%20v3.png)

---

## What it does

- **Browse files** on an SD card directly on your C64 — folder navigation with cursor keys
- **Load programs** (`.PRG`) — BASIC and machine code, including programs that use KERNAL file I/O
- **View graphics** — Koala Painter (`.KOA`) and PETSCII art (`.PET`)
- **Play audio** — digitized sound (`.WAV`) and Sidplayer SID music (`.MUS`)
- **Play video** — CVD video files (`.CVD`) converted from standard video sources
- **Automatic TAP conversion** — `.TAP` tape images load without a separate plugin

---

## How it works

The cartridge has two parts working together:

- An **Arduino Nano** reads the SD card and streams file data to the C64 at up to ~40 KB/s via the NMI line
- A **512 Kbit (64 KB) EEPROM** holds the cartridge ROM: the file browser menu that boots when you turn on the C64

When you select a file, the menu loads the matching plugin from the SD card's `/PLUGINS/` folder, which handles playback or display. This keeps the ROM small and lets new file types be added without reflashing the EEPROM.

---

## Hardware

To build EasySD you need the following components:

| Component | Notes |
|-----------|-------|
| **Commodore 64** | PAL or NTSC |
| **Arduino Nano 3.x** | ATmega328P, 5V — clones work fine |
| **MicroSD card adapter (5V)** | Standard SPI module |
| **EEPROM 512 Kbit** | AT27C512R-45PU or M27C512 — both compatible; holds the cartridge ROM |
| **EasySD PCB** | See schematic above (designed in EasyEDA) |
| **100 nF ceramic + 10–47 µF electrolytic capacitor** | Both directly at SD module VCC/GND pins — required for stable SPI |
| **5mm LED + 220 Ω resistor** | Power indicator — connect between PCB 5V rail and GND (always lit when powered) |
| **Tactile pushbutton** | Menu/Reset button |

> **SD card:** FAT16 or FAT32 formatted. Any capacity works. Copy your files into the root or subdirectories; put the plugin files in a `/PLUGINS/` folder.
>
> **Filename limit:** 8.3 format — up to 8 characters for the name, 3 for the extension (e.g. `MYGAME.PRG`). Long filenames are not supported.
>
> **Directory depth limit:** The full path cannot exceed 63 characters. With 8-character folder names (FAT maximum) this allows approximately 7 levels of nesting; shorter names allow more.

---

## SD card layout

```
SD card root/
├── PLUGINS/
│   ├── PRGPLUGIN.PRG    ← C64 program loader
│   ├── KOAPLUGIN.PRG    ← Koala graphics viewer
│   ├── PETGPLUGIN.PRG   ← PETSCII art viewer
│   ├── WAVPLUGIN.PRG    ← WAV audio player
│   ├── MUSPLUGIN.PRG    ← SID music player
│   └── CVDPLUGIN.PRG    ← CVD video player
├── GAMES/
│   ├── MYGAME.PRG
│   └── ...
├── MUSIC/
│   └── SONG.WAV
└── ...                  ← Any folder structure you like
```

---

## Building and flashing

### Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| Python 3.7+ | Build system | [python.org](https://python.org) |
| [64tass](https://sourceforge.net/projects/tass64/) | 6502 assembler | Add to PATH |
| `petcat` (part of VICE) | BASIC stub converter | Add to PATH |
| `arduino-cli` | Arduino compiler & uploader | `winget install Arduino.ArduinoCLI` |

### First-time setup

```bash
# Install Arduino libraries (SdFat, etc.)
python Tools/build.py arduino-setup
```

### Build

```bash
# Build everything: C64 ROM + Arduino firmware
python Tools/build.py release

# Build only the C64 side (no Arduino needed)
python Tools/build.py release --skip-arduino
```

### Flash the Arduino

```bash
# Upload via USB (Arduino already has a bootloader)
python Tools/build.py arduino-upload COM4

# Upload via ISP programmer (blank chip, first time)
python Tools/build.py arduino-upload-isp --isp-sck 100
```

> After flashing, the Arduino firmware is complete. Next, program the C64-side ROM into the AT27C512R-45PU EEPROM using a TL866 or similar parallel EEPROM programmer — see **Flash the EEPROM** below.

### Flash the EEPROM

The build produces `EasySD/build/easysd.prg` — this is the C64 cartridge ROM binary. Write it to the AT27C512R-45PU with any parallel EEPROM programmer (TL866II+, etc.).

---

## Status LED

The LED is connected directly to the PCB 5V rail and is **always lit when the cartridge is powered** — it is a power indicator, not an Arduino-controlled signal. The Arduino drives pin A7 (NC on the current PCB) with boot-status blink patterns in firmware, but these are not visible on the current hardware.

---

## Troubleshooting

**SD card not detected** — Check that a 100 nF ceramic and a 10–47 µF electrolytic capacitor are fitted directly at the SD module's VCC/GND pins. Missing or misplaced bypass caps are the most common cause of SD init failures, especially on breadboard builds.

**Garbled screen on boot** — Check that the EEPROM is correctly seated and the PCB connections are solid.

**File won't load** — Make sure the correct plugin is in `/PLUGINS/` on the SD card. Plugin filenames must match exactly (8.3 format, uppercase).

---

## Development

<details>
<summary>For developers: architecture overview</summary>

EasySD has two cooperating halves:

**Arduino firmware** (`Arduino/EasySD/`) — manages SD card, FAT filesystem, directory navigation, file streaming. Entry point: `EasySD.ino`. Command routing: `CartApi.cpp`. Directory logic: `DirFunction.cpp`. ATmega328P constraint: 2 KB SRAM, ~415 bytes free at boot.

**C64 software** (`EasySD/`) — 6502 assembly built with 64tass. Cartridge ROM includes the communication library (`Loader/`), file browser menu (`Menus/EasySD/`), and plugin system (`Plugins/`).

**Data transfer:**
| Mechanism | Rate | Used by |
|-----------|------|---------|
| NMI transfer | ~40 KB/s | File loading |
| IO2 streaming | ~13.5 KB/s | WAV / CVD playback |

See [docs/architecture/CARTRIDGE_PROTOCOL.md](docs/architecture/CARTRIDGE_PROTOCOL.md) for hardware and timing details.

**Build targets:**
```bash
python Tools/build.py debug-vice        # C64 only, VICE emulator, mock data
python Tools/build.py debug-arduino     # Full debug with Arduino serial logging
python Tools/build.py plugins           # Rebuild plugins only
python Tools/build.py clean             # Remove all build artifacts
python Tools/test_vice_menu.py --build --verbose   # Automated VICE test suite
```

</details>

---

## Credits

EasySD Gemini is a major rewrite of the original **IRQHack64** project. The original hardware concept and cartridge design come from the IRQHack64 community. This version adds SdFat 2.x support, a Python build system, KernalBridge KERNAL compatibility layer (P2TK for large programs), plugin architecture, CVD video playback, and extensive automated testing.

Hardware design: **GuyLeslie** (EasyEDA, 2025)
