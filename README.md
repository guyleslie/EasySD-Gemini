# EasySD

> Load programs and media files on your Commodore 64 straight from an SD card.

EasySD is a DIY expansion cartridge for the Commodore 64. An Arduino Nano reads FAT-formatted SD cards and streams file data to the C64 via NMI pulses. A 512 Kbit ROML chip handles cartridge autostart, the cold-boot sequence, and the NMI byte-transfer handler that receives every file byte from the Arduino. The interactive menu and plugins are `.PRG` files on the SD card, loaded at runtime.

![EasySD v3 PCB](PCB%20EasySd%20v3%20.png)

*EasySD v3 PCB — Arduino Nano (top), 512 Kbit ROML socket (centre), MicroSD slot (top-left), SEL button (top-right), C64 expansion port edge connector (bottom).*

---

## Features

- Browse folders and load `.PRG` programs directly from SD card — a typical 50 KB game loads in about 3 seconds
- Plugin system for additional file types — loaded on demand
- Supported file formats: `.PRG`, `.KOA` (Koala graphics), `.WAV` (audio), `.CVD` (CVD video)
- FAT16 / FAT32, any SD card capacity, long filenames supported
- C64 boots normally to BASIC
- Short press MENU/RESET (SEL) button → open menu; long press → return to BASIC

---

## Hardware

| Component | Notes |
|-----------|-------|
| EasySD PCB | EasyEDA design |
| Arduino Nano 3.x | ATmega328P, 5 V |
| MicroSD card adapter (5 V) | Standard SPI module |
| Cartridge ROML chip, 512 Kbit | AT27C512R-45PU or M27C512 |
| 100 nF ceramic capacitor | At SD module VCC/GND pins |
| 5 mm LED + 220 Ω resistor | Power indicator |
| Tactile pushbutton | SEL / long-press BASIC |
| 10–100 µF electrolytic capacitor | Optional, at SD module VCC/GND |

![EasySD Schematic v3](Schematic%20EasySD%20v3.png)

---

## SD Card Layout

```
SD:/
├── EASYSD.PRG          ← C64 menu, loaded on SEL press
├── PLUGINS/
│   ├── PRGPLUGIN.PRG   ← PRG loader with KERNAL compatibility (KernalBridge)
│   ├── KOAPLUGIN.PRG   ← Koala graphics viewer
│   ├── WAVPLUGIN.PRG   ← WAV audio player
│   └── CVDPLUGIN.PRG   ← CVD video player
├── GAMES/
│   └── MYGAME.PRG
└── MUSIC/
    └── SONG.WAV
```

FAT16 or FAT32. Maximum full path length: 63 characters.

---

## Getting Started

### Prerequisites

| Tool | Install |
|------|---------|
| Python 3.7+ | [python.org](https://python.org) |
| 64tass | [sourceforge.net/projects/tass64](https://sourceforge.net/projects/tass64/) — add to PATH |
| petcat (VICE) | [vice-emu.sourceforge.io](https://vice-emu.sourceforge.io/) — add to PATH |
| arduino-cli | `winget install Arduino.ArduinoCLI` |

### First-time setup

```bash
python Tools/build.py arduino-setup   # install Arduino libraries
```

### Build everything

```bash
python Tools/build.py release
```

Build outputs:
- `EasySD/build/release/sd-content/` — `EASYSD.PRG` + `PLUGINS/*.PRG` ready to copy to SD card (`EASYSD.PRG`, `PLUGINS/`, and plugin PRGs are marked hidden on Windows)
- `EasySD/build/IRQLoaderRom.bin` — image to program into the ROML chip
- `EasySD/build/upload/` — Arduino firmware files

### Flash the Arduino

ISP programmer required (e.g. USBtinyISP). USB serial upload is intentionally unsupported — a bootloader startup window breaks the EasySD cold-boot sequence.

```bash
python Tools/build.py arduino-upload-isp

# Blank or bricked chip (slow SCK, ~8 min):
python Tools/build.py arduino-upload-isp --isp-sck 100
```

### Program the ROML chip

Write `EasySD/build/IRQLoaderRom.bin` to the AT27C512R-45PU or M27C512 using a TL866 or compatible EPROM programmer.

### Deploy SD card content

```bash
python Tools/build.py sd-deploy D:   # copy built files to SD card at drive D:
```

On Windows, deploy keeps `EASYSD.PRG`, `PLUGINS/`, and plugin PRGs hidden after copying so normal users do not see or launch the runtime support files from the EasySD menu.

---

## Build Reference

```bash
python Tools/build.py release                   # full build (C64 + Arduino)
python Tools/build.py release --skip-arduino    # C64 side only
python Tools/build.py arduino-compile --debug   # debug firmware (serial logging)
python Tools/build.py arduino-monitor COM4      # serial monitor, 57600 baud
```

---

## Architecture

EasySD has two cooperating halves:

**Arduino firmware** (`Arduino/EasySD/`) — SD card access, directory state, file streaming. ATmega328P, 2 KB SRAM.

**C64 software** (`EasySD/`) — 6502 assembly (64tass). ROML chip holds the boot stub and NMI transfer handler. The menu and all plugins are `.PRG` files on the SD card.

| Transfer path | Rate | Used for |
|---------------|------|----------|
| NMI line | ~16 KB/s | PRG loading |
| IO2 streaming | ~13.5 KB/s | WAV / CVD playback |

---

## Credits

EasySD Gemini builds on the original **IRQHack64** project by **I.R.on**, carrying the concept forward with further development, optimizations, and hardware refinements.

Hardware and firmware: **GuyLeslie** (2025–2026)

---

## License

See [LICENSE](LICENSE).
