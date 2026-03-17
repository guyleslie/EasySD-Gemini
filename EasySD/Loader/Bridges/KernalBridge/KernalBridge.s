;================================================================================
; KERNALBRIDGE - C64 KERNAL I/O -> EasySD Bridge
;================================================================================
;
; PURPOSE:
;   Provides KERNAL-compatible file I/O for unmodified BASIC programs.
;   Intercepts device 8 file operations and routes them through EasySD API.
;
; WHAT THIS IS:
;   - A KERNAL vector replacement bridge
;   - Enables BASIC OPEN/CLOSE/GET# to work with the EasySD cartridge
;   - Launched by the menu system before jumping to the BASIC program
;
; WHAT THIS IS NOT:
;   - NOT a menu plugin (never invoked by user selection)
;   - NOT a standalone loader (requires BASIC environment)
;   - NOT a general-purpose PRG loader (use LoadFileBySize API instead)
;
; LIFECYCLE:
;   1. Menu loads this code to $C000
;   2. Menu loads the target PRG file using EasySD API
;   3. This code replaces KERNAL vectors (OPEN, CLOSE, CHKIN, CHRIN, CLRCHN)
;   4. Control jumps to the loaded PRG (BASIC program starts)
;   5. BASIC program file I/O is intercepted and routed to EasySD
;   6. On exit, vectors remain patched (one-way compatibility layer)
;
; PROTOCOL INVARIANTS:
;   - ALL file operations MUST be wrapped in PROT_StartTalking/PROT_EndTalking
;   - Error paths MUST call PROT_EndTalking before returning
;   - Protocol state leak will corrupt subsequent operations
;
; ENTRY POINT:
;   $C000: JMP MAIN (initial PRG load and launch)
;
; KNOWN LIMITATIONS:
;   - Sequential files only (no relative files)
;   - Device 8 only (other devices fall through to original KERNAL)
;
; DEPENDENCIES:
;   - CartLibHi.s, DebugMacros.s (via ../../ relative to Loader/)
;
; VERSION HISTORY:
;   - 2018-08-26: Initial version (I.R.on, Istanbul)
;   - 2026-01-01: Protocol state leak fixes (Sprint 11 post-audit)
;================================================================================


.enc "screen"

; --- KernalBridge Constants ---
FAT_FILE_LENGTH_INDEX = 28
LOAD_START_LO         = $AE
LOAD_START_HI         = $AF

; DEBUG mode - defined from command line (-D DEBUG=1 or -D DEBUG=0)
; Load DEBUG macros BEFORE first use
.include "../../DebugMacros.s"
.include "../../APIMacros.s"


EQ16	.macro
	LDA #<\1
	CMP #<\2
	BNE +
	LDA #>(\1 + 1)
	CMP #>(\2 + 1)
+
	.endm

INC16	.macro
	INC \1
	BNE +
	INC \1 + 1
+
	.endm

ADD16	.macro
	CLC
	LDA \1
	ADC \2
	STA \3
	LDA \1 + 1
	ADC \2 + 1
	STA \3 + 1
	.endm


	*=$C000
	JMP MAIN

;-----------------------------------------------
; Phase 3 data tables at $C003 (KernalBridge gap, always-accessible RAM).
; Placed here rather than after variables because the variable section overflows
; into $D000+ I/O space, making reads from there unreliable on real hardware.
;-----------------------------------------------

P3_TAIL_CODE
	; 39 bytes: copy TAIL_BUF ($03BB-$03C0) → $FFFA-$FFFF, then jump to Launcher
	.BYTE $AD, $BB, $03, $8D, $FA, $FF  ; LDA $03BB : STA $FFFA
	.BYTE $AD, $BC, $03, $8D, $FB, $FF  ; LDA $03BC : STA $FFFB
	.BYTE $AD, $BD, $03, $8D, $FC, $FF  ; LDA $03BD : STA $FFFC
	.BYTE $AD, $BE, $03, $8D, $FD, $FF  ; LDA $03BE : STA $FFFD
	.BYTE $AD, $BF, $03, $8D, $FE, $FF  ; LDA $03BF : STA $FFFE
	.BYTE $AD, $C0, $03, $8D, $FF, $FF  ; LDA $03C0 : STA $FFFF
	.BYTE $4C, $34, $03                 ; JMP $0334  (Launcher)

