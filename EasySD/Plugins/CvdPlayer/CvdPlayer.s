; CvdPlayer — Bad Apple!! video player for EasySD / IRQHack64
; Original: 14/07/2016 - Istanbul
;
;==============================================================================
; CVD FORMAT SPECIFICATION
;==============================================================================
; CVD is a custom, C64-optimized video format designed for NMI-driven
; streaming via the EasySD cartridge. Each stream block is exactly 400 bytes,
; consumed as 50 fragments of 8 bytes via COMMAND_NI_STREAM (26). One complete
; logical video frame is 10 stream blocks = 4000 bytes.
;
; STREAM BLOCK LAYOUT (400 bytes, stored at TRANSFERBUFFER = $A000)
; ----------------------------------------------------------------
; Offset $000-$04F (80 bytes): Bitmap, first C64 char row, left 20 cells
; Offset $050-$09F (80 bytes): Bitmap, first C64 char row, right 20 cells
; Offset $0A0-$0EF (80 bytes): Bitmap, second C64 char row, left 20 cells
; Offset $0F0-$13F (80 bytes): Bitmap, second C64 char row, right 20 cells
; Offset $140-$167 (40 bytes): Screen color data for this logical row group
; Offset $168-$18F (40 bytes): D800 color data for this logical row group
;
; DISPLAY PARAMETERS
; ------------------
; Mode    : Multicolor bitmap (VIC-II, PAL)
; Resolution: 160×80 logical pixels, doubled by the player to 320×160
;             physical pixels (20 C64 character rows × 40 cells wide).
; Position: Starts at PICTUREROW=3 (screen row 3, approx Y=24 on PAL screen)
; Frame rate: 5 fps (1 video frame = 10 PAL raster frames = 10 CVD blocks)
; Throughput: 5 fps × 10 blocks/frame × 400 bytes = 20 KB/s from SD card
; Colors per cell (VIC-II multicolor bitmap):
;   00 = Background ($D021)
;   01 = Screen RAM high nibble ($0400/$4400)
;   10 = Screen RAM low nibble ($0400/$4400)
;   11 = Color RAM low nibble ($D800-$DBE7)
;
; VIDEO FRAME ASSEMBLY (10 consecutive CVD blocks = 1 complete video frame)
; Each CVD block updates one logical 160×8 row group and maps it to two
; physical C64 character rows by duplicating each bitmap byte vertically:
;   Block 0 → logical rows 0-7,   C64 character rows 0-1
;   Block 1 → logical rows 8-15,  C64 character rows 2-3
;   ...
;   Block 9 → logical rows 72-79, C64 character rows 18-19
; Blocks 0-9 fill bank B0, blocks 10-19 fill bank B1 (double-buffering).
; One bank displays while the other receives and decodes. No screen tearing
; because the NMI fires at STARTRASTER=241 (VBlank / vertical blanking period).
;
; MEMORY MAP
; ----------
; $2000-$3FFF  Bitmap bank 0 (VIDEO_B0)   — displayed while bank 1 decodes
; $4000-$418F  Color buffer (COLORBUFFER) — accumulates D800 data for 10 rows
; $4400-$47E8  Screen bank 1 (SCREEN_HI)
; $0400-$07E8  Screen bank 0 (SCREEN_LO)
; $6000-$7FFF  Bitmap bank 1 (VIDEO_B1)   — displayed while bank 0 decodes
; $A000-$A18F  Transfer buffer (TRANSFERBUFFER) — NMI pseudo-DMA target (400 B)
;
; STREAMING PIPELINE
; ------------------
; 1. C64 calls PROT_NIStream with A=50 (50 fragments × 8 bytes = 400 bytes/block)
; 2. Arduino enters HandleNonInterruptedStream(): disables all interrupts,
;    pre-loads two 400-byte SD buffers (double-buffering on Arduino side), then
;    streams bytes synchronised to IO2 strobes from C64 NMI handlers.
;    Streaming continues until EOF or an Arduino-side IO2 edge timeout.
; 3. NMI_000 fires at STARTRASTER=241 (VBlank) and performs a fully unrolled
;    400-byte read into $A000-$A18F. Protocol-wise this is still 50 fragments
;    of 8 bytes, matching COMMAND_NI_STREAM.
; 4. Foreground (FGStuff.s) decompresses the 400-byte block:
;    copies the 4 bitmap quadrants to the inactive bank, writes screen color
;    data, and accumulates D800 colors in COLORBUFFER for all 10 rows.
; 5. Playback stops when the CVD file is exhausted; Arduino exits the NI stream,
;    then the plugin closes the file/session and remains in a stable halt state.
;
; VIDEO FILE: path provided by the EasySD menu via FILE_PATH_BUF (null-terminated).
;   The user selects any .CVD file from the menu and presses Enter.
;   CVD converter: Tools/cvd_convert.py
;==============================================================================

