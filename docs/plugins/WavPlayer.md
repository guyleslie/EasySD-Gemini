# EasySD – WavPlayer Plugin

Plays 8-bit PCM WAV audio files on the C64 from an SD card.
Supports SID-only, DigiMax compat, and DigiMax MK3 NMI-buffered output modes.

---

## File Format — WAV

| Property | Value |
|----------|-------|
| Extension | `.WAV` |
| Format | PCM (uncompressed) |
| Bit depth | 8-bit unsigned |
| Sample rate | 11025 Hz (compat/MK3 11K/MK3 stereo) or 22050 Hz (MK3 22K) |
| Channels | 1 (mono) or 2 (stereo for MK3 Stereo mode) |

Use `Tools/wavtodigimax.py` to convert any audio file to the correct format.

---

## Output Modes

Selected at runtime via the mode selector menu shown before playback.

| Cursor | Label | `PLAYTYPE` | Hardware | When shown |
|--------|-------|-----------|----------|------------|
| 0 | `C64 SID ONLY` | 0 | C64 SID 4-bit DAC, IO2 | always |
| 1 | `DIGIMAX` | 1 | DigiMax compat, IO2 | always |
| 2 | `SID + DIGIMAX` | 2 | SID + DigiMax, IO2 | always |
| 3 | `DIGIMAX MK3 11K` | 3 | MK3 NMI 11025 Hz mono | MK3 only |
| 4 | `DIGIMAX MK3 22K` | 4 | MK3 NMI 22050 Hz mono | MK3 only |
| 5 | `MK3 STEREO 11K` | 5 | MK3 NMI 11025 Hz stereo | MK3 only |

Modes 3–5 appear only when a DigiMax MK3 is detected at startup.

---

## Streaming Architecture

### Compat modes (PLAYTYPE 0–2)

Uses IO2 streaming (`PROT_Stream`). A 128-byte double buffer and CIA1 IRQ
feed samples at ~11 kHz. Susceptible to CIA jitter.

### MK3 NMI-buffered modes (PLAYTYPE 3–5)

Uses NMI double-buffer streaming:

1. Two 6144-byte audio buffers (`AUDIO_BUF_A` at `$4000`, `AUDIO_BUF_B` at `$5800`).
2. Buffers are pre-filled via `ReadNextChunk` (Arduino `COMMAND_READ_NEXT_CHUNK=27`
   pushes pages via NMI).
3. A CIA1 Timer A ISR (`PlaybackIRQ_Fast`) writes one byte per tick to `$DD01`
   (CIA2 DATA_B → MK3 `/PC2` latch).
4. The MK3 ATmega TIMER1 ISR drains its 4096-byte FIFO at crystal-exact rate.
5. Main loop refills the inactive buffer while the active one plays.

CIA1 timer values:

| Mode | Timer A lo | Effective rate |
|------|-----------|----------------|
| PLAYTYPE_MK3 (11K mono) | 89 | 985248 / 89 ≈ 11070 Hz |
| PLAYTYPE_MK3_22K | 44 | 985248 / 44 ≈ 22392 Hz |
| PLAYTYPE_MK3_STEREO | 44 | 22392 ticks/s × frame_size=2 → 11025 stereo pairs/s |

---

## DigiMax MK3 Auto-Detection

`DETECT_MK3` runs before the mode selector and sets `MK3_ACTIVE` (`$FB`).

**Phase 1** — magic bytes `$AC $DE $AD $BE` → MK3 replies with ≥1 FLAG2 pulse.
**Phase 2** — config bytes `$01` (frame_size=1) + `$40` (autostart) → 3 confirmation
pulses → `MK3_ACTIVE = 1`.
Timeout: `13 cycles × 256 × 18 ≈ 60 ms` per phase (loop-counter, no jiffy clock).

---

## MK3 Runtime Reconfiguration (SP2 extended commands)

For modes 4 and 5, `MK3_ConfigureMode` reconfigures the MK3 after detection
(mode 3 uses detection defaults and skips this step).

**SP2 pin**: CIA2 SDR output (user port pin 7 → ATmega PD4, 10 kΩ pull-down on MK3 PCB).

```
SP2 HIGH  → LDA $DD0F : ORA #$40 : STA $DD0F  (CRB bit6=1 → SDR output)
            LDA #$FF : STA $DD0C               (SDR write → SP2 HIGH)
SP2 LOW   → LDA $DD0F : AND #$BF : STA $DD0F  (CRB bit6=0 → pull-down → LOW)
```

Commands sent via `STA $DD01` (CIA2 PA → MK3 INT0), 10 NOPs between writes:

| Command byte | Meaning |
|-------------|---------|
| `$42` | CMD_FLUSH_FIFO — exits PARSER_STREAM_RECV → PARSER_IDLE |
| `$20` + lo | CMD_SET_RATE_L — OCR1A low byte |
| `$21` + hi | CMD_SET_RATE_H — OCR1A high byte |
| `$23` + n | CMD_SET_FRAME_SIZE — 1=mono, 2=stereo |
| `$30` | CMD_STREAM_PUSH — re-enters PARSER_STREAM_RECV |

