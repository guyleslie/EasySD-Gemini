# EasySD MultiLoad

## Purpose

MultiLoad lets EasySD run C64 games that continue loading additional parts with standard Kernal `LOAD` calls on device 8.

EasySD does not emulate a full 1541 drive. Instead, `EASYLOAD.PRG` installs a resident hook on the Kernal LOAD vector at `$0330/$0331`, loads the first game part from SD, then hands control to the game. Any later `LOAD "NAME",8,x` call that goes through the normal Kernal path is redirected to the EasySD resident loader and served from the same game directory on the SD card.

This is intended for standard sequential multiload cracks, not for games that use custom fast loaders, raw sector access, or random-access file systems.

## Quick Start

Build the MultiLoad template:

```bash
python Tools/build.py multiload
```

Preview the contents of one or more disk images:

```bash
python Tools/create_multiload.py --from-disk DISK1.d64 [DISK2.d64 ...] --list-only
```

Generate a ready-to-extract ZIP:

```bash
python Tools/create_multiload.py --from-disk DISK1.d64 [DISK2.d64 ...]
```

Override the first part if the auto-selected file is not the correct boot file:

```bash
python Tools/create_multiload.py --from-disk DISK1.d64 [DISK2.d64 ...] --first-part "LOADER"
```

Autoswap lists are also supported:

```bash
python Tools/create_multiload.py --from-autoswap autoswap.lst
```

The output ZIP contains this layout:

```text
MULTILOAD/GAMENAME/
  EASYLOAD.PRG
  FIRSTPART.PRG
  FILE2.PRG
  FILE3.PRG
```

Extract the ZIP to the SD card root, browse to `MULTILOAD/GAMENAME/`, and launch `EASYLOAD.PRG` from the EasySD menu.

## Repository Assets

The disk images in the top-level `multiload/` folder are source assets for rebuilding MultiLoad packages. They are intentionally kept in Commodore disk format so new ZIPs can be regenerated after template or resident-loader changes.

Generated ZIPs are disposable outputs. The disk images are the important long-term inputs.

## What `create_multiload.py` Does

`Tools/create_multiload.py` reads PRG files from supported disk images: D64, D71, D81, and T64.

Its current behavior is:

- It merges PRG files from all input disks into one file set.
- If the same PRG name appears on multiple disks, the first occurrence wins and later duplicates are reported as warnings.
- The game folder name is derived from the first disk image filename, then the internal disk label, and finally the parent folder if needed.
- It builds `EASYLOAD.PRG` by patching the MultiLoad template and prepending a normal PRG load header for `$C000`.
- It writes all extracted PRGs into a ZIP under `MULTILOAD/GAMENAME/`.

By default, the first merged PRG becomes the first part. If that is wrong for a given game, use `--first-part NAME`.

## Filename Rules

The resident loader ultimately looks for FAT filenames on the SD card.

- The first part name is stored in `EASYLOAD.PRG` including the `.PRG` suffix.
- Later game loads may call `LOAD "LEVEL1",8,x` or `LOAD "LEVEL1.PRG",8,x`.
- If the requested name does not already end with uppercase `.PRG`, the resident loader appends `.PRG` before opening the SD file.
- The first-part config field is 20 bytes wide, which matches the C64 maximum 16-character filename plus `.PRG`.

`create_multiload.py` converts disk-directory names to FAT-safe uppercase names. Printable ASCII that is valid on FAT is preserved; illegal FAT characters and unsupported high PETSCII characters are replaced with `_`.

## Runtime Flow

### 1. Menu Launch

The menu loads `EASYLOAD.PRG` to `$C000` and jumps to it.

### 2. Install Resident Loader

`EASYLOAD.PRG`:

- saves minimal state for clean error return,
- installs the resident LOAD stub at `$033C`,
- copies the resident handler and mini CartLib into RAM under the Kernal ROM area,
- patches `$0330/$0331` to point to the resident stub,
- writes the RAM NMI redirect used during transfers under `$01=$35`.

### 3. Capture Game Directory

Before loading the first file, `EASYLOAD.PRG` asks the Arduino for the current directory path with `COMMAND_GET_PATH` and stores it in resident RAM. This makes later loads robust even if the Arduino working directory drifts.

### 4. Load First Part

The first-part filename comes from the patched config block in `EASYLOAD.PRG`.

The launcher:

