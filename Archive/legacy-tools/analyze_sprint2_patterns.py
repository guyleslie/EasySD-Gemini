#!/usr/bin/env python3
"""
Sprint 2 Pattern Analysis Tool
Analyzes IRQHack64 assembly code for macro conversion patterns.
"""

import os
import re
from pathlib import Path
from collections import defaultdict

class PatternAnalyzer:
    def __init__(self, base_path):
        self.base_path = Path(base_path)
        self.results = defaultdict(list)

    def find_assembly_files(self):
        """Find all .s assembly files in IRQHack64 directory."""
        return list(self.base_path.glob('**/*.s'))

    def analyze_setaddr_pattern(self, content, filepath):
        """
        Pattern: 16-bit zero page pointer setup
        LDA #<address
        STA zp_pointer
        LDA #>address
        STA zp_pointer+1
        """
        # Match multi-line pattern for SETADDR
        pattern = r'LDA\s+#<(\w+)\s+STA\s+(ZP_\w+)\s+LDA\s+#>(\w+)\s+STA\s+(ZP_\w+)'
        matches = re.findall(pattern, content, re.MULTILINE | re.IGNORECASE)

        for match in matches:
            if match[0] == match[2]:  # Same address for both < and >
                self.results['SETADDR'].append({
                    'file': str(filepath.relative_to(self.base_path)),
                    'address': match[0],
                    'zp_low': match[1],
                    'zp_high': match[3]
                })

    def analyze_display_control(self, content, filepath):
        """
        Pattern: Display enable/disable via IRQ_DisableDisplay / IRQ_EnableDisplay
        """
        disable_count = len(re.findall(r'JSR\s+IRQ_DisableDisplay', content, re.IGNORECASE))
        enable_count = len(re.findall(r'JSR\s+IRQ_EnableDisplay', content, re.IGNORECASE))

        if disable_count > 0 or enable_count > 0:
            self.results['DISPLAY_CONTROL'].append({
                'file': str(filepath.relative_to(self.base_path)),
                'disable_count': disable_count,
                'enable_count': enable_count
            })

    def analyze_openfile_pattern(self, content, filepath):
        """
        Pattern: File opening sequence
        LDX #<buffer
        LDY #>buffer
        LDA #length
        JSR IRQ_SetName
        LDX #flags
        JSR IRQ_OpenFile
        """
        pattern = r'JSR\s+IRQ_SetName.*?JSR\s+IRQ_OpenFile'
        matches = re.findall(pattern, content, re.DOTALL | re.IGNORECASE)

        for _ in matches:
            self.results['OPENFILE'].append({
                'file': str(filepath.relative_to(self.base_path))
            })

    def analyze_getinfo_pattern(self, content, filepath):
        """
        Pattern: Get file info sequence
        LDA #<buffer
        STA ZP_IRQ_API_DATA_LO
        LDA #>buffer
        STA ZP_IRQ_API_DATA_HI
        JSR IRQ_GetInfoForFile
        """
        matches = re.findall(r'JSR\s+IRQ_GetInfoForFile', content, re.IGNORECASE)

        for _ in matches:
            self.results['GETINFO'].append({
                'file': str(filepath.relative_to(self.base_path))
            })

    def analyze_closefile_pattern(self, content, filepath):
        """
        Pattern: File close
        JSR IRQ_CloseFile
        """
        matches = re.findall(r'JSR\s+IRQ_CloseFile', content, re.IGNORECASE)

        for _ in matches:
            self.results['CLOSEFILE'].append({
                'file': str(filepath.relative_to(self.base_path))
            })

    def analyze_countloop_pattern(self, content, filepath):
        """
        Pattern: Register-based countdown loops
        LDX #count
        -
        DEX
        BNE -
        """
        pattern = r'LDX\s+#\$?\w+.*?DEX\s+BNE'
        matches = re.findall(pattern, content, re.DOTALL | re.IGNORECASE)

        for _ in matches:
            self.results['COUNTLOOP'].append({
                'file': str(filepath.relative_to(self.base_path))
            })

    def analyze_file(self, filepath):
        """Analyze a single assembly file for all patterns."""
        try:
            with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()

            # Remove line numbers if present (from our Read tool output format)
            content = re.sub(r'^\s*\d+→', '', content, flags=re.MULTILINE)

            self.analyze_setaddr_pattern(content, filepath)
            self.analyze_display_control(content, filepath)
            self.analyze_openfile_pattern(content, filepath)
            self.analyze_getinfo_pattern(content, filepath)
            self.analyze_closefile_pattern(content, filepath)
            self.analyze_countloop_pattern(content, filepath)

        except Exception as e:
            print(f"Error analyzing {filepath}: {e}")

    def run_analysis(self):
        """Run analysis on all assembly files."""
        files = self.find_assembly_files()
        print(f"Found {len(files)} assembly files to analyze...")

        for filepath in files:
            self.analyze_file(filepath)

        return self.results

    def print_report(self):
        """Print formatted analysis report."""
        print("\n" + "="*80)
        print("SPRINT 2 PATTERN ANALYSIS REPORT")
        print("="*80 + "\n")

        # SETADDR patterns
        setaddr_count = len(self.results['SETADDR'])
        print(f"1. SETADDR Pattern (16-bit ZP pointer setup)")
        print(f"   Total occurrences: {setaddr_count}")
        if setaddr_count > 0:
            files = set(item['file'] for item in self.results['SETADDR'])
            print(f"   Files affected: {len(files)}")
            for f in sorted(files):
                count = sum(1 for item in self.results['SETADDR'] if item['file'] == f)
                print(f"     - {f}: {count}×")
        print()

        # Display control
        display_items = self.results['DISPLAY_CONTROL']
        total_disable = sum(item['disable_count'] for item in display_items)
        total_enable = sum(item['enable_count'] for item in display_items)
        print(f"2. DISPLAY Control (IRQ_DisableDisplay / IRQ_EnableDisplay)")
        print(f"   IRQ_DisableDisplay calls: {total_disable}")
        print(f"   IRQ_EnableDisplay calls: {total_enable}")
        print(f"   Files affected: {len(display_items)}")
        print()

        # OPENFILE pattern
        openfile_count = len(self.results['OPENFILE'])
        print(f"3. OPENFILE Pattern (IRQ_SetName + IRQ_OpenFile sequence)")
        print(f"   Total occurrences: {openfile_count}")
        if openfile_count > 0:
            files = defaultdict(int)
            for item in self.results['OPENFILE']:
                files[item['file']] += 1
            for f in sorted(files.keys()):
                print(f"     - {f}: {files[f]}×")
        print()

        # GETINFO pattern
        getinfo_count = len(self.results['GETINFO'])
        print(f"4. GETINFO Pattern (IRQ_GetInfoForFile)")
        print(f"   Total occurrences: {getinfo_count}")
        if getinfo_count > 0:
            files = defaultdict(int)
            for item in self.results['GETINFO']:
                files[item['file']] += 1
            for f in sorted(files.keys()):
                print(f"     - {f}: {files[f]}×")
        print()

        # CLOSEFILE pattern
        closefile_count = len(self.results['CLOSEFILE'])
        print(f"5. CLOSEFILE Pattern (IRQ_CloseFile)")
        print(f"   Total occurrences: {closefile_count}")
        print()

        # COUNTLOOP pattern
        countloop_count = len(self.results['COUNTLOOP'])
        print(f"6. COUNTLOOP Pattern (LDX #n / DEX / BNE)")
        print(f"   Total occurrences: {countloop_count}")
        print()

        # Summary
        print("="*80)
        print("SUMMARY")
        print("="*80)
        total_patterns = (setaddr_count + total_disable + total_enable +
                         openfile_count + getinfo_count + closefile_count +
                         countloop_count)
        print(f"Total patterns identified: {total_patterns}")
        print(f"  - SETADDR: {setaddr_count}")
        print(f"  - DISPLAY_CONTROL: {total_disable + total_enable}")
        print(f"  - OPENFILE: {openfile_count}")
        print(f"  - GETINFO: {getinfo_count}")
        print(f"  - CLOSEFILE: {closefile_count}")
        print(f"  - COUNTLOOP: {countloop_count}")
        print()

        # Estimated code reduction
        estimated_reduction = (
            setaddr_count * 2 +      # SETADDR saves 2 lines (4→2)
            openfile_count * 3 +     # OPENFILE saves ~3 lines
            getinfo_count * 2 +      # GETINFO saves ~2 lines
            countloop_count * 1      # COUNTLOOP saves ~1 line
        )
        print(f"Estimated code reduction: ~{estimated_reduction} lines")
        print("="*80 + "\n")

if __name__ == '__main__':
    base_path = Path(__file__).parent.parent / 'IRQHack64'

    if not base_path.exists():
        print(f"Error: {base_path} not found!")
        exit(1)

    analyzer = PatternAnalyzer(base_path)
    analyzer.run_analysis()
    analyzer.print_report()
