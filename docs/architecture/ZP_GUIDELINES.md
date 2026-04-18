# EasySD Zero Page Guidelines

Zero Page ($00–$FF) is the most valuable memory on the 6502. This document defines how EasySD uses it.

Single source of truth: `EasySD/Loader/CartZpMap.inc` — all ZP addresses are defined there and nowhere else.

---

## Three Layers

| Layer | Range | Owner | Rules |
|-------|-------|-------|-------|
| System | $00–$63 | C64 Kernal/BASIC | Do not write |
| Protocol | $64–$77 | IRQ/NMI handlers (CartLib) | IRQ-safe only; stable across plugin boundaries |
| Application | $80+ | Loader, menu, plugins | General use with rules below |

---

## Variable Categories

Every ZP variable has a semantic category that determines its lifetime:

| Category | Lifetime | Example |
|----------|----------|---------|
| **API** | Single function call | `ZP_LOADFILE_API_SIZE0` ($80) — LoadFileBySize parameter, invalid after return |
| **STATE** | Entire session | Protocol status flags — must be preserved across calls |
| **WORK** | Multi-step operation | Streaming byte counter — valid during one operation only |
| **TMP** | Single code block | Loop counter — undefined on entry, no preservation expected |

---

## Current Allocation

| Address | Symbol | Category | Used By |
|---------|--------|----------|---------|
| $64 | `ZP_IRQ_STATE_WAITHANDLE` | Protocol | Transfer-done flag (BIT poll) |
| $69–$6A | `ZP_IRQ_API_SEEK_LO/HI` | Protocol | Seek address for file ops |
| $6B | `ZP_IRQ_API_DATA_LENGTH` | Protocol | Transfer length in pages |
| $6C–$6D | `ZP_IRQ_API_DATA_LO/HI` | Protocol | NMI transfer: target address |
| $73–$74 | `ZP_IRQ_API_CALLBACK_LO/HI` | Protocol | Callback address |
| $75–$76 | `ZP_IRQ_API_SEEK_UPPER_LO/HI` | Protocol | 32-bit seek upper bytes |
| $77 | `ZP_IRQ_TMP_SCRATCH` | Protocol | ISR scratch byte |
| $80–$83 | `ZP_LOADFILE_API_SIZE0..3` | API | LoadFileBySize: 32-bit file size |
| $84–$85 | `ZP_LOADFILE_API_SKIP_LO/HI` | API | LoadFileBySize: skip offset |
| $86–$87 | `ZP_LOADFILE_API_PAYLOAD_LO/HI` | API | LoadFileBySize: target address |
| $8B–$8E | — | Free | Available (SafeStream params removed) |
| $90–$91 | `ZP_STREAM_TARGET_*` | WORK | StreamLargeFile: target address |
| $92–$95 | `ZP_STREAM_REMAIN_*` | WORK | StreamLargeFile: 32-bit byte counter |
| $FB–$FC | `NAMELOW/NAMEHIGH` | STATE | Menu navigation pointer — do not use as temp |
| $FD–$FE | `COLLOW/COLHIGH` | STATE | Color RAM pointer — do not use as temp |

---

## IRQ Safety Rules

IRQ/NMI handlers fire asynchronously. Mainline and interrupt code must not share the same ZP addresses without coordination.

- **`ZP_IRQ_*` addresses**: reserved for interrupt handlers. Mainline code may set them up before enabling interrupts, but must use SEI/CLI around multi-byte writes.
- **Mainline-only addresses** ($80+): never access these from an ISR.
- **Polling pattern**: ISR writes a status flag; mainline polls it read-only (e.g., `BIT ZP_IRQ_STATE_WAITHANDLE`).

---

## Naming Convention

All ZP symbols use the `ZP_` prefix. Format: `ZP_<MODULE>_<DESCRIPTION>`

- `ZP_LOADFILE_API_SIZE0` — LoadFileBySize, size byte 0
- `ZP_IRQ_STATE_WAITHANDLE` — IRQ layer, transfer-done flag
- `ZP_STREAM_API_TARGET_LO` — streaming, target address low

Never hardcode ZP addresses in code. Always use symbolic names from `CartZpMap.inc`.

---

## Plugin ZP Usage

Plugins may freely use `$8B–$8E` (free) and `$FB–$FE` (if not navigating). The `$80–$87` range is reserved for the LoadFileBySize API — only use it through that API. The `$90–$95` range is reserved for StreamLargeFile.

When a plugin needs temporary ZP storage, use addresses that do not conflict with the protocol layer ($64–$77) or active API parameters.
