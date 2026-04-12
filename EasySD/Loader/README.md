# EasySD Loader Directory

This directory contains the active C64-side cartridge communication libraries, macro layers, transfer handlers, and bridge code used by the current EasySD build.

This file is a quick orientation note, not the canonical architecture reference. For current behavior, prefer the source code in this directory and the focused docs under `docs/architecture/`.

---

## What Is Here

- `CartLib.s` — low-level cartridge protocol primitives such as `PROT_StartTalking`, `PROT_EndTalking`, send/receive helpers, and the NMI transfer handler.
- `CartLibHi.s` — high-level protocol functions such as file open/close, path operations, streaming entry points, and menu return helpers.
- `CartLibStream.s` — top-level include wrapper for plugins that need the full CartLib stack.
- `CartLibCommon.s` — shared cartridge constants and common support code.
- `APIMacros.s` — explicit helper macros such as `#OPENFILE`, `#GETFILEINFO`, `#EXTRACTFILESIZE`, `#CLOSEFILE`, and `#SETADDR`.
- `SystemMacros.s` — general system and cartridge macros such as register save/restore and bank switching helpers.
- `CartZpMap.inc` — the active zero-page allocation map.
- `Common/` — shared include files such as `System.inc` and `EasySD.inc`.
- `Bridges/` — bridge loaders such as KernalBridge and MultiLoad-related code.
- `_archive/` — historical files not meant to describe the current active design.

---

## Current Include Rule

For most plugins, include the highest-level wrapper you need and avoid mixing multiple CartLib layers manually.

Current active chain:

```text
CartLibStream.s -> CartLibHi.s -> CartLib.s -> CartLibCommon.s -> Common/System.inc + Common/EasySD.inc
```

If a file uses Tier 2 API macros such as `#OPENFILE` or `#GETFILEINFO`, it must also include `APIMacros.s` explicitly.

---

## Current Naming

The active API uses the `PROT_` prefix.

Examples:

- `PROT_StartTalking`
- `PROT_EndTalking`
- `PROT_OpenFile`
- `PROT_CloseFile`
- `PROT_ExitToMenu`

Older `IRQ_` naming belongs to previous stages of the project and should not be treated as the current public interface.

---

## What Not To Infer From This Folder

- Do not use archived files as evidence of current behavior.
- Do not assume old SafeStream-era abstractions are still active just because archived files exist.
- Do not use this README as the source of truth for status claims; verify behavior in code first.

---

## Preferred References

- `docs/architecture/CARTRIDGE_PROTOCOL.md` — protocol and transfer behavior
- `docs/architecture/MACRO_ARCHITECTURE.md` — macro layering
- `docs/architecture/MEMORY_MAP_CANONICAL.md` — memory layout reference
- `docs/architecture/EEPROM_ARCHITECTURE.md` — terminology for cartridge ROML chip vs MCU internal EEPROM
