# SD Card Contents

This folder mirrors the expected SD card root layout for EasySD.

Files here are **not committed to git** (too large / generated). Place them
on the SD card manually after generating or downloading them.

## Required files

| File | Description | How to generate |
|------|-------------|-----------------|
| `VIDEO.CVID` | CVID video file for CvidPlayer | `python Tools/cvid_convert.py input.mp4 VIDEO.CVID` |

## Subdirectories

```
/ (SD card root)
├── VIDEO.CVID          ← CvidPlayer video (place here)
└── PLUGINS/
    ├── PRGPLUGIN.PRG
    ├── KOAPLUGIN.PRG
    ├── PETGPLUGIN.PRG
    ├── WAVPLUGIN.PRG
    ├── MUSPLUGIN.PRG
    └── CVIDPLUGIN.PRG
```

Plugin binaries are built by `python Tools/build.py plugins` and output to `IRQHack64/build/plugins/`.
