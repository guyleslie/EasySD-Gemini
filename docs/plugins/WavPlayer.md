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

## Known Limitations

- Only uncompressed PCM WAV files are supported. Compressed formats (µ-law, IMA ADPCM, etc.) are not.
- DigiMax mode requires a DigiMax cartridge in the expansion port alongside EasySD.
- Timing accuracy depends on CIA interrupt stability; other software running concurrently may cause glitches.
- Very high sample rates (above ~22 kHz) may exceed the streaming bandwidth.

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
