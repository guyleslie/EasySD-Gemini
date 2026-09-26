# Next Steps

Working plan, last updated 2026-09-26. Companion documents: `docs/DEBUG_TOOLING.md`
(hardware debug wiring and logic-analyzer plans), `CLAUDE.md` (rules and budgets),
`GEMINI.md` (patterns and API details).

---

## Status snapshot (measured 2026-09-26)

| | Flash | RAM |
|---|---|---|
| release | 26678 / 30720 B (86%, 4042 B free) | 1568 / 2048 B (480 B free) |
| debug | 28428 / 30720 B (92%, 2292 B free) | 1572 / 2048 B (476 B free) |

`python Tools/build.py release` is green. SD bundle: `EASYSD.PRG` 11 KB plus
PRG/KOA/WAV/CVD plugins.

Real hardware: cold boot, menu, directory navigation, PRG loading and
KoalaDisplayer work. WavPlayer and CvdPlayer do not. PetsciiDisplayer was
removed from the tree in `41b6a8f` and is not coming back.

---

## 1. Validate the new serial backend on real hardware — BLOCKING

Owner: hardware side. Everything below depends on the log being trustworthy.

Commit `1ffc393` replaced HardwareSerial with a polled TX-only UART and moved
the `[LEVEL][CAT]` tag into a shared table. Output format is unchanged by
design, but this has not yet run on a real C64.

```bash
deploy-serial-debug.bat
python Tools/build.py arduino-monitor COM4
```

Pass criteria: `[INFO][SYS] EasySD DEBUG boot` appears at power-up, a SEL press
produces readable `[INFO][DIR]` navigation lines, and no garbled characters
(garbling would mean the UBRR divisor is wrong).

Wire the monitor as described in `docs/DEBUG_TOOLING.md` section 1.2 — external
USB-TTL adapter on TX + GND, the Nano USB port unplugged.

---

## 2. Debug content rework (firmware)

The current debug output is systematically truncated: 23 call sites print a
label and then expect a value from `LOG_PRINT`/`LOG_PRINTLN`, which the shipped
debug profile compiles out (`LOG_ENABLE_RAW=0`). So `Unknown cmd` never shows
the command byte, `chdir FAILED:` never shows the name, `RD` never shows the
page index. That is the main reason the log does not help.

Budget: 2292 B free, estimated cost 700-1000 B.

- **2.1 Make values first-class.** Typed emitters sharing one backend function,
  for example `LOGS(cat, "msg", str)` and `LOGN(cat, "msg", num)`, so every line
  carries its data without the RAW gate. Sites to convert:
  `CartApi.cpp` 594-596, 618-619, 858-861, 888, 892, 1699, 1728, 1823, 1976,
  1981; `DirFunction.cpp` 103, 184, 228, 247, 270, 420, 432.
- **2.2 Instrument the plugin return path.** `COMMAND_EXIT_TO_MENU` arrival,
  session state, `TransferMenu()` byte count and completion, path restore.
  Today this path — the one that fails — has effectively no logging.
- **2.3 Instrument directory paging.** Page index, entry count, watermark name,
  slot count, and whether a rebuild was needed (see backlog B1/B2).
- **2.4 SD error codes.** `sd.sdErrorCode()` / `sdErrorData()` instead of a bare
  `SD FAIL - check card`.
- **2.5 Session and boot markers**, plus an optional millisecond timestamp so
  stalls and timeouts are visible.
- **2.6 TRACE pin on D0.** Pulse-coded firmware event markers for the logic
  analyzer; D0 is free now that the logger is TX-only. See
  `docs/DEBUG_TOOLING.md` section 3.4.
- **2.7 Re-enable the FILE category** in the debug profile — only three call
  sites, and there is room now.

Acceptance: one full SEL to navigate to launch WAV to return cycle produces a
log in which every line carries its data.

---

## 3. Measure before fixing

Run capture set A from `docs/DEBUG_TOOLING.md` section 3.3 (plugin return path)
with the log and the analyzer together. The goal is to distinguish, with
evidence, between a menu transfer that never starts, one that starts too early
relative to reset and EXROM, and one that completes but is never launched.

---

## 4. Fix the plugin return path

Only after step 3. The working KoalaDisplayer returns through an
Arduino-driven re-invoke with `RestorePathIfProvided` (`CartApi.cpp:1049`),
while WavPlayer and CvdPlayer return through `COMMAND_EXIT_TO_MENU` into
`TransferMenu()` (`CartApi.cpp:1815`), which calls `dirFunc.ReInit()` and
`Prepare()` and therefore also drops the current directory. Unifying the two
paths on the Koala-style return is the likely fix.

