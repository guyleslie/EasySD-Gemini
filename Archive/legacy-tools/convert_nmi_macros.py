#!/usr/bin/env python3
"""
Convert NMI.s READCART_MODULATED patterns to macro invocations
Sprint 1: Macro Refactoring - BurstLoader NMI Handler
"""

import re
import sys
from pathlib import Path

def convert_nmi_file(file_path: Path) -> int:
    """Convert READCART_MODULATED patterns in NMI.s"""

    lines = file_path.read_text(encoding='utf-8').split('\n')
    new_lines = []
    count = 0
    i = 0

    while i < len(lines):
        line = lines[i]

        # Check for the 3-line pattern:
        # \tLDA MODULATION_ADDRESS
        # \tLDA CARTRIDGE_BANK_VALUE
        # \tSTA $a000\t
        if (i + 2 < len(lines) and
            'LDA' in line and 'MODULATION_ADDRESS' in line and
            'LDA' in lines[i+1] and 'CARTRIDGE_BANK_VALUE' in lines[i+1] and
            'STA' in lines[i+2]):

            # Extract the address from line i+2
            match = re.search(r'STA\s+(\$[a-fA-F0-9]+)', lines[i+2])
            if match:
                address = match.group(1)
                # Get indentation from original line
                indent = line[:len(line) - len(line.lstrip())]
                # Preserve trailing tab if exists
                trailing = '\t' if lines[i+2].rstrip() != lines[i+2].rstrip('\t') else ''
                new_lines.append(f'{indent}#READCART_MODULATED {address}{trailing}')
                count += 1
                i += 3  # Skip the 3 lines we just processed
                continue

        new_lines.append(line)
        i += 1

    # Write back
    file_path.write_text('\n'.join(new_lines), encoding='utf-8')
    return count

def add_include_systemmacrosto_nmi(nmi_file: Path) -> None:
    """Add .include SystemMacros.s to beginning of NMI.s"""
    content = nmi_file.read_text(encoding='utf-8')

    # Check if already included
    if 'SystemMacros.s' in content:
        print("SystemMacros.s already included")
        return

    # Add at the very beginning (before NMI_000 label)
    lines = content.split('\n')

    # Find first non-empty, non-comment line or first label
    insert_pos = 0
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped and not stripped.startswith(';'):
            insert_pos = i
            break

    # Insert include directive
    lines.insert(insert_pos, '.include "../../Loader/SystemMacros.s"')
    lines.insert(insert_pos + 1, '')  # Add blank line

    nmi_file.write_text('\n'.join(lines), encoding='utf-8')
    print("Added .include \"../../Loader/SystemMacros.s\"")

if __name__ == '__main__':
    repo_root = Path(__file__).parent.parent
    nmi_file = repo_root / 'IRQHack64' / 'Plugins' / 'BurstLoader' / 'NMI.s'

    if not nmi_file.exists():
        print(f"ERROR: {nmi_file} not found!", file=sys.stderr)
        sys.exit(1)

    print(f"Processing: {nmi_file}")

    # Step 1: Add include
    add_include_systemmacrosto_nmi(nmi_file)

    # Step 2: Convert patterns
    count = convert_nmi_file(nmi_file)

    print(f"[OK] Converted {count} READCART_MODULATED patterns")
    print(f"[OK] File: {nmi_file}")
