# Hardware Debug Tooling

How to get real information out of EasySD running in a real C64: the serial log,
the USB back-power hazard that breaks cold-boot testing, and the logic analyzer.

Status markers: **NOW** = current supported workflow, **PLAN** = agreed future
work, not implemented.

---

## 1. Serial log workflow (NOW)

```bash
deploy-serial-debug.bat                 # build + ISP upload debug firmware + SD deploy
python Tools/build.py arduino-monitor COM4
```

Baud 57600. Format `[LEVEL][CATEGORY] message`.

Backend: polled, TX-only UART in `Arduino/EasySD/EasySDLog.cpp` — not
HardwareSerial. Consequences worth knowing:

- No UART interrupt exists, so logging cannot perturb the IO2 pulse decoder, and
  a log call inside a `noInterrupts()` region is safe.
- RX is not enabled. The AVR never reads the serial line, so `D0/RX` is a free
  pin (see the trace-pin idea in section 3.4).

### 1.1 The USB back-power hazard

**Do not use the Nano USB port when testing cold boot.**

Schematic (`Schematic EasySD v3.png`): cartridge port pin 2 (+5V) is tied
directly to the board +5V net, which is also the Nano `5V` pin, the EPROM VCC
and the SD module VCC. There is no series element anywhere in that path.

So with a USB cable in the Nano: USB VBUS -> the internal Nano Schottky -> Nano
`5V` pin -> board +5V net -> cartridge pin 2 -> **the whole C64 5V rail**.
Switching the C64 PSU off leaves the C64 running at ~4.6 V on 5V-only, with no
+12V and no 9VAC: it half-starts and shows a ghost screen. Cold boot cannot be
tested in that state, and any cold-boot conclusion drawn with USB attached is
invalid.

### 1.2 Supported debug wiring (NOW)

Use an **external USB-TTL adapter, TX + GND only**:

| Adapter | EasySD |
|---------|--------|
| RX      | Nano `TX` (D1) |
| GND     | Nano `GND` |
| VCC     | **not connected** |

The Nano USB port stays unplugged. The C64 powers the Nano; the PC only listens.
Cold boot then behaves exactly as it does without any debug gear.

Alternative: a data-only (VBUS-cut) USB cable into the Nano. Works, but the
Nano USB-serial chip is powered from the board rail, so the PC port enumerates
only while the C64 is on — the monitor has to be restarted after every power
cycle. The external adapter stays enumerated, so it is preferred.

---

## 2. Hardware isolation (PLAN — future PCB revision, not now)

The TX+GND workflow solves the problem operationally. These are the durable
fixes to fold into the next PCB spin.

**2.1 Schottky on the Nano supply.** One Schottky (SS14 / 1N5819 / SD103,
SOD-123) in series between the board +5V net and the Nano `5V` pin, cathode
towards the Nano.

- C64 on: the Nano draws ~20 mA, Vf is about 0.2 V, so the AVR sits at ~4.8 V —
  comfortably above the 4.5 V an ATmega328P needs at 16 MHz. EPROM and SD module
  stay on the undropped rail.
- C64 off, USB on: the diode blocks, so the board rail and cartridge pin 2 stay
  dead. The internal Nano USB Schottky already blocks the opposite direction.

**2.2 PHI2 presence gate (firmware).** A diode alone is not sufficient: powered
from USB, the AVR is still alive and its cartridge-facing pins (D0-D7 via
D4-D7/A0-A3, EXROM, NMI, RESET) would drive into unpowered chips and inject
current through their clamp diodes, lifting the dead rail again.

The fix needs no new hardware: **PHI2 is already wired to Nano A4**
(`CartInterface.h:17`, currently marked "optional; not used by default"). Sample
A4 for ~2 ms; a toggling line (~985 kHz PAL) means the C64 is alive, a static
level means it is not. Hold every cartridge-facing pin in hi-Z and EXROM
released until PHI2 is seen. Useful beyond the power question: it is also the
natural first event of a cold-boot trace ("C64 power detected @ t=...").

**2.3 Debug header.** Bring PHI2, /RESET, /EXROM, /NMI, /IO2, /ROML, a firmware
TRACE pin and GND to a 0.1 inch header, so the logic analyzer can be attached
without probing the Nano pins directly.

**2.4 Bigger hammer, probably unnecessary.** 74LVC245 bus buffers with OE driven
by a rail/PHI2 sense give real electrical isolation, at the cost of a redesign.

---

## 3. Logic analyzer: Seengreat SG-NANO-DLA-A

### 3.1 What it is

| | |
|---|---|
| Chipset | CY7C68013A (Cypress EZ-USB FX2LP), 74HC245 input buffer |
| Channels | 8 (CH0-CH7) |
| Sample rate | up to 24 MHz (vendor states 24 MHz on Linux; Windows is usually lower) |
| Input range | 0-5.5 V, VIH > 2 V, VIL < 1.5 V (retail spec — 5 V TTL is in range) |
| Software | sigrok / PulseView with `fx2lafw` firmware |

