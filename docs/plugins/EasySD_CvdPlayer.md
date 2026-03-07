# EasySD – CvdPlayer Plugin

Plays black-and-white video on the Commodore 64 from an SD card via the EasySD cartridge.
Video is streamed in real time at 5 fps in multicolor bitmap mode (160×80 effective pixels).

---

## Quick Start

1. Convert a video to CVD format on your PC:
   ```
   python Tools/cvd_convert.py myvideo.mp4 VIDEO.CVD
   ```
2. Copy `VIDEO.CVD` to the **root** of the SD card.
3. On the C64, navigate to `CVDPLUGIN.PRG` in the EasySD menu and launch it.
4. Press **STOP** to exit back to the menu.

---

## Converting Video — cvd_convert.py

Requires **ffmpeg** installed and available in PATH.

### Basic conversion

```bash
python Tools/cvd_convert.py input.mp4 VIDEO.CVD
```

### With Floyd-Steinberg dithering (recommended for videos with gradients or gray areas)

```bash
python Tools/cvd_convert.py input.mp4 VIDEO.CVD --dither
```

### Custom brightness threshold

```bash
python Tools/cvd_convert.py input.mp4 VIDEO.CVD --threshold 110
```

Pixels with grayscale value ≥ threshold are encoded as white; below as black.
Default is 128. Lower values produce a brighter image; higher values produce a darker one.

### Probe input video without converting

```bash
python Tools/cvd_convert.py --info input.mp4
```

Prints source FPS, duration, estimated frame count, and output file size.

### Output

The converter prints a live progress bar:

```
Frame  312/1500  [████████░░░░░░░░░░░░]   4.3 enc-fps    1248 KB
```

The output file size is always an exact multiple of 4000 bytes (one frame = 4000 bytes).

---

## SD Card Layout

```
/ (root)
├── VIDEO.CVD           ← video file (required, in root)
└── PLUGINS/
    └── CVDPLUGIN.PRG   ← plugin binary (loaded by EasySD menu)
```

The video filename is hardcoded as `VIDEO.CVD` in the plugin. It must be placed in the
SD card root, not in a subdirectory.

---

## C64 Side — How It Works

When `CVDPLUGIN.PRG` is launched from the EasySD menu:

1. The plugin initialises the VIC-II for multicolor bitmap mode (160×80, 5 fps).
2. It opens `VIDEO.CVD` from the SD card root.
3. Playback begins: the Arduino streams 400 bytes per raster frame via NMI-driven
   transfer (non-interrupted stream, 20 KB/s sustained).
4. Each video frame = 10 consecutive 400-byte blocks. The C64 double-buffers the
   bitmap so one bank displays while the other is being filled — no screen tearing.
5. Playback stops automatically when the file ends, or immediately when **STOP** is pressed.

### Controls

| Key  | Action             |
|------|--------------------|
| STOP | Exit to EasySD menu |

### Display area

The video occupies character rows 3–22 (20 rows × 40 columns), centered vertically
on a black screen with a black border. Each CVD pixel maps to a 2×2 area on the
physical display (multicolor mode).

---

## CVD File Format (reference)

| Property       | Value                              |
|----------------|------------------------------------|
| Resolution     | 160×80 effective pixels            |
| Frame rate     | 5 fps                              |
| Frame size     | 4000 bytes (10 blocks × 400 bytes) |
| File size      | `N_frames × 4000` bytes            |
| Color depth    | 1-bit (black / white)              |
| Header         | None — flat binary                 |

Each 400-byte block encodes one character-row pair (2 char rows = 16 scan lines):

| Offset       | Size     | Content                                      |
|--------------|----------|----------------------------------------------|
| `$000–$04F`  | 80 bytes | Bitmap: char row A, left 20 columns          |
| `$050–$09F`  | 80 bytes | Bitmap: char row A, right 20 columns         |
| `$0A0–$0EF`  | 80 bytes | Bitmap: char row B, left 20 columns          |
| `$0F0–$13F`  | 80 bytes | Bitmap: char row B, right 20 columns         |
| `$140–$167`  | 40 bytes | Screen RAM colors (white, same for both rows)|
| `$168–$18F`  | 40 bytes | Color RAM ($D800) for this line pair         |

---

## Build Integration

The plugin is built automatically by the standard build system:

```bash
python Tools/build.py plugins    # build all plugins including CvdPlayer
python Tools/build.py release    # full build
```

Source: `EasySD/Plugins/CvdPlayer/`
Output: `build/plugins/cvdplugin.prg` → deployed to SD card as `PLUGINS/CVDPLUGIN.PRG`
