#!/usr/bin/env python3
"""create_multiload.py — Disk-image extractor for EasySD MultiLoad.

Converts a Commodore D64/D71/D81/T64 disk image (or several merged together)
into a flat directory of `.PRG` files under `multiload/<GAME>/`. Copy that
directory into `MULTILOAD/<GAME>/` on the SD card, then select any first-part
PRG inside it from the EasySD menu — the cartridge synthesises the MLBoot
prologue blob on the fly (no per-game `EASYLOAD.PRG`, no template patching).

Usage:
    python Tools/create_multiload.py --from-disk TURRICAN.D64
    python Tools/create_multiload.py --from-disk 1.d64 2.d64
    python Tools/create_multiload.py --from-autoswap autoswap.lst
    python Tools/create_multiload.py --from-disk TURRICAN.D64 --list-only

Output:
    multiload/<GAME>/<NAME>.PRG  (one file per closed PRG entry on the disk)

Old per-game `*.ZIP` artefacts produced by previous versions of this script
are obsolete; they may be deleted or ignored. The MLBoot pipeline reads PRGs
straight from `MULTILOAD/<GAME>/` on the SD card.

Supported formats: D64, D71, D81, T64.
"""

import argparse
import os
import struct
import sys

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

OUTPUT_DIR = "multiload"

# D64 sectors per track (index = track number, 1-based; index 0 unused)
_D64_SPT = [0] + [21]*17 + [19]*7 + [18]*6 + [17]*5   # tracks 1-35


# ---------------------------------------------------------------------------
# Section A: PETSCII / filename utilities
# ---------------------------------------------------------------------------

def petscii_to_fat(raw: bytes, padding: int) -> str:
    """Convert PETSCII filename bytes to uppercase FAT-safe ASCII string.

    Args:
        raw:     Raw bytes from a D64/T64 directory entry filename field.
        padding: The byte value used for trailing padding ($A0 for D64/D81,
                 $20 for T64).

    Returns:
        Uppercase ASCII string with illegal FAT characters replaced by '_'.
        May be empty if the input is all padding or all untranslatable bytes.

    NOTE: The conversion is intentionally 1-to-1 (no trailing-char stripping).
    The game's internal LOAD calls use the same PETSCII bytes as the D64 directory
    entry, so the FAT filename on the SD card must match exactly what the game
    sends — including any cracker-added suffixes or non-standard padding bytes.
    """
    name = raw.rstrip(bytes([padding])).rstrip(b'\x00')
    result = []
    # FAT-illegal characters that must be replaced
    _FAT_ILLEGAL = set(b'*?/:<>|\\"\x00')

    for b in name:
        if 0xC1 <= b <= 0xDA:          # PETSCII uppercase A-Z → ASCII uppercase
            result.append(chr(b - 0x80))
        elif 0x41 <= b <= 0x5A:         # ASCII uppercase (some mastering tools)
            result.append(chr(b))
        elif 0x61 <= b <= 0x7A:         # ASCII lowercase → uppercase
            result.append(chr(b - 0x20))
        elif 0x30 <= b <= 0x39:         # digits 0-9
            result.append(chr(b))
        elif b == 0x20:                 # space — valid in VFAT LFN, preserve
            result.append(' ')
        elif b == 0x2E:                 # period — valid in FAT, preserve
            result.append('.')
        elif b in _FAT_ILLEGAL:         # truly illegal FAT characters → underscore
            result.append('_')
        elif 0x21 <= b <= 0x7E:         # other printable ASCII, FAT-safe → preserve as-is
            # RL_STUB sends raw PETSCII bytes to Arduino; SD card filename must match exactly.
            # Standard ASCII punctuation ($21-$2F, $3A-$40) is identical in PETSCII and ASCII.
            # E.g. '+' ($2B), '-' ($2D), '!' ($21) must NOT be converted to '_'.
            result.append(chr(b))
        else:                           # high PETSCII graphics chars → underscore
            result.append('_')
    return ''.join(result)


