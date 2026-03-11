; EasySDMenuMock.s — DEBUG=1 mock implementation
; Included from EasySDMenu.s only when DEBUG=1.
; No .if DEBUG blocks inside — the conditional is in the parent.
;
; Replaces Arduino SD card communication with hardcoded directory data
; (MOCK_DIR1/2/3) for VICE emulator testing.
;
; MOCK_CURRENT_PATH mirrors Arduino's currentPath format:
;   "/" (root), "/games", "/games/demos" — no trailing slash except root.
; MOCK_GetCurrentPath / MOCK_EnterDir / MOCK_GoBack maintain it so that
; PRINTDIRHEADER and PrepareFileNameParameter run the same production logic
; in both DEBUG and release modes.
;
; Forward references to main-file labels (DIRLOAD, INPUT_GET,
; DEBUG_PRG_REACHED, MSG_VICE_DEBUG, etc.) are resolved by
; 64tass multi-pass assembly.

; ============================================================
; MOCK SUBROUTINES
; ============================================================

; ------------------------------------------------------------
; MOCK_InitReadDirectory
;   Called from initial directory load (replaces block 3 .else)
; ------------------------------------------------------------
MOCK_InitReadDirectory
	JSR SETDIR1
	JSR DIRREAD
	LDA #$02			; red
	LDX #<MSG_VICE_DEBUG
	LDY #>MSG_VICE_DEBUG
	JSR STATUS_LINE
	RTS

; ------------------------------------------------------------
; MOCK_EnterDir
;   Called from ENTERDIR (replaces block 6 .else)
;   Increments DIRLEVEL (capped at 2), then appends the selected
;   dirname to MOCK_CURRENT_PATH, mirroring Arduino's ENTERDIR.
;   On entry: X = current row (from GETCURRENTROW, still valid)
;   Temp ZP: $08/$09 = source ptr (dirname), $0B/$0C = dest ptr
; ------------------------------------------------------------
MOCK_EnterDir
	INC DIRLEVEL
	; DEBUG mock supports DIRLEVEL 0..2 only (MOCK_DIR1..DIR3)
	LDA DIRLEVEL
	CMP #3
	BCC _med_path
	LDA #2
	STA DIRLEVEL

_med_path
	; --- Append dirname to MOCK_CURRENT_PATH ---
	; 1. Find null terminator of MOCK_CURRENT_PATH → Y = path length
	LDY #0
_med_find_null
	LDA MOCK_CURRENT_PATH, Y
	BEQ _med_found_null
	INY
	BNE _med_find_null		; path < 64 bytes, safe
_med_found_null
	; 2. If Y > 1 (not root "/"), insert '/' separator first
	CPY #1
	BEQ _med_skip_slash
	LDA #$2F			; '/'
	STA MOCK_CURRENT_PATH, Y
	INY
_med_skip_slash
	; 3. $0B/$0C = MOCK_CURRENT_PATH + Y (destination write position)
	TYA
	CLC
	ADC #<MOCK_CURRENT_PATH
	STA $0B
	LDA #>MOCK_CURRENT_PATH
	ADC #0
	STA $0C
	; 4. $08/$09 = pointer to selected entry's dirname string
	LDA NAMESLO, X
	STA $08
	LDA NAMESHI, X
	STA $09
	; 5. Copy dirname from ($08/$09) into ($0B/$0C), null-terminate
	LDY #0
_med_copy
	LDA ($08), Y
	BEQ _med_end
	STA ($0B), Y
	INY
	CPY #32				; max dirname length safety
	BNE _med_copy
_med_end
	LDA #0
	STA ($0B), Y			; null-terminate
	RTS

; ------------------------------------------------------------
; MOCK_ReadDirectory
;   Called from DOREADDIRECTORY (replaces block 7 .else)
;   Dispatches to SETDIR1/2/3 based on DIRLEVEL
; ------------------------------------------------------------
MOCK_ReadDirectory
	LDA DIRLEVEL
	CMP #0
	BNE _mrd_l1
	JSR SETDIR1
	RTS
_mrd_l1
	CMP #1
	BNE _mrd_l2
	JSR SETDIR2
	RTS
_mrd_l2
	JSR SETDIR3
	RTS

; ============================================================
; SETDIR1 / SETDIR2 / SETDIR3
;   Copy MOCK_DIR1/2/3 to DIRLOAD area.
;   Copy uses X register (forward) — Y (backward) corrupts data.
; ============================================================

SETDIR1
	LDA #$02        ; BORDER = RED (visual indicator)
	STA $D020
	LDX #$00
-
	LDA MOCK_DIR1, X
	STA DIRLOAD, X
	INX
	CPX #(MOCK_DIR2-MOCK_DIR1)
	BNE -
	LDA #$05        ; BORDER = GREEN (visual indicator)
	STA $D020
	RTS

