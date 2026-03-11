; EasySDMenuMock.s — DEBUG=1 mock implementation
; Included from EasySDMenu.s only when DEBUG=1.
; No .if DEBUG blocks inside — the conditional is in the parent.
;
; Replaces Arduino SD card communication with hardcoded directory data
; (MOCK_DIR1/2/3) for VICE emulator testing.
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
;   Increments DIRLEVEL, caps at 2 (MOCK_DIR1..DIR3 only)
; ------------------------------------------------------------
MOCK_EnterDir
	INC DIRLEVEL
	; DEBUG mock supports DIRLEVEL 0..2 only (MOCK_DIR1..DIR3)
	LDA DIRLEVEL
	CMP #3
	BCC +
	LDA #2
	STA DIRLEVEL
+
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
; MOCK_SetDirname
;   Called from PRINTDIRHEADER (replaces block 14 .else)
;   Convention:
;     Carry SET   → root case fully handled (writes "ROOT" chars,
;                   sets Y=4); caller JMPs to _pdh_done_copy
;     Carry CLEAR → subdir case; NAMELOW/NAMEHIGH set to dirname;
;                   caller falls through to _pdh_copy
; ------------------------------------------------------------
MOCK_SetDirname
	LDA DIRLEVEL
	BNE _msd_sub
	; Root: write "ROOT" reversed at $042D-$0430
	LDA #$D2		; R ($52|$80)
	STA $042D
	LDA #$CF		; O ($4F|$80)
	STA $042E
	LDA #$CF		; O
	STA $042F
	LDA #$D4		; T ($54|$80)
	STA $0430
	LDY #$04		; Y=4 → place ─■ at col 9-10
	SEC			; carry set = root handled
	RTS
_msd_sub
	CMP #1
	BNE _msd_l2
	LDA #<MOCK_DIRNAME_L1
	STA NAMELOW
	LDA #>MOCK_DIRNAME_L1
	STA NAMEHIGH
	CLC			; carry clear = subdir, fall through to copy loop
	RTS
_msd_l2
	LDA #<MOCK_DIRNAME_L2
	STA NAMELOW
	LDA #>MOCK_DIRNAME_L2
	STA NAMEHIGH
	CLC
	RTS

; ------------------------------------------------------------
; MOCK_PrepareFilePath
;   Tail-jumped from PrepareFileNameParameter (replaces block 15 .else)
;   Builds mock absolute path: DIRLEVEL=0→"/file",
;   DIRLEVEL=1→"/games/file", DIRLEVEL=2→"/games/demos/file"
;   Output: PATHBUFFER = null-terminated absolute path
;   Carry: always clear on return
; ------------------------------------------------------------
MOCK_PrepareFilePath
	LDA NAMESLO, X
	STA NAMELOW
	LDA NAMESHI, X
	STA NAMEHIGH
	; Select path prefix pointer into $08/$09
	LDA DIRLEVEL
	BNE _mpfp_notroot
	LDA #<MOCK_PATH_L0
	STA $08
	LDA #>MOCK_PATH_L0
	STA $09
	JMP _mpfp_copy_prefix
_mpfp_notroot
	CMP #1
	BNE _mpfp_l2
	LDA #<MOCK_PATH_L1
	STA $08
	LDA #>MOCK_PATH_L1
	STA $09
	JMP _mpfp_copy_prefix
_mpfp_l2
	LDA #<MOCK_PATH_L2
	STA $08
	LDA #>MOCK_PATH_L2
	STA $09
_mpfp_copy_prefix
	; Copy prefix ($08/$09) → PATHBUFFER; Y = null position = prefix length
	LDY #0
_mpfp_pfx_loop
	LDA ($08), Y
	STA PATHBUFFER, Y
	BEQ _mpfp_pfx_done
	INY
	BNE _mpfp_pfx_loop
_mpfp_pfx_done
	; Y = prefix length (position of null in PATHBUFFER)
	; Set $09/$0A = PATHBUFFER + Y (start of filename write position)
	TYA
	CLC
	ADC #<PATHBUFFER
	STA $09
	LDA #>PATHBUFFER
	ADC #0
	STA $0A
	; Append filename from (NAMELOW/NAMEHIGH) into ($09/$0A)
	LDY #0
_mpfp_fname_loop
	LDA (NAMELOW), Y
	BEQ _mpfp_null_term
	STA ($09), Y
	INY
	CPY #MAXFILENAMELENGTH
	BNE _mpfp_fname_loop
_mpfp_null_term
	LDA #0
	STA ($09), Y			; null-terminate
	CLC
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

; Mock directory names for PRINTDIRHEADER debug display
MOCK_DIRNAME_L1		.TEXT "games"
			.BYTE 0
MOCK_DIRNAME_L2		.TEXT "demos"
			.BYTE 0

; Path prefixes for PrepareFileNameParameter debug mode
MOCK_PATH_L0		.TEXT "/"
			.BYTE 0
MOCK_PATH_L1		.TEXT "/games/"
			.BYTE 0
MOCK_PATH_L2		.TEXT "/games/demos/"
			.BYTE 0

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