P3_HANDLER
	; 52-byte NMI handler (installed at $036A).
	; X = pages remaining (NMI page counter); Y = byte index within page.
	; For non-last pages (X > 1): behaves identically to CartLib.s TransferHandler.
	; For last page (X = 1), Y >= $FA: saves byte to TAIL_BUF[$03BB + Y-$FA] instead
	; of writing to $FFFA+, preventing corruption of the active NMI vector.
	;
	; Offsets (relative to $036A):
	;  +0  AD AB 80   LDA $80AB          read byte from cartridge
	;  +3  E0 01      CPX #$01           last page?
	;  +5  F0 11      BEQ +17 → +24      yes → .phase3
	;  +7  91 6C      STA ($6C),Y        no  → normal write
	;  +9  C8         INY
	;  +10 F0 01      BEQ +1  → +13      end of page? → .endofblock
	;  +12 40         RTI
	;  +13 E6 6D      INC $6D            .endofblock: advance target page
	;  +15 CA         DEX                pages remaining--
	;  +16 F0 01      BEQ +1  → +19      all pages done? → .endoftransfer
	;  +18 40         RTI
	;  +19 A9 64      LDA #$64           .endoftransfer: signal done
	;  +21 85 64      STA $64            ZP_IRQ_STATE_WAITHANDLE = $64
	;  +23 40         RTI
	;  +24 C0 FA      CPY #$FA           .phase3: tail region? (Y >= $FA)
	;  +26 B0 04      BCS +4  → +32      yes → .save_tail
	;  +28 91 6C      STA ($6C),Y        no  → normal write ($FF00-$FFF9)
	;  +30 C8         INY
	;  +31 40         RTI
	;  +32 84 77      STY $77            .save_tail: preserve Y
	;  +34 AA         TAX                preserve byte in X
	;  +35 98         TYA
	;  +36 38         SEC
	;  +37 E9 FA      SBC #$FA           compute TAIL_BUF offset (0..5)
	;  +39 A8         TAY
	;  +40 8A         TXA                restore byte
	;  +41 99 BB 03   STA $03BB,Y        save to TAIL_BUF
	;  +44 A4 77      LDY $77            restore Y
	;  +46 A2 01      LDX #$01           restore X (still last page)
	;  +48 C8         INY                advance byte counter
	;  +49 F0 DA      BEQ -38 → +13      Y wrapped ($FF→$00)? → .endofblock
	;  +51 40         RTI
	.BYTE $AD, $AB, $80  ; +0  LDA $80AB
	.BYTE $E0, $01       ; +3  CPX #$01
	.BYTE $F0, $11       ; +5  BEQ +17 → .phase3
	.BYTE $91, $6C       ; +7  STA ($6C),Y
	.BYTE $C8            ; +9  INY
	.BYTE $F0, $01       ; +10 BEQ +1  → .endofblock
	.BYTE $40            ; +12 RTI
	.BYTE $E6, $6D       ; +13 INC $6D            (.endofblock)
	.BYTE $CA            ; +15 DEX
	.BYTE $F0, $01       ; +16 BEQ +1  → .endoftransfer
	.BYTE $40            ; +18 RTI
	.BYTE $A9, $64       ; +19 LDA #$64           (.endoftransfer)
	.BYTE $85, $64       ; +21 STA $64
	.BYTE $40            ; +23 RTI
	.BYTE $C0, $FA       ; +24 CPY #$FA           (.phase3)
	.BYTE $B0, $04       ; +26 BCS +4  → .save_tail
	.BYTE $91, $6C       ; +28 STA ($6C),Y
	.BYTE $C8            ; +30 INY
	.BYTE $40            ; +31 RTI
	.BYTE $84, $77       ; +32 STY $77            (.save_tail)
	.BYTE $AA            ; +34 TAX
	.BYTE $98            ; +35 TYA
	.BYTE $38            ; +36 SEC
	.BYTE $E9, $FA       ; +37 SBC #$FA
	.BYTE $A8            ; +39 TAY
	.BYTE $8A            ; +40 TXA
	.BYTE $99, $BB, $03  ; +41 STA $03BB,Y
	.BYTE $A4, $77       ; +44 LDY $77
	.BYTE $A2, $01       ; +46 LDX #$01
	.BYTE $C8            ; +48 INY
	.BYTE $F0, $DA       ; +49 BEQ -38 → .endofblock
	.BYTE $40            ; +51 RTI

;-----------------------------------------------
; Data variables in KernalBridge gap ($C060–$C17D).
; MUST stay below $D000: reads from $D000+ on real hardware
; return VIC-II register values instead of RAM content.
;-----------------------------------------------
	*=$C060

