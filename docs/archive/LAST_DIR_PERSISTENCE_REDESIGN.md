# EasySD Last-Directory Persistence Redesign

## Status

This document is a design study only.

- No firmware behavior is changed here.
- Current practical behavior remains: boot always starts from root.
- Goal: define how last-directory persistence should work cleanly and professionally before any new code change.

## Why This Needs Redesign

The earlier implementation treated saved-directory persistence as a boot-time side effect:

1. read EEPROM in `CartApi::Init()`
2. immediately navigate the SdFat current working directory
3. then continue menu startup

That model is too optimistic for real hardware.

It mixes together three separate concerns:

1. storing a user-facing resume hint
2. validating persisted state
3. mutating live filesystem state during a timing-sensitive startup path

The result is fragile even if each individual function is locally correct.

## Current EasySD Architecture Constraints

The redesign has to respect the current architecture instead of fighting it.

### 1. Directory state is Arduino-authoritative

Current project architecture already uses a single source of truth:

- SdFat volume working directory is the real filesystem state.
- `DirFunction::currentPath[64]` is a mirrored UI/debug string.
- the C64 menu asks the Arduino for the active path via `COMMAND_GET_PATH`
- MultiLoad restores working directories explicitly via `COMMAND_GOTO_PATH`

This is the right base model.

### 2. `openCwd()` invariants matter

The project already established the correct SdFat 2.x invariant:

- after every `sd.chdir()`, `ResyncDirFromCwd()` must reopen the directory handle with `openCwd()`
- directory iteration is only valid after that resync

Any persistence design that mutates cwd must respect this lifecycle exactly.

### 3. Boot is timing-sensitive on real C64 hardware

Menu transfer, cartridge visibility, PHI2 synchronization, and the first directory read all happen near startup.

Injecting extra SD navigation into `CartApi::Init()` increases the number of things that can go wrong before the first menu request is even complete.

That is the core architectural reason why boot-time restore is the wrong default model.

## Code Audit Findings

The last-directory code path was reviewed end-to-end in:

- `Arduino/EasySD/CartApi.cpp`
- `Arduino/EasySD/DirFunction.cpp`
- `docs/architecture/DIRECTORY_LIFECYCLE_INVARIANT.md`
- `docs/architecture/ARCHITECTURE_REVIEW.md`

### Finding 1: the stored record is under-validated

The existing format is:

- 2 magic bytes
- 64-byte path payload

That is not enough for robust persistence.

Missing pieces:

- record version
- explicit payload length
- integrity check
- commit semantics
- invalidation policy

With only magic bytes, a torn or partially updated record can still look superficially valid.

### Finding 2: write ordering is unsafe

The earlier implementation wrote validity markers first, then payload.

That means power loss during the write window can leave behind:

- valid-looking magic
- half-old / half-new path bytes

This is the opposite of transactional safety.

### Finding 3: restore is too early in system lifecycle

Calling restore in `CartApi::Init()` means persistence mutates cwd before:

- menu autoload fully stabilizes
- first directory read completes
- C64-side UI has synchronized to firmware state

That is architecturally high risk.

### Finding 4: persistence is modeled as implicit control flow

The old design assumed:

- if a saved record exists, the firmware should silently navigate there on boot

That is not a persistence concern. That is a product behavior decision.

Those should not be the same thing.

### Finding 5: EEPROM writes are not free

The Arduino EEPROM documentation states:

- write operations are slow, about 3.3 ms per byte in the Arduino EEPROM guide
- endurance is finite, about 100,000 write cycles per cell

The avr-libc EEPROM routines are also documented as:

- polled/blocking
- non-reentrant

So a persistence design should minimize both:

- how often it writes
- how much it writes

## External Research Summary

The redesign principles below are based on the following sources:

- avr-libc EEPROM manual: `eeprom_read_block`, `eeprom_update_block`, non-reentrant/polled behavior
- Arduino EEPROM guide: `EEPROM.update`, `EEPROM.put`, EEPROM CRC example, write-latency/endurance notes
- SdFat documentation and source: volume working directory semantics, `chdir()`, `openCwd()`, relative-path resolution

### EEPROM conclusions

Professional embedded persistence normally uses some combination of:

- structured records instead of raw ad hoc byte layouts
- version fields
- length fields
- checksum or CRC
- commit-last write order, or dual-slot journaling

### SdFat conclusions

SdFat already provides a clean model:

- the volume working directory is authoritative
- relative paths resolve from cwd
- `openCwd()` is the canonical way to bind a directory handle to cwd

So the correct persistence design is not to invent a second filesystem state model.
It should store only enough metadata to later request a controlled navigation.

## The Core Design Decision

The clean solution is:

> Persist last-directory as data, not as startup behavior.

That means the saved path should exist independently from whether boot chooses to restore it.

This is the main architectural change in thinking.

## Candidate Designs

### Option A: implicit boot restore in `CartApi::Init()`

Description:

- firmware reads EEPROM on boot
- firmware immediately navigates to the saved path
- menu starts there

Assessment:

- simplest on paper
- highest startup risk
- hardest to debug on real hardware
- couples storage integrity with boot timing

Verdict:

- not recommended

### Option B: delayed automatic restore after menu load

Description:

- boot still starts root
- after menu is already up and stable, firmware or menu auto-resumes the saved path

Assessment:

- much safer than boot-time restore
- still has hidden behavior
- can surprise the UI unless carefully synchronized

Verdict:

- acceptable, but still not the cleanest product model

### Option C: explicit user-driven resume

Description:

- boot always starts root
- firmware keeps a validated saved-path record available
- menu may show a status or offer a `Resume last directory` action
- only on explicit request does the system navigate there

Assessment:

