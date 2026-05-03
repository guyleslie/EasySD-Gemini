# MultiLoad Debug Observations

Date: 2026-05-03

## Current Baseline

Normal PRG launches outside `/MULTILOAD/` still work reliably.

Observed non-MultiLoad example:

- Path: `/PRG/eggfeud.prg`
- Serial reaches `Launch`, `Launch sz`, `AVR Enabling Cartridge`, directory restore, then `Launched - C64 running game`.
- Screen behavior: black outer border, dark-blue inner area, then the PRG starts correctly after a short delay.

This suggests the normal PRG transfer and launch path is still healthy.

## MultiLoad Failure Mode A: Last Ninja 1

Tested path:

- `/MULTILOAD/LASTNINJA1/THE LAST NINJA.PRG`

Serial reaches:

- `MLMode launch: THE LAST NINJA.PRG`
- `MLBoot launched`
- `GotoPath: /MULTILOAD/LASTNINJA1`
- `Changed to ROOT`
- `Entered: /MULTILOAD`
- `Entered: /MULTILOAD/LASTNINJA1`

Serial does not reach:

- `OpenFile: THE LAST NINJA.PRG`

Screen behavior:

- Black outer border, dark-blue inner area.
- Then a short red outer border.
- A few garbage characters are visible briefly.
- C64 resets to BASIC.

Interpretation:

- Arduino receives the first resident-loader session and handles `COMMAND_GOTO_PATH`.
- The C64 side does not successfully continue to `COMMAND_OPEN_FILE`.
- This failure is before first-part `OpenFile`, not during file data streaming.

## MultiLoad Failure Mode A2: Last Ninja 2

Tested path:

- `/MULTILOAD/LASTNINJA2/LAST NINJA 2.PRG`

Serial reaches:

- `MLMode launch: LAST NINJA 2.PRG`
- `MLBoot launched`
- `GotoPath: /MULTILOAD/LASTNINJA2`
- `Changed to ROOT`
- `Entered: /MULTILOAD`
- `Entered: /MULTILOAD/LASTNINJA2`
- `[ERR ][SYS] Unknown cmd`

Screen behavior:

- Red border was visible.
- C64 then hung.

Interpretation:

- Arduino receives and handles `COMMAND_GOTO_PATH`.
- The next byte sequence from the C64 is not decoded as a valid command.
- This points to a protocol/session timing or C64-side resident-loader continuation problem after `GotoPath`, not to a missing directory.

## MultiLoad Failure Mode B: Iowa Jack

Tested path:

- `/MULTILOAD/IOWA JACK/IOWA JACK.PRG`

Serial reaches:

- `MLMode launch: IOWA JACK.PRG`
- `MLBoot launched`
- `GotoPath: /MULTILOAD/IOWA JACK`
- `OpenFile: IOWA JACK.PRG`
- `OpenFile OK`
- `FileSize: 252`

Serial does not reach:

- `ReadFile pages: ...`

Screen behavior:

- Black screen.
- After a short delay, C64 hangs with black screen.

Interpretation:

- First-part name/path handling and `OpenFile` are correct for this game.
- The C64 appears to stop after `COMMAND_GET_INFO_FOR_FILE` response/data transfer.
- This points at the resident loader's NMI receive path or the handoff after file-info transfer, not path lookup.

## Post-Failure Instability

After a failed MultiLoad launch, subsequent `/MULTILOAD/<game>/*.PRG` launches are less stable until a normal non-MultiLoad PRG is launched.

Observed pattern:

- MultiLoad failures can leave later MultiLoad attempts showing red border earlier/more often.
- Launching a normal PRG outside `/MULTILOAD/` restores the system enough that MultiLoad attempts again split into the two failure modes above.

Interpretation:

- A failed MLBoot/resident-loader session likely leaves Arduino receive state, C64 vectors, cartridge page state, open file state, or CWD-related state partially dirty.
- The normal PRG path performs a stronger reset/launch cleanup, masking or clearing that dirty state.

## Working Hypotheses

1. `Last Ninja 1` stops between successful `GotoPath` response and `OpenFile`, likely in the C64 resident handler after `RL_WaitProcessing` or during filename-state restore.
2. `Last Ninja 2` reaches `Unknown cmd` after `GotoPath`, so the next resident-loader command is corrupted, missed, or misaligned.
3. `Iowa Jack` stops after `FileSize`, likely in `RL_GetInfoForFile` / `RL_ReceiveFragmentNoCallback`, before `RL_ReadFileNoCallback` can send `COMMAND_READ_FILE`.
4. The remaining issue is no longer primarily an SD path problem. The path restore works at least through `COMMAND_GOTO_PATH`, and `Iowa Jack` proves `OpenFile` can succeed from a MultiLoad directory.
5. The post-failure instability indicates a cleanup/reset-state problem after failed resident-loader attempts.