HEXTOSCREEN
	.BYTE 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 1, 2, 3, 4, 5, 6

GENERALBUFFER
	.FILL 256

; Attributes of launched initial program file
FILELENGTH16BIT
FILELENGTH
	.FILL 4

STARTADDRESS
STARTADDRESSLO
	.BYTE 0
STARTADDRESSHI
	.BYTE 0

ENDADDRESS
ENDADDRESSLO
	.BYTE 0
ENDADDRESSHI
	.BYTE 0

; Attributes of opened files
OPENEDFILELENGTH16BIT
OPENEDFILELENGTH
	.FILL 4

FILEINDEX
FILEINDEXLOW
	.FILL 1
FILEINDEXHIGH
	.FILL 1

	*=$C700
MAIN
	JSR INIT		;Clears screen, disables interrupts.

;Lets try to open a file
	PRINTSTATUSANDWAIT OPENINGFILE, 100
	JSR PROT_DisableDisplay
	; CRITICAL: Start protocol session - MUST call PROT_EndTalking on ALL exit paths
	JSR PROT_StartTalking
	#OPENFILE FILE_PATH_BUF, #31, #01
	BCC OPENINGCONT
	JMP MAIN_ERROR_EXIT
OPENINGCONT
	JSR PROT_EnableDisplay

	PRINTSTATUSANDWAIT OPENINGSUCCESS, 200

	#SETADDR GENERALBUFFER, ZP_IRQ_API_DATA_LO

	JSR PROT_DisableDisplay

	LDY #$00
	JSR PROT_GetInfoForFile
	JSR ERROR_GATE

	#EXTRACTFILESIZE GENERALBUFFER, FILELENGTH

	DELAYFRAMES 2

	; === Refactored PRG Loading Logic (using LoadFileBySize) ===
	; Step 1: Read first page to get PRG load address
	#SETADDR GENERALBUFFER, ZP_IRQ_API_DATA_LO
	LDA #1
	STA ZP_IRQ_API_DATA_LENGTH
	JSR PROT_ReadFileNoCallback
	JSR ERROR_GATE
	DELAYFRAMES 2

	; Step 2: Parse load address from header
	LDA GENERALBUFFER
	STA STARTADDRESSLO
	STA ZP_IRQ_API_DATA_LO
	LDA GENERALBUFFER + 1
	STA STARTADDRESSHI
	STA ZP_IRQ_API_DATA_HI

	; Compute ENDADDRESS early (STARTADDR + FILELENGTH) before branching
	ADD16 STARTADDRESS, FILELENGTH16BIT, ENDADDRESS

	; P2TK detection: data reaches $C000+ iff ENDADDRESS > $C002
	; (last data byte = ENDADDRESS - 3; P2TK needed iff ENDADDRESS - 3 >= $C000)
	LDA ENDADDRESSHI
	CMP #$C0
	BCC NORMAL_LOAD        ; hi < $C0: definitely normal path
	BNE p2tk_trigger       ; hi > $C0: P2TK needed
	; hi == $C0: check lo ($C000/$C001/$C002 have no data at $C000+)
	LDA ENDADDRESSLO
	CMP #$03
	BCC NORMAL_LOAD
p2tk_trigger:
	JMP DO_P2TK            ; two-phase load path

NORMAL_LOAD:
	; Step 3: Setup parameters for LoadFileBySize
	; Copy 32-bit file size from local FILELENGTH to ZP locations
	LDA FILELENGTH
	STA ZP_LOADFILE_API_SIZE0
	LDA FILELENGTH + 1
	STA ZP_LOADFILE_API_SIZE1
	LDA FILELENGTH + 2
	STA ZP_LOADFILE_API_SIZE2
	LDA FILELENGTH + 3
	STA ZP_LOADFILE_API_SIZE3

	; Set skip bytes for PRG header
	LDA #2
	STA ZP_LOADFILE_API_SKIP_LO
	LDA #0
	STA ZP_LOADFILE_API_SKIP_HI

	; Step 4: Call the centralized loader
	JSR LoadFileBySize
	JSR ERROR_GATE

	; (ENDADDRESS already computed above)