Two properties shape how it is used:

- **No onboard sample memory and no hardware trigger.** `fx2lafw` streams to the
  host and PulseView triggers in software on that stream. In practice: arm the
  capture first, then power-cycle the C64 or press SEL. Capture length is bounded
  by host RAM, not by a device buffer, so multi-second recordings are fine.
- **It connects only GND and high-impedance inputs.** Unlike the Nano USB port it
  does not back-power the C64, so it is the correct instrument for cold-boot work
  (section 1.1).

Sample-rate sanity check for this project: PHI2 is ~985 kHz (PAL) and the
protocol pulses are in the microsecond range, so 8-16 MSa/s is ample. Sub-100 ns
glitch hunting is out of reach — that needs a real scope.

If the input range ever looks doubtful on a particular unit, 1 kOhm series
resistors per channel cost nothing and protect both sides.

### 3.2 Probe points

Almost every interesting signal is available on the Nano headers, so no
cartridge-port breakout is needed:

| Signal | Probe at | What it tells you |
|--------|----------|-------------------|
| PHI2 | Nano A4 | C64 is alive and clocked (~985 kHz PAL) |
| /EXROM | Nano D2 | cartridge visible or hidden, and exactly when |
| /IO2 | Nano D3 | C64 -> AVR command pulses (software serial) |
| /NMI | Nano D8 | AVR -> C64 byte strobe |
| /RESET | Nano D9 | when the AVR drives reset, and for how long |
| D0-D3 | Nano A0-A3 | data bus, low nibble |
| D4-D7 | Nano D4-D7 | data bus, high nibble |
| /ROML | EPROM socket pin 22 (OE#/VPP) | C64 actually fetching from cartridge ROM |
| /IRQ | Nano A5 | CIA1 pulses every ~16.6 ms = C64 is running BASIC |
| SD CS / SCK | Nano D10 / D13 | correlate SD activity with bus phases |
| R/W | not routed on EasySD v3 | would need a cartridge-port breakout |

### 3.3 Capture sets (8 channels each)

**A. Plugin return path** — the open WAV/CVD to `READY.` bug.
`PHI2, /RESET, /EXROM, /ROML, /NMI, /IO2, D7, TRACE`
Answers: does `COMMAND_EXIT_TO_MENU` reach `TransferMenu()`; is /RESET actually
pulsed; does /EXROM go low before the C64 starts fetching; does /ROML activity
follow reset release; does the NMI byte stream start. A menu transfer that never
begins, one that begins too early, and one that completes but is not launched
look completely different here — the serial log cannot separate them.

**B. C64 to AVR command channel** — the "Unknown cmd" / false-handshake class.
`PHI2, /IO2, /EXROM, /RESET, /NMI, D7, /IRQ, TRACE`
Measure real /IO2 pulse widths and jitter against the thresholds
`CartInterface::ReceiveInterrupt()` decodes with. The log only ever shows the
decoded result, never the waveform that produced it.

**C. NMI byte transfer / streaming.**
`PHI2, /NMI, /IO2, D0, D1, D2, D3, TRACE`
Byte cadence, handshake latency and data-bus contention during WAV/CVD
streaming.

**D. Cold boot** (from `Archive/docs/archive/COLD_BOOT_FAILURE_RETROSPECTIVE.md`).
`/RESET, /EXROM, PHI2, /IRQ, /NMI, D0, AVR D9, SD CS`
Trigger on the /RESET rising edge, 100 ms pre / 1 s post. /IRQ pulsing every
~16.6 ms proves the C64 reached the BASIC cursor-blink loop.

### 3.4 TRACE pin — correlating firmware state with the waveform (PLAN)

The serial log says what the firmware *thinks* happened; the analyzer says what
the wires *did*. One channel ties them together: drive `D0` (PD0) from the
firmware at chosen events, pulse-count- or pulse-width-coded (1 pulse = entered
`TransferMenu`, 2 = header sent, 3 = transfer complete, and so on). Two
instructions per marker, no meaningful flash cost.

Precondition: the Nano USB port must be unplugged, because D0 is also the
USB-serial chip TX output — driving it while that chip drives it is contention.
This composes exactly with the TX+GND workflow in section 1.2.

### 3.5 Custom sigrok decoder (PLAN)

A Python protocol decoder for the /IO2 pulse-width command protocol would turn
captures into readable command streams (`OPENFILE "GAMES"`, `READDIR pg=2`, ...)
instead of edge soup. This is the single biggest force multiplier for protocol
bugs, and it shares its constants with `CartApi.h` / `CartInterface.cpp`.
