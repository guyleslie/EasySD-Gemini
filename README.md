# EasySD Gemini

**Load programs and media on your Commodore 64 straight from an SD card.**

EasySD is a cartridge for the Commodore 64 that combines an Arduino-based SD card controller with a cartridge ROML chip that boots the C64-side loader/runtime. The full menu program is normally loaded from the SD card root as `EASYSD.PRG`, then you browse files on the C64 and load the selected item directly from the SD card.

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
- **Use file-type plugins** for graphics, audio, and video playback from the SD card (see status below)

---

## Hardware verification status (current worktree, post-v0.5)

Verified on real Commodore 64 hardware with the EasySD v3 PCB:

| Feature | Status |
|---------|--------|
| C64 boots to BASIC with cartridge inserted | ✅ Verified |
| SEL button press loads EasySD menu | ✅ Verified |
| File browser: directory listing | ✅ Verified |
| File browser: folder navigation | ✅ Verified |
| File browser: directory header (`ROOT` / current folder) | ✅ Verified |
| PRG file loading | ✅ Verified |
| Cold boot after long power-off (1-2 min) | ✅ Verified on current bench firmware/hardware state |
| Plugin-class return path (`.CVD`, `HWTEST.HWT`) | ❌ Current bench report: returns to cleared screen / top-line `READY.` instead of stable EasySD menu |
| Other non-PRG plugins (`.WAV`, `.KOA`, `.PET`) | ⚠️ Not yet re-verified on current real HW firmware baseline |

---

## How it works

The cartridge has two parts working together:

- An **Arduino Nano** reads the SD card and streams file data to the C64 at up to ~40 KB/s via the NMI line
- A **512 Kbit (64 KB) cartridge ROML chip** holds the boot stub and NMI transfer handler used by the C64 side; the interactive menu is normally loaded from the SD card root as `EASYSD.PRG`

When you select a file, the menu loads the matching plugin from the SD card's `/PLUGINS/` folder, which handles playback or display. This keeps the ROM small and lets new file types be added without reprogramming the cartridge ROML chip.

**Boot sequence:** IRQHack64-style — the Arduino does **not** hold the C64 in reset. On power-on, the cartridge interface is configured for BASIC-safe idle (`/RESET` HIGH, `/EXROM` HIGH, data bus tristate) and the C64 cold-boots to BASIC on its own RC reset. The Arduino initialises the SD card in parallel, ready by the time the user presses SEL. The menu is loaded only on an explicit SEL press, never automatically at boot.

**SEL button policy:** A short press opens the EasySD menu. A long press returns the machine to BASIC. In the current firmware a press is treated as "long" only when the button is released strictly after the 1000 ms threshold.

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
| **100 nF ceramic + optional 10–100 µF electrolytic capacitor** | Both directly at SD module VCC/GND pins — required for stable SPI |
| **5mm LED + 220 Ω resistor** | Power indicator — connect between PCB 5V rail and GND (always lit when powered) |
| **Tactile pushbutton** | Menu/Reset button |

> **SD card:** FAT16 or FAT32 formatted. Any capacity works. Copy your files into the root or subdirectories; put the plugin files in a `/PLUGINS/` folder.
>
> **Directory depth limit:** The full path cannot exceed 63 characters. With 8-character folder names (FAT maximum) this allows approximately 7 levels of nesting; shorter names allow more.

---

## SD card layout

```
SD card root/
├── EASYSD.PRG        ← main C64 menu loaded by SEL / TransferMenu()
├── PLUGINS/
│   ├── PRGPLUGIN.PRG    ← standard PRG loader (KernalBridge)
│   ├── HWTPLUGIN.PRG    ← hardware test launcher
│   ├── KOAPLUGIN.PRG    ← Koala graphics viewer
│   ├── PETGPLUGIN.PRG   ← PETSCII art viewer
│   ├── WAVPLUGIN.PRG    ← WAV audio player
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
# Build everything: C64 + plugins + Arduino + staged bundles
python Tools/build.py release

# Build only the C64 side (no Arduino needed)
python Tools/build.py release --skip-arduino

# Rebuild SD content package only (from current build artifacts)
python Tools/build.py sd-content
```

`release` now stages reproducible outputs under:
- `EasySD/build/sd-content/` (`EASYSD.PRG` + `PLUGINS/*.PRG`)
- `EasySD/build/upload/` (Arduino upload files)
- `EasySD/build/release/` (full release package)

### Flash the Arduino

