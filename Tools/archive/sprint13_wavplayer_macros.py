"""Sprint 13: Apply SETBANK macro and remaining RESTOREREGS to WavPlayer.s

Replaces:
  - LDA #PP_CONFIG_DEFAULT / STA PROCESSOR_PORT  ->  #SETBANK PP_CONFIG_DEFAULT
  - LDA #PP_CONFIG_RAM_ON_ROM / STA PROCESSOR_PORT  ->  #SETBANK PP_CONFIG_RAM_ON_ROM
  - PLA/TAY/PLA/TAX/PLA sequences (with optional blank/tab-only lines between)
    ->  #RESTOREREGS

Run: python Tools/sprint13_wavplayer_macros.py "IRQHack64/Plugins/WavPlayer/WavPlayer.s"
"""
import re
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

original = content

# --- SETBANK replacements ---
# Match LDA #PP_CONFIG_DEFAULT (with optional trailing comment/whitespace)
# then optional blank/tab lines, then STA PROCESSOR_PORT (with optional trailing)
# The LDA and STA may be separated by blank lines (only in PlayDigimaxSimple/PlayBothBuffered)

def setbank_pattern(config):
    return (
        r'(\t)LDA #' + re.escape(config) + r'[^\n]*\n'
        r'(?:[\t ]*\n)*'          # optional blank lines (may contain tabs)
        r'\t?STA PROCESSOR_PORT[^\n]*'
    )

def setbank_replacement(config):
    return r'\1#SETBANK ' + config

content, n1 = re.subn(
    setbank_pattern('PP_CONFIG_DEFAULT'),
    setbank_replacement('PP_CONFIG_DEFAULT'),
    content
)
content, n2 = re.subn(
    setbank_pattern('PP_CONFIG_RAM_ON_ROM'),
    setbank_replacement('PP_CONFIG_RAM_ON_ROM'),
    content
)

# --- RESTOREREGS replacement ---
# Match PLA / (opt blank lines) TAY / (opt) PLA / (opt) TAX / (opt) PLA
# where "blank lines" may be empty or contain only whitespace
blank = r'(?:[\t ]*\n)*'
restoreregs_pat = (
    r'\tPLA\n' + blank +
    r'\tTAY\n' + blank +
    r'\tPLA\n' + blank +
    r'\tTAX\n' + blank +
    r'\tPLA'
)
content, n3 = re.subn(restoreregs_pat, '\t#RESTOREREGS', content)

print(f"SETBANK DEFAULT:    {n1} replacement(s)")
print(f"SETBANK RAM_ON_ROM: {n2} replacement(s)")
print(f"RESTOREREGS:        {n3} replacement(s)")

if content == original:
    print("WARNING: No changes made!")
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)

print("Done.")