Reconfiguration sequence for modes 4/5:
```
SP2 HIGH → CMD_FLUSH_FIFO → [CMD_SET_RATE if 22K] → [CMD_SET_FRAME_SIZE if stereo]
→ CMD_STREAM_PUSH → SP2 LOW
```

---

## wavtodigimax.py

Converts any audio to the correct WAV format for WavPlayer.

### Quick-start — choose by hardware

| You have | Use mode | Command |
|----------|----------|---------|
| No add-on (SID only) | `sid` | `--mode sid` |
| Original DigiMax | `sid` | `--mode sid` (4-bit optimised) |
| DigiMax MK3, 11 kHz mono | `11k` | `--mode 11k` |
| DigiMax MK3, 22 kHz mono | `22k` | `--mode 22k` |
| DigiMax MK3, stereo | `stereo` | `--mode stereo` |

```bash
# SID-only or original DigiMax (no MK3) — 4-bit optimised, pop-free:
python Tools/wavtodigimax.py input.mp3 out.wav --mode sid

# DigiMax MK3 modes:
python Tools/wavtodigimax.py input.mp3 out.wav --mode 11k     # PLAYTYPE_MK3
python Tools/wavtodigimax.py input.mp3 out.wav --mode 22k     # PLAYTYPE_MK3_22K
python Tools/wavtodigimax.py input.mp3 out.wav --mode stereo  # PLAYTYPE_MK3_STEREO

# Manual (advanced):
python Tools/wavtodigimax.py input.mp3 out.wav --rate 11025 --channels 1
```

**`--mode sid` processing pipeline** (why it sounds better than plain conversion):
1. HP filter at 80 Hz — removes DC offset that causes a pop when playback starts/stops
2. `dynaudnorm` loudness normalisation — maximises dynamic range within 4-bit limits
3. TPDF dithering — adds shaped noise before 4-bit quantisation to reduce harsh
   quantisation artefacts (16-level staircase → smoother perceived sound)
4. 50 ms fade-in / fade-out to mid-scale — smooths the volume-register ramp at
   start and end, preventing the remaining transient pop

The output byte stores the 4-bit value in the upper nibble (`byte = val << 4`),
matching WavPlayer's `SHIFT4BIT` lookup (`SHIFT4BIT[n] = n >> 4`).
Using `--mode sid` with an original DigiMax (compat) is fine — DAC accuracy
will be 4-bit instead of 8-bit, but the dithering still improves perceived quality.

Requires `ffmpeg` in PATH.

---

## API Calls Used

| Call | Purpose |
|------|---------|
| `PROT_StartTalking` | Wake Arduino at plugin start |
| `#OPENFILE` | Open the selected WAV file (APIMacros Tier 2) |
| `PROT_Stream` | Initialize IO2 streaming (compat modes) |
| `PROT_SeekFile` | Skip 44-byte WAV header (MK3 modes) |
| `PROT_Send` + `PROT_WaitProcessing` | `ReadNextChunk` command (MK3 modes) |
| `PROT_CloseFile` | Close file on exit |
| `PROT_EndTalking` | End Arduino session |
| `PROT_ExitToMenu` | Return to EasySD menu |

Macros: `#OPENFILE` (Tier 2), `#SETBANK`, `#SAVEREGS`/`#RESTOREREGS` (Tier 1).

---

## Controls

| Key | Action |
|-----|--------|
| Any key (compat) | Stop playback and exit to menu |
| STOP key (MK3) | Stop playback and exit to menu |

---

## Zero-Page Usage

| Address | Label | Description |
|---------|-------|-------------|
| `$FB` | `MK3_ACTIVE` | 1 = MK3 confirmed; 0 = compat |
| `$FC` | `DETECT_TIMEOUT` | Scratch during detection; free after |
| `$8B` | `ZP_WAV_PTR_LO` | Playback pointer lo |
| `$8C` | `ZP_WAV_PTR_HI` | Playback pointer hi |
| `$8D` | `ZP_WAV_END_HI` | Active buffer end hi-byte |
| `$8E` | `ZP_WAV_ACTBUF` | 0=BUF_A active, 1=BUF_B active |
| `$8F` | `ZP_WAV_FILL` | 0=idle, 1=fill inactive buffer |
| `$90` | `ZP_WAV_EOFLAG` | 0=more data, $FF=last block |
| `$91` | `ZP_WAV_TIMERLO` | CIA1 Timer A lo (89=11025 Hz, 44=22050 Hz/stereo) |

---

## Known Limitations

- Only uncompressed 8-bit unsigned PCM WAV files are supported.
- DigiMax compat modes (0–2) require a DigiMax cartridge alongside EasySD.
- MK3 modes (3–5) require a DigiMax MK3 (auto-detected).
- Compat mode timing depends on CIA1 stability; MK3 modes use crystal-exact ATmega TIMER1.

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
