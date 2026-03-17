# EasySD – PetsciiDisplayer Plugin

Displays PETSCII full-screen dumps on the C64 from an SD card.

---

## File Format — PETSCII Screen Dump

| Property | Value |
|----------|-------|
| Extension | `.SEQ`, `.SCR`, or custom (whatever the menu associates) |
| Size | 2002 bytes |
| Layout | 2 bytes (border/background color) + 1000 bytes screen RAM + 1000 bytes color RAM |

Exact structure:

| Offset | Size | Content |
|--------|------|---------|
| 0 | 1 byte | Border color (written to `$D020`) |
| 1 | 1 byte | Background color (written to `$D021`) |
| 2–1001 | 1000 bytes | Screen RAM characters (PETSCII screen codes) |
| 1002–2001 | 1000 bytes | Color RAM |

The plugin validates that the file is exactly 2002 bytes (fits in the 2048-byte buffer).
No PRG header is expected — the file is raw.

---

## Memory Layout (C64 side)

| Address | Content |
|---------|---------|
| `READBUFFER` | 2002-byte file loaded here (plugin-private RAM, at end of plugin image) |

After loading, the plugin copies data directly to VIC-II display RAM:
- Screen RAM → `$0400` (1000 bytes)
- Color RAM → `$D800` (1000 bytes)
- Border/background bytes → `$D020`/`$D021`

---

## API Calls Used

| Call | Purpose |
|------|---------|
| `PROT_OpenFile` | Open the selected file |
| `PROT_GetInfoForFile` | Read FAT entry to obtain file size |
| `LoadFileBySize` | Load file payload into `READBUFFER` |
| `PROT_CloseFile` | Close the file |
| `PROT_ExitToMenu` | Return to EasySD menu |

Macros: `#OPENFILE`, `#SETADDR`, `#EXTRACTFILESIZE` (Tier 2).

---

## Controls

| Key | Action |
|-----|--------|
| Any key | Exit back to EasySD menu |

---

## Known Limitations

- Accepts only exactly 2002 bytes. Files outside this range are rejected with a "BAD FILE SIZE" message.
- The display uses the standard 40-column text mode. VIC-II mode is not changed — the screen remains in character mode. PETSCII screen codes must be in `"screen"` encoding.
- The plugin does not support color animation or raster effects.

---

## Source and Build

| Item | Path |
|------|------|
| Source | `EasySD/Plugins/PetsciiDisplayer/PetsciiDisplayer.s` |
| Build output | `EasySD/build/plugins/petgplugin.prg` |
| SD card path | `/PLUGINS/PETGPLUGIN.PRG` |

```bash
python Tools/build.py plugins
```
