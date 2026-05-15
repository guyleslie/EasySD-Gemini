#!/usr/bin/env python3
"""
wavtoeasysd.py - Convert audio to WavPlayer-compatible format for EasySD

Converts any audio file to an 8-bit unsigned PCM mono WAV with a clean 44-byte
RIFF header — the exact format expected by the WavPlayer plugin.

Usage:
    python Tools/wavtoeasysd.py input.mp3 output.wav
    python Tools/wavtoeasysd.py input.mp3 output.wav --mode sid

Requires: ffmpeg in PATH (for MP3/FLAC/OGG/WAV input and resampling).

Output: 44-byte RIFF/WAVE header + raw 8-bit unsigned PCM.
        Copy the resulting .wav file to the SD card and open it with WavPlayer.

PAL timing note:
    CIA1 Timer A reload=89 → period=90 cycles → 985248/90 = 10947 Hz ≈ 11kHz.
    Target sample rate for conversion: 11025 Hz (standard CD-quality base).
    The 0.7% rate mismatch is inaudible in practice.

Modes:
    (default) → 11025 Hz mono, 8-bit unsigned PCM.
                Works with both DigiMax (full 8-bit) and SID (4-bit effective,
                since the lower nibble is ignored by WavPlayer's SHIFT4BIT table).

    --mode sid → 11025 Hz mono, 4-bit value stored in upper nibble of each byte.
                 Processing: HP filter (80 Hz, removes DC offset / start-stop pops),
                 loudness normalisation, TPDF dithering, 50ms fade-in/out.
                 WavPlayer reads: LDA SHIFT4BIT,Y  (SHIFT4BIT[n] = n >> 4)
                 so the 4-bit sample is in the upper nibble: byte = (value << 4).
                 Also works with DigiMax in compat mode — DAC accuracy is 4-bit.
"""

import argparse
import random
import struct
import subprocess
import sys
import os
from array import array as _array


def build_wav_header(num_samples: int, sample_rate: int = 11025, channels: int = 1) -> bytes:
    """Return a standard 44-byte RIFF PCM WAV header for 8-bit unsigned PCM audio."""
    data_size = num_samples          # 1 byte per sample (8-bit)
    file_size = 36 + data_size       # RIFF chunk size = 36 + data_size
    byte_rate = sample_rate * channels
    block_align = channels

    header = struct.pack(
        '<4sI4s'   # RIFF + file_size + WAVE
        '4sI'      # "fmt " + fmt_chunk_size (16)
        'HHIIHH'   # audio_fmt, channels, sample_rate, byte_rate, block_align, bits_per_sample
        '4sI',     # "data" + data_size
        b'RIFF', file_size, b'WAVE',
        b'fmt ', 16,
        1,          # PCM
        channels,
        sample_rate,
        byte_rate,
        block_align,
        8,          # bits per sample
        b'data', data_size,
    )
    assert len(header) == 44, f"Header length mismatch: {len(header)}"
    return header


