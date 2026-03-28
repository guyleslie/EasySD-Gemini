# EasySD – WavPlayer Plugin

Plays 4-bit or 8-bit PCM WAV audio files on the C64 from an SD card.
Supports SID-only, DigiMax, and combined SID+DigiMax output modes.

---

## File Format — WAV

| Property | Value |
|----------|-------|
| Extension | `.WAV` |
| Format | PCM (uncompressed) |
| Bit depth | 4-bit or 8-bit |
| Sample rate | Depends on file (plugin reads WAV header) |

Standard WAV files (RIFF/PCM) are accepted. The plugin parses the WAV header
to determine sample rate, bit depth, and audio data offset.

---

## Output Modes

The plugin selects an output mode based on hardware and file contents:

| Mode | Constant | Output device |
|------|----------|---------------|
| SID only | `PLAYTYPE_ONLYSID` | C64 SID chip (4-bit DAC trick) |
| DigiMax | `PLAYTYPE_DIGIMAX` | DigiMax cartridge (external DAC) |
| Both | `PLAYTYPE_BOTH` | SID + DigiMax simultaneously |

Default at runtime: `PLAYTYPE_BOTH`. The mode can be changed in the source.

---

## Streaming Architecture

Unlike other plugins, WavPlayer does not buffer the entire file in RAM.
It uses the cartridge streaming API (`PROT_Stream`) to feed audio data
directly to the playback interrupt routine:

1. File is opened and streaming mode is initialized via `PROT_Stream`.
2. An IRQ/NMI-driven play routine reads samples from a 128-byte double
   buffer (`STREAMINGBUFFERHALF = 64` bytes per half).
3. The Arduino continuously sends audio data; the C64 consumes it in
   real time via the interrupt handler.

This allows playback of files larger than available C64 RAM.

---

## API Calls Used

| Call | Purpose |
|------|---------|
| `PROT_StartTalking` | Wake Arduino at plugin start |
| `PROT_OpenFile` | Open the selected WAV file |
| `PROT_Stream` | Initialize streaming mode |
| `PROT_CloseFile` | Close file on exit |
| `PROT_EndTalking` | End Arduino session |
| `PROT_ExitToMenu` | Return to EasySD menu |

Macros: `#OPENFILE` (Tier 2), `#SETBANK`, `#SAVEREGS`/`#RESTOREREGS` (Tier 1).

---

## Controls

| Key | Action |
|-----|--------|
| Any key | Stop playback and exit to menu |

---

## DigiMax MK3 Streaming Mode

WavPlayer **auto-detects** a DigiMax MK3 at startup via the `DETECT_MK3` routine.  No user
configuration is required.  If an original Digimax or no hardware is found, compat mode
is selected transparently.

### Mode comparison

| Mode | Hardware | Timing source | FIFO buffer | Quality |
|------|----------|---------------|-------------|---------|
| **Compat** (default) | Original Digimax or MK3 | C64 CIA1 IRQ (~11 kHz, jitter) | None | 8-bit, ~11 kHz, may click |
| **MK3 streaming** (auto) | DigiMax MK3 only | ATmega TIMER1 (crystal, exact) | 4096 bytes ≈ 372 ms | 8-bit, 11025 Hz, **stable** |

### Initialisation sequence

1. `SetupDigimax` / `SetupBoth` calls `NMIDIGI_InitNew` (CIA2 setup — unchanged).
2. `DETECT_MK3` is called immediately after.
3. **Phase 1** — magic sequence `$AC $DE $AD $BE` sent on channel 0 (`$DD01`, PA3=1,
   PA2=0).  MK3 responds with ≥1 FLAG2 pulse within ~60 ms; no pulse → compat mode.
4. **Phase 2** — two config bytes sent:
   - `$01` — frame_size = 1 (mono; 1 byte per ATmega TIMER1 tick, replicated to all 4 DAC channels)
   - `$40` — auto-start threshold = 64 → 64 × 16 = 1024 bytes ≈ 93 ms pre-buffer
5. ATmega replies with exactly **3 FLAG2 confirmation pulses** → `MK3_ACTIVE` (`$FB`) = 1.

### Playback

`PlayDigimax` / `PlayBothBuffered` write one byte per CIA1 tick to `$DD01` — **identical
to compat**.  On MK3, each write triggers INT0 → byte enters the ATmega FIFO → TIMER1 ISR
drains at crystal-exact 11025 Hz.  The FIFO absorbs CIA1/IO2 jitter → no clicks.
Playback auto-starts when FIFO reaches 1024 bytes (~93 ms).

### Timeout design

`DETECT_MK3` uses a loop-counter timeout (not the jiffy clock `$A2`).  `KILLCIA` disables
CIA1 interrupts before detection, so `$A2` stops updating — a jiffy-based timeout would
freeze at 0 and loop forever on non-MK3 hardware.

`13 cycles × 256 inner × 18 outer ≈ 60 000 cycles ≈ 60 ms @ 1 MHz` per phase.

### Zero-page usage

| Address | Label | Description |
|---------|-------|-------------|
| `$FB` | `MK3_ACTIVE` | 1 = MK3 streaming confirmed; 0 = compat mode |
| `$FC` | `DETECT_TIMEOUT` | Scratch during detection only; free after `DETECT_DONE` |

---

## Known Limitations

- Only uncompressed PCM WAV files are supported. Compressed formats (µ-law, IMA ADPCM, etc.) are not.
- DigiMax mode requires a DigiMax cartridge in the expansion port alongside EasySD.
- In compat mode, timing accuracy depends on CIA interrupt stability; other software running concurrently may cause glitches.  **MK3 streaming mode eliminates this via the ATmega FIFO.**
- MK3 streaming mode supports **11 kHz mono only**; higher rates exceed EasySD IO2 bandwidth (~13.5 KB/s).
- Very high sample rates (above ~22 kHz) may exceed the streaming bandwidth in compat mode.

---

## Source and Build

| Item | Path |
|------|------|
| Source | `EasySD/Plugins/WavPlayer/WavPlayer.s` |
| Build output | `EasySD/build/plugins/wavplugin.prg` |
| SD card path | `/PLUGINS/WAVPLUGIN.PRG` |

```bash
python Tools/build.py plugins
```
