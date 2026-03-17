; CvdPlayer — Bad Apple!! video player for EasySD / IRQHack64
; Original: 14/07/2016 - Istanbul
;
;==============================================================================
; CVD FORMAT SPECIFICATION
;==============================================================================
; CVD is a custom, C64-optimized video format designed for NMI-driven
; streaming via the EasySD cartridge. Each frame is exactly 400 bytes,
; consumed as 50 fragments of 8 bytes each via COMMAND_NI_STREAM (26).
;
; FRAME BLOCK LAYOUT (400 bytes, stored at TRANSFERBUFFER = $A000)
; ----------------------------------------------------------------
; Offset $000-$04F (80 bytes): Bitmap quadrant 0 (line pairs 0-1)
; Offset $050-$09F (80 bytes): Bitmap quadrant 1 (line pairs 2-3)
; Offset $0A0-$0EF (80 bytes): Bitmap quadrant 2 (line pairs 4-5)
; Offset $0F0-$13F (80 bytes): Bitmap quadrant 3 (line pairs 6-7)
; Offset $140-$167 (40 bytes): Screen color data for this frame row
; Offset $168-$18F (40 bytes): D800 color data for the final line pair
;
; DISPLAY PARAMETERS
; ------------------
; Mode    : Multicolor bitmap (VIC-II, PAL)
; Resolution: 160×80 pixels effective (10 character rows × 40 chars wide)
;             Each pixel is 2×2 physical pixels; physical size: 320×80.
; Position: Starts at PICTUREROW=3 (screen row 3, approx Y=24 on PAL screen)
; Frame rate: 5 fps (1 video frame = 10 PAL raster frames = 10 CVD blocks)
; Throughput: 10 blocks × 400 bytes × 50 Hz = 20 KB/s from SD card
; Colors per cell (multicolor):
;   00 = Background ($D021)
;   01 = Screen RAM color (from $0400 / $4400)
;   10 = Color RAM ($D800)
;   11 = Border color ($D020)
;
; VIDEO FRAME ASSEMBLY (10 consecutive CVD blocks = 1 complete video frame)
; Each CVD block updates exactly ONE character row (8 scan lines, 40 cells):
;   Block 0 → character row 0 (scan lines 0-7)
;   Block 1 → character row 1 (scan lines 8-15)
;   ...
;   Block 9 → character row 9 (scan lines 72-79)
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
;    Infinite loop until SEL (GAME) line goes low.
; 3. NMI handlers (NMI_000..NMI_031 in NMI.s) fire at STARTRASTER=241 (VBlank),
;    each receiving 8 bytes via READCART_MODULATED into $A000+.
;    32 handlers × 8 bytes = 256 bytes, remaining 144 bytes from a second pass.
; 4. Foreground (FGStuff.s) decompresses the 400-byte block:
;    copies the 4 bitmap quadrants to the inactive bank, writes screen color
;    data, and accumulates D800 colors in COLORBUFFER for all 10 rows.
; 5. Playback stops when the CVD file is exhausted and the plugin calls
;    PROT_ExitToMenu (drives SEL low, terminating the NI stream on Arduino).
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

DELAYFRAMES	.macro
	LDX #\1
	JSR WAITFRAMES
	.endm



	*=$080E
	
	SAVESTATE
	
	JSR PROT_DisableDisplay		
	JSR INIT				;Clears screen, disables interrupts.	
	JSR PROT_StartTalking	
	.CHANGEBANK 2	
	
	JSR INIT_GFX_MEM
	JSR SET_LO_COLOR
	JSR SET_HI_COLOR
	JSR SETMULTICOLOR
	
	LDA #$00
	STA $D01A
	STA $D015	

	;JMP ZIBIRT				;For testing in VICE 
	LDA #$35
	STA $01
	DELAYFRAMES 1
	
	LDA #$37
	STA $01
	; Compute length of null-terminated path placed in FILE_PATH_BUF by the menu
	LDX #$00
-	LDA FILE_PATH_BUF, X
	BEQ CVD_STRLEN_DONE
	INX
	BNE -
CVD_STRLEN_DONE
	TXA             ; A = path length
	LDX #<FILE_PATH_BUF
	LDY #>FILE_PATH_BUF
	JSR PROT_SetName
	LDX #01		; Flags=read
	JSR PROT_OpenFile
	BCC +
	JMP ERROR_OPENING_FILE

+
	DELAYFRAMES 2
	LDA #50     ; 50 * 8 = 400 bytes per block
	JSR PROT_NIStream
	DELAYFRAMES 2
	
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
    
    ; --- STOP Key Check ---
    LDA $01
    PHA
    LDA #$37
    STA $01
    JSR $FFE1       ; Check STOP key
    BEQ StopPressed
    PLA
    STA $01
    ; ----------------------
    
	JMP LOOP

StopPressed
    PLA
    STA $01
    SEI
    LDA #$00
    STA $D01A       ; Disable Raster IRQ
    JSR PROT_CloseFile
    JSR PROT_ExitToMenu
    RTS

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
	
	;At this point Raster moved to $20 or so and this foreground task has time to do something for the
	;last transferred 400 byte at $C000
	;The format of this data is
	;160x8 multicolor bitmap data = 320 bytes 
	;40 bytes screen color data
	;40 bytes d800 colors
	;bitmap data will be copied to current bank at current location
	;screen color data will be copied to screen memory to current bank at current location
	;D800 colors will be cached in a buffer for the initial 9 transfers. On last transfer cache will be copied to $d800 along with the 40 byte of the 
	;10th transfer
	
	;At this point both X and Y registers are free and unused by both NMI and IRQ handlers.
	;We have around 12000 cycles to complete our job.
	
	LDA #05
	STA BORDER
.include "FGStuff.s"

OUTCOPY	
	LDA #00
	STA BORDER

	INY
	CPY #20
	BNE +
	LDY #$00
+	
	JMP AGAIN
	
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
	JSR PROT_ExitToMenu
	

	
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
	
.include "../../Loader/CartLibStream.s"

VIDEO_B0 = PICTURE_LO 

VIDEO_B1 = PICTURE_HI 
   
ENDOFEXECUTABLE			

COLORBUFFER	= $4000

.include "Common.s"


; * = $C1A0
 * = $C000
.include "NMI.s"	  
	RTS