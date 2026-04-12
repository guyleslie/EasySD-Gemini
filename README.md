# EasySD Gemini

**Load programs and media on your Commodore 64 straight from an SD card.**

EasySD is a cartridge for the Commodore 64 that combines an Arduino-based SD card controller with a cartridge ROML chip that boots the C64-side menu. You browse files on the C64, then the selected file is loaded directly from the SD card.

> Documentation note: this README describes the current architecture and user-visible behavior at a high level. Detailed implementation status belongs in the developer docs.

![EasySD v3 PCB](PCB%20EasySd%20v3%20.png)

*EasySD v3 PCB render: Arduino Nano (blue, top), DIP-28 cartridge ROML chip socket (bottom), MicroSD slot (top left), MENU/RESET button (top right), and the C64 expansion port edge connector.*

---

## Schematic

![EasySD Schematic v3](Schematic%20EasySD%20v3.png)

---

## What it does

- **Browse files** on an SD card directly on your C64 — folder navigation with cursor keys
- **Load programs** (`.PRG`) — BASIC and machine code, including programs that use KERNAL file I/O
- **Use file-type plugins** for graphics, audio, and video playback from the SD card
- **Convert supported tape images** (`.TAP`) into launchable content without a separate TAP plugin

---

## How it works

The cartridge has two parts working together:

- An **Arduino Nano** reads the SD card and streams file data to the C64 at up to ~40 KB/s via the NMI line
- A **512 Kbit (64 KB) cartridge ROML chip** holds the cartridge menu and transfer handler used by the C64 side

When you select a file, the menu loads the matching plugin from the SD card's `/PLUGINS/` folder, which handles playback or display. This keeps the ROM small and lets new file types be added without reprogramming the cartridge ROML chip.

---

## Hardware

To build EasySD you need the following components:

| Component | Notes |
|-----------|-------|
| **Commodore 64** | PAL or NTSC |
| **Arduino Nano 3.x** | ATmega328P, 5V — clones work fine |
| **MicroSD card adapter (5V)** | Standard SPI module |
| **Cartridge ROML chip, 512 Kbit** | AT27C512R-45PU or M27C512 — holds the C64 cartridge ROM |
| **EasySD PCB** | See schematic above (designed in EasyEDA) |
| **100 nF ceramic + 10–100 µF electrolytic capacitor** | Both directly at SD module VCC/GND pins — required for stable SPI |
| **5mm LED + 220 Ω resistor** | Power indicator — connect between PCB 5V rail and GND (always lit when powered) |
| **Tactile pushbutton** | Menu/Reset button |

> **SD card:** FAT16 or FAT32 formatted. Any capacity works. Copy your files into the root or subdirectories; put the plugin files in a `/PLUGINS/` folder.
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
│   ├── SIDPLAYER.PRG    ← external SID player binary used by the MUS plugin
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

# Upload via ISP programmer (default, recommended for EasySD: no Optiboot)
python Tools/build.py arduino-upload-isp

# Upload via ISP programmer for a blank/bricked chip (slower SCK)
python Tools/build.py arduino-upload-isp --isp-sck 100

# Only use this if you explicitly want Optiboot restored for later USB uploads
python Tools/build.py arduino-upload-isp --optiboot
```

> Important: when writing the Arduino over ISP for EasySD, Optiboot should normally be omitted. The default `arduino-upload-isp` flow now keeps the chip in application-start mode (`BOOTRST=1`), avoiding bootloader delay. Use `--optiboot` only when you intentionally want to restore USB bootloader uploads.

> After flashing, the Arduino firmware is complete. Next, program the C64-side ROM image into the cartridge ROML chip using a TL866 or similar programmer — see **Flash the Cartridge ROML Chip** below.

### Flash the Cartridge ROML Chip

The build produces `EasySD/build/IRQLoaderRom.bin` — this is the image for the cartridge ROML chip. Write it to the AT27C512R-45PU or M27C512 with a suitable programmer.

`EasySD/build/easysd.prg` is the C64 menu program that `TransferMenu()` prefers to load from the SD card root as `EASYSD.PRG` when present.

---

## Status LED

The LED is connected directly to the PCB 5V rail and is **always lit when the cartridge is powered** — it is a power indicator, not an Arduino-controlled signal. The Arduino drives pin A7 (NC on the current PCB) with boot-status blink patterns in firmware, but these are not visible on the current hardware.

---

## Troubleshooting

**SD card not detected** — Check that a 100 nF ceramic and a 10–100 µF electrolytic capacitor are fitted directly at the SD module's VCC/GND pins. Missing or misplaced bypass caps are the most common cause of SD init failures, especially on breadboard builds.

**Garbled screen on boot** — Check that the cartridge ROML chip is correctly seated and the PCB connections are solid.

**File won't load** — Make sure the correct plugin is in `/PLUGINS/` on the SD card. Plugin filenames must match exactly (8.3 format, uppercase).

---

## Development

<details>
<summary>For developers: architecture overview</summary>

EasySD has two cooperating halves:

**Arduino firmware** (`Arduino/EasySD/`) — manages SD card access, directory state, file streaming, and the ATmega328P internal EEPROM used for saved path data.

**C64 software** (`EasySD/`) — 6502 assembly built with 64tass. The cartridge ROML chip contains the communication library, transfer handler, and the boot menu used to start the system.

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
