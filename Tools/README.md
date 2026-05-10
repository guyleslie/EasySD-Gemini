# EasySD - Build Tools

## Overview

This folder contains the build and deployment tools for the EasySD project.

## Main Tools

### `build.py` - Main Build Script

**C64 code + Arduino artifact generation**

```bash
# Release build (C64 + Arduino + SD bundle + upload bundle)
python Tools/build.py release

# Build only core or plugins
python Tools/build.py core
python Tools/build.py plugins

# Clean build artifacts
python Tools/build.py clean

# Arduino-specific commands
python Tools/build.py arduino-compile [--debug]
python Tools/build.py arduino-upload-isp [--debug] [--isp-sck USEC]
python Tools/build.py arduino-monitor COM4

# Build SD card bundle only from current artifacts
python Tools/build.py sd-content

# Skip Arduino artifact generation
python Tools/build.py release --skip-arduino

# First-time Arduino setup
python Tools/build.py arduino-setup
```

**NOTE:** On Windows, use `py` instead of `python` if needed (Python launcher).

**What it does:**
1. Compiles C64 assembly code (64tass)
2. Converts PETMATE frame export (`petmate frame.asm` → `menu.bin`)
3. Generates Arduino header files (`FlashLib.h`, `BuildConfig.h`)
4. Compiles plugins
5. Stages reproducible output bundles under `EasySD/build/`

**Output:**
- `EasySD/build/sd-content/` - SD-ready package (`EASYSD.PRG` + `PLUGINS/*.PRG`)
- `EasySD/build/upload/` - Arduino upload artifacts (`EasySD.ino.hex/.elf/...`)
- `EasySD/build/release/` - Full release package (C64 + plugins + Arduino + symbols/listings + sd-content)
- `EasySD/build/plugins/` - Plugin binaries (working build output)
- `Arduino/EasySD/FlashLib.h` - Arduino header (generated)
- `Arduino/EasySD/BuildConfig.h` - Debug flag (generated)

---

## Workflow

### Release Deploy

```bash
deploy-release.bat
```

Equivalent to:
```bash
python Tools/build.py release
python Tools/build.py arduino-upload-isp --use-existing
python Tools/build.py sd-deploy D:
```

### Arduino Serial Debug (real C64 hardware + serial logging)

```bash
deploy-serial-debug.bat
```

Equivalent to:
```bash
python Tools/build.py release --skip-arduino       # C64 release
python Tools/build.py arduino-upload-isp --debug   # Arduino debug firmware (serial ON)
python Tools/build.py sd-deploy D:
```

### ISP Upload Options

```bash
python Tools/build.py arduino-upload-isp              # default 500 kHz
python Tools/build.py arduino-upload-isp --isp-sck 100  # 10 kHz, blank chip
python Tools/build.py arduino-upload-isp --debug      # debug firmware (serial ON)
python Tools/build.py arduino-upload-isp --use-existing  # reuse last build
```

### Full Clean Build

```bash
python Tools/build.py clean
python Tools/build.py release
python Tools/build.py arduino-upload-isp --use-existing
```

---

### `cvd_convert.py` - CVD Video Converter

Converts MP4/AVI video files to the C64 CVD format used by CvdPlayer.

### `wavtodigimax.py` - WAV to Digimax Converter

Converts WAV audio files to Digimax format used by WavPlayer.

---

## File Structure

```
Tools/
├── build.py                      # Main build script
├── README.md                     # This file
├── cvd_convert.py                # CVD video converter
└── wavtodigimax.py               # WAV to Digimax audio converter
```

---

## Troubleshooting

### `64tass not found`

Download 64tass and add it to your PATH:
https://sourceforge.net/projects/tass64/

### `arduino-cli not found`

Install: `winget install Arduino.ArduinoCLI`
Or see `docs/build/ARDUINO_CLI_SETUP.md` for detailed setup.

### `petcat not found`

Install VICE emulator and add its tools to PATH.

### `Port COM4 not found`

Check available ports: `python Tools/build.py arduino-list-ports`
On Windows: Device Manager → Ports (COM & LPT)

---

## Related Documentation

- `docs/build/BUILD_SYSTEM.md` - Detailed build system documentation
- `docs/build/ARDUINO_CLI_SETUP.md` - Arduino CLI installation guide
