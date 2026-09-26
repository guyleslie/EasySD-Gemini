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
