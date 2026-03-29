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

Requires: ffmpeg in PATH (for MP3/FLAC/OGG/etc. input)
          For plain .wav input ffmpeg is still used for resampling.

Output: 44-byte RIFF/WAVE header + raw 8-bit unsigned PCM.
        Directly usable from the EasySD SD card with WavPlayer (WAV_HEADER_SIZE=44).

Mode presets (--mode overrides --rate and --channels):
    11k    → 11025 Hz, 1 channel (mono)   — PLAYTYPE_MK3
    22k    → 22050 Hz, 1 channel (mono)   — PLAYTYPE_MK3_22K
    stereo → 11025 Hz, 2 channels (L+R)   — PLAYTYPE_MK3_STEREO
"""

import argparse
import struct
import subprocess
import sys
import os


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
        '--mode', choices=['11k', '22k', 'stereo'], default=None,
        help='Preset: 11k=11025 Hz mono, 22k=22050 Hz mono, stereo=11025 Hz stereo',
    )
    args = parser.parse_args()

    # Mode presets override --rate and --channels
    if args.mode == '11k':
        args.rate, args.channels = 11025, 1
    elif args.mode == '22k':
        args.rate, args.channels = 22050, 1
    elif args.mode == 'stereo':
        args.rate, args.channels = 11025, 2

    if not os.path.isfile(args.input):
        print(f"ERROR: Input file not found: {args.input}", file=sys.stderr)
        sys.exit(1)

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


if __name__ == '__main__':
    main()
