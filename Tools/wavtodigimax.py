#!/usr/bin/env python3
"""
wavtodigimax.py - Convert audio to WavPlayer-compatible format

Converts any audio file to an 8-bit unsigned PCM WAV with a clean 44-byte
RIFF header — the exact format expected by the WavPlayer plugin.

Usage:
    python Tools/wavtodigimax.py input.mp3 output.wav
    python Tools/wavtodigimax.py input.wav output.wav [--rate 11025]
    python Tools/wavtodigimax.py input.mp3 output.wav --mode 11k
    python Tools/wavtodigimax.py input.mp3 output.wav --mode 22k
    python Tools/wavtodigimax.py input.mp3 output.wav --mode stereo
    python Tools/wavtodigimax.py input.mp3 output.wav --mode sid

Requires: ffmpeg in PATH (for MP3/FLAC/OGG/etc. input)
          For plain .wav input ffmpeg is still used for resampling.

Output: 44-byte RIFF/WAVE header + raw 8-bit unsigned PCM.
        Directly usable from the EasySD SD card with WavPlayer (WAV_HEADER_SIZE=44).

Mode presets (--mode overrides --rate and --channels):
    11k    → 11025 Hz, 1 channel (mono)   — PLAYTYPE_MK3 (MK3 hardware)
    22k    → 22050 Hz, 1 channel (mono)   — PLAYTYPE_MK3_22K (MK3 hardware)
    stereo → 11025 Hz, 2 channels (L+R)   — PLAYTYPE_MK3_STEREO (MK3 hardware)
    sid    → 11025 Hz, 1 channel (mono)   — PLAYTYPE_ONLYSID / PLAYTYPE_DIGIMAX
             Applies 4-bit optimisation: HP filter (removes DC offset to prevent
             start/end pops), TPDF dithering before upper-nibble truncation, and
             50 ms fade-in/fade-out to silence.  The 4-bit value is stored in the
             upper nibble of each byte so WavPlayer's SHIFT4BIT table (byte >> 4)
             reads it correctly.  Also works fine with a real DigiMax (compat mode)
             — the lower nibble is zero, so DAC accuracy is 4-bit, not 8-bit.
"""

import argparse
import random
import struct
import subprocess
import sys
import os
from array import array as _array


