#!/usr/bin/env python3
"""
Sprint 2 Macro Conversion Tool
Converts assembly patterns to Sprint 2 macros.
"""

import os
import re
import sys
from pathlib import Path

class Sprint2Converter:
    def __init__(self, filepath):
        self.filepath = Path(filepath)
        self.content = ""
        self.changes = []
        self.stats = {
            'SETADDR': 0,
            'OPENFILE': 0,
            'GETFILEINFO': 0,
            'EXTRACTFILESIZE': 0,
            'COUNTLOOP': 0
        }

    def load_file(self):
        """Load assembly file content."""
        with open(self.filepath, 'r', encoding='utf-8', errors='ignore') as f:
            self.content = f.read()

    def save_file(self):
        """Save modified assembly file."""
        with open(self.filepath, 'w', encoding='utf-8', newline='\n') as f:
            f.write(self.content)

    def convert_setaddr(self):
        """
        Convert SETADDR pattern:
        LDA #<ADDRESS
        STA ZP_XXX
        LDA #>ADDRESS
        STA ZP_XXX+1

        To:
        #SETADDR ADDRESS, ZP_XXX
        """
        # Pattern: Multi-line SETADDR
        pattern = r'(\s*)LDA\s+#<(\w+)\s*\n\s*STA\s+(ZP_\w+)\s*\n\s*LDA\s+#>\2\s*\n\s*STA\s+\3\s*\+\s*1'

        def replace_setaddr(match):
            indent = match.group(1)
            address = match.group(2)
            zp_pointer = match.group(3)
            self.stats['SETADDR'] += 1
            self.changes.append(f"  SETADDR: {address} -> {zp_pointer}")
            return f'{indent}#SETADDR {address}, {zp_pointer}'

        self.content = re.sub(pattern, replace_setaddr, self.content, flags=re.MULTILINE)

    def convert_openfile(self):
        """
        Convert OPENFILE pattern:
        LDX #<BUFFER
        LDY #>BUFFER
        LDA #LENGTH
        JSR IRQ_SetName
        LDX #FLAGS
        JSR IRQ_OpenFile

        To:
        #OPENFILE BUFFER, #LENGTH, #FLAGS
        """
        # This is complex - need to match across multiple lines with potential variations
        pattern = r'(\s*)LDX\s+#<(\w+)\s*\n\s*LDY\s+#>\2\s*\n\s*LDA\s+(#?\$?\w+)\s*\n\s*JSR\s+IRQ_SetName\s*\n\s*LDX\s+(#?\$?\w+)\s*\n\s*JSR\s+IRQ_OpenFile'

        def replace_openfile(match):
            indent = match.group(1)
            buffer = match.group(2)
            length = match.group(3)
            flags = match.group(4)

            # Ensure immediate addressing
            if not length.startswith('#'):
                length = '#' + length
            if not flags.startswith('#'):
                flags = '#' + flags

            self.stats['OPENFILE'] += 1
            self.changes.append(f"  OPENFILE: {buffer}, {length}, {flags}")
            return f'{indent}#OPENFILE {buffer}, {length}, {flags}'

        self.content = re.sub(pattern, replace_openfile, self.content, flags=re.MULTILINE)

    def convert_getfileinfo(self):
        """
        Convert GETFILEINFO pattern:
        LDA #<BUFFER
        STA ZP_IRQ_API_DATA_LO
        LDA #>BUFFER
        STA ZP_IRQ_API_DATA_HI
        [LDY #$00]
        JSR IRQ_GetInfoForFile

        To:
        #GETFILEINFO BUFFER
        """
        # Pattern with optional LDY #$00
        pattern = r'(\s*)LDA\s+#<(\w+)\s*\n\s*STA\s+ZP_IRQ_API_DATA_LO\s*\n\s*LDA\s+#>\2\s*\n\s*STA\s+ZP_IRQ_API_DATA_HI\s*\n(?:\s*LDY\s+#\$00\s*\n)?\s*JSR\s+IRQ_GetInfoForFile'

        def replace_getfileinfo(match):
            indent = match.group(1)
            buffer = match.group(2)
            self.stats['GETFILEINFO'] += 1
            self.changes.append(f"  GETFILEINFO: {buffer}")
            return f'{indent}#GETFILEINFO {buffer}'

        self.content = re.sub(pattern, replace_getfileinfo, self.content, flags=re.MULTILINE)

    def convert_extractfilesize(self):
        """
        Convert EXTRACTFILESIZE pattern:
        LDA BUFFER + 28
        STA DEST
        LDA BUFFER + 29
        STA DEST + 1
        LDA BUFFER + 30
        STA DEST + 2
        LDA BUFFER + 31
        STA DEST + 3

        To:
        #EXTRACTFILESIZE BUFFER, DEST
        """
        # Pattern: Extract file size from FAT entry
        pattern = r'(\s*)LDA\s+(\w+)\s*\+\s*28\s*\n\s*STA\s+(\w+)\s*\n\s*LDA\s+\2\s*\+\s*29\s*\n\s*STA\s+\3\s*\+\s*1\s*\n\s*LDA\s+\2\s*\+\s*30\s*\n\s*STA\s+\3\s*\+\s*2\s*\n\s*LDA\s+\2\s*\+\s*31\s*\n\s*STA\s+\3\s*\+\s*3'

        def replace_extractfilesize(match):
            indent = match.group(1)
            source = match.group(2)
            dest = match.group(3)
            self.stats['EXTRACTFILESIZE'] += 1
            self.changes.append(f"  EXTRACTFILESIZE: {source} -> {dest}")
            return f'{indent}#EXTRACTFILESIZE {source}, {dest}'

        self.content = re.sub(pattern, replace_extractfilesize, self.content, flags=re.MULTILINE)

    def convert_countloop(self):
        """
        Convert COUNTLOOP pattern:
        LDX #COUNT
        -
            ; loop body
            DEX
            BNE -

        To:
        #COUNTLOOP #COUNT
            ; loop body
        #ENDLOOP

        NOTE: This is complex and may require manual conversion
        due to varied loop body structures.
        """
        # Simple pattern - just the LDX part (DEX/BNE needs manual handling)
        # This is left for manual conversion or a more sophisticated parser
        pass

    def add_includes(self):
        """Add necessary includes if not present."""
        includes_needed = []

        # Check if we made any Tier 2 conversions (API macros)
        if (self.stats['OPENFILE'] > 0 or
            self.stats['GETFILEINFO'] > 0 or
            self.stats['EXTRACTFILESIZE'] > 0):
            if '.include "APIMacros.s"' not in self.content and \
               '.include "../../Loader/APIMacros.s"' not in self.content:
                includes_needed.append('APIMacros.s')

        # SystemMacros.s should already be included via CartLibStream.s or similar
        # but check for SETADDR usage
        if self.stats['SETADDR'] > 0:
            if '.include "SystemMacros.s"' not in self.content and \
               '.include "../../Loader/SystemMacros.s"' not in self.content:
                # SystemMacros is included via CartLibStream.s typically
                pass

        # Add includes after existing includes
        if includes_needed:
            # Find first .include line
            include_match = re.search(r'^\.include\s+"[^"]+"\s*$', self.content, re.MULTILINE)
            if include_match:
                insert_pos = include_match.end()
                for inc in includes_needed:
                    # Determine relative path
                    if 'Plugins' in str(self.filepath):
                        inc_path = f'../../Loader/{inc}'
                    elif 'Loader' in str(self.filepath):
                        inc_path = inc
                    else:
                        inc_path = inc

                    include_line = f'\n.include "{inc_path}"'
                    self.content = self.content[:insert_pos] + include_line + self.content[insert_pos:]
                    insert_pos += len(include_line)

    def convert_all(self):
        """Run all conversions."""
        self.load_file()

        print(f"\nConverting: {self.filepath.name}")

        # Run conversions
        self.convert_setaddr()
        self.convert_openfile()
        self.convert_getfileinfo()
        self.convert_extractfilesize()
        # self.convert_countloop()  # Skip for now - complex

        # Add includes if needed
        # self.add_includes()  # Disabled for now - let's add includes manually

        # Report changes
        total_changes = sum(self.stats.values())
        if total_changes > 0:
            print(f"  Changes made: {total_changes}")
            for change in self.changes:
                print(change)
            return True
        else:
            print("  No changes needed")
            return False

    def get_stats(self):
        """Return conversion statistics."""
        return self.stats