RESUMEFULLLOAD
	DELAYFRAMES  2
	#CLOSEFILE
	JSR ERROR_GATE

	JSR PROT_EndTalking
	JSR ERROR_GATE

	; Now we need to change the kernal vectors and launch the program.
	; GET BACK HERE - GET BACK HERE - GET BACK HERE

	STX $D016					; Turn on VIC for PAL / NTSC check
	JSR $FDA3					; IOINIT - Init CIA chips
	;JSR $FD50					; RANTAM - Clear/test system RAM
	;JSR ALTRANTAM				        ; Metallic's fast alternative to RANTAM
	JSR $FD15					; RESTOR - Init KERNAL RAM vectors
	JSR $FF5B					; CINT   - Init VIC and screen editor
	JSR SETVECTORS
	CLI							; Re-enable IRQ interrupts

;	BASIC RESET  Routine

	JSR $E453					; Init BASIC RAM vectors
	JSR $E3BF					; Main BASIC RAM Init routine
	JSR $E422					; Power-up message / NEW command
	LDX #$FB
	TXS


	LDY ENDADDRESSLO
	STY $2D
	STY $2F
	STY LOAD_START_LO
	LDA ENDADDRESSHI
	STA $2E
	STA $30
	STA LOAD_START_HI

	JSR CLEANUP

	LDA #$37					;Restore default memory layout
	STA $01

	JSR PROT_EnableDisplay

	LDA #$08					;Initialize current device number as 8
	STA $BA

	LDA #$81					;%10000001 ; Enable CIA interrupts
	STA $DC0D

	JMP $0840

LAUNCH
	LDA #$08
	CMP STARTADDRESSHI
	BNE MACHINELANG
	LDA STARTADDRESSLO
	CMP #$01
	BNE MACHINELANG

	JSR $A659 ;"CLR"
	JMP $A7AE ;"RUN"

MACHINELANG
	LDA STARTADDRESSLO
	STA $FB
	LDA STARTADDRESSHI
	STA $FC
	JMP ($00FB)				        ; Leave control to loaded stuff




; --------------------------------------------------
; Error Gate: Carry set -> fatal error
; Centralized error handling - prevents branch distance issues
; --------------------------------------------------
ERROR_GATE
	BCC +
	JMP EXITFAIL
+
	RTS


INPUT_GET
	JSR SCNKEY		                        ; Call kernal's key scan routine
 	JSR GETIN					; Get the pressed key by the kernal routine
  	BEQ INPUT_GET					; If zero then no key is pressed so repeat

; --------------------------------------------------
; MAIN_ERROR_EXIT: Cleanup handler for MAIN section errors
; Ensures PROT_EndTalking is called before error exit
; --------------------------------------------------
MAIN_ERROR_EXIT
	JSR PROT_EndTalking	; CRITICAL: Cleanup protocol session
	; Fall through to EXITFAIL

EXITFAIL
.if DEBUG = 1
	LDA #$02
	STA DEBUG_ERROR_CODE				; Store error code for debugging
.endif
	LDA #$02
	STA BORDER
	JSR PROT_EnableDisplay

	JMP INPUT_GET


CLEANUP
	; Restore nmi vector
	LDA #<DEFAULT_NMI_HANDLER
	STA NMI_LO
	LDA #>DEFAULT_NMI_HANDLER
	STA NMI_HI

	RTS

SETVECTORS
	LDA #<NEW_CHRIN
	STA V_CHRIN
	LDA #>NEW_CHRIN
	STA V_CHRIN	+ 1

	LDA #<NEW_OPEN
	STA V_OPEN
	LDA #>NEW_OPEN
	STA V_OPEN 	+ 1

	LDA #<NEW_CLOSE
	STA V_CLOSE
	LDA #>NEW_CLOSE
	STA V_CLOSE + 1

	LDA #<NEW_CHKIN
	STA V_CHKIN
	LDA #>NEW_CHKIN
	STA V_CHKIN + 1

	LDA #<NEW_CLRCHN
	STA V_CLRCHN
	LDA #>NEW_CLRCHN
	STA V_CLRCHN + 1
	RTS


INIT							; Input : None, Changed : A
	CLD
	LDA #$93
	JSR CHROUT
;	LDA #$00
;	STA $D020
;	LDA #$0B
;	STA $D021

	JSR DISABLEINTERRUPTS
	JSR KILLCIA

	RTS

KILLCIA
	;LDA #$00
	;STA ISMUSICPLAYING
	LDY #$7f    ; $7f = %01111111
    STY $dc0d   ; Turn off CIAs Timer interrupts
    STY $dd0d   ; Turn off CIAs Timer interrupts
    LDA $dc0d   ; cancel all CIA-IRQs in queue/unprocessed
    LDA $dd0d   ; cancel all CIA-IRQs in queue/unprocessed
	RTS