---

## 5. Open hypothesis: /EXROM floats during the AVR startup window

Status: unverified, cheap to falsify. This is the first idea about the
machine-specific cold-boot symptom that lives *outside* the firmware, which is
why it is worth testing before anything else.

**Mechanism.** After power-on the ATmega328P holds every pin as an input with no
pull-up until `setup()` runs. The first thing that drives /EXROM HIGH is
`IOSetup()` (`CartInterface.cpp:227`), and the stock Arduino low fuse gives a
start-up delay of 16K CK + 65 ms. The C64 own 556 reset pulse is about 50 ms. So
the C64 can already be executing while /EXROM is still undefined, and EasySD has
no pull-up on that line — `Schematic EasySD v3.png` shows cartridge port pin 9
going straight to Nano D2, nothing else.

If the PLA samples that floating line as asserted, $8000-$9FFF maps to the
cartridge during the KERNAL reset sequence, while the EPROM page-select lines
(A8-A15, also AVR pins, also undefined at that moment) present garbage. Whether
this actually bites depends on the host board own EXROM pull-up strength and its
reset timing — exactly the "works on another machine" pattern this bug has
always had.

**Why it was missed.** `Tools/build.py` already documents this precise failure
mode, but only for bootloaders: "Optiboot is intentionally unsupported — its
~1-2s boot window leaves /RESET and EXROM floating, which breaks the EasySD
cold-boot sequence". Optiboot was banned for it. The same window exists without
any bootloader, 20x shorter, on every single power-up — that connection was
never made. All 39 commits touching cold boot / reset / cursor stayed inside the
firmware, and the retrospective own verdict was "every firmware change was a
hypothesis without evidence".

**Falsifiable predictions, cheapest first.**

1. **Read the C64 BASIC banner when it fails.** This is the machine own startup
   screen above `READY.`, not the EasySD menu footer. If EXROM was asserted
   while the KERNAL RAMTAS routine probed for the top of RAM, RAMTAS stops at
   $8000 instead of $A000 and the banner reads **30719 BASIC BYTES FREE**
   instead of 38911. Costs nothing, needs no instrument. A normal 38911 with the
   symptom present falsifies this hypothesis outright.
2. **10k from Nano D2 to Nano 5V.** One resistor between two header pins on the
   existing board, no PCB change, fully reversible. It defines /EXROM HIGH from
   the microsecond power arrives, independent of the AVR. If cold boot becomes
   reliable on the problem machine, the hypothesis is confirmed.
3. **Capture set D** in `docs/DEBUG_TOOLING.md` section 3.3, armed before
   power-on: watch /EXROM during the first 100 ms and compare its rise against
   the /RESET release and the start of PHI2.

**If confirmed, the fix is passive**: a pull-up on /EXROM on the next PCB
revision. /NMI and /RESET deserve the same treatment — both are released with
nothing but the AVR weak internal pull-up, and only after those 65 ms. No
firmware change can substitute for this, because the whole window exists before
any firmware is running. The same floating window also lasts for *seconds*
during ISP programming, while the programmer holds the AVR in reset.

**Secondary, only after measurement.** `arduino_upload_isp` writes only hfuse
(`0xDB`, BOOTRST) and never touches lfuse, so the stock 16K CK + 65 ms start-up
is in force. The SUT bits offer shorter options. That narrows the window but
never closes it, so it ranks below the resistor. Read the exact bit pattern from
the datasheet before programming anything.

**Note on PHI2.** PHI2 gating cannot address this. Cold boot is the mirror image
of the USB back-power case: there the AVR is alive while the C64 is dead and
firmware can decide, here the C64 is alive while the AVR is not yet running at
all. PHI2 remains useful here only as *instrumentation* — logging whether PHI2
was already toggling when the AVR woke up, and pulsing the TRACE pin at
`IOSetup()` entry so the analyzer shows the AVR wake-up against the C64
timeline. Also note `WaitForStablePhi2()` (`CartInterface.cpp:272`) and
`syncBusChangeToPhi2Low()` (`CartInterface.cpp:29`) are deliberate stubs today —
a `return true` and a 1 us delay — neutered during the IRQHack64-style revert.

---

## 6. Open lead: memory-status footer truncation = byte loss on the 256-byte page transfer

Reported symptom: the footer line sometimes renders only half, a quarter, or a
few characters.