def fat_safe_name(s: str, max_len: int = 16) -> str:
    """Uppercase and sanitise a string for use as a FAT folder/filename stem.

    Replaces characters illegal in FAT (Windows) filenames with '_'.
    Truncates to max_len characters. Returns 'UNNAMED' if result is empty.
    """
    s = s.upper()
    illegal = set('*?/:<>|\\"\x00')
    s = ''.join('_' if c in illegal else c for c in s)
    s = s[:max_len].rstrip('_') or s[:max_len]   # avoid all-underscores if possible
    return s if s else 'UNNAMED'


# ---------------------------------------------------------------------------
# Section B: Disk image parsers
# ---------------------------------------------------------------------------

def _d64_sector_offset(track: int, sector: int) -> int:
    """Byte offset of a D64 sector within the image data."""
    return sum(_D64_SPT[1:track]) * 256 + sector * 256


class D64Image:
    """Parser for Commodore 1541 D64 disk images (35-track, standard)."""

    VALID_SIZES = {174848, 175531}   # without / with 683 error bytes

    def __init__(self, data: bytes, path: str):
        self._data = data
        self._path = path
        if len(data) not in self.VALID_SIZES:
            print(f"[MULTILOAD] Warning: {os.path.basename(path)}: "
                  f"unexpected size {len(data)} (expected {sorted(self.VALID_SIZES)})")

    def _sector_offset(self, track: int, sector: int) -> int:
        return _d64_sector_offset(track, sector)

    def _read_sector(self, track: int, sector: int) -> bytes:
        off = self._sector_offset(track, sector)
        if off + 256 > len(self._data):
            raise IndexError(f"Sector T{track}/S{sector} out of range")
        return self._data[off:off + 256]

    def _follow_chain(self, track: int, sector: int) -> bytes:
        """Follow a sector chain and return the complete file data."""
        result = bytearray()
        seen = set()
        for _ in range(683):            # max D64 sectors — anti-loop guard
            key = (track, sector)
            if key in seen:
                raise ValueError(f"Sector chain loop at T{track}/S{sector}")
            seen.add(key)
            sec = self._read_sector(track, sector)
            next_track  = sec[0]
            next_sector = sec[1]
            if next_track == 0:
                # Last sector: byte[1] = number of used bytes (data at [2..byte[1]-1])
                used = next_sector
                if used >= 2:
                    result.extend(sec[2:used])
                break
            else:
                result.extend(sec[2:])  # 254 data bytes
                track, sector = next_track, next_sector
        return bytes(result)

    def list_files(self) -> list:
        """Return list of {'name': str, 'data': bytes} for all closed PRG entries."""
        files = []
        seen_names: dict = {}

        # Directory starts at T18/S1; follow chain through directory sectors
        dir_track, dir_sector = 18, 1
        dir_seen = set()
        while dir_track != 0:
            key = (dir_track, dir_sector)
            if key in dir_seen:
                break
            dir_seen.add(key)
            try:
                sec = self._read_sector(dir_track, dir_sector)
            except IndexError:
                break
            dir_track  = sec[0]
            dir_sector = sec[1]

            for i in range(8):          # 8 directory entries per sector
                entry = sec[i * 32: i * 32 + 32]
                ftype = entry[2]
                if ftype == 0x00:       # scratched/deleted
                    continue
                if not (ftype & 0x80):  # not closed (still open / splat file)
                    continue
                if (ftype & 0x07) != 0x02:  # not PRG
                    continue

                raw_name = entry[5:21]
                name = petscii_to_fat(raw_name, 0xA0) or "UNNAMED"

                # Deduplicate within image
                if name in seen_names:
                    seen_names[name] += 1
                    name = f"{name}_{seen_names[name]}"
                else:
                    seen_names[name] = 1

                ft, fs = entry[3], entry[4]
                try:
                    data = self._follow_chain(ft, fs)
                except (ValueError, IndexError) as e:
                    print(f"[MULTILOAD] Warning: '{name}' — {e}, skipping.")
                    continue

                if len(data) < 2:
                    print(f"[MULTILOAD] Warning: '{name}' has <2 bytes of data, skipping.")
                    continue

                files.append({"name": name, "data": data})

        return files

    def image_name(self) -> str:
        """Return disk label as a FAT-safe uppercase ASCII string."""
        try:
            bam = self._read_sector(18, 0)
            label = petscii_to_fat(bam[0x90:0xA0], 0xA0)
            return label
        except (IndexError, Exception):
            return ""