DISABLEINTERRUPTS
    LDY #$7f    					; $7f = %01111111
    STY $dc0d   					; Turn off CIAs Timer interrupts
    STY $dd0d  						; Turn off CIAs Timer interrupts
    LDA $dc0d  						; cancel all CIA-IRQs in queue/unprocessed
    LDA $dd0d   					; cancel all CIA-IRQs in queue/unprocessed


; 	Change interrupt routines
	ASL $D019
	LDA #$00
	STA $D01A
	RTS

DISABLEDISPLAY
	LDA #$0B					;%00001011 ; Disable VIC display until the end of transfer
	STA $D011
	RTS

ENABLEDISPLAY
	LDA #$3B
	STA $D011
	RTS

WAITFRAMES
FD
	LDY #$90
-
	CPY $D012
	BNE -
	LDY #50
-
	DEY
	BNE -

	DEX
	BNE FD
	RTS


;================================================================================
; DO_P2TK — Phase 2 Transfer Kernel
;
; Two-phase loader for machine-code PRGs whose payload extends into $C000+.
; KernalBridge lives at $C000-$CFFF; a normal single-phase load would overwrite
; the running code.  P2TK solves this by:
;   Phase 1 — load STARTADDR..$BFFF using the normal LoadFileBySize path
;   Phase 2 — relocate the NMI wait loop to an 8-byte stub at $033B (FILE_PATH_BUF area),
;             switch to $01=$34 (all RAM — I/O hidden, $D000-$FFFF writable as RAM),
;             and let TransferHandler at $80AF fill $C000+ via NMI pulses.
;   Phase 3 — if Phase2_pages = 64 (data fills $FF00-$FFFF), swap in a special NMI
;             handler (P3_HANDLER at $036A) that intercepts tail bytes $FFFA-$FFFF and
;             saves them to TAIL_BUF ($03BB-$03C0) to prevent mid-transfer corruption
;             of the active NMI vector. After transfer, P3_TAIL_CODE ($0343) copies
;             TAIL_BUF → $FFFA-$FFFF and falls through to Launcher.
;
; Entry conditions:
;   ENDADDRESS > $C002 (guaranteed by caller)
;   ZP_IRQ_API_DATA_LO/HI = STARTADDRESSLO/HI (set at "Step 2: Parse load address")
;   Active PROT_StartTalking session; file open, position at start of data.
;
; Exit (normal, <64 pages): JMP $033B → poll ZP_IRQ_STATE_WAITHANDLE → JMP $0334 (Launcher)
; Exit (Phase3, 64 pages): JMP $033B → poll → JMP $0343 (P3_TAIL_CODE) → copy $FFFA-$FFFF →
;                          JMP $0334 (Launcher) → LDA #$37 / STA $01 / JMP STARTADDR
;
; Note: CLOSEFILE / PROT_EndTalking are NOT called — intentional protocol leak.
;       The Arduino returns to SoftStartListening; all state resets on next C64
;       hardware reset.
;================================================================================
DO_P2TK:
	; --- Phase 1: Load STARTADDR .. ~$BFFF ---
	; SIZE = $C000 - STARTADDR  (payload = SIZE-2 fills STARTADDR..ceil boundary)
	SEC
	LDA #$00
	SBC STARTADDRESSLO
	STA ZP_LOADFILE_API_SIZE0
	LDA #$C0
	SBC STARTADDRESSHI
	STA ZP_LOADFILE_API_SIZE1
	LDA #0
	STA ZP_LOADFILE_API_SIZE2
	STA ZP_LOADFILE_API_SIZE3
	LDA #2
	STA ZP_LOADFILE_API_SKIP_LO
	LDA #0
	STA ZP_LOADFILE_API_SKIP_HI
	JSR LoadFileBySize
	JSR ERROR_GATE

	; --- Phase 2: Compute page count = ceil((ENDADDRESS - $C002) / 256) ---
	; ENDADDRESS - $C002 = number of data bytes that belong at $C000+
	SEC
	LDA ENDADDRESSLO
	SBC #$02
	TAX                          ; X = Phase2_bytes lo
	LDA ENDADDRESSHI
	SBC #$C0
	TAY                          ; Y = Phase2_bytes hi = floor page count
	TXA
	BEQ p2tk_no_partial
	INY                          ; round up for partial last page