- clean separation of persistence and startup
- easiest to debug
- failure is non-fatal: if restore fails, menu stays at root
- matches the current protocol philosophy well

Verdict:

- recommended

### Option D: no cwd restore, save path for plugins/loaders only

Description:

- EEPROM stores only a "most recent useful path"
- menu boot never uses it
- other flows can read it if needed

Assessment:

- safest technically
- may be too limited as a user feature

Verdict:

- viable fallback if resume UX is postponed

## Recommended Professional Model

The recommended model for EasySD is:

### 1. Boot policy

- boot always starts at root
- no hidden cwd mutation inside `CartApi::Init()`

### 2. Persistence policy

- store last successful directory as a validated EEPROM record
- do not treat existence of a saved record as permission to mutate cwd during boot

### 3. Resume policy

- restore only after explicit action
- the action may come from:
  - a menu command
  - a dedicated key/button gesture
  - a future startup prompt shown by the menu after it is already stable

### 4. Navigation policy

- when resume is requested, use the same authoritative navigation path as other runtime features
- that means a controlled `NavigateToPath()`-based restore, followed by `Prepare()`
- do not create a special hidden restore path that bypasses normal directory lifecycle rules

## Recommended EEPROM Record Format

The current 66-byte layout should be replaced by a proper record.

Suggested shape:

```c
struct LastDirRecord {
  uint8_t magic0;
  uint8_t magic1;
  uint8_t version;
  uint8_t flags;
  uint8_t pathLen;
  char path[64];
  uint16_t crc16;
  uint8_t committed;
};
```

Suggested field meanings:

- `magic0`, `magic1`: fixed signature
- `version`: layout version for future migration
- `flags`: reserved for future behavior bits
- `pathLen`: actual used length, must be `1..63`
- `path[64]`: null-terminated path buffer
- `crc16`: integrity check over version/flags/pathLen/path
- `committed`: final byte written last, used as a commit marker

Notes:

- CRC-16 is sufficient here; cryptographic protection is not needed
- a CRC is preferable to magic-only validation because it detects random corruption and torn payloads far better

## Recommended Write Strategy

### Minimum acceptable strategy

1. build record in RAM
2. compute CRC in RAM
3. write all payload fields except `committed`
4. write `committed` last

On read:

1. verify magic
2. verify version
3. verify `committed`
4. verify `pathLen`
5. verify null termination rules
6. verify CRC

If any check fails, ignore the record.

### Better strategy: dual-slot journal

Because the ATmega328P has 1 KB EEPROM and the record is small, a more professional model is to use two slots.

Benefits:

- one slot can remain valid if power dies during update of the other
- latest valid record can be chosen by sequence number
- no need to trust a single partially updated record

Suggested additions:

- `uint16_t sequence`
- two fixed EEPROM slots
- choose highest valid sequence at boot/read time

For EasySD, dual-slot is the preferred long-term design.

## Recommended Save Policy

Do not write blindly on every possible state transition.

Recommended rules:

1. save only after successful directory changes
2. save only if the new path differs from the currently persisted path
3. do not rewrite root repeatedly unless root is intentionally chosen as the new saved state
4. keep writes out of interrupt context
5. keep writes out of the most timing-sensitive startup window

Optional improvement:

- coalesce rapid navigation bursts and save only the final settled path after a short delay or at menu idle time

This is not mandatory for correctness, but it is better for EEPROM wear and latency.

## Recommended Restore API Model

The cleanest firmware design is to separate these three operations:

1. `LoadSavedLastDirRecord()`
2. `ValidateSavedLastDirRecord()`
3. `ApplySavedLastDirToCwd()`

That keeps read/validate/apply independent.

Even better, expose persistence at protocol level instead of hiding it in boot.

### Best product-facing approach

Add a dedicated high-level feature later:

- `GET_SAVED_LAST_DIR_STATUS`
- `GET_SAVED_LAST_DIR_PATH`
- `RESTORE_SAVED_LAST_DIR`
- `CLEAR_SAVED_LAST_DIR`

Why this is better than raw EEPROM commands:

- keeps EEPROM format private to firmware
- avoids coupling the C64 side to storage layout
- allows future layout changes without breaking protocol clients

## Why This Is Better Than the Old Design

The old design asked the wrong question:

> "Can we restore the last directory during boot?"

The right question is:

> "What is the clean ownership boundary between persisted user state and live filesystem state?"

The recommended model answers that cleanly:

- EEPROM owns persisted metadata
- SdFat cwd owns live filesystem state
- menu logic decides when resume should happen
- boot remains deterministic and root-based

## Practical Recommendation For EasySD

For this repository, the most professional next implementation should be:

1. keep current root-on-boot behavior
2. redesign EEPROM storage as a versioned, checksummed record
3. make restore explicit instead of automatic
4. if automatic resume is ever desired, do it only after menu startup is already stable
5. keep all actual path changes going through the same `NavigateToPath()` and `Prepare()` lifecycle used elsewhere

## Proposed Implementation Order

When code work resumes, the safest order is:

1. replace the raw EEPROM layout with a validated record type
2. implement read/validate helpers without changing boot behavior
3. implement a diagnostic/debug way to inspect saved-path validity
4. implement explicit restore command path
5. test explicit restore on hardware
6. only then evaluate whether any automatic resume behavior is still desirable

## Bottom Line

Yes, this likely should be solved differently than the original implementation.

The correct model is not:

- save a path
- silently replay it during boot

The correct model is:

- persist a validated resume record
- keep boot deterministic
- restore only through a controlled, explicit, architecturally visible action

That is the cleanest fit for EasySD's current Arduino-authoritative directory model, SdFat cwd invariants, and real-hardware startup constraints.