class D71Image(D64Image):
    """Parser for Commodore 1571 D71 disk images (70-track, dual-sided)."""

    VALID_SIZES = {349696, 351062}   # without / with 1366 error bytes

    def _sector_offset(self, track: int, sector: int) -> int:
        if 1 <= track <= 35:
            return _d64_sector_offset(track, sector)
        elif 36 <= track <= 70:
            t2 = track - 35
            return 174848 + _d64_sector_offset(t2, sector)
        else:
            raise IndexError(f"D71: invalid track {track}")


class D81Image:
    """Parser for Commodore 1581 D81 disk images (80-track, 40 sectors/track)."""

    VALID_SIZES = {819200, 822400}   # without / with 3200 error bytes

    def __init__(self, data: bytes, path: str):
        self._data = data
        self._path = path
        if len(data) not in self.VALID_SIZES:
            print(f"[MULTILOAD] Warning: {os.path.basename(path)}: "
                  f"unexpected size {len(data)} (expected {sorted(self.VALID_SIZES)})")

    def _sector_offset(self, track: int, sector: int) -> int:
        return ((track - 1) * 40 + sector) * 256

    def _read_sector(self, track: int, sector: int) -> bytes:
        off = self._sector_offset(track, sector)
        if off + 256 > len(self._data):
            raise IndexError(f"Sector T{track}/S{sector} out of range")
        return self._data[off:off + 256]

    def _follow_chain(self, track: int, sector: int) -> bytes:
        result = bytearray()
        seen = set()
        for _ in range(3200):           # max D81 sectors
            key = (track, sector)
            if key in seen:
                raise ValueError(f"Sector chain loop at T{track}/S{sector}")
            seen.add(key)
            sec = self._read_sector(track, sector)
            next_track  = sec[0]
            next_sector = sec[1]
            if next_track == 0:
                used = next_sector
                if used >= 2:
                    result.extend(sec[2:used])
                break
            else:
                result.extend(sec[2:])
                track, sector = next_track, next_sector
        return bytes(result)

    def list_files(self) -> list:
        """Return list of {'name': str, 'data': bytes} for all closed PRG entries."""
        files = []
        seen_names: dict = {}

        # Directory starts at T40/S3
        dir_track, dir_sector = 40, 3
        dir_seen = set()
        while dir_track != 0:
            key = (dir_track, dir_sector)
            if key in dir_seen:
                break
            dir_seen.add(key)
            try:
                sec = self._read_sector(dir_track, dir_sector)
            except IndexError:
                break
            dir_track  = sec[0]
            dir_sector = sec[1]

            for i in range(8):
                entry = sec[i * 32: i * 32 + 32]
                ftype = entry[2]
                if ftype == 0x00:
                    continue
                if not (ftype & 0x80):
                    continue
                if (ftype & 0x07) != 0x02:
                    continue

                raw_name = entry[5:21]
                name = petscii_to_fat(raw_name, 0xA0) or "UNNAMED"

                if name in seen_names:
                    seen_names[name] += 1
                    name = f"{name}_{seen_names[name]}"
                else:
                    seen_names[name] = 1

                ft, fs = entry[3], entry[4]
                try:
                    data = self._follow_chain(ft, fs)
                except (ValueError, IndexError) as e:
                    print(f"[MULTILOAD] Warning: '{name}' — {e}, skipping.")
                    continue

                if len(data) < 2:
                    print(f"[MULTILOAD] Warning: '{name}' has <2 bytes of data, skipping.")
                    continue

                files.append({"name": name, "data": data})

        return files

    def image_name(self) -> str:
        try:
            # D81 BAM sector 1 (T40/S1); disk name at bytes $04–$13
            bam = self._read_sector(40, 1)
            label = petscii_to_fat(bam[0x04:0x14], 0xA0)
            return label
        except (IndexError, Exception):
            return ""


