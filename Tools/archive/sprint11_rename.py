#!/usr/bin/env python3
"""Sprint 11 ZP Rename Script
Renames 23 ZP variables in IRQHack64/ assembly files.
Pure symbol rename - no address or logic changes.
"""

import os
import sys

# Working directory must be project root
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASM_ROOT = os.path.join(PROJECT_ROOT, "IRQHack64")

# 23 renames: (old_name, new_name)
RENAMES = [
    # Protocol Layer ($64-$77)
    ("ZP_IRQ_WaitHandle",       "ZP_IRQ_STATE_WAITHANDLE"),
    ("ZP_IRQ_SEEK_LOW",         "ZP_IRQ_API_SEEK_LO"),
    ("ZP_IRQ_SEEK_HIGH",        "ZP_IRQ_API_SEEK_HI"),
    ("ZP_IRQ_DATA_LENGTH",      "ZP_IRQ_API_DATA_LENGTH"),
    ("ZP_IRQ_DATA_LOW",         "ZP_IRQ_API_DATA_LO"),
    ("ZP_IRQ_DATA_HIGH",        "ZP_IRQ_API_DATA_HI"),
    ("ZP_IRQ_CALLBACK_LO",      "ZP_IRQ_API_CALLBACK_LO"),
    ("ZP_IRQ_CALLBACK_HI",      "ZP_IRQ_API_CALLBACK_HI"),
    ("ZP_IRQ_SEEK_UPPER_LO",    "ZP_IRQ_API_SEEK_UPPER_LO"),
    ("ZP_IRQ_SEEK_UPPER_HI",    "ZP_IRQ_API_SEEK_UPPER_HI"),
    ("ZP_IRQ_TEMP",             "ZP_IRQ_TMP_SCRATCH"),
    # LoadFileBySize API ($80-$87)
    ("ZP_LF_SIZE0",             "ZP_LOADFILE_API_SIZE0"),
    ("ZP_LF_SIZE1",             "ZP_LOADFILE_API_SIZE1"),
    ("ZP_LF_SIZE2",             "ZP_LOADFILE_API_SIZE2"),
    ("ZP_LF_SIZE3",             "ZP_LOADFILE_API_SIZE3"),
    ("ZP_LF_SKIP_LO",           "ZP_LOADFILE_API_SKIP_LO"),
    ("ZP_LF_SKIP_HI",           "ZP_LOADFILE_API_SKIP_HI"),
    ("ZP_LF_PAYLOAD_LO",        "ZP_LOADFILE_API_PAYLOAD_LO"),
    ("ZP_LF_PAYLOAD_HI",        "ZP_LOADFILE_API_PAYLOAD_HI"),
    # StreamLargeFile API ($90-$95)
    ("ZP_STREAM_TARGET_ADDR_LO","ZP_STREAM_API_TARGET_LO"),
    ("ZP_STREAM_TARGET_ADDR_HI","ZP_STREAM_API_TARGET_HI"),
    ("ZP_STREAM_BYTES_REMAIN_0","ZP_STREAM_API_REMAIN0"),
    ("ZP_STREAM_BYTES_REMAIN_1","ZP_STREAM_API_REMAIN1"),
    ("ZP_STREAM_BYTES_REMAIN_2","ZP_STREAM_API_REMAIN2"),
    ("ZP_STREAM_BYTES_REMAIN_3","ZP_STREAM_API_REMAIN3"),
]

def process_file(filepath):
    with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
        original = f.read()

    content = original
    for old, new in RENAMES:
        content = content.replace(old, new)

    if content != original:
        with open(filepath, 'w', encoding='utf-8', errors='replace') as f:
            f.write(content)
        # Count changes
        changes = sum(original.count(old) for old, _ in RENAMES)
        print(f"  MODIFIED ({changes} replacements): {os.path.relpath(filepath, PROJECT_ROOT)}")
        return True
    return False

def main():
    total_files = 0
    modified_files = 0

    for root, dirs, files in os.walk(ASM_ROOT):
        # Skip build output directories
        dirs[:] = [d for d in dirs if d != 'build']
        for fname in files:
            if fname.endswith(('.s', '.inc')):
                total_files += 1
                fpath = os.path.join(root, fname)
                if process_file(fpath):
                    modified_files += 1

    print(f"\nDone: {modified_files}/{total_files} files modified")

if __name__ == '__main__':
    main()
