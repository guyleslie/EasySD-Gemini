#!/usr/bin/env python3
"""
cvid_convert.py — Convert MP4/AVI to C64 CVID format for EasySD CvidPlayer.

Usage:
    python Tools/cvid_convert.py input.mp4 VIDEO.CVID
    python Tools/cvid_convert.py input.mp4 VIDEO.CVID --dither
    python Tools/cvid_convert.py input.mp4 VIDEO.CVID --threshold 100
    python Tools/cvid_convert.py --info input.mp4

CVID format: flat binary, 4000 bytes/frame (10 blocks x 400 bytes/block).
See IRQHack64/Plugins/CvidPlayer/CvidPlayer.s for the full format spec.
"""

import argparse
import json
import subprocess
import sys
import time

# ── CVID format constants ─────────────────────────────────────────────────────

FRAME_WIDTH      = 160
FRAME_HEIGHT     = 80
FPS              = 5
BLOCKS_PER_FRAME = 10
BYTES_PER_BLOCK  = 400
BYTES_PER_FRAME  = BLOCKS_PER_FRAME * BYTES_PER_BLOCK  # 4000

# Block layout offsets (see TRANSFERDATAINNER macro in FGStuff.s)
#   Quadrant 0 ($000-$04F): char_row_A, left  20 cols
#   Quadrant 1 ($050-$09F): char_row_A, right 20 cols
#   Quadrant 2 ($0A0-$0EF): char_row_B, left  20 cols
#   Quadrant 3 ($0F0-$13F): char_row_B, right 20 cols
#   $140-$167: Screen RAM color (both char rows of this pair, same 40 bytes)
#   $168-$18F: D800 color RAM cache for this line pair
QUADRANT_OFFSETS = [0x000, 0x050, 0x0A0, 0x0F0]
SCREEN_OFFSET    = 0x140
COLOR_OFFSET     = 0x168

# ── Argument parsing ──────────────────────────────────────────────────────────

def parse_args():
    ap = argparse.ArgumentParser(
        description="Convert video to C64 CVID format for EasySD CvidPlayer.",
        epilog="Requires ffmpeg and ffprobe in PATH.",
    )
    ap.add_argument("input", help="Input video file (MP4, AVI, etc.)")
    ap.add_argument("output", nargs="?",
                    help="Output CVID file (e.g. VIDEO.CVID). "
                         "Omit when using --info.")
    ap.add_argument("--dither", action="store_true",
                    help="Apply Floyd-Steinberg dithering (better gradients)")
    ap.add_argument("--threshold", type=int, default=128, metavar="N",
                    help="B&W threshold 0-255 (default: 128; pixel >= N → white)")
    ap.add_argument("--info", action="store_true",
                    help="Show video info only, do not convert")
    return ap.parse_args()

# ── ffprobe / ffmpeg helpers ──────────────────────────────────────────────────