def convert_file(filepath):
    """Convert a single file."""
    converter = Sprint2Converter(filepath)
    changed = converter.convert_all()

    if changed:
        # Create backup
        backup_path = filepath.with_suffix('.s.bak_sprint2')
        import shutil
        shutil.copy2(filepath, backup_path)
        print(f"  Backup created: {backup_path.name}")

        # Save changes
        converter.save_file()
        print(f"  [OK] Converted and saved")

    return converter.get_stats()

def main():
    if len(sys.argv) < 2:
        print("Usage: python convert_sprint2_macros.py <file.s> [file2.s ...]")
        print("   or: python convert_sprint2_macros.py --all")
        sys.exit(1)

    if sys.argv[1] == '--all':
        # Convert all plugin files
        base_path = Path(__file__).parent.parent / 'IRQHack64'
        files_to_convert = [
            base_path / 'Plugins' / 'KoalaDisplayer' / 'KoalaDisplayer.s',
            base_path / 'Plugins' / 'PetsciiDisplayer' / 'PetsciiDisplayer.s',
            base_path / 'Plugins' / 'PrgPlugin' / 'PrgPlugin.s',
            base_path / 'Plugins' / 'PrgPlugin' / 'PrgPluginStub.s',
            base_path / 'Plugins' / 'WavPlayer' / 'WavPlayer.s',
            base_path / 'Plugins' / 'MusPlayer' / 'MusPlayer.s',
            base_path / 'Menus' / 'EasySD' / 'IrqLoaderMenuNew.s',
        ]
    else:
        files_to_convert = [Path(f) for f in sys.argv[1:]]

    total_stats = {
        'SETADDR': 0,
        'OPENFILE': 0,
        'GETFILEINFO': 0,
        'EXTRACTFILESIZE': 0,
        'COUNTLOOP': 0
    }

    print("="*80)
    print("SPRINT 2 MACRO CONVERSION")
    print("="*80)

    for filepath in files_to_convert:
        if not filepath.exists():
            print(f"\nWarning: {filepath} not found, skipping")
            continue

        stats = convert_file(filepath)

        # Accumulate stats
        for key in total_stats:
            total_stats[key] += stats[key]

    print("\n" + "="*80)
    print("CONVERSION SUMMARY")
    print("="*80)
    print(f"Total conversions:")
    for pattern, count in total_stats.items():
        if count > 0:
            print(f"  {pattern}: {count}")
    print()

    total = sum(total_stats.values())
    print(f"Grand total: {total} patterns converted")
    print("\nNext steps:")
    print("  1. Review .bak_sprint2 files for accuracy")
    print("  2. Add .include statements for APIMacros.s where needed")
    print("  3. Run build system to verify")
    print("  4. Test on hardware/emulator")
    print("="*80)

if __name__ == '__main__':
    main()