p2tk_no_partial:
	; Y = Phase2_pages

	; Write P2TK wait-stub to $033B (FILE_PATH_BUF area — safe from Phase 1 and Phase 2)
	; Phase 2 writes $C000-$FEFF and would overwrite anything at $E000+, so the stub
	; MUST live below $C000.  The FILE_PATH_BUF area ($0334-$03FB) is safe as long as
	; STARTADDR >= $0800 (true for all BASIC and typical machine-code programs).
	; Byte values are identical to the old $E000 stub; relative BVC offset (-4) is
	; address-independent and the absolute JMP target ($0334) is unchanged.
	;   $033B: B8          CLV
	;   $033C: 24 64       BIT ZP_IRQ_STATE_WAITHANDLE
	;   $033E: 50 FC       BVC $033C   (loop)
	;   $0340: 4C 34 03    JMP $0334   (Launcher)
	LDA #$B8
	STA $033B                    ; CLV
	LDA #$24
	STA $033C                    ; BIT zp
	LDA #$64
	STA $033D                    ;   operand: ZP_IRQ_STATE_WAITHANDLE ($64)
	LDA #$50
	STA $033E                    ; BVC rel
	LDA #$FC
	STA $033F                    ;   offset: -4 -> loops back to BIT at $033C
	LDA #$4C
	STA $0340                    ; JMP abs
	LDA #$34
	STA $0341                    ;   lo: $0334
	LDA #$03
	STA $0342                    ;   hi: $0334

	; Write Launcher to $0334 (FILE_PATH_BUF area — safe at this stage, 7 bytes)
	; On invocation: restores normal memory map and jumps to PRG entry point
	LDA #$A9
	STA $0334                    ; LDA #imm
	LDA #$37
	STA $0335                    ;   $37 = PP_CONFIG_DEFAULT (KERNAL+BASIC visible)
	LDA #$85
	STA $0336                    ; STA zp
	LDA #$01
	STA $0337                    ;   $01 = PROCESSOR_PORT
	LDA #$4C
	STA $0338                    ; JMP abs
	LDA STARTADDRESSLO
	STA $0339                    ;   PRG entry point lo
	LDA STARTADDRESSHI
	STA $033A                    ;   PRG entry point hi

	; --- Phase 3: protection when Phase2_pages = 64 (last page fills $FF00-$FFFF) ---
	; Without protection, TransferHandler writes to $FFFA/$FFFB mid-transfer, corrupting
	; the active NMI vector before all bytes in that page are received → crash.
	; Fix: pre-copy P3_TAIL_CODE and P3_HANDLER to FILE_PATH_BUF area; change NMI vector
	; to P3_HANDLER ($036A) which saves $FFFA-$FFFF bytes to TAIL_BUF instead of writing
	; them directly; after transfer, P3_TAIL_CODE ($0343) restores those 6 bytes.
	CPY #$40
	BNE p2tk_normal_nmi

	; Copy P3_TAIL_CODE (39 bytes) → $0343
	LDX #38
-	LDA P3_TAIL_CODE, X
	STA $0343, X
	DEX
	BPL -

	; Copy P3_HANDLER (52 bytes) → $036A
	LDX #51
-	LDA P3_HANDLER, X
	STA $036A, X
	DEX
	BPL -

	; Override BVC loop JMP lo: $0341 ← $43 (target $0343 tail write, not $0334 Launcher)
	LDA #$43
	STA $0341

	; NMI vector → P3_HANDLER at $036A
	LDA #$6A
	STA $FFFA                    ; NMI vector lo = $6A
	LDA #$03
	STA $FFFB                    ; NMI vector hi = $03
	BNE p2tk_after_nmi           ; always branch (A=$03, Z=0)