def probe_video(path):
    """Return (duration_seconds: float, fps_str: str) via ffprobe."""
    cmd = [
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=duration,r_frame_rate",
        "-of", "json", path,
    ]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except FileNotFoundError:
        print("Error: ffprobe not found — install ffmpeg and add it to PATH.",
              file=sys.stderr)
        sys.exit(1)
    if res.returncode != 0:
        print(f"Error probing video:\n{res.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    try:
        data    = json.loads(res.stdout)
        stream  = data["streams"][0]
        duration = float(stream.get("duration", 0) or 0)
        fps_str  = stream.get("r_frame_rate", "?")
        return duration, fps_str
    except (KeyError, IndexError, ValueError) as exc:
        print(f"Error parsing ffprobe output: {exc}", file=sys.stderr)
        sys.exit(1)


def extract_frames(path):
    """Generator: yield raw 160x80 grayscale frames as bytes objects."""
    cmd = [
        "ffmpeg", "-i", path,
        "-vf",
        f"fps={FPS},scale={FRAME_WIDTH}:{FRAME_HEIGHT}:flags=lanczos,format=gray",
        "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1",
        "-loglevel", "error",
    ]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError:
        print("Error: ffmpeg not found — install ffmpeg and add it to PATH.",
              file=sys.stderr)
        sys.exit(1)

    frame_size = FRAME_WIDTH * FRAME_HEIGHT
    while True:
        chunk = proc.stdout.read(frame_size)
        if len(chunk) < frame_size:
            break
        yield chunk

    proc.stdout.close()
    stderr_data = proc.stderr.read()
    proc.wait()
    # returncode 255/-1 can mean broken pipe (fine); 0 = clean EOF
    if proc.returncode not in (0, -1, 255):
        print(f"ffmpeg error:\n{stderr_data.decode(errors='replace').strip()}",
              file=sys.stderr)

# ── Dithering ─────────────────────────────────────────────────────────────────

def floyd_steinberg(pixels, threshold):
    """
    Apply Floyd-Steinberg dithering in-place.

    pixels: mutable list of floats (length FRAME_WIDTH * FRAME_HEIGHT, 0.0-255.0).
    After the call, each entry is exactly 0.0 (black) or 255.0 (white).
    """
    w, h = FRAME_WIDTH, FRAME_HEIGHT
    for y in range(h):
        for x in range(w):
            idx     = y * w + x
            old     = pixels[idx]
            new_val = 255.0 if old >= threshold else 0.0
            pixels[idx] = new_val
            err = old - new_val
            if x + 1 < w:
                pixels[idx + 1]             += err * 7.0 / 16
            if y + 1 < h:
                if x > 0:
                    pixels[(y+1)*w + x - 1] += err * 3.0 / 16
                pixels[(y+1)*w + x]         += err * 5.0 / 16
                if x + 1 < w:
                    pixels[(y+1)*w + x + 1] += err * 1.0 / 16

# ── CVID encoding ─────────────────────────────────────────────────────────────

def encode_block(pixels, y_pair, threshold):
    """
    Encode one 400-byte CVID block for line pair y_pair (0..9).

    pixels: indexed sequence of grayscale values (int 0-255 or float).
    y_pair: block index within the frame (0 = top, 9 = bottom).

    Block covers y_vid rows [y_pair*8 .. y_pair*8+7], which map to two
    C64 character rows.  Each block covers 8 "video rows" (each row
    = 2 duplicated physical scan lines on the C64 bitmap).

    Multicolor pixel encoding:
        white (>= threshold) → 2-bit '01' (screen RAM upper nibble = 1/white)
        black (<  threshold) → 2-bit '00' (background $D021)

    Screen RAM ($140-$167): all 0x11 (color 1/white for both nibble slots)
    D800 color ($168-$18F): all 0x01 (color 1/white, for '11' bits)
    """
    block = bytearray(BYTES_PER_BLOCK)

    # Screen RAM: color 1 (white) in both nibbles for every cell
    for x in range(40):
        block[SCREEN_OFFSET + x] = 0x11

    # D800 color: color 1 (white) for every cell
    for x in range(40):
        block[COLOR_OFFSET + x] = 0x01

    # Bitmap quadrants
    for local_y in range(8):
        char_row_in_pair = local_y >> 2   # 0 = char_row_A (local_y 0-3)
                                          # 1 = char_row_B (local_y 4-7)
        scan_pair        = local_y & 3   # 0-3: which scan-line pair in the char cell
        y_vid = y_pair * 8 + local_y

        for x_vid in range(FRAME_WIDTH):
            char_col     = x_vid >> 2    # 0..39: which character column
            pixel_in_char = x_vid & 3   # 0..3: which 2-bit slot within the byte

            half         = 1 if char_col >= 20 else 0
            char_in_half = char_col - half * 20   # 0..19 within the left/right half

            # quadrant index:  char_row_in_pair * 2 + half  →  0..3
            quadrant = (char_row_in_pair << 1) | half
            x_in_q   = char_in_half * 4 + scan_pair
            byte_off  = QUADRANT_OFFSETS[quadrant] + x_in_q

            # bit_shift: 6 for pixel 0 (leftmost), 4, 2, 0 for pixels 1-3
            bit_shift = 6 - (pixel_in_char << 1)

            # '01' pattern → set only the lower bit of this 2-bit field
            if pixels[y_vid * FRAME_WIDTH + x_vid] >= threshold:
                block[byte_off] |= (1 << bit_shift)

    return bytes(block)


def encode_frame(pixels, threshold):
    """Encode one full video frame → 4000 bytes (10 CVID blocks)."""
    return b"".join(
        encode_block(pixels, y_pair, threshold)
        for y_pair in range(BLOCKS_PER_FRAME)
    )

# ── Progress display ──────────────────────────────────────────────────────────

def _progress(frame_count, total_frames, elapsed):
    bar_w  = 20
    if total_frames > 0:
        frac   = min(frame_count / total_frames, 1.0)
        filled = int(frac * bar_w)
        total_s = str(total_frames)
    else:
        frac   = 0.0
        filled = 0
        total_s = "?"
    bar  = "#" * filled + "-" * (bar_w - filled)
    rate = frame_count / elapsed if elapsed > 0 else 0.0
    written_kb = frame_count * BYTES_PER_FRAME / 1024
    print(
        f"\rFrame {frame_count:4d}/{total_s:<5s} [{bar}]"
        f"  {rate:5.1f} enc-fps  {written_kb:6.0f} KB",
        end="", flush=True,
    )

# ── Main pipeline ─────────────────────────────────────────────────────────────

def convert(input_path, output_path, dither, threshold):
    duration, fps_str = probe_video(input_path)
    total_frames = int(duration * FPS) if duration > 0 else 0

    print(f"Input:     {input_path}")
    print(f"Source:    {fps_str} fps,  {duration:.1f}s")
    print(f"Output:    {output_path}")
    print(f"CVID:      {FPS} fps, {FRAME_WIDTH}x{FRAME_HEIGHT}, "
          f"{'Floyd-Steinberg dither' if dither else f'threshold={threshold}'}")
    if total_frames > 0:
        print(f"Estimated: {total_frames} frames, "
              f"{total_frames * BYTES_PER_FRAME / 1024:.0f} KB")
    print()

    frame_count = 0
    start = time.monotonic()

    try:
        with open(output_path, "wb") as out_f:
            for raw_frame in extract_frames(input_path):
                if dither:
                    pixels = [float(b) for b in raw_frame]
                    floyd_steinberg(pixels, threshold)
                else:
                    pixels = raw_frame  # bytes: indexing returns int 0-255

                out_f.write(encode_frame(pixels, threshold))
                frame_count += 1

                elapsed = time.monotonic() - start
                _progress(frame_count, total_frames, elapsed)

    except KeyboardInterrupt:
        print("\nInterrupted.")
        sys.exit(1)

    elapsed = time.monotonic() - start
    size_kb = frame_count * BYTES_PER_FRAME / 1024
    print(f"\nDone: {frame_count} frames, {size_kb:.0f} KB"
          f"  ({elapsed:.1f}s, {frame_count/elapsed:.1f} fps)")


def main():
    args = parse_args()

    if args.info:
        duration, fps_str = probe_video(args.input)
        total_cvid = int(duration * FPS) if duration > 0 else 0
        print(f"File:          {args.input}")
        print(f"Source FPS:    {fps_str}")
        print(f"Duration:      {duration:.1f}s")
        print(f"CVID frames:   {total_cvid}  (at {FPS} fps)")
        print(f"CVID size:     {total_cvid * BYTES_PER_FRAME / 1024:.0f} KB")
        return

    if args.output is None:
        print("Error: output file required (or use --info to probe only).",
              file=sys.stderr)
        sys.exit(1)

    convert(args.input, args.output, args.dither, args.threshold)


if __name__ == "__main__":
    main()
