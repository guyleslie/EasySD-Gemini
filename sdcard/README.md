# SD Card Contents

This folder mirrors the expected SD card root layout for EasySD.

Files here are **not committed to git** (too large / generated). Place them
on the SD card manually after generating or downloading them.

## Video files

CVD files can be placed anywhere on the SD card. The user browses to them in
the EasySD menu and presses Enter to play. Convert with:

```
python Tools/cvd_convert.py input.mp4 output.cvd
```

## Subdirectories

```
/ (SD card root)
├── EASYSD.PRG
└── PLUGINS/
    ├── PRGPLUGIN.PRG
    ├── HWTPLUGIN.PRG
    ├── KOAPLUGIN.PRG
    ├── PETGPLUGIN.PRG
    ├── WAVPLUGIN.PRG
    └── CVDPLUGIN.PRG
```

The exact staged SD bundle is produced by `python Tools/build.py sd-content` under `EasySD/build/sd-content/`.