```bash
# Upload via ISP programmer (USBtinyISP)
python Tools/build.py arduino-upload-isp

# Upload for a blank/bricked chip (slower SCK)
python Tools/build.py arduino-upload-isp --isp-sck 100
```

> USB serial upload is intentionally unsupported. Any bootloader (e.g. Optiboot) introduces a startup window during which the AVR pins float, breaking the EasySD cold-boot sequence that must hold the C64 in reset until the AVR is fully initialised. Always use an ISP programmer.

> After flashing, the Arduino firmware is complete. Next, program the C64-side ROM image into the cartridge ROML chip using a TL866 or similar programmer — see **Flash the Cartridge ROML Chip** below.

### Prepare/deploy SD content

```bash
# Create SD-ready content in EasySD/build/sd-content
python Tools/build.py sd-content

# Copy staged SD content to mounted SD card
python Tools/build.py sd-deploy D:
```

### Release logging (field diagnosis)

Add `--release-log` to any Arduino build or upload command to enable lightweight serial logging in the firmware. Only DIR, SYS, SD and ERR log categories are compiled in — FILE, PRG, and PROTO stay compiled out to keep flash usage under control (~1–2 KB overhead vs. silent release).

```bash
# Compile with release logging
python Tools/build.py arduino-compile --release-log

# Upload via ISP with release logging
python Tools/build.py arduino-upload-isp --release-log

# Full release build (C64 + Arduino) with release logging
python Tools/build.py release --release-log

# Monitor serial output (57600 baud)
python Tools/build.py arduino-monitor COM4
```

### Flash the Cartridge ROML Chip

The build produces `EasySD/build/IRQLoaderRom.bin` — this is the image for the cartridge ROML chip. Write it to the AT27C512R-45PU or M27C512 with a suitable programmer.

`EasySD/build/easysd.prg` is the C64 menu program that `TransferMenu()` prefers to load from the SD card root as `EASYSD.PRG` when present.

---

## When to update each component

EasySD has three separately updatable parts. Not every change requires updating all three.

| Component | How to update | When to update |
|-----------|---------------|----------------|
| **Arduino firmware** | `arduino-upload-isp` | Any change to `Arduino/EasySD/` source files (command handling, directory logic, protocol, SD card code). This is the most frequently updated component. |
| **SD card files** | Build `sd-content` and copy/deploy `EASYSD.PRG` + `PLUGINS/*.PRG` | Any change to C64 assembly source files (`EasySD/Menu/`, `EasySD/Loader/`, `EasySD/Plugins/`). The menu and all plugins are loaded from the SD card at runtime — the cartridge ROML chip does not need to change. |
| **Cartridge ROML chip** | Reprogram with TL866 or similar EPROM programmer | Only when `EasySD/build/IRQLoaderRom.bin` changes — this happens if the NMI transfer handler, boot stub, or the resident loader code changes. Plugin and menu changes do **not** require reprogramming the ROML chip. |

> **Tip:** Most development only touches Arduino firmware and/or C64 menu/plugin code. You can go a long time without needing to reprogram the ROML chip — only changes to `EasySD/Loader/CartLib.s`, `CartLibCommon.s`, or the EPROM build artifacts require it.

---

## Status LED

The LED is connected directly to the PCB 5V rail and is **always lit when the cartridge is powered** — it is a power indicator only. The Arduino does not control the LED; D13 is shared with SPI SCK and must not be driven as output.

---

## Development

<details>
<summary>For developers: architecture overview</summary>

EasySD has two cooperating halves:

**Arduino firmware** (`Arduino/EasySD/`) — manages SD card access, directory state, and file streaming. The ATmega328P MCU internal EEPROM is currently unused.

**C64 software** (`EasySD/`) — 6502 assembly built with 64tass. The cartridge ROML chip contains the boot stub, communication library, transfer handler, and resident loader; the interactive menu is normally staged as `EASYSD.PRG` on the SD card.

**Data transfer:**
| Mechanism | Rate | Used by |
|-----------|------|---------|
| NMI transfer | ~40 KB/s | File loading |
| IO2 streaming | ~13.5 KB/s | WAV / CVD playback |

See [docs/architecture/CARTRIDGE_PROTOCOL.md](docs/architecture/CARTRIDGE_PROTOCOL.md) for hardware and timing details.

</details>

---

## Credits

EasySD Gemini is a major rewrite of the original **IRQHack64** project. The original hardware concept and cartridge design come from the IRQHack64 community. This version adds SdFat 2.x support, a Python build system, KernalBridge KERNAL compatibility layer, better plugin architecture, updated CVD video playback.

Hardware design: **GuyLeslie** (EasyEDA, 2025)