def build_wav_header(num_samples: int, sample_rate: int = 11025, channels: int = 1) -> bytes:
    """Return a standard 44-byte RIFF PCM WAV header for 8-bit PCM audio."""
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
        STA $D418           ; SID volume register (0–15)

    So the 4-bit sample must live in the upper nibble: byte = (value << 4).

    Processing pipeline:
      1. ffmpeg: resample to 11025 Hz mono, apply HP filter at 80 Hz to remove
         DC offset (DC → SID volume offset → audible pop on play/stop).
      2. Loudness normalization (dynaudnorm) to use the full 4-bit dynamic range.
      3. TPDF dithering in Python before 4-bit quantisation, reducing perceived
         quantisation noise from 16-step resolution.
      4. 50 ms fade-in / fade-out to mid-scale (value=8) to silence any remaining
         start/end transient.
      5. Store as (4bit_value << 4) — lower nibble zero.

    Returns raw 8-bit unsigned PCM bytes (no WAV header).
    """
    # Step 1: decode to 16-bit signed PCM with HP filter + normalisation
    raw = _run_ffmpeg([
        'ffmpeg',
        '-i', input_path,
        '-ar', str(sample_rate),
        '-ac', '1',
        # highpass removes DC offset; dynaudnorm maximises loudness for 4-bit
        '-af', 'highpass=f=80,dynaudnorm=p=0.95:s=5',
        '-acodec', 'pcm_s16le',
        '-f', 's16le',
        '-',
    ])

    if not raw:
        print("ERROR: ffmpeg produced no PCM data.", file=sys.stderr)
        sys.exit(1)

    # Step 2: load samples into a typed array (faster iteration than struct loop)
    samples = _array('h', raw)   # signed 16-bit host-endian
    n = len(samples)

    # Step 3: find peak for final normalisation (leave 5 % headroom for dither)
    peak = max(abs(s) for s in samples) if n else 1
    if peak == 0:
        peak = 1
    scale = 0.95 / peak          # maps peak → ±0.95

    # Step 4: TPDF dither + quantise to 4 bits + store in upper nibble
    #   TPDF = Triangular Probability Density Function dither.
    #   Two independent uniform random values summed → triangular distribution,
    #   amplitude ±0.5 LSB at 4-bit resolution (1/15 ≈ 0.0667).
    fade_len = min(int(sample_rate * 0.05), n // 4)   # 50 ms in samples
    output = bytearray(n)
    rand = random.random

    for i, s in enumerate(samples):
        f = s * scale                                 # -0.95 … +0.95
        dither = (rand() - rand()) * (1.0 / 15.0)    # TPDF, ±1 LSB at 4-bit
        val = int((f + 1.0) * 7.5 + dither + 0.5)   # float → 0 … 15
        val = val if val >= 0 else 0
        val = val if val <= 15 else 15

        # Fade-in: linear ramp from mid-scale (8) to full amplitude
        if i < fade_len:
            fade = i / fade_len
            val = int(8.0 * (1.0 - fade) + val * fade + 0.5)
        # Fade-out: linear ramp from full amplitude back to mid-scale (8)
        elif i >= n - fade_len:
            fade = (n - 1 - i) / fade_len
            val = int(8.0 * (1.0 - fade) + val * fade + 0.5)

        output[i] = val << 4     # upper nibble = 4-bit sample; lower nibble = 0

    return bytes(output)


def main() -> None:
    parser = argparse.ArgumentParser(
        description='Convert audio to WavPlayer-compatible 8-bit PCM WAV.',
    )
    parser.add_argument('input', help='Input audio file (mp3, wav, flac, ogg, …)')
    parser.add_argument('output', help='Output .wav file')
    parser.add_argument(
        '--rate', type=int, default=11025,
        help='Target sample rate in Hz (default: 11025)',
    )
    parser.add_argument(
        '--channels', type=int, choices=[1, 2], default=1,
        help='Number of channels: 1=mono (default), 2=stereo',
    )
    parser.add_argument(
        '--mode', choices=['11k', '22k', 'stereo', 'sid'], default=None,
        help=(
            'Preset mode: '
            '11k=11025 Hz mono (MK3), '
            '22k=22050 Hz mono (MK3 22K), '
            'stereo=11025 Hz stereo (MK3 stereo), '
            'sid=11025 Hz mono with 4-bit dither+HP filter (SID/DigiMax compat)'
        ),
    )
    args = parser.parse_args()

    # Mode presets override --rate and --channels
    if args.mode == '11k':
        args.rate, args.channels = 11025, 1
    elif args.mode == '22k':
        args.rate, args.channels = 22050, 1
    elif args.mode == 'stereo':
        args.rate, args.channels = 11025, 2
    elif args.mode == 'sid':
        args.rate, args.channels = 11025, 1

    if not os.path.isfile(args.input):
        print(f"ERROR: Input file not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    if args.mode == 'sid':
        print(
            f"Converting '{args.input}' → '{args.output}' "
            f"at {args.rate} Hz mono  [SID 4-bit optimised: HP filter + TPDF dither + fade] …"
        )
        pcm_data = convert_sid_optimized(args.input, args.rate)
    else:
        ch_desc = 'mono' if args.channels == 1 else 'stereo'
        print(f"Converting '{args.input}' → '{args.output}' at {args.rate} Hz {ch_desc} …")
        pcm_data = convert_with_ffmpeg(args.input, args.rate, args.channels)

    num_samples = len(pcm_data)
    if num_samples == 0:
        print("ERROR: ffmpeg produced no PCM data.", file=sys.stderr)
        sys.exit(1)

    header = build_wav_header(num_samples, args.rate, args.channels)

    with open(args.output, 'wb') as f:
        f.write(header)
        f.write(pcm_data)

    duration_s = num_samples / (args.rate * args.channels)
    size_kb = (len(header) + num_samples) / 1024
    print(f"Done: {num_samples} bytes PCM, {duration_s:.1f}s, {size_kb:.1f} KB")
    print(f"Output: {args.output}")
    if args.mode == 'sid':
        print("Note: samples stored as upper nibble (val<<4) for SID SHIFT4BIT table.")


if __name__ == '__main__':
    main()