SETDIR2
	LDX #$00
-
	LDA MOCK_DIR2, X
	STA DIRLOAD, X
	INX
	CPX #(MOCK_DIR3-MOCK_DIR2)
	BNE -
	RTS

SETDIR3
	LDX #$00
-
	LDA MOCK_DIR3, X
	STA DIRLOAD, X
	INX
	CPX #(MOCK_DIR3_END-MOCK_DIR3)
	BNE -
	RTS

; ------------------------------------------------------------
; MOCK_GetCurrentPath
;   Mirrors what IRQ_GetCurrentPath (COMMAND_GET_PATH) delivers.
;   Copies MOCK_CURRENT_PATH (64 bytes) into PATHBUFFER.
;   Carry: always clear on return.
; ------------------------------------------------------------
MOCK_GetCurrentPath
	LDX #0
_mgcp_copy
	LDA MOCK_CURRENT_PATH, X
	STA PATHBUFFER, X
	INX
	CPX #64
	BNE _mgcp_copy
	CLC
	RTS

; ------------------------------------------------------------
; MOCK_GoBack
;   Called before JSR GOBACK (replaces DIRLEVEL decrement block).
;   Decrements DIRLEVEL (with underflow protection), then truncates
;   MOCK_CURRENT_PATH to its parent, mirroring Arduino's GoBack().
;   "/games/demos" → "/games",  "/games" → "/"
; ------------------------------------------------------------
MOCK_GoBack
	; 1. Decrement DIRLEVEL, protect from underflow
	LDA DIRLEVEL
	BEQ _mgb_path
	DEC DIRLEVEL
_mgb_path
	; 2. Find last '/' in MOCK_CURRENT_PATH
	LDY #0
	LDX #0				; X = position of last '/'
_mgb_scan
	LDA MOCK_CURRENT_PATH, Y
	BEQ _mgb_truncate
	CMP #$2F			; '/'
	BNE _mgb_next
	TYA
	TAX				; X = position of this '/'
_mgb_next
	INY
	BNE _mgb_scan
_mgb_truncate
	; X == 0 → parent is root: null-terminate at pos 1 → "/"
	; X > 0 → null-terminate at pos X → parent path
	CPX #0
	BNE _mgb_not_root
	INX				; X = 1
_mgb_not_root
	LDA #0
	STA MOCK_CURRENT_PATH, X
	RTS

; ------------------------------------------------------------
; MOCK_PrgExecute
;   Tail-jumped from PROGRAM (replaces block 10 .else)
;   Copies mock PRG to $C000, patches JMP target, executes it.
;   The mock PRG writes sentinels then JMPs back to INPUT_GET.
; ------------------------------------------------------------
MOCK_PrgExecute
	; Mark that PROGRAM path was reached
	LDA #$01
	STA DEBUG_PRG_REACHED

	; Copy mock PRG code to $C000
	LDX #0
_mpe_copy
	LDA MOCK_PRG_CODE, X
	STA $C000, X
	INX
	CPX #MOCK_PRG_CODE_SIZE
	BNE _mpe_copy

	; Patch JMP target with actual INPUT_GET address
	LDA #<INPUT_GET
	STA $C000 + MOCK_PRG_JMP_OFFSET
	LDA #>INPUT_GET
	STA $C000 + MOCK_PRG_JMP_OFFSET + 1

	JSR IRQ_EnableDisplay
	JMP $C000		; execute mock PRG

; ============================================================
; MOCK DATA
; ============================================================
; Simulates Arduino HandleReadDirectory wire protocol.
;
; Wire format (must match Arduino CartApi.cpp exactly):
;   Byte 0:    CURPAGEITEMS (number of entries on this page)
;   Byte 1:    PAGECOUNT (total pages, always 1 here)
;   Byte 2+:   32-byte entries:
;              Bytes 0-30:  ASCII filename, null-padded
;              Byte 31:     $04 = directory, $00 = file
;
; Directory flag trick: .enc "screen" + .TEXT "D" = $04
; Filenames are ASCII (.TEXT default), converted to screen
; codes by PRINTASCIIFILENAME at display time.
;
; Mock SD card layout:
;   /                        (MOCK_DIR1 — root)
;   +-- games/               directory
;   +-- giana.prg            PRG program
;   +-- wizball.prg          PRG program
;   +-- sunset.koa           Koala image  -> /PLUGINS/KOAPLUGIN.BIN
;   +-- logo.petg            PETSCII art  -> /PLUGINS/PETGPLUGIN.BIN
;
;   /games/                  (MOCK_DIR2 — level 1)
;   +-- ..                   parent
;   +-- demos/               directory
;   +-- music/               directory
;   +-- bubble.prg           PRG program
;   +-- ocean.koa            Koala image
;   +-- intro.petg           PETSCII art
;
;   /games/demos/            (MOCK_DIR3 — level 2)
;   +-- ..                   parent
;   +-- tools/               directory
;   +-- matrix.prg           PRG program
;   +-- space.koa            Koala image
;   +-- ascii.petg           PETSCII art
;   +-- coder.wav            WAV audio    -> /PLUGINS/WAVPLUGIN.BIN
; ============================================================

