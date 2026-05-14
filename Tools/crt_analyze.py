"""Analyze CRT coldstart code to debug loading failures."""
import struct, sys, os

def disasm_bytes(rom, rom_offset, rom_base, count=64):
    """Very simple 6502 disassembly of 'count' bytes starting at rom_offset."""
    lines = []
    i = 0
    ops1 = {0x18:'CLC',0x38:'SEC',0x58:'CLI',0x78:'SEI',0xD8:'CLD',0xF8:'SED',
            0xEA:'NOP',0x60:'RTS',0x40:'RTI',0xAA:'TAX',0xA8:'TAY',0x8A:'TXA',
            0x98:'TYA',0x9A:'TXS',0xBA:'TSX',0xCA:'DEX',0x88:'DEY',0xE8:'INX',
            0xC8:'INY',0x48:'PHA',0x68:'PLA',0x08:'PHP',0x28:'PLP'}
    ops2 = {0xA9:'LDA',0xA2:'LDX',0xA0:'LDY',0xC9:'CMP',0xE0:'CPX',0xC0:'CPY',
            0x09:'ORA',0x29:'AND',0x49:'EOR',0x69:'ADC',0xE9:'SBC',0x24:'BIT',
            0x85:'STA',0x86:'STX',0x84:'STY'}
    ops2rel = {0x10:'BPL',0x30:'BMI',0x50:'BVC',0x70:'BVS',0x90:'BCC',0xB0:'BCS',
               0xD0:'BNE',0xF0:'BEQ'}
    ops3 = {0xAD:'LDA',0xAE:'LDX',0xAC:'LDY',0x8D:'STA',0x8E:'STX',0x8C:'STY',
            0xCD:'CMP',0xEC:'CPX',0xCC:'CPY',0x4C:'JMP',0x20:'JSR',
            0x0D:'ORA',0x2D:'AND',0x4D:'EOR',0x6D:'ADC',0xED:'SBC',
            0x2C:'BIT',0xEE:'INC',0xCE:'DEC',0x0E:'ASL',0x4E:'LSR',
            0x2E:'ROL',0x6E:'ROR'}
    while i < count and rom_offset + i < len(rom):
        addr = rom_base + rom_offset + i
        b = rom[rom_offset + i]
        if b in ops1:
            lines.append(f'  ${addr:04X}: {ops1[b]}')
            i += 1
        elif b in ops2 and rom_offset + i + 1 < len(rom):
            lines.append(f'  ${addr:04X}: {ops2[b]} #${rom[rom_offset+i+1]:02X}')
            i += 2
        elif b in ops2rel and rom_offset + i + 1 < len(rom):
            off = rom[rom_offset + i + 1]
            target = addr + 2 + (off if off < 128 else off - 256)
            lines.append(f'  ${addr:04X}: {ops2rel[b]} ${target:04X}')
            i += 2
        elif b in ops3 and rom_offset + i + 2 < len(rom):
            lo, hi = rom[rom_offset+i+1], rom[rom_offset+i+2]
            lines.append(f'  ${addr:04X}: {ops3[b]} ${hi:02X}{lo:02X}')
            i += 3
        elif b == 0x6C and rom_offset + i + 2 < len(rom):  # JMP (ind)
            lo, hi = rom[rom_offset+i+1], rom[rom_offset+i+2]
            lines.append(f'  ${addr:04X}: JMP (${hi:02X}{lo:02X})')
            i += 3
        else:
            lines.append(f'  ${addr:04X}: ${b:02X}  ???')
            i += 1
            break
    return '\n'.join(lines)

def analyze(path, name):
    with open(path, 'rb') as f:
        data = f.read()
    if len(data) < 96:
        print(f'{name}: file too small')
        return
    exrom = data[24]; game = data[25]
    hw_type = struct.unpack('>H', data[22:24])[0]
    load_hi = data[76]; load_lo = data[77]
    rsz = struct.unpack('>H', data[78:80])[0]
    chip_type_real = struct.unpack('>H', data[72:74])[0]
    rom = data[80:]
    load_addr = load_hi * 256 + load_lo
    # $8000-based carts: vectors at $8000-$8003
    cold_lo, cold_hi = rom[0], rom[1]   # coldstart vector (little-endian)
    nmi_lo, nmi_hi   = rom[2], rom[3]   # NMI vector (little-endian)
    cold_addr = cold_lo + cold_hi * 256
    nmi_addr  = nmi_lo  + nmi_hi  * 256
    cold_off  = cold_addr - load_addr
    print(f'\n=== {name} ===')
    print(f'  EXROM={exrom} GAME={game}  hw_type={hw_type}  chip_type={chip_type_real}  rsz={rsz}')
    print(f'  load=${load_addr:04X}  COLD=${cold_addr:04X}  NMI=${nmi_addr:04X}  (cold_off=+{cold_off})')
    print('  ROM first 16: ' + ' '.join(f'{b:02X}' for b in rom[:16]))
    if 0 <= cold_off < len(rom) - 10:
        cold_bytes = rom[cold_off:cold_off + 48]
        print('  coldstart hex: ' + ' '.join(f'{b:02X}' for b in cold_bytes))
        print('  coldstart disasm:')
        print(disasm_bytes(rom, cold_off, load_addr, count=48))

base = r'C:\Users\guyle\OneDrive\Asztali gep\SD_CARD\8kcrt'
# Find actual path with unicode
import glob
candidates = glob.glob(r'C:\Users\guyle\OneDrive\*\SD_CARD\8kcrt')
if candidates:
    base = candidates[0]
    print(f'Base: {base}')

for name in ['64MON', 'ASSEMBLM']:
    path = os.path.join(base, f'{name}.CRT')
    if os.path.exists(path):
        analyze(path, name)
    else:
        print(f'{name}: NOT FOUND at {path}')

# Also check a few WORKING carts for comparison
print('\n\n=== WORKING CARTS FOR COMPARISON ===')
for name in ['AVENGER', 'CENTIPDE']:
    path = os.path.join(base, f'{name}.CRT')
    if os.path.exists(path):
        analyze(path, name)
