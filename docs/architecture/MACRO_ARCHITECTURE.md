# Macro Architecture

EasySD uses a two-tier macro system in 64tass assembly.

---

## Tier 1 — System Macros

**File:** `IRQHack64/Loader/SystemMacros.s`
**Included via:** CartLib.s (part of the CartLibStream.s chain — never directly)

| Macro | Purpose | Expands to |
|-------|---------|-----------|
| `READCART addr` | Read cartridge bank, store to addr | LDA CARTRIDGE_BANK_VALUE / STA addr |
| `READCART_MODULATED addr` | Modulated cartridge read (timing-critical) | LDA MOD_ADDR / LDA CART_BANK / STA addr |
| `SETBANK config` | Set processor port | LDA #config / STA PROCESSOR_PORT |
| `SAVEREGS` / `RESTOREREGS` | Preserve A/X/Y on stack | PHA/TXA/PHA/TYA/PHA and reverse |
| `WAITFOR addr, branch` | BIT-based status poll loop | - / BIT addr / branch - |
| `WAITVALUE addr, val` | Poll until addr == val | - / LDA addr / CMP #val / BNE - |
| `SETADDR label, zp_lo` | Load 16-bit address into ZP pair | LDA #<label / STA zp / LDA #>label / STA zp+1 |
| `COUNTLOOP n` / `ENDLOOP` | X-register countdown loop | LDX #n / body / DEX / BNE |

---

## Tier 2 — API Macros

**File:** `IRQHack64/Loader/APIMacros.s`
**Included by:** Files that need API macros before CartLibStream.s is pulled in (e.g. KernalBridge).

| Macro | Purpose | Replaces |
|-------|---------|---------|
| `OPENFILE buf, #len, #flags` | Set filename + open file | LDX/LDY/LDA/JSR IRQ_SetName + LDX/JSR IRQ_OpenFile (6 lines) |
| `GETFILEINFO buf` | Read FAT directory entry into buf | LDA/STA × 2 + LDY #0 + JSR IRQ_GetInfoForFile (6 lines) |
| `EXTRACTFILESIZE src, dst` | Copy 32-bit file size from FAT entry | LDA src+28..31 / STA dst..dst+3 (8 lines) |
| `CLOSEFILE` | Close current file | JSR IRQ_CloseFile |
| `SETADDR label, zp_lo` | 16-bit ZP pointer setup | LDA #<label / STA zp / LDA #>label / STA zp+1 (4 lines) |

`SETADDR` appears in both tiers with identical expansion. APIMacros.s defines it for files that include APIMacros.s before CartLibStream.s; 64tass silently accepts the later duplicate from SystemMacros.s.

---

## Include Pattern

```asm
.include "../../DebugMacros.s"      ; debug print macros
.include "../../APIMacros.s"        ; Tier 2 — only when needed before CartLibStream
; ... code ...
.include "../../CartLibStream.s"    ; Tier 1 arrives here via include chain
```

**Rule:** Never include `SystemMacros.s` directly. Tier 1 macros arrive through `CartLibStream.s`.

---

## Adopters

| File | Tier 1 macros used | Tier 2 macros used |
|------|-------------------|-------------------|
| `CvidPlayer/NMI.s` | READCART_MODULATED (×400) | — |
| `Loader/CartLib*.s` | SETBANK, SAVEREGS, RESTOREREGS, WAITFOR, WAITVALUE | — |
| `Loader/Bridges/KernalBridge/KernalBridge.s` | SETADDR | OPENFILE, GETFILEINFO, EXTRACTFILESIZE, CLOSEFILE, SETADDR |

---

## FAT Entry Layout (reference for GETFILEINFO / EXTRACTFILESIZE)

| Offset | Size | Content |
|--------|------|---------|
| 0–10 | 11B | 8.3 filename |
| 11 | 1B | Attributes |
| 28–31 | 4B | File size (32-bit little-endian) |
