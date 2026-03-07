# SD Card Contents

This folder mirrors the expected SD card root layout for EasySD.

Files here are **not committed to git** (too large / generated). Place them
on the SD card manually after generating or downloading them.

## Required files

| File | Description | How to generate |
|------|-------------|-----------------|
| `VIDEO.CVD` | CVD video file for CvdPlayer | `python Tools/cvd_convert.py input.mp4 VIDEO.CVD` |

## Subdirectories

```
/ (SD card root)
├── VIDEO.CVD           ← CvdPlayer video (place here)
└── PLUGINS/
    ├── PRGPLUGIN.PRG
    ├── KOAPLUGIN.PRG
    ├── PETGPLUGIN.PRG
    ├── WAVPLUGIN.PRG
    ├── MUSPLUGIN.PRG
    └── CVDPLUGIN.PRG
```

Plugin binaries are built by `python Tools/build.py plugins` and output to `EasySD/build/plugins/`.