class T64Image:
    """Parser for C64S tape container (T64) files."""

    def __init__(self, data: bytes, path: str):
        self._data = data
        self._path = path
        # Validate signature
        if len(data) < 64 or data[0:3].upper() != b'C64':
            raise ValueError(f"{os.path.basename(path)}: not a valid T64 file")
        self._max_entries = struct.unpack_from("<H", data, 0x22)[0]
        self._used_entries = struct.unpack_from("<H", data, 0x24)[0]

    def list_files(self) -> list:
        files = []
        seen_names: dict = {}
        data = self._data
        entries = self._max_entries

        for i in range(entries):
            base = 0x40 + i * 32
            if base + 32 > len(data):
                break
            entry = data[base:base + 32]

            c64s_type = entry[0]
            if c64s_type != 1:          # only type 1 = normal tape file
                continue

            load_start = struct.unpack_from("<H", entry, 2)[0]
            load_end   = struct.unpack_from("<H", entry, 4)[0]
            offset     = struct.unpack_from("<I", entry, 8)[0]

            # CONV64 bug: end_address hardcoded to $C3C6 by early converter
            if load_end == 0xC3C6:
                if i + 1 < entries:
                    next_base = 0x40 + (i + 1) * 32
                    if next_base + 32 <= len(data):
                        next_off = struct.unpack_from("<I", data, next_base + 8)[0]
                        real_size = next_off - offset
                    else:
                        real_size = len(data) - offset
                else:
                    real_size = len(data) - offset
                load_end = load_start + real_size

            file_size = load_end - load_start
            if file_size <= 0:
                continue
            if offset + file_size > len(data):
                file_size = len(data) - offset
                if file_size <= 0:
                    continue

            raw_name = entry[0x10:0x20]
            name = petscii_to_fat(raw_name, 0x20) or "UNNAMED"

            if name in seen_names:
                seen_names[name] += 1
                name = f"{name}_{seen_names[name]}"
            else:
                seen_names[name] = 1

            # Prepend 2-byte load address (T64 does not store it in data)
            raw_bytes = struct.pack("<H", load_start) + data[offset:offset + file_size]
            files.append({"name": name, "data": raw_bytes})

        return files

    def image_name(self) -> str:
        try:
            label = petscii_to_fat(self._data[0x28:0x40], 0x20)
            return label
        except Exception:
            return ""


def open_disk_image(path: str):
    """Open and return the appropriate disk image parser for the given file."""
    ext = os.path.splitext(path)[1].upper()
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        print(f"Error: cannot read '{path}': {e}")
        sys.exit(1)

    if ext == ".D64":
        return D64Image(data, path)
    elif ext == ".D71":
        return D71Image(data, path)
    elif ext == ".D81":
        return D81Image(data, path)
    elif ext == ".T64":
        try:
            return T64Image(data, path)
        except ValueError as e:
            print(f"Error: {e}")
            sys.exit(1)
    else:
        print(f"Error: unsupported disk image format '{ext}'.")
        print("Supported formats: D64, D71, D81, T64")
        sys.exit(1)


# ---------------------------------------------------------------------------
# Section C: Multi-disk merge and helpers
# ---------------------------------------------------------------------------