p2tk_normal_nmi:
	; Write hardware NMI vector to RAM at $FFFA/$FFFB
	; (writes reach RAM regardless of $01 setting — HIRAM=0 doesn't block writes)
	LDA #<CARTRIDGENMIHANDLERX1
	STA $FFFA                    ; NMI vector lo = $AF
	LDA #>CARTRIDGENMIHANDLERX1
	STA $FFFB                    ; NMI vector hi = $80

p2tk_after_nmi:

	; Setup ZP for TransferHandler (same layout as PROT_ReceiveFragmentNoCallback)
	LDA #$00
	STA ZP_IRQ_STATE_WAITHANDLE  ; clear done flag ($64 = pending)
	STA ZP_IRQ_API_DATA_LO       ; target address lo = $00  -> $C000
	LDA #$C0
	STA ZP_IRQ_API_DATA_HI       ; target address hi = $C0
	STY ZP_IRQ_API_DATA_LENGTH   ; Phase2_pages (also used for LDX below)

	; Send COMMAND_READ_FILE for Phase 2 (inside the active PROT_StartTalking session)
	LDA #COMMAND_READ_FILE
	JSR PROT_Send
	TYA                          ; Y = Phase2_pages (PROT_Send preserves Y)
	JSR PROT_Send
	JSR PROT_WaitProcessing       ; wait for Arduino ACK (1 ms before streaming starts)

	; Load TransferHandler page counter, reset byte index, enter P2TK
	LDX ZP_IRQ_API_DATA_LENGTH   ; X = Phase2_pages (NMI handler page counter)
	LDY #0                       ; Y = byte index within current page
	CLV                          ; clear V so BVC loop enters correctly
	LDA #PP_CONFIG_ALL_RAM       ; $34: all RAM — I/O hidden, $D000-$FFFF writable as RAM
	STA $01
	JMP $033B                    ; enter P2TK wait-stub in FILE_PATH_BUF area — never returns here


TALK_STATUS
	.BYTE $00
TALK_DIRECTION
	.BYTE $00
TALK_FILE
	.BYTE $00
HAS_OPENED_FILE
	.BYTE $00


NEW_OPEN
	INC $D020
	LDA KERNAL_DEVICE_NUMBER
	CMP #08
	BEQ +
	JMP K_OPEN
+
	JSR PROT_DisableDisplay
	JSR PROT_StartTalking
	DELAYFRAMES 2
	; Load filename pointer from KERNAL zero page ($BB/$BC)
	; CRITICAL: Use zero page CONTENT, not ADDRESS
	LDX KERNAL_FILENAME_LOW
	LDY KERNAL_FILENAME_HIGH
	LDA KERNAL_FILENAME_LENGTH
	JSR PROT_SetName
	LDX #01		; Flags=read
	JSR PROT_OpenFile
	BCC OPEN_SUCCESS
	; CRITICAL: Cleanup protocol session on error
	JSR PROT_EndTalking
	LDA #128
	SEC
	JMP NEW_OPEN_FINISH
OPEN_SUCCESS
	DELAYFRAMES 2
	#GETFILEINFO GENERALBUFFER

	BCC +
	; CRITICAL: Cleanup protocol session on error
	JSR PROT_EndTalking
	LDA #128
	SEC
	JMP NEW_OPEN_FINISH
+
	DELAYFRAMES 2
	JSR PROT_EndTalking


	#EXTRACTFILESIZE GENERALBUFFER, OPENEDFILELENGTH


	LDA #0
	STA FILEINDEX
	STA FILEINDEX+1
	LDA #1
	STA HAS_OPENED_FILE
	EQ16 OPENEDFILELENGTH16BIT, 0
	BNE +
	LDA #64
	SEC
	JMP NEW_OPEN_FINISH
+
	CLC
	LDA #0
NEW_OPEN_FINISH
	STA KERNAL_STATUS
	JSR PROT_EnableDisplay

	RTS

NEW_CHKIN
	INC $D020
	LDA KERNAL_DEVICE_NUMBER
	CMP #08
	BEQ +
	JMP K_CHKIN
+
	STX TALK_FILE
	LDA #$00
	STA TALK_DIRECTION				; Program wants to read
	STA KERNAL_STATUS				; Clear status (success)
	CLC						; Clear carry (no error)
	RTS

NEW_CLOSE
	INC $D020
	LDA KERNAL_DEVICE_NUMBER
	CMP #08
	BEQ +
	JMP K_CLOSE
+
	JSR PROT_DisableDisplay

	JSR PROT_StartTalking

	DELAYFRAMES 2
	#CLOSEFILE
	BCC +
	; CRITICAL: Cleanup protocol session on error
	JSR PROT_EndTalking
	LDA #128
	STA KERNAL_STATUS
	SEC
	RTS
+
	DELAYFRAMES 2
	JSR PROT_EndTalking
	RTS

NEW_CLRCHN
	INC $D020
	LDA KERNAL_DEVICE_NUMBER
	CMP #08
	BEQ +
	JMP K_CLRCHN
+
	RTS

	;First chrin will be pulling 256 bytes from the micro
	;then it will serve the calling program from this buffer.
	;for the next 256 bytes it will call the micro again.
	;so this way calling program will be able to invoke other api functions like close and such.
NEW_CHRIN
	INC $D020
	LDA KERNAL_DEVICE_NUMBER
	CMP #08
	BEQ +
	JMP K_CHRIN
+
	; Check EOF: FILEINDEX == OPENEDFILELENGTH16BIT?
	; CRITICAL: Compare CONTENT, not ADDRESSES!
	LDA FILEINDEXLOW
	CMP OPENEDFILELENGTH
	BNE +						; Low bytes different, not EOF
	LDA FILEINDEXHIGH
	CMP OPENEDFILELENGTH+1
	BNE +						; High bytes different, not EOF
	; EOF reached - KERNAL convention
	LDA #$40					; EOF bit (bit 6 of STATUS)
	STA KERNAL_STATUS
	LDA #$00					; Return null byte (KERNAL EOF convention)
	CLC						; No error
	RTS
+
	LDA FILEINDEXLOW
	BNE +			;Read from already filled buffer

	JSR PROT_StartTalking
	DELAYFRAMES 2

	LDY #$00
	#SETADDR GENERALBUFFER, ZP_IRQ_API_DATA_LO
	LDA #1

	STA ZP_IRQ_API_DATA_LENGTH
	JSR PROT_ReadFileNoCallback
	BCC +						; If carry clear, success
	; Read error handling
	; CRITICAL: Cleanup protocol session on error
	JSR PROT_EndTalking
	LDA #128					; Read error flag
	STA KERNAL_STATUS
	SEC						; Set carry (error)
	RTS
+
	DELAYFRAMES 2
	JSR PROT_EndTalking
	BCC +						; Check EndTalking success
	; EndTalking error handling
	LDA #128					; Communication error flag
	STA KERNAL_STATUS
	SEC						; Set carry (error)
	RTS
+
	LDA #$00
	STA KERNAL_STATUS

	LDX FILEINDEXLOW
	LDA GENERALBUFFER, X
	TAY
	INC16 FILEINDEX
	TYA
	RTS




.include "../../CartLibStream.s"
.include "../../DebugStrings.s"

DUMPHEX	.macro
	; \1 -> source addresses
	; \2 -> dump destination
	; \3 -> length

	; Init self modified addresses
	LDA #<\1
	STA DATASOURCE+1

	LDA #<\2
	STA HNIBBLESTORE+1

	LDA #<\2 + 1
	STA LNIBBLESTORE+1

	LDA #>\1
	STA DATASOURCE+2
	LDA #>\2
	STA HNIBBLESTORE+2
	LDA #>\2
	STA LNIBBLESTORE+2

	LDY #0
-
DATASOURCE
	LDA \1,Y
	JSR GetHigh
HNIBBLESTORE
	STA \2

	LDA \1,Y
	JSR GetLow
LNIBBLESTORE
	STA \2 + 1

	INC16 HNIBBLESTORE+1
	INC16 HNIBBLESTORE+1
	INC16 LNIBBLESTORE+1
	INC16 LNIBBLESTORE+1
	INY
	CPY #\3
	BNE -
	.endm

	; X have first byte, 	Y have second byte
DisplayReceived
	DUMPHEX GENERALBUFFER, $0400, $00
	DUMPHEX GENERALBUFFER+256, $0700, $10

	RTS


GetHigh
	LSR
	LSR
	LSR
	LSR
	TAX
	LDA  HEXTOSCREEN, X
	RTS

GetLow
	AND #$0F
	TAX
	LDA  HEXTOSCREEN, X
	RTS

minikey:
	lda #$0
	sta $dc03					; port b ddr (input)
	lda #$ff
	sta $dc02					; port a ddr (output)

	lda #$00
	sta $dc00					; port a
	lda $dc01       				; port b
	cmp #$ff
	beq nokey
	; got column
	tay

	lda #$7f
	sta nokey2+1
	ldx #8
nokey2:
	lda #0
	sta $dc00					; port a

	sec
	ror nokey2+1
	dex
	bmi nokey

	lda $dc01       				; port b
	cmp #$ff
	beq nokey2

	; got row in X
	txa
	ora columntab,y
	sec
	rts

nokey:
	clc
	rts

columntab:
.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF
.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF
.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF
.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $70
.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF
.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $60
.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $50
.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $40,$FF, $FF, $FF, $FF, $FF, $FF, $FF, $30,$FF, $FF, $FF, $20,$FF, $10, $00, $FF

;-----------------------------------------------
; DEBUG Status Strings moved to DebugStrings.s
; (Common file shared across plugins)
;-----------------------------------------------