**What the footer contains** (`EasySDMenu.s:305`, `CartApi.cpp:508`):
`   MCU SRAM:<n>B C64 STK:<m>B FREE`, where MCU SRAM is the AVR free SRAM
(`SP - __bss_end`, `CartApi.cpp:97`) and C64 STK is the 6502 stack headroom from
`TSX` (SP+1 bytes, range 0-256). Both are live measurements. Free BASIC RAM is
not displayed at all, and would not be meaningful while the menu PRG is running
in place of BASIC.

**Why it truncates at varying lengths.** The menu prints until the first $00.
The Arduino zeroes the 256-byte buffer and writes only ~30 characters, so
everything past the text is already zero. A single byte lost or corrupted to $00
during the NMI page transfer cuts the printed line exactly there — the
truncation length is simply where the first bad byte landed. That is the
signature of random byte loss, not of a formatting bug.

**This path is already known to be marginal.** `CartApi.cpp:107` records that
interleaving `pgm_read_byte` and arithmetic with `TransmitByteFast` "produced
intermittent byte loss on the C64", which is why `fc4b6a8` moved to building the
response in RAM and blasting a deterministic 256-byte burst. The menu disables
the display around the receive because "NMI page receive is only stable with
display off" — VIC badlines steal the cycles.

**Why it matters beyond cosmetics.** This footer is the only place in the UI that
exercises a full 256-byte NMI page transfer, the same path WAV and CVD streaming
use. A machine that truncates the footer has a transfer margin problem that
would equally corrupt streamed audio and video. Treat it as a lead on the
WAV/CVD failures, not as a separate cosmetic issue.

**Proposed step: make the footer self-verifying.** The Arduino already sends 256
deterministic bytes; put a known sentinel or checksum in the tail, have the menu
verify it and surface a mismatch. That converts "sometimes the line is short"
into a measurable error rate, per machine, with the display on and off, before
and after cleaning the edge connector. Capture set C in
`docs/DEBUG_TOOLING.md` measures the same thing at the wire level.

**Re-test first.** Until `1ffc393` every protocol response was preceded by
`Serial.flush()`, which could stall the AVR for milliseconds right before the
burst. That perturbation is gone (polled TX, bounded wait), so a debug build is
now a fairer place to observe the symptom.

---

## Backlog, ranked (from the 2026-09-26 audit)

- **B1 — Directory sort key truncation (correctness).** `DirSortSlot.key` holds
  only the first 15 characters of the LFN (`CartApi.cpp:523`, written at 695 and
  733), but the watermark filter compares full names (`CartApi.cpp:732`). Two
  entries sharing a 15-character prefix make the two passes disagree, which can
  drop or duplicate a row at a page boundary. This is the area with five
  revert/restore commits in the history.
- **B2 — Page rebuild cost.** A non-sequential page request rescans pages
  `0..startPage-1`, each a full directory iteration plus `GetLFNByDirIdx`
  (`CartApi.cpp:663-717`). Noticeable above ~200 entries. Measure, then bound it.
- **B3 — 16-bit size arithmetic.** `int menu_data_length = workingFile.size()`
  (`CartApi.cpp:1833`) overflows above 32 KB. The menu is 11 KB today, so this is
  latent; the fix is one `long`.
- **B4 — No regression safety net.** `Tools/build.py` has a single check
  (`validate_cvd_memory_layout`). `cmpDirEntry`, `sortSlotInsert` and the
  pagination logic are plain C++ and could be unit-tested on the host. Highest
  long-term value of anything in this list.
- **B5 — Remaining doc drift.** `GEMINI.md` describes ZP `$8B-$8E` as handler
  scratch while `CLAUDE.md` calls it free, and `CartZpMap.inc:15-16` says both.
  Pick one truth. `GEMINI.md` also still carries an older plugin-status
  paragraph.
- **B6 — WavPlayer rewrite unverified.** The full rewrite in `c4e90db` has not
  been tested on hardware. Do not start it before step 4, or the symptoms mix.
- **B7 — `Arduino/EasySD/DebugLog.h` is dead.** Nothing includes it; it
  documents itself as replaced by `EasySDLog.h`. Delete it.

---

## Future hardware work (PLAN, not scheduled)

See `docs/DEBUG_TOOLING.md` section 2: Schottky in series to the Nano 5V pin,
PHI2 presence gate in firmware (PHI2 is already wired to A4), and a debug header
for the analyzer. Also the custom sigrok decoder for the IO2 command protocol
(section 3.5).

---

## Dead features — do not propose reviving

- MultiLoad / MLBoot / ResidentLoader / EASYLOAD chain (dropped 2026-05-07)
- HWTest plugin (dropped 2026-05-07)
- PetsciiDisplayer plugin (removed in `41b6a8f`, 2026-05-13)
