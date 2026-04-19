# Arduino CLI Setup

The EasySD build system uses `arduino-cli` for compiling and uploading Arduino firmware.

---

## Installation

```bash
# Windows (winget)
winget install Arduino.ArduinoCLI

# Verify
arduino-cli version
```

## First-Time Setup

```bash
python Tools/build.py arduino-setup
```

This installs the Arduino AVR board support package and the SdFat library.

---

## Build & Upload Commands

All commands run from the repository root via `build.py`:

```bash
# Compile firmware (release)
python Tools/build.py arduino-compile

# Compile firmware (debug, serial logging enabled)
python Tools/build.py arduino-compile --debug

# Upload via USBtinyISP (ISP only — no bootloader)
python Tools/build.py arduino-upload-isp

# Upload via ISP with debug firmware
python Tools/build.py arduino-upload-isp --debug

# Serial monitor (57600 baud)
python Tools/build.py arduino-monitor COM4
```

---

## Board Configuration

| Parameter | Value |
|-----------|-------|
| FQBN | `arduino:avr:nano:cpu=atmega328` |
| MCU | ATmega328P |
| Flash | 32768 bytes (32 KB, no bootloader) |
| SRAM | 2048 bytes (2 KB) |

---

## ISP Upload Notes

- EasySD requires ISP upload (USBtinyISP). USB serial upload is unsupported — any bootloader's startup window breaks the cold-boot /RESET sequence.
- Default ISP SCK: `-B 2` (500 kHz) for chips with existing firmware
- Blank/bricked chips: `-B 100` (10 kHz, ~8 min upload time)
- See `CLAUDE.md` for full ISP details

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `arduino-cli not found` | Install via winget or add to PATH |
| `Port not found` | Check Device Manager → Ports (COM & LPT) |
| `stk500 not in sync` | Expected — EasySD uses ISP upload only, not USB serial |
| Flash overflow in debug build | Disable log categories in `EasySDLog.h` (see `docs/arduino/LOGGING_QUICKREF.md`) |