DIRLEVEL	.BYTE 0

; Live path buffer — mirrors Arduino's currentPath.
; Format: "/" (root) or "/games" or "/games/demos" — no trailing slash except root.
; Updated by MOCK_EnterDir and MOCK_GoBack.
MOCK_CURRENT_PATH	.BYTE $2F		; '/' — initialized to root
			.FILL 64, 0		; null terminator + 63 zeros

; --- Root directory (DIRLEVEL=0) — 5 entries -----------------
MOCK_DIR1
	.BYTE 5             ; CURPAGEITEMS
	.BYTE 1             ; PAGECOUNT
	;-- entry 0: "games" (directory) --
	.TEXT "games"
	.FILL 26, 0
.enc "screen"
	.TEXT "D"           ; $04 = directory
.enc "none"
	;-- entry 1: "giana.prg" (PRG file) --
	.TEXT "giana.prg"
	.FILL 23, 0         ; byte 31 = $00 = file
	;-- entry 2: "wizball.prg" (PRG file) --
	.TEXT "wizball.prg"
	.FILL 21, 0
	;-- entry 3: "sunset.koa" (Koala image) --
	.TEXT "sunset.koa"
	.FILL 22, 0
	;-- entry 4: "logo.petg" (PETSCII art) --
	.TEXT "logo.petg"
	.FILL 23, 0

; --- /games/ (DIRLEVEL=1) — 6 entries -----------------------
MOCK_DIR2
	.BYTE 6             ; CURPAGEITEMS
	.BYTE 1             ; PAGECOUNT
	;-- entry 0: ".." (parent directory) --
	.TEXT ".."
	.FILL 29, 0
.enc "screen"
	.TEXT "D"           ; $04 = directory
.enc "none"
	;-- entry 1: "demos" (directory) --
	.TEXT "demos"
	.FILL 26, 0
.enc "screen"
	.TEXT "D"           ; $04 = directory
.enc "none"
	;-- entry 2: "music" (directory) --
	.TEXT "music"
	.FILL 26, 0
.enc "screen"
	.TEXT "D"           ; $04 = directory
.enc "none"
	;-- entry 3: "bubble.prg" (PRG file) --
	.TEXT "bubble.prg"
	.FILL 22, 0
	;-- entry 4: "ocean.koa" (Koala image) --
	.TEXT "ocean.koa"
	.FILL 23, 0
	;-- entry 5: "intro.petg" (PETSCII art) --
	.TEXT "intro.petg"
	.FILL 22, 0

; --- /games/demos/ (DIRLEVEL=2) — 6 entries -----------------
MOCK_DIR3
	.BYTE 6             ; CURPAGEITEMS
	.BYTE 1             ; PAGECOUNT
	;-- entry 0: ".." (parent directory) --
	.TEXT ".."
	.FILL 29, 0
.enc "screen"
	.TEXT "D"           ; $04 = directory
.enc "none"
	;-- entry 1: "tools" (directory) --
	.TEXT "tools"
	.FILL 26, 0
.enc "screen"
	.TEXT "D"           ; $04 = directory
.enc "none"
	;-- entry 2: "matrix.prg" (PRG file) --
	.TEXT "matrix.prg"
	.FILL 22, 0
	;-- entry 3: "space.koa" (Koala image) --
	.TEXT "space.koa"
	.FILL 23, 0
	;-- entry 4: "ascii.petg" (PETSCII art) --
	.TEXT "ascii.petg"
	.FILL 22, 0
	;-- entry 5: "coder.wav" (WAV audio) --
	.TEXT "coder.wav"
	.FILL 23, 0

MOCK_DIR3_END

; --- Mock PRG program (loaded to $C000, returns to menu) ---
MOCK_PRG_CODE
	LDA #$42		; sentinel value 1
	STA DEBUG_PRG_EXECUTED	; $CF51
	LDA #$DE		; sentinel value 2
	STA DEBUG_PRG_SENTINEL	; $CF52
	JMP $0000		; placeholder — patched to INPUT_GET at runtime
MOCK_PRG_CODE_END
MOCK_PRG_CODE_SIZE = MOCK_PRG_CODE_END - MOCK_PRG_CODE
MOCK_PRG_JMP_OFFSET = MOCK_PRG_CODE_END - MOCK_PRG_CODE - 2