def _run_ffmpeg(cmd: list) -> bytes:
    """Run an ffmpeg command, return stdout bytes.  Exits on error."""
    try:
        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
    except FileNotFoundError:
        print("ERROR: ffmpeg not found in PATH.", file=sys.stderr)
        print("Install ffmpeg and make sure it is in your PATH.", file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as e:
        print(f"ERROR: ffmpeg failed:\n{e.stderr.decode(errors='replace')}", file=sys.stderr)
        sys.exit(1)
    return result.stdout


def convert_with_ffmpeg(input_path: str, sample_rate: int, channels: int = 1) -> bytes:
    """Use ffmpeg to decode/resample input to raw 8-bit unsigned PCM."""
    cmd = [
        'ffmpeg',
        '-i', input_path,
        '-ar', str(sample_rate),   # output sample rate
        '-ac', str(channels),      # channel count
        '-acodec', 'pcm_u8',       # 8-bit unsigned PCM
        '-f', 'u8',                # raw output (no container)
        '-',                       # stdout
    ]
    return _run_ffmpeg(cmd)


def convert_sid_optimized(input_path: str, sample_rate: int = 11025) -> bytes:
    """Decode and process audio for SID 4-bit playback (PLAYTYPE_ONLYSID).

    WavPlayer reads the byte from IO2 and does:
        LDA SHIFT4BIT, Y   ; SHIFT4BIT[n] = n >> 4
        STA $D418           ; SID master volume register (0-15)

    So the 4-bit sample must live in the upper nibble: byte = (value << 4).

    Processing pipeline:
      1. ffmpeg: resample to 11025 Hz mono, HP filter at 80 Hz (removes DC
         offset — prevents audible pop on play/stop), dynaudnorm for full
         4-bit dynamic range.
      2. TPDF dithering in Python before 4-bit quantisation, reducing perceived
         quantisation noise from 16-step resolution.
      3. 50 ms fade-in / fade-out to mid-scale (value=8) to eliminate any
         remaining start/stop transient.
      4. Store as (4bit_value << 4) — lower nibble always zero.

    Returns raw 8-bit unsigned PCM bytes (no WAV header).
    """
    # Decode to 16-bit signed PCM with HP filter + loudness normalisation
    raw = _run_ffmpeg([
        'ffmpeg',
        '-i', input_path,
        '-ar', str(sample_rate),
        '-ac', '1',
        '-af', 'highpass=f=80,dynaudnorm=p=0.95:s=5',
        '-acodec', 'pcm_s16le',
        '-f', 's16le',
        '-',
    ])

    if not raw:
        print("ERROR: ffmpeg produced no PCM data.", file=sys.stderr)
        sys.exit(1)

    samples = _array('h', raw)   # signed 16-bit host-endian
    n = len(samples)

    # Normalise to ±0.95 (5% headroom for dither)
    peak = max(abs(s) for s in samples) if n else 1
    if peak == 0:
        peak = 1
    scale = 0.95 / peak

    # TPDF dither + quantise to 4 bits + store in upper nibble.
    # TPDF = two independent uniform randoms summed → triangular distribution,
    # amplitude ±0.5 LSB at 4-bit resolution (1/15 ≈ 0.0667).
    fade_len = min(int(sample_rate * 0.05), n // 4)   # 50 ms in samples
    output = bytearray(n)
    rand = random.random

    for i, s in enumerate(samples):
        f = s * scale                                 # -0.95 … +0.95
        dither = (rand() - rand()) * (1.0 / 15.0)    # TPDF, ±1 LSB at 4-bit
        val = int((f + 1.0) * 7.5 + dither + 0.5)   # float → 0 … 15
        val = max(0, min(15, val))

        # Fade-in: ramp from mid-scale (8) to full amplitude
        if i < fade_len:
            fade = i / fade_len
            val = int(8.0 * (1.0 - fade) + val * fade + 0.5)
        # Fade-out: ramp from full amplitude back to mid-scale (8)
        elif i >= n - fade_len:
            fade = (n - 1 - i) / fade_len
            val = int(8.0 * (1.0 - fade) + val * fade + 0.5)

        output[i] = val << 4     # upper nibble = 4-bit sample; lower nibble = 0

    return bytes(output)


def main() -> None:
    parser = argparse.ArgumentParser(
        description='Convert audio to WavPlayer-compatible 8-bit PCM WAV for EasySD.',
    )
    parser.add_argument('input',  help='Input audio file (mp3, wav, flac, ogg, …)')
    parser.add_argument('output', help='Output .wav file')
    parser.add_argument(
        '--mode', choices=['sid'], default=None,
        help=(
            'sid = 11025 Hz mono, 4-bit value in upper nibble '
            '(HP filter + TPDF dither + fade-in/out). '
            'Default (omit --mode): 11025 Hz mono, plain 8-bit unsigned PCM '
            'for DigiMax or basic SID use.'
        ),
    )
    args = parser.parse_args()

    if not os.path.isfile(args.input):
        print(f"ERROR: Input file not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    sample_rate = 11025   # PAL C64: CIA1 reload=89 → 10947 Hz; 11025 Hz source is close enough

    if args.mode == 'sid':
        print(
            f"Converting '{args.input}' -> '{args.output}'  "
            f"[SID 4-bit: HP filter + TPDF dither + fade, {sample_rate} Hz mono] …"
        )
        pcm_data = convert_sid_optimized(args.input, sample_rate)
        channels = 1
    else:
        print(
            f"Converting '{args.input}' -> '{args.output}'  "
            f"[8-bit unsigned PCM mono, {sample_rate} Hz] …"
        )
        pcm_data = convert_with_ffmpeg(args.input, sample_rate, channels=1)
        channels = 1

    header = build_wav_header(len(pcm_data), sample_rate, channels)

    with open(args.output, 'wb') as f:
        f.write(header)
        f.write(pcm_data)

    size_kb = (len(header) + len(pcm_data)) / 1024
    duration_s = len(pcm_data) / sample_rate
    print(f"Done. {size_kb:.1f} KB, {duration_s:.1f} s  →  {args.output}")


if __name__ == '__main__':
    main()
