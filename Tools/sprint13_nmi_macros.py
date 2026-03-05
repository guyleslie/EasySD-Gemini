"""Sprint 13: Replace READCART_MODULATED triplets in NMI.s

Pattern (400x):
    LDA MODULATION_ADDRESS
    LDA CARTRIDGE_BANK_VALUE
    STA $aXXX

Replacement:
    #READCART_MODULATED $aXXX

Run: python Tools/sprint13_nmi_macros.py "IRQHack64/Plugins/CvidPlayer/NMI.s"
"""
import re
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

pattern = r'\tLDA MODULATION_ADDRESS\t*\n\tLDA CARTRIDGE_BANK_VALUE\n\tSTA (\$a[0-9a-f]+)\t*'
replacement = r'\t#READCART_MODULATED \1'

new_content, count = re.subn(pattern, replacement, content)
print(f"Replaced {count} occurrences")  # expect 400

if count != 400:
    print(f"WARNING: Expected 400, got {count}!")
    sys.exit(1)

with open(path, 'w') as f:
    f.write(new_content)

print("Done.")