INITIALWAITTIME = 150

STARTRASTER		= 241

BITTARGET = $64

FG_GATE = $FB

PICTUREROW = 3

TRANSFERBUFFER = $A000
FILEINFOBUFFER = TRANSFERBUFFER
COLORBUFFER = $4000

DELAYFRAMES	.macro
	LDX #\1
	JSR WAITFRAMES
	.endm

; Tier-2 API macros (#GETFILEINFO, #EXTRACTFILESIZE, etc.)
.include "../../Loader/APIMacros.s"

; 4-byte ZP counter: remaining bytes in CVD file.
; Decremented by 400 each block; underflow or exact zero triggers clean exit.
; Uses $8B-$8E (free per CartZpMap.inc).
CVD_SIZE = $8B

	*=$080E
	
	SAVESTATE
	
	JSR PROT_DisableDisplay
	JSR INIT				;Clears screen, disables interrupts.
	JSR PROT_StartTalking
	#LOADMEDIAPATH MEDIAPATH_BUF	; recover media path from $FF00 shadow
	.CHANGEBANK 2

	JSR INIT_GFX_MEM
	JSR SET_LO_COLOR
	JSR SET_HI_COLOR
	JSR SETMULTICOLOR

	LDA #$00
	STA $D01A
	STA $D015

	LDA #$35
	STA $01
	DELAYFRAMES 1

	LDA #$37
	STA $01
	LDX #<MEDIAPATH_BUF
	LDY #>MEDIAPATH_BUF
	JSR PROT_SetNameZ
	BCS ERROR_OPENING_FILE
	LDX #01		; Flags=read
	JSR PROT_OpenFile
	BCC +
	JMP ERROR_OPENING_FILE

+
	; Query file size for natural end-of-stream detection.
	; FILEINFOBUFFER aliases TRANSFERBUFFER ($A000); streaming not yet started.
	#GETFILEINFO FILEINFOBUFFER
	BCC +
	; GETFILEINFO failed: set counter to max ($FFFFFFFF).
	LDA #$FF
	STA CVD_SIZE
	STA CVD_SIZE+1
	STA CVD_SIZE+2
	STA CVD_SIZE+3
	JMP CVD_SIZE_READY
+	; $A000-$BFFF is hidden by BASIC ROM when $01=$37. The fileinfo bytes
	; were written to RAM, so expose RAM briefly while copying the size.
	LDA #$35
	STA $01
	#EXTRACTFILESIZE FILEINFOBUFFER, CVD_SIZE
	LDA #$37
	STA $01
CVD_SIZE_READY

	DELAYFRAMES 2
	LDA #50     ; 50 * 8 = 400 bytes per block
	JSR PROT_NIStream
	; Do NOT add a delay here: the AVR has already entered its IO2 busy-wait
	; loop by the time PROT_NIStream returns. Any extra delay shrinks the
	; budget the AVR has before its first-byte timeout fires and bails out
	; (DisableCartridge), leaving NMI_000 to read RAM garbage instead of
	; AVR-driven bytes — which manifests as a frozen grey bitmap.

ZIBIRT
	JSR ENABLEDISPLAY

	JSR PREPAREJMPTAB	
	
	LDA $d011                     ; clear high bit of raster line
	AND #$7f
	STA $d011		
	
	LDA #STARTRASTER
	STA $D012

	LDA #<SIMPLEHANDLER
	STA IRQ6502
	LDA #>SIMPLEHANDLER
	STA IRQ6502+1
		
	LDA #$35
	STA $01
	
	LDY #$00
	LDX #$00
	
	LDA #$00
	STA FG_GATE	
	
	LDA #$01
	STA $D01A	
	CLI

AGAIN	
	CLV
	
LOOP
	BIT FG_GATE
	BVS EXIT
	JMP LOOP

EXIT
	LDA #$37			
	STA $01	
	LDA #$01
	STA BORDER
	JSR NMI_000			; Do the transfer job
	LDA #$00
	STA BORDER	
		
	LDA #$00
	STA FG_GATE
	
	LDA #$35
	STA $01	
	
	DEC BORDER

	
	;
	;
	
	; At this point raster is near $20 and the foreground task decodes the
	; last transferred 400-byte block from TRANSFERBUFFER ($A000):
	; 320 bytes bitmap, 40 bytes screen RAM colors, 40 bytes D800 colors.
	; Bitmap and screen bytes are copied to the inactive display bank. D800
	; colors are cached for the first 9 row groups, then COPYCOLOR writes the
	; cached rows plus the 10th row group to color RAM at the bank flip.
	
	;At this point both X and Y registers are free and unused by both NMI and IRQ handlers.
	;We have around 12000 cycles to complete our job.
	
	LDA #05
	STA BORDER
.include "FGStuff.s"

OUTCOPY
	LDA #00
	STA BORDER
	; Decrement 32-bit remaining-byte counter by 400 (one CVD block = 400 bytes).
	; Carry clear on underflow means file is exhausted — exit cleanly.
	SEC
	LDA CVD_SIZE+0
	SBC #<400
	STA CVD_SIZE+0
	LDA CVD_SIZE+1
	SBC #>400
	STA CVD_SIZE+1
	LDA CVD_SIZE+2
	SBC #0
	STA CVD_SIZE+2
	LDA CVD_SIZE+3
	SBC #0
	STA CVD_SIZE+3
	BCC CVD_DONE
	LDA CVD_SIZE+0
	ORA CVD_SIZE+1
	ORA CVD_SIZE+2
	ORA CVD_SIZE+3
	BEQ CVD_DONE
	INY
	CPY #20
	BNE +
	LDY #$00
+
	JMP AGAIN

; Natural end-of-file exit path.
; Arduino exits HandleNonInterruptedStream() on EOF, then calls StartListening().
; We delay 5 frames (~100ms) to let the Arduino complete that transition before
; re-sending PROT_StartTalking to re-establish the command session.
CVD_DONE
	SEI
	LDA #$00
	STA $D01A       ; Disable raster IRQ
	ASL $D019       ; Acknowledge any pending raster IRQ
	LDA #$37
	STA $01
	DELAYFRAMES 5
	JSR PROT_StartTalking
	JSR PROT_CloseFile
	JSR PROT_EndTalking
	SEI
	LDA #$00
	STA $D01A
	ASL $D019
CVD_DONE_HALT
	JMP CVD_DONE_HALT
	
;TRANSFERROUTINE
;	LDX #$00
;-	
; 	BIT MODULATION_ADDRESS
;	NOP	
;	LDA CARTRIDGE_BANK_VALUE
;	STA $C000,X		
;	INX
;	BNE - 

;	TYA
;	PHA
;	LDY #$90
;-		
; 	BIT MODULATION_ADDRESS
;	INX
;	LDA CARTRIDGE_BANK_VALUE
;	STA $C0FF,X		
;	DEY
;	BNE -
	
;	PLA
;	TAY	
;	RTS	
	
SIMPLEHANDLER
	NOP	
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	LDA #$40
	STA FG_GATE			; Let foreground task unleash
	ASL $D019			; Acknowledge interrupt
	LDA #1
	STA $D01A
	
	RTI	
	
	
	
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

	
;WASTELINES
;	LDX #20
;CONSUME	
;	DEX
;	BNE CONSUME		
;	RTS	


;INITIALWAIT
;	LDY #INITIALWAITTIME	
;-	
;	LDA $D012
;	BNE -
;	JSR WASTELINES
;	DEY 
;	BNE -
;	RTS	
	
	

INIT		; Input : None, Changed : A
	CLD
	LDA #$93
	JSR CHROUT
	LDA #$00 
	STA $D020
	LDA #$0B
	STA $D021
		
	JSR PROT_DisableInterrupts
		
	RTS
	
ERROR_OPENING_FILE
	; PROT_StartTalking was called before PROT_OpenFile, so EndTalking is required.
	JSR PROT_EndTalking
	JSR PROT_ExitToMenu
ERROR_OPENING_FILE_HALT
	JMP ERROR_OPENING_FILE_HALT
	
.include "../../Loader/CartLibStream.s"

VIDEO_B0 = PICTURE_LO

VIDEO_B1 = PICTURE_HI

CVD_LOW_CODE_END
ENDOFEXECUTABLE

 * = $4800
CVD_COLORCOPY_START
COPYCOLOR
.for line = 0,line<9,line=line+1
	.for src = 0, src<40, src = src + 1
		LDA COLORBUFFER+line*40 + src
		STA $D800 + (PICTUREROW + line*2)*40 + src
		STA $D800 + (PICTUREROW + line*2 + 1)*40 + src		
	.next
.next

.for line = 9,line<10,line=line+1
	.for src = 0, src<40, src = src + 1
		LDA TRANSFERBUFFER + $168+src
		STA $D800 + (PICTUREROW + line*2)*40 + src
		STA $D800 + (PICTUREROW + line*2 + 1)*40 + src	
	.next
.next

	RTS

CVD_COLORCOPY_END

 * = $C000
.include "Common.s"

.include "NMI.s"

; Local copy of the media file path recovered from FILE_PATH_SHADOW ($FF00).
MEDIAPATH_BUF
	.FILL FILE_PATH_SHADOW_MAX, 0

CVD_HELPER_END

.if CVD_LOW_CODE_END > $2000
	.error "CVD low code overlaps bitmap buffer 0"
.endif

.if CVD_HELPER_END > $D000
	.error "CVD helper segment exceeds $C000-$CFFF"
.endif

.if CVD_COLORCOPY_START < $4800 || CVD_COLORCOPY_END > $6000
	.error "CVD color-copy segment exceeds $4800-$5FFF"
.endif