def resolve_autoswap(lst_path: str) -> list:
    """Parse an autoswap.lst file and return absolute paths to disk images."""
    base = os.path.dirname(os.path.abspath(lst_path))
    disks = []
    try:
        with open(lst_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                name = line.strip()
                if not name:
                    continue
                full = os.path.join(base, name)
                if not os.path.isfile(full):
                    print(f"[MULTILOAD] Warning: disk '{name}' not found next to "
                          f"autoswap.lst, skipping.")
                else:
                    disks.append(full)
    except OSError as e:
        print(f"Error: cannot read autoswap.lst '{lst_path}': {e}")
        sys.exit(1)

    if not disks:
        print(f"Error: autoswap.lst contains no valid disk images.")
        sys.exit(1)
    return disks


def merge_disks(disk_paths: list) -> tuple:
    """Extract and merge PRG files from all disk images.

    Returns:
        (all_files, disk_labels, warnings)
        all_files:   list of {'name': str, 'data': bytes}
        disk_labels: list of disk image name strings (one per path)
        warnings:    list of warning strings to print
    """
    all_files = []
    disk_labels = []
    warnings = []
    seen_names: dict = {}       # name → disk index (1-based)

    for i, path in enumerate(disk_paths):
        disk_num = i + 1
        image = open_disk_image(path)
        label = image.image_name()
        disk_labels.append(label)

        try:
            files = image.list_files()
        except Exception as e:
            warnings.append(f"Disk {disk_num} ({os.path.basename(path)}): "
                            f"parse error — {e}")
            files = []

        if not files:
            warnings.append(
                f"Disk {disk_num} ({os.path.basename(path)}): no PRG files found "
                f"— likely uses raw sector access (incompatible with EasySD MultiLoad)."
            )
            continue

        for f in files:
            name = f["name"]
            if name in seen_names:
                warnings.append(
                    f"Disk {disk_num}: '{name}' also on disk {seen_names[name]}, "
                    f"disk {seen_names[name]} version used."
                )
            else:
                seen_names[name] = disk_num
                all_files.append(f)

    return all_files, disk_labels, warnings


def derive_game_name(disk_paths: list, disk_labels: list) -> str:
    """Derive a FAT-safe uppercase game folder name.

    Priority:
    1. Stem of the first disk image filename (most reliable — files are typically
       named after the game: BARBARIAN.D64 → BARBARIAN).
    2. Internal disk label of the first image.
    3. Parent folder of the first disk image (last resort — parent may be a
       generic folder such as "NEW" or "GAMES").
    """
    # 1. Filename stem
    stem = os.path.splitext(os.path.basename(disk_paths[0]))[0]
    name = fat_safe_name(stem, max_len=16)
    if name and name != "UNNAMED":
        return name

    # 2. Disk label
    if disk_labels and disk_labels[0]:
        name = fat_safe_name(disk_labels[0], max_len=16)
        if name and name != "UNNAMED":
            return name

    # 3. Parent folder name (last resort)
    parent = os.path.basename(os.path.dirname(os.path.abspath(disk_paths[0])))
    return fat_safe_name(parent.replace(" ", "_"), max_len=16) or "UNNAMED"


# ---------------------------------------------------------------------------
# Section D: --list-only display
# ---------------------------------------------------------------------------

def cmd_list_only(disk_paths: list) -> None:
    """Show disk directory contents and exit without creating any files."""
    all_files, disk_labels, warnings = merge_disks(disk_paths)

    for i, (path, label) in enumerate(zip(disk_paths, disk_labels)):
        disk_num = i + 1
        print(f"[MULTILOAD] Disk {disk_num}: {os.path.basename(path)}"
              + (f" ({label})" if label else ""))

    for w in warnings:
        print(f"[MULTILOAD] WARNING: {w}")

    game_name = derive_game_name(disk_paths, disk_labels)
    print(f"[MULTILOAD] Game folder: {game_name}")
    print(f"[MULTILOAD] Files ({len(all_files)}):")

    if not all_files:
        print("  (no PRG files found)")
        return

    for i, f in enumerate(all_files):
        size_b  = len(f["data"])
        size_kb = size_b / 1024
        print(f"  [{i+1:3d}] {f['name']:<20s}  {size_b:6d} B  ({size_kb:5.1f} KB)")


# ---------------------------------------------------------------------------
# Section E: Folder extractor
# ---------------------------------------------------------------------------

def extract_to_folder(all_files: list, game_name: str, output_dir: str) -> None:
    """Write extracted PRGs to <output_dir>/<game_name>/<NAME>.PRG."""
    if not all_files:
        print("[MULTILOAD] Error: no PRG files found across all disk images.")
        sys.exit(1)

    target_dir = os.path.join(output_dir, game_name)
    os.makedirs(target_dir, exist_ok=True)

    for f in all_files:
        out_path = os.path.join(target_dir, f["name"] + ".PRG")
        with open(out_path, "wb") as fh:
            fh.write(f["data"])

    total_kb = sum(len(f["data"]) for f in all_files) / 1024
    print(f"[MULTILOAD] Game folder : {game_name}")
    print(f"[MULTILOAD] PRG files   : {len(all_files)}  ({total_kb:.1f} KB total)")
    print(f"[MULTILOAD] Output dir  : {target_dir}")
    print(f"[MULTILOAD] OK")
    print()
    print(f"  Copy contents to the SD card:")
    print(f"    MULTILOAD/{game_name}/")
    print(f"  Then select any PRG inside MULTILOAD/{game_name}/ from the EasySD menu.")
    print(f"  The cartridge synthesises the MLBoot prologue automatically.")


# ---------------------------------------------------------------------------
# Section F: Main dispatcher
# ---------------------------------------------------------------------------

def main_from_disk(args) -> None:
    """Handle --from-disk or --from-autoswap mode."""
    # Resolve disk image list
    if args.from_autoswap:
        if not os.path.isfile(args.from_autoswap):
            print(f"Error: autoswap.lst not found: {args.from_autoswap}")
            sys.exit(1)
        disk_paths = resolve_autoswap(args.from_autoswap)
    else:
        disk_paths = args.from_disk
        for p in disk_paths:
            if not os.path.isfile(p):
                print(f"Error: disk image not found: {p}")
                sys.exit(1)

    # --list-only: show directory and exit
    if args.list_only:
        cmd_list_only(disk_paths)
        return

    # Merge disks
    all_files, disk_labels, warnings = merge_disks(disk_paths)
    for w in warnings:
        print(f"[MULTILOAD] WARNING: {w}")

    # Derive game name and output path
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root  = os.path.dirname(script_dir)
    game_name  = derive_game_name(disk_paths, disk_labels)
    output_dir = os.path.join(repo_root, OUTPUT_DIR)

    extract_to_folder(all_files, game_name, output_dir)


# ---------------------------------------------------------------------------
# Section G: Argument parsing and entry point
# ---------------------------------------------------------------------------

def parse_args():
    ap = argparse.ArgumentParser(
        prog="create_multiload.py",
        description="Disk-image extractor for EasySD MultiLoad.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Examples:
  python Tools/create_multiload.py --from-disk TURRICAN.D64
  python Tools/create_multiload.py --from-disk 1.d64 2.d64
  python Tools/create_multiload.py --from-autoswap autoswap.lst
  python Tools/create_multiload.py --from-disk TURRICAN.D64 --list-only

Supported formats: D64, D71, D81, T64
""")

    ap.add_argument(
        "--from-disk", nargs="+", metavar="DISK_IMAGE",
        help="One or more disk images (D64/D71/D81/T64) to extract")
    ap.add_argument(
        "--from-autoswap", metavar="AUTOSWAP_LST",
        help="Read disk image list from autoswap.lst (SD2IEC format)")
    ap.add_argument(
        "--list-only", action="store_true",
        help="List disk contents and exit without writing PRGs")

    return ap.parse_args()


def main():
    args = parse_args()

    if not (args.from_disk or args.from_autoswap):
        print("Usage:")
        print("  python Tools/create_multiload.py --from-disk DISK_IMAGE [...]")
        print("  python Tools/create_multiload.py --from-autoswap autoswap.lst")
        print("  python Tools/create_multiload.py --help")
        sys.exit(1)

    if args.from_disk and args.from_autoswap:
        print("Error: --from-disk and --from-autoswap are mutually exclusive.")
        sys.exit(1)

    main_from_disk(args)


if __name__ == "__main__":
    main()
