# EasySD – KoalaDisplayer Plugin

Displays Koala Painter multicolor bitmap images on the C64 from an SD card.

---

## File Format — KOA

| Property | Value |
|----------|-------|
| Extension | `.KOA` |
| Total size | 10003 bytes (with 2-byte PRG header) or 10001 bytes (raw) |
| Bitmap data | 8000 bytes |
| Screen RAM | 1000 bytes |
| Color RAM | 1000 bytes |
| Background color | 1 byte |
| Header | 2-byte PRG load address `$00 $60` (optional) |

The plugin accepts both the standard 10003-byte (`.KOA` with header) and raw
10001-byte variants. File size is checked exactly; any other size is rejected.

---

## Memory Layout (C64 side)

The picture data is loaded to `$2000` and then transferred into VIC-II display RAM:

| Address | Symbol | Content |
|---------|--------|---------|
| `$2000–$3F3F` | `PICTURE` / `BITMAP` | 8000 bytes bitmap data |
| `$3F40–$432F` | `VIDEO` | 1000 bytes screen RAM (copied to `$0400`) |
| `$4328–$4710` | `COLOR` | 1000 bytes color RAM (copied to `$D800`) |
| `$4710` | `BACKGROUND` | 1 byte background color (written to `$D021`) |

VIC-II configuration:
- Bank 0 (`$DD00` bits 0–1 = `%11`)
- Bitmap at `$2000`, screen at `$0400`, `$D018` = `$18`
- Multicolor mode (`$D016` bit 4 set)
- Border color set to 0

---

## API Calls Used

| Call | Purpose |
|------|---------|
| `PROT_OpenFile` | Open the selected file |
| `PROT_GetInfoForFile` | Read FAT entry to get exact file size |
| `LoadFileBySize` | Load bitmap payload to `$2000` |
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

- Only accepts exactly 10003 or 10001 bytes. Files with other sizes are rejected with a "BAD KOALA SIZE" message.
- Display uses VIC bank 0 — incompatible with programs that also use `$0000–$3FFF`.

---

## Source and Build

| Item | Path |
|------|------|
| Source | `EasySD/Plugins/KoalaDisplayer/KoalaDisplayer.s` |
| Build output | `EasySD/build/plugins/koaplugin.prg` |
| SD card path | `/PLUGINS/KOAPLUGIN.PRG` |

```bash
python Tools/build.py plugins
```
