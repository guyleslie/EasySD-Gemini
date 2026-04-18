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

# Upload via USB serial (Optiboot bootloader, 115200 baud)
python Tools/build.py arduino-upload COM4

# Upload via USBtinyISP (no bootloader required)
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
| FQBN | `arduino:avr:nano` (Optiboot, 115200 baud) |
| MCU | ATmega328P |
| Flash | 30720 bytes (30 KB) |
| SRAM | 2048 bytes (2 KB) |

---

## ISP Upload Notes

- ISP upload erases the bootloader — USB serial upload will not work afterward unless Optiboot is restored with `--optiboot`
- Default ISP SCK: `-B 2` (500 kHz) for chips with existing firmware
- Blank/bricked chips: `-B 100` (10 kHz, ~8 min upload time)
- See `CLAUDE.md` for full ISP details

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `arduino-cli not found` | Install via winget or add to PATH |
| `Port not found` | Check Device Manager → Ports (COM & LPT) |
| `stk500 not in sync` | Bootloader may be erased — use ISP upload instead |
| Flash overflow in debug build | Disable log categories in `EasySDLog.h` (see `docs/arduino/LOGGING_QUICKREF.md`) |