- opens that file,
- reads its size,
- reads the first 256 bytes,
- copies the payload to the PRG load address,
- streams the remainder if needed,
- closes the file,
- ends the EasySD session,
- jumps to the loaded program.

### 5. Intercept Later LOAD Calls

Once the game is running, any later `LOAD` that goes through the standard Kernal LOAD dispatch and uses device 8 reaches the resident handler.

The resident handler:

- passes non-device-8 loads through to the original Kernal vector,
- changes the Arduino back to the stored game directory with `COMMAND_GOTO_PATH`,
- reconstructs the requested filename,
- appends `.PRG` if needed,
- opens the file from SD,
- loads it either to the PRG header address or to the saved X/Y target when SA=0,
- returns with the normal Kernal convention: carry clear on success and X/Y set to the end address.

## Config Block

`EASYLOAD.PRG` starts with a fixed config block immediately after `JMP MAIN`:

| Address | Symbol | Meaning |
|---------|--------|---------|
| `$C003` | `ML_CONFIG_VERSION` | Must be `3` |
| `$C004` | `ML_FIRST_PART_LEN` | Length of first filename including `.PRG` |
| `$C005-$C018` | `ML_FIRST_PART_NAME` | First filename including `.PRG`, null-padded, 20 bytes |

Template layout in `bootplugin.prg`:

| File Offset | Meaning |
|-------------|---------|
| `3` | `ML_CONFIG_VERSION` |
| `4` | `ML_FIRST_PART_LEN` |
| `5-24` | `ML_FIRST_PART_NAME` |

Generated `EASYLOAD.PRG` adds a 2-byte PRG header in front of that raw template, so the config data appears at file offsets `5`, `6`, and `7-26` in the final SD-card file.

## Memory Areas Used at Runtime

The important resident locations are:

| Address | Purpose |
|---------|---------|
| `$0330/$0331` | Patched Kernal LOAD vector |
| `$033C-$036F` | Resident LOAD stub and saved metadata |
| `$0368-$036A` | `RL_NMI_REDIRECT` = `JMP ($0318)` |
| `$E800+` | Resident handler and embedded mini CartLib |
| `$E840` | Stored game directory path |
| `$E880` | Runtime filename buffer |
| `$E8A4` | File info buffer |
| `$E8C4` | First-page read buffer |

The plugin itself still lives at `$C000+`, but later game parts may overwrite that area. That is why the active resident code is copied elsewhere before the game starts.

## Limits and Compatibility

MultiLoad is a good fit when the game uses normal sequential `LOAD` calls between stages or scenes.

Known limits:

- Direct calls that bypass the Kernal LOAD vector, such as `JSR $E16F`, cannot be intercepted.
- Custom fast loaders, raw sector loaders, and non-Kernal APIs are not supported.
- Loads to addresses overlapping `$033C-$036F` would destroy the resident stub.
- Loads to the resident handler area under `$E800+` would also break the hook, although this is rare.
- The first-part filename, including `.PRG`, must fit in 20 bytes.
- The resident code checks only uppercase `.PRG` when deciding whether to append the extension.

Practical rule: if a crack already works with SD2IEC using normal Kernal loading, it is usually a good MultiLoad candidate.

## Build and Debug Notes

Build the template only:

```bash
python Tools/build.py multiload
```

Optional border-color debug markers can be enabled through the build system with `--ml-debug-borders`. These are intended for real hardware hang diagnosis and are not part of normal use.

## Key Source Files

| File | Purpose |
|------|---------|
| `EasySD/Loader/Bridges/MultiLoad/MultiLoad.s` | `EASYLOAD.PRG` launcher, first-part load, error path |
| `EasySD/Loader/ResidentLoader.s` | Resident stub, handler, embedded mini CartLib, install/uninstall logic |
| `EasySD/Loader/Common/System.inc` | Canonical resident-loader addresses |
| `Tools/create_multiload.py` | Disk-image merge, template patching, ZIP generation |
| `Tools/build.py` | `multiload` build target |
| `Arduino/EasySD/CartApi.cpp` | Commands used by the launcher and resident loader |

## Summary

The current MultiLoad design is simple:

- build one generic launcher template,
- patch in the correct first-part filename,
- package all PRGs under one game folder,
- install a resident hook before the game starts,
- keep serving later Kernal LOAD calls from the same SD directory.

That is the current source-of-truth behavior.
