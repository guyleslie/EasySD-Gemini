; 4/8 bit Wav Player for IRQHack64V2
; 04/08/2018 - Istanbul
; I.R.on

.enc "screen"

STATUS		=$FE
CURSCROLL	=$A0
SCROLLCOS   =$A1
SCROLLCOLOR = $09

PLAYSTATE   = $A2
PLAYTYPE    = $A3
PLAYINDEX   = $A4

; DigiMax MK3 detection — ZP scratch (free after detection)
MK3_ACTIVE      = $FB   ; 0 = compat mode, 1 = MK3 streaming active
DETECT_TIMEOUT  = $FC   ; outer loop counter during detection

PLAYTYPE_ONLYSID    = 0           ; C64 SID 4-bit DAC, IO2 streaming
PLAYTYPE_DIGIMAX    = 1           ; DigiMax compat, IO2 streaming
PLAYTYPE_BOTH       = 2           ; SID + DigiMax, IO2 streaming
PLAYTYPE_MK3        = 3           ; MK3 NMI 11025 Hz mono, CIA=89
PLAYTYPE_MK3_22K    = 4           ; MK3 NMI 22050 Hz mono, CIA=44
PLAYTYPE_MK3_STEREO = 5           ; MK3 NMI 11025 Hz stereo, CIA=44

; MK3 audio double-buffer layout ($4000–$6FFF)
AUDIO_BUF_A         = $4000       ; 6144 bytes: $4000–$57FF
AUDIO_BUF_B         = $5800       ; 6144 bytes: $5800–$6FFF
AUDIO_BUF_A_END_HI  = $58        ; hi-byte of first addr past BUF_A
AUDIO_BUF_B_END_HI  = $70        ; hi-byte of first addr past BUF_B
BUFFER_PAGES        = 24          ; 24 × 256 = 6144 bytes per buffer
WAV_HEADER_SIZE     = 44          ; standard PCM WAV header (fixed for v1)
COMMAND_READ_NEXT_CHUNK = 27      ; Arduino command: NMI-push numPages*256 bytes

; ZP scratch for MK3 path (plugin-local, $8B-$90 per CartZpMap.inc)
ZP_WAV_PTR_LO   = $8B   ; playback pointer lo (current byte address)
ZP_WAV_PTR_HI   = $8C   ; playback pointer hi
ZP_WAV_END_HI   = $8D   ; hi-byte of end address for active buffer
ZP_WAV_ACTBUF   = $8E   ; 0 = BUF_A active, 1 = BUF_B active
ZP_WAV_FILL     = $8F   ; 0 = idle, 1 = inactive buffer needs fill
ZP_WAV_EOFLAG   = $90   ; 0 = more data, $FF = last block loaded
ZP_WAV_TIMERLO   = $91  ; CIA1 Timer A low byte (89=11025 Hz, 44=22050 Hz/stereo)
ZP_WAV_BUF_READY = $92  ; 0=fill in progress,  1=inactive buffer fully ready for ISR
ZP_WAV_SILENCE   = $93  ; 0=play normally,      1=output silence (stale-read guard)
; NOTE: $92/$93 overlap ZP_STREAM_API_REMAIN0/1 (CartZpMap.inc) — safe because
;       StreamLargeFile is never active during MK3 playback.



; DEBUG mode - defined from command line (-D DEBUG=1 or -D DEBUG=0)
; Load DEBUG macros BEFORE first use
.include "../../Loader/DebugMacros.s"
.include "../../Loader/APIMacros.s"

STREAMINGBUFFERHALF = 64

	*=$C000

	;*=$080E
PETGLPLUGINREAD				;Remove when callback in the transfer code fixed.
	JMP MAIN
	
MAIN		
	JSR SAVESTATE		; Save VIC/$01 state for clean menu return
	JSR INIT		; Clears screen, disables interrupts.	
	JSR PROT_StartTalking	; Initialize cartridge communication
	
ALTENTRY	
	CLD

;Lets try to open a file
	;PRINTSTATUSANDWAIT OPENINGFILE, 100
	DELAYFRAMES 5
	JSR PROT_DisableDisplay		
	#OPENFILE FILE_PATH_BUF, #31, #01
	BCC OPENINGCONT
	JMP ERROR_OPENING_FILE
OPENINGCONT	
	JSR PROT_EnableDisplay
	DELAYFRAMES 5
	;RINTSTATUSANDWAIT OPENINGSUCCESS, 200
	;JMP FILEREAD
	;RINTSTATUSANDWAIT STREAMINGFILE, 200

	; Initialize Arduino streaming mode (parameters ignored by firmware)
	; WavPlayer implements its own IRQ-based streaming loop (see PlayRoutine)
	LDA #$00
	LDX #$00
	LDY #$00
	JSR PROT_Stream

	DELAYFRAMES 5

	; Detect MK3 BEFORE mode selector so it can show/hide the MK3 option
	JSR DIGI_Init
	JSR NMIDIGI_InitNew
	JSR DETECT_MK3          ; sets MK3_ACTIVE = 0 or 1

	; Mode selector screen — returns selected PLAYTYPE in A
	JSR ShowModeSelector
	STA PLAYTYPE

	; Clear screen before playback
	LDA #$93
	JSR CHROUT

	; Branch to MK3 NMI-buffered path if any MK3 mode selected
	LDA PLAYTYPE
	CMP #PLAYTYPE_MK3
	BEQ StartMK3Playback
	CMP #PLAYTYPE_MK3_22K
	BEQ StartMK3Playback
	CMP #PLAYTYPE_MK3_STEREO
	BEQ StartMK3Playback

	; Fall through to existing IO2 streaming paths (PLAYTYPE 0/1/2)
	JMP STREAMFILE
	
ERROR_OPENING_FILE	
	JSR PROT_EnableDisplay
	PRINTSTATUSANDWAIT OPENINGFILEFAILED, 200		
	JSR CleanReturnToMenu
	RTS

STREAMFILE
	LDA #0
	STA PLAYSTATE
	; PLAYINDEX is initialized inside SETUPMUSICTRANSFER
	JSR SETUPMUSICTRANSFER
	JSR PROT_DisableDisplay
WAITAKEY
	JSR GETIN
	BEQ WAITAKEY
	JSR CleanReturnToMenu
	RTS
	;JSR minikey
  	;BEQ WAITAKEY	
	;SEI 
	;JSR $FDA3			; Init CIA
	;JSR $FD15			; Restore Vectors
	;DELAYFRAMES 10		; Wait for Cartridge to go back to command mode
	;JSR PROT_CloseFile		; Close the file
	;JSR PROT_DisableDisplay
	;JSR PROT_ExitToMenu	


PlayRoutineSimple:
	#SAVEREGS

	INC VIC_BORDER_COLOR			;is interrupt handler alive?
	#SETBANK PP_CONFIG_DEFAULT
	LDA MODULATION_ADDRESS	
	NOP
	LDA CARTRIDGE_BANK_VALUE
	TAY
	LDA SHIFT4BIT, Y				; 4+	
	STA $D418

	#SETBANK PP_CONFIG_RAM_ON_ROM
	LDA CIA_1_BASE + CIA_INT_MASK	; Acknowledge interrupt

	#RESTOREREGS
	RTI

PlayRoutineBoth:
	#SAVEREGS

	INC VIC_BORDER_COLOR			;is interrupt handler alive?
	#SETBANK PP_CONFIG_DEFAULT
	LDA MODULATION_ADDRESS	
	NOP
	LDA CARTRIDGE_BANK_VALUE
	TAY
	LDA SHIFT4BIT, Y				; 4+	
	STA $D418
	STY CIA_2_BASE + DATA_B			; 8-bit Digimax
	
	#SETBANK PP_CONFIG_RAM_ON_ROM
	LDA CIA_1_BASE + CIA_INT_MASK	; Acknowledge interrupt

	#RESTOREREGS
	RTI

.align $100

PlayRoutine							; 7
	#SAVEREGS

	INC VIC_BORDER_COLOR			; 6
	LDA PLAYSTATE					; 3
	BNE PlayFromBuffer				; 2 - 3

	#SETBANK PP_CONFIG_DEFAULT

	LDA MODULATION_ADDRESS			; 4
	NOP								; 2
	LDA CARTRIDGE_BANK_VALUE		; 4
	LDX PLAYINDEX
	STA READBUFFER, X				; 5
	TAY								; 2
	LDA SHIFT4BIT, Y				; 4+
	STA $D418						; 4
	
	DEX								; 2
	BNE +							; 2-3
	INC PLAYSTATE					; 5
	LDX #STREAMINGBUFFERHALF		; 2
+	
	STX PLAYINDEX
	#SETBANK PP_CONFIG_RAM_ON_ROM
	LDA CIA_1_BASE + CIA_INT_MASK	; 4 - Acknowledge interrupt

	#RESTOREREGS
	RTI

PlayFromBuffer	
	LDX PLAYINDEX
	LDA READBUFFER, X				; 4+ (if page crossed)
	TAY								; 2
	LDA SHIFT4BIT, Y				; 4+
	STA $D418						; 4
	DEX								; 2
	BNE +							; 2 - 3
	DEC PLAYSTATE					; 5
	LDX #STREAMINGBUFFERHALF		; 2
+	
	STX PLAYINDEX
	#SETBANK PP_CONFIG_RAM_ON_ROM
	LDA CIA_1_BASE + CIA_INT_MASK	; 4 - Acknowledge interrupt

	#RESTOREREGS
	RTI								; 6

.align $100	

PlayDigimax							; 7
	#SAVEREGS

	INC VIC_BORDER_COLOR			; 6
	LDA PLAYSTATE					; 3
	BNE PlayFromBufferDigimax		; 2 - 3

	#SETBANK PP_CONFIG_DEFAULT

	LDA MODULATION_ADDRESS			; 4
	NOP								; 2
	LDA CARTRIDGE_BANK_VALUE		; 4
	LDX PLAYINDEX
	STA READBUFFER, X				; 5
	STA CIA_2_BASE + DATA_B			; 4
	
	DEX								; 2
	BNE +							; 2-3
	INC PLAYSTATE					; 5
	LDX #STREAMINGBUFFERHALF		; 2
+	
	STX PLAYINDEX
	#SETBANK PP_CONFIG_RAM_ON_ROM
	LDA CIA_1_BASE + CIA_INT_MASK	; 4 - Acknowledge interrupt

	#RESTOREREGS
	RTI

PlayFromBufferDigimax
	LDX PLAYINDEX
	LDA READBUFFER, X				; 4+ (if page crossed)
	STA CIA_2_BASE + DATA_B			; 4
	DEX								; 2
	BNE +							; 2 - 3
	DEC PLAYSTATE					; 5
	LDX #STREAMINGBUFFERHALF		; 2
+	
	STX PLAYINDEX
	#SETBANK PP_CONFIG_RAM_ON_ROM
	LDA CIA_1_BASE + CIA_INT_MASK	; 4 - Acknowledge interrupt

	#RESTOREREGS
	RTI


PlayDigimaxSimple					; 7
	#SAVEREGS
	
	

	
	
	INC VIC_BORDER_COLOR			; 6
	
	
	#SETBANK PP_CONFIG_DEFAULT
	
	

	
	
	LDA MODULATION_ADDRESS			; 4
	
	
	NOP						; 2
	
	
	NOP
	
	
	NOP
	
	
	LDA CARTRIDGE_BANK_VALUE		; 4
	
	
	STA CIA_2_BASE + DATA_B			; 4
	
	
	#SETBANK PP_CONFIG_RAM_ON_ROM
	
	
	LDA CIA_1_BASE + CIA_INT_MASK	; 4 - Acknowledge interrupt		
	
	

	
	
	#RESTOREREGS
	
	
	RTI
	
	

	
	
PlayBothBuffered:
	
	
	PHA
	
	
	TXA
	
	
	PHA
	
	
	TYA
	
	
	PHA
	
	

	
	
	INC VIC_BORDER_COLOR
	
	
	LDA PLAYSTATE
	
	
	BNE +
	
	

	
	
	#SETBANK PP_CONFIG_DEFAULT
	
	
	LDA MODULATION_ADDRESS
	
	
	NOP
	
	
	LDA CARTRIDGE_BANK_VALUE
	
	
	LDX PLAYINDEX
	
	
	STA READBUFFER, X
	
	
	TAY
	
	
	LDA SHIFT4BIT, Y
	
	
	STA $D418
	
	
	STY CIA_2_BASE + DATA_B
	
	
	
	
	
	DEX
	
	
	BNE _not_zero
	
	
	INC PLAYSTATE
	
	
	LDX #STREAMINGBUFFERHALF
	
	
_not_zero
	
	
	STX PLAYINDEX	
	
	JMP PlayBothBuffered_Exit
	
	

	
	
+	; Play from buffer
	
	
	LDX PLAYINDEX
	
	
	LDA READBUFFER, X
	
	
	TAY
	
	
	LDA SHIFT4BIT, Y
	
	
	STA $D418
	
	
	STY CIA_2_BASE + DATA_B
	
	
	
	
	
DEX
	
	
	BNE +
	
	
	DEC PLAYSTATE
	
	
	LDX #STREAMINGBUFFERHALF
	
	
+
	
	
	STX PLAYINDEX
	
	

	
	
PlayBothBuffered_Exit:
	
	
	#SETBANK PP_CONFIG_RAM_ON_ROM
	
	
	LDA CIA_1_BASE + CIA_INT_MASK
	
	
	#RESTOREREGS
	
	
	RTI
	
	

	
	
SETUPMUSICTRANSFER	
	
	
	JSR PROT_DisableDisplay
	
	
	SEI
	
	
	#SETBANK PP_CONFIG_RAM_ON_ROM
	
	
	
	
	
	LDA #STREAMINGBUFFERHALF
	
	
	STA PLAYINDEX
	
	

	
	
	LDA PLAYTYPE
	
	
	CMP #PLAYTYPE_ONLYSID			
	
	
	BEQ SetupSidOnly
	
	
	CMP #PLAYTYPE_DIGIMAX
	
	
	BEQ SetupDigimax
	
	
	CMP #PLAYTYPE_BOTH
	
	
	BEQ SetupBoth
	
	
	
	
	

	
	
SetupBoth:
	
	
	JSR DIGI_Init
	
	
	JSR NMIDIGI_InitNew
	JSR DETECT_MK3			; MK3 detection + streaming config


	LDA #<PlayBothBuffered
	
	
	STA ROM_IRQ_HANDLER
	
	
	LDA #>PlayBothBuffered
	
	
	STA ROM_IRQ_HANDLER+1
	
	

	
	
	LDA #$00
	
	
	BEQ SetupInterrupt			;Fake unconditional
	
	
	
	
	
		
	
	
SetupSidOnly:
	
	
	JSR DIGI_Init
	
	
	LDA #<PlayRoutine
	
	
	STA ROM_IRQ_HANDLER
	
	
	LDA #>PlayRoutine
	
	
	STA ROM_IRQ_HANDLER+1
	
	

	
	
	LDA #$00
	
	
	BEQ SetupInterrupt			;Fake unconditional
	
	
; =============================================================================
; DETECT_MK3 — detect DigiMax MK3 and configure streaming mode
; =============================================================================
; Called from SetupDigimax / SetupBoth, AFTER NMIDIGI_InitNew, BEFORE SetupInterrupt.
; Polls CIA_2_BASE + CIA_INT_MASK ($DD0D) for FLAG2 falling edges (bit 4).
;
; Loop-counter timeout: 13 cycles × 256 inner × 18 outer ≈ 60 000 cycles ≈ 60 ms.
; No jiffy clock dependency — safe after KILLCIA.
;
; Phase 1 — magic sequence $AC $DE $AD $BE → ATmega responds with ≥1 FLAG2 pulse.
;   0 pulses at timeout → compat mode (original Digimax or absent).
;
; Phase 2 — config bytes $01 (frame_size=1, mono) + $40 (autostart=64×16=1024 bytes).
;   ATmega confirms with exactly 3 FLAG2 pulses → MK3_ACTIVE = 1.
;   Timeout with <3 pulses → compat fallback.
;
; Registers: A, X, Y clobbered. MK3_ACTIVE ($FB) set on return.
; =============================================================================

DETECT_MK3:
	LDA #0
	STA MK3_ACTIVE			; assume compat until confirmed

	; ── Phase 1: send magic sequence ──────────────────────────────────

	LDA CIA_2_BASE + CIA_INT_MASK	; read-clear CIA2 ICR (discard stale edges)

	LDA #$AC
	STA CIA_2_BASE + DATA_B		; magic byte 1
	LDA #$DE
	STA CIA_2_BASE + DATA_B		; magic byte 2
	LDA #$AD
	STA CIA_2_BASE + DATA_B		; magic byte 3

	LDA CIA_2_BASE + CIA_INT_MASK	; clear again before trigger byte

	LDA #$BE
	STA CIA_2_BASE + DATA_B		; magic byte 4 — triggers ATmega response

	LDA #18
	STA DETECT_TIMEOUT		; outer loop counter (~60 ms total)
	LDX #0				; FLAG2 pulse counter

PHASE1_OUTER:
	LDY #0				; 256 inner iterations × 13 cycles ≈ 3.3 ms
PHASE1_LOOP:
	LDA CIA_2_BASE + CIA_INT_MASK
	AND #$10			; bit 4 = FLAG2 falling edge
	BNE PHASE1_GOT_PULSE
	DEY
	BNE PHASE1_LOOP
	DEC DETECT_TIMEOUT
	BNE PHASE1_OUTER
	; timeout — check pulse count
	CPX #0
	BEQ DETECT_DONE			; 0 pulses → no MK3, stay compat
	JMP PHASE2_START

PHASE1_GOT_PULSE:
	INX
	JMP PHASE1_OUTER		; keep counting remaining pulses until timeout

	; ── Phase 2: send streaming config ────────────────────────────────

PHASE2_START:
	LDA CIA_2_BASE + CIA_INT_MASK	; clear ICR before config bytes

	LDA #$01
	STA CIA_2_BASE + DATA_B		; frame_size = 1 (mono)
	LDA #$40
	STA CIA_2_BASE + DATA_B		; auto-start threshold = 64 (×16 = 1024 bytes)

	LDA #18
	STA DETECT_TIMEOUT		; reset outer counter
	LDX #0				; confirmation pulse counter

PHASE2_OUTER:
	LDY #0
PHASE2_LOOP:
	LDA CIA_2_BASE + CIA_INT_MASK
	AND #$10
	BNE PHASE2_GOT_PULSE
	DEY
	BNE PHASE2_LOOP
	DEC DETECT_TIMEOUT
	BNE PHASE2_OUTER
	; timeout with < 3 pulses → compat fallback
	JMP DETECT_DONE

PHASE2_GOT_PULSE:
	INX
	CPX #3
	BEQ DETECT_MK3_OK		; all 3 pulses → streaming confirmed
	JMP PHASE2_OUTER

DETECT_MK3_OK:
	LDA #1
	STA MK3_ACTIVE

DETECT_DONE:
	RTS

SetupDigimax:


	JSR NMIDIGI_InitNew
	JSR DETECT_MK3			; MK3 detection + streaming config


	
	
	LDA #<PlayDigimax
	
	
	STA ROM_IRQ_HANDLER
	
	
	LDA #>PlayDigimax
	
	
	STA ROM_IRQ_HANDLER+1
	
	

	
	
	LDA #$00	
	
	
	
	
	
SetupInterrupt:
	LDA #$00
	STA CIA_1_BASE + TIMER_A_HI

	LDA #89							;985000/11000 = 89
	STA CIA_1_BASE + TIMER_A_LO

	LDA #$81						; Enable Timer A interrupts	
	STA CIA_1_BASE + CIA_INT_MASK
	
	LDX #(CRA_FORCE_LOAD + CRA_START)		;Continous
	STX CIA_1_BASE + CIA_TIMER_A_CTRL			
		
	LDA #02				
   	STA BORDER
	LDA CIA_1_BASE + CIA_INT_MASK
	CLI	
	
	RTS
	
NMIDIGI_InitNew:

	LDA CIA_2_BASE + DDR_A
	ORA #$0C
	STA CIA_2_BASE + DDR_A			;Set PA2/PA3 as output		
	
	LDA CIA_2_BASE + DATA_A
	ORA #$08						;PA3 = 1, PA2 = 0 (Select first dac output)
	STA CIA_2_BASE + DATA_A
	
	LDA #$FF
	STA CIA_2_BASE + DDR_B			;Set PB0..PB7 as output
	
	RTS
	
DIGI_Init:
	LDA #$FF
	STA $D406
	STA $D406+7
	STA $D406+14
	LDA #$49
	STA $D404
	STA $D404+7
	STA $D404+14

	RTS
	
INIT		; Input : None, Changed : A
	CLD
	LDA #$93
	JSR CHROUT
	LDA #$00 
	STA $D020
	LDA #$0B
	STA $D021
	JSR INITPC
		
	JSR DISABLEINTERRUPTS		
	JSR KILLCIA
	JSR PREPARESHIFTBIT
		
	RTS

INITPC
	LDX #$00
	LDA #$0F
CBL
	STA $D800,X
	STA $D900,X
	STA $DA00,X
	STA $DB00,X	
	INX
	BNE CBL
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
    LDY #$7f    				; $7f = %01111111 
    STY $dc0d   				; Turn off CIAs Timer interrupts 
    STY $dd0d  				; Turn off CIAs Timer interrupts 
    LDA $dc0d  				; cancel all CIA-IRQs in queue/unprocessed 
    LDA $dd0d   				; cancel all CIA-IRQs in queue/unprocessed 
	
					
; 	Change interrupt routines
	ASL $D019
	LDA #$00
	STA $D01A
	RTS

DISABLEDISPLAY
	LDA #$0B				;%00001011 ; Disable VIC display until the end of transfer
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
	
PREPARESHIFTBIT
	LDX #0
-	
	TXA
	LSR
	LSR
	LSR
	LSR
	STA SHIFT4BIT, X
	INX
	BNE -
	RTS


	
	
STREAMTEST1
	#SETBANK PP_CONFIG_DEFAULT

WAIT1
	JSR minikey
  	BEQ WAIT1
	
	JSR PROT_DisableDisplay

	LDA MODULATION_ADDRESS
	NOP
	LDA CARTRIDGE_BANK_VALUE
	STA $FB
	JSR DisplayReceived1	
	DELAYFRAMES 25

	JSR PROT_EnableDisplay
	JMP WAIT1
	
	
STREAMTEST2
	#SETBANK PP_CONFIG_DEFAULT

WAIT2
	JSR minikey
  	BEQ WAIT2
	
	JSR PROT_DisableDisplay

	LDA MODULATION_ADDRESS
	NOP
	LDA CARTRIDGE_BANK_VALUE
	TAX
	LDA CARTRIDGE_BANK_VALUE
	TAY
	JSR DisplayReceived2	
	DELAYFRAMES 50

	JSR PROT_EnableDisplay
	JMP WAIT2
	
	
	
; X have first byte, 	Y have second byte
DisplayReceived1
	JSR GetHigh
	STA $0400
	
	LDA $FB
	JSR GetLow
	STA $0401
	
	LDX $FB
	LDA SHIFT4BIT, X
	TAX
	LDA  HEXTOSCREEN, X	
	
	STA $0405
		
	RTS
	
; X have first byte, 	Y have second byte
DisplayReceived2
	STX $FB
	STY $FC

	LDA $FB
	JSR GetHigh
	STA $0400
	
	LDA $FB
	JSR GetLow
	STA $0401
	
	LDA $FC
	JSR GetHigh
	STA $0403
	
	LDA $FC
	JSR GetLow
	STA $0404
	
	LDX $FB
	LDA SHIFT4BIT, X
	TAX
	LDA  HEXTOSCREEN, X	
	STA $0408
	
	LDY $FC
	LDA SHIFT4BIT, X
	TAX
	LDA  HEXTOSCREEN, X		
	STA $040B
	
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
	sta $dc03	; port b ddr (input)
	lda #$ff
	sta $dc02	; port a ddr (output)
			
	lda #$00
	sta $dc00	; port a
	lda $dc01       ; port b
	cmp #$ff
	beq nokey
	; got column
	tay
			
	lda #$7f
	sta nokey2+1
	ldx #8
nokey2:
	lda #0
	sta $dc00	; port a
	
	sec
	ror nokey2+1
	dex
	bmi nokey
			
	lda $dc01       ; port b
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
	
.align $100	
SHIFT4BIT
	.FILL 256

READBUFFER
	.FILL 128
		
HEXTOSCREEN
	.BYTE 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 1, 2, 3, 4, 5, 6
INITTEXT
	.TEXT "IRQHACK64V2 WAV TEST"
	.BYTE 0	
	
SENDSTARTTALKING
	.TEXT "SENDING START TALKING COMMAND"
	.BYTE 0		

STARTEDTALKING
	.TEXT "STARTED TALKING"
	.BYTE 0		

OPENINGFILE
	.TEXT "OPENING WAV FILE"
	.BYTE 0		

OPENINGFILEFAILED
	.TEXT "OPENING WAV FILE FAILED"
	.BYTE 0	

OPENINGSUCCESS
	.TEXT "FILE OPEN SUCCEEDED"
	.BYTE 0		
	
STREAMINGFILE
	.TEXT "STREAMING FILE"
	.BYTE 0		


READINGFAILED	
	.TEXT "READING FAILED"
	.BYTE 0		
CLOSINGFILE	
	.TEXT "CLOSING FILE"
	.BYTE 0	
	
FILECLOSED
	.TEXT "FILE CLOSING SUCCEEDED"
	.BYTE 0
	
	
ERRORCLOSINGFILE
	.TEXT "CLOSING FAILED"
	.BYTE 0	

DEMOFILE
	.TEXT "test.wav"
	.BYTE 0
DEMOFILEEND


;------------------------------------------------------------
; Clean return to menu (stop CIA IRQs, close file, restore VIC/$01)
;------------------------------------------------------------
CleanReturnToMenu
	SEI
	LDA #$7F
	STA $DC0D			; Disable all CIA1 interrupts
	LDA $DC0D			; Ack pending
	LDA #$00
	STA $D01A			; Disable VIC raster IRQs
	CLI

	JSR PROT_CloseFile		; Safe even if already closed
	JSR PROT_EndTalking		; End cartridge communication
	JSR RESTORESTATE		; Restore VIC/$01 state
	JSR PROT_DisableDisplay
	JSR PROT_ExitToMenu
	RTS

;------------------------------------------------------------
; Clean return helpers (shared pattern with Koala/Petscii/MUS)
;------------------------------------------------------------
FORCEIO
	LDA $01
	ORA #$04			; Ensure I/O visible ($D000-$DFFF)
	STA $01
	RTS

SAVESTATE
	LDA $01
	STA SAVED_01
	LDA $DD00
	STA SAVED_DD00
	LDA $D011
	STA SAVED_D011
	LDA $D016
	STA SAVED_D016
	LDA $D018
	STA SAVED_D018
	LDA $D020
	STA SAVED_D020
	LDA $D021
	STA SAVED_D021
	LDA $D022
	STA SAVED_D022
	LDA $D023
	STA SAVED_D023
	RTS

RESTORESTATE
	JSR FORCEIO
	LDA SAVED_01
	STA $01
	LDA SAVED_DD00
	STA $DD00
	LDA SAVED_D018
	STA $D018
	LDA SAVED_D016
	STA $D016
	LDA SAVED_D011
	STA $D011
	LDA SAVED_D020
	STA $D020
	LDA SAVED_D021
	STA $D021
	LDA SAVED_D022
	STA $D022
	LDA SAVED_D023
	STA $D023
	RTS

SAVED_01:	.byte 0
SAVED_DD00:	.byte 0
SAVED_D011:	.byte 0
SAVED_D016:	.byte 0
SAVED_D018:	.byte 0
SAVED_D020:	.byte 0
SAVED_D021:	.byte 0
SAVED_D022:	.byte 0
SAVED_D023:	.byte 0

; ============================================================
; ShowModeSelector — display playback mode selection menu
; Returns: A = selected PLAYTYPE (0=SID only, 1=DigiMax, 2=MK3)
; Prerequisite: DETECT_MK3 already called (MK3_ACTIVE set)
; Uses GETIN (KERNAL) — called before CIA is killed, so this works.
; ============================================================

; Menu state (data)
MENU_CURSOR     .byte 0    ; current selection index (0-based)
MENU_MAX        .byte 0    ; number of items: 3 without MK3, 6 with MK3

; Screen positions (row*40+$0400)
MENU_ROW_SID     = $0400 +  2*40 + 2
MENU_ROW_DIGI    = $0400 +  4*40 + 2
MENU_ROW_BOTH    = $0400 +  6*40 + 2
MENU_ROW_MK3_11K = $0400 +  8*40 + 2
MENU_ROW_MK3_22K = $0400 + 10*40 + 2
MENU_ROW_MK3_ST  = $0400 + 12*40 + 2

; Translates cursor index → PLAYTYPE constant
MODE_PLAYTYPE_TABLE: .byte 0, 1, 2, 3, 4, 5

STR_TITLE:       .text "SELECT PLAYBACK MODE"
                 .byte 0
STR_SID:         .text "C64 SID ONLY"
                 .byte 0
STR_DIGIMAX:     .text "DIGIMAX"
                 .byte 0
STR_SID_DIGI:    .text "SID + DIGIMAX"
                 .byte 0
STR_MK3_11K:     .text "DIGIMAX MK3 11K"
                 .byte 0
STR_MK3_22K:     .text "DIGIMAX MK3 22K"
                 .byte 0
STR_MK3_STEREO:  .text "MK3 STEREO 11K"
                 .byte 0

ShowModeSelector:
	; Black screen, clear
	LDA #$00
	STA $D020
	STA $D021
	LDA #$93
	JSR CHROUT

	; Set item count based on MK3_ACTIVE (3 base + 3 MK3 modes)
	LDA #3
	LDX MK3_ACTIVE
	BEQ MSSEL_NO_MK3
	LDA #6
MSSEL_NO_MK3:
	STA MENU_MAX

	; Default cursor = 0 (SID only)
	LDA #0
	STA MENU_CURSOR

	; Print title at row 1, col 2
	LDA #<STR_TITLE
	STA $FB
	LDA #>STR_TITLE
	STA $FC
	LDA #<($0400 + 1*40 + 2)
	STA $FD
	LDA #>($0400 + 1*40 + 2)
	STA $FE
	JSR PrintStringAt

MSSEL_LOOP:
	JSR MS_Render       ; redraw all items, selected one inverted
	JSR GETIN
	BEQ MSSEL_LOOP      ; no key — keep polling

	CMP #$11            ; cursor DOWN
	BEQ MSSEL_DOWN
	CMP #$91            ; cursor UP
	BEQ MSSEL_UP
	CMP #$0D            ; RETURN
	BEQ MSSEL_SELECT
	JMP MSSEL_LOOP

MSSEL_DOWN:
	INC MENU_CURSOR
	LDA MENU_CURSOR
	CMP MENU_MAX
	BCC MSSEL_LOOP
	LDA #0
	STA MENU_CURSOR
	JMP MSSEL_LOOP

MSSEL_UP:
	LDA MENU_CURSOR
	BNE MSSEL_UP_DEC
	LDA MENU_MAX
	STA MENU_CURSOR
MSSEL_UP_DEC:
	DEC MENU_CURSOR
	JMP MSSEL_LOOP

MSSEL_SELECT:
	LDX MENU_CURSOR
	LDA MODE_PLAYTYPE_TABLE,X   ; translate cursor index to PLAYTYPE
	RTS

; ---- MS_Render: redraw all menu items, highlight selected ----
MS_Render:
	; SID item (index 0) — always shown
	LDA #<STR_SID
	STA $FB
	LDA #>STR_SID
	STA $FC
	LDA #<MENU_ROW_SID
	STA $FD
	LDA #>MENU_ROW_SID
	STA $FE
	LDA MENU_CURSOR
	BNE MSR_SID_NORMAL
	JSR PrintStringInvAt
	JMP MSR_DIGI
MSR_SID_NORMAL:
	JSR PrintStringAt

MSR_DIGI:
	; DIGIMAX item (index 1) — always shown
	LDA #<STR_DIGIMAX
	STA $FB
	LDA #>STR_DIGIMAX
	STA $FC
	LDA #<MENU_ROW_DIGI
	STA $FD
	LDA #>MENU_ROW_DIGI
	STA $FE
	LDA MENU_CURSOR
	CMP #1
	BNE MSR_DIGI_NORMAL
	JSR PrintStringInvAt
	JMP MSR_BOTH
MSR_DIGI_NORMAL:
	JSR PrintStringAt

MSR_BOTH:
	; SID + DIGIMAX item (index 2) — always shown
	LDA #<STR_SID_DIGI
	STA $FB
	LDA #>STR_SID_DIGI
	STA $FC
	LDA #<MENU_ROW_BOTH
	STA $FD
	LDA #>MENU_ROW_BOTH
	STA $FE
	LDA MENU_CURSOR
	CMP #2
	BNE MSR_BOTH_NORMAL
	JSR PrintStringInvAt
	JMP MSR_MK3_CHECK
MSR_BOTH_NORMAL:
	JSR PrintStringAt

MSR_MK3_CHECK:
	; MK3 items (index 3-5) — only if MENU_MAX = 6
	LDA MENU_MAX
	CMP #6
	BNE MSR_DONE
	; MK3 11K item (index 3)
	LDA #<STR_MK3_11K
	STA $FB
	LDA #>STR_MK3_11K
	STA $FC
	LDA #<MENU_ROW_MK3_11K
	STA $FD
	LDA #>MENU_ROW_MK3_11K
	STA $FE
	LDA MENU_CURSOR
	CMP #3
	BNE MSR_MK3_11K_NORMAL
	JSR PrintStringInvAt
	JMP MSR_MK3_22K
MSR_MK3_11K_NORMAL:
	JSR PrintStringAt

MSR_MK3_22K:
	; MK3 22K item (index 4)
	LDA #<STR_MK3_22K
	STA $FB
	LDA #>STR_MK3_22K
	STA $FC
	LDA #<MENU_ROW_MK3_22K
	STA $FD
	LDA #>MENU_ROW_MK3_22K
	STA $FE
	LDA MENU_CURSOR
	CMP #4
	BNE MSR_MK3_22K_NORMAL
	JSR PrintStringInvAt
	JMP MSR_MK3_ST
MSR_MK3_22K_NORMAL:
	JSR PrintStringAt

MSR_MK3_ST:
	; MK3 Stereo item (index 5)
	LDA #<STR_MK3_STEREO
	STA $FB
	LDA #>STR_MK3_STEREO
	STA $FC
	LDA #<MENU_ROW_MK3_ST
	STA $FD
	LDA #>MENU_ROW_MK3_ST
	STA $FE
	LDA MENU_CURSOR
	CMP #5
	BNE MSR_MK3_ST_NORMAL
	JSR PrintStringInvAt
	JMP MSR_DONE
MSR_MK3_ST_NORMAL:
	JSR PrintStringAt
MSR_DONE:
	RTS

; ---- PrintStringAt: null-terminated PETSCII string to screen ----
; In: $FB/$FC = string ptr, $FD/$FE = screen dest
PrintStringAt:
	LDY #0
PSA_LOOP:
	LDA ($FB),Y
	BEQ PSA_DONE
	STA ($FD),Y
	INY
	JMP PSA_LOOP
PSA_DONE:
	RTS

; ---- PrintStringInvAt: same but OR $80 (reverse video) ----
PrintStringInvAt:
	LDY #0
PSI_LOOP:
	LDA ($FB),Y
	BEQ PSI_DONE
	ORA #$80
	STA ($FD),Y
	INY
	JMP PSI_LOOP
PSI_DONE:
	RTS

; ============================================================
; StartMK3Playback — NMI-buffered double-buffer playback path
; ============================================================
StartMK3Playback:
	; Seek past 44-byte WAV header
	LDA #<WAV_HEADER_SIZE
	STA ZP_IRQ_API_SEEK_LO
	LDA #>WAV_HEADER_SIZE
	STA ZP_IRQ_API_SEEK_HI
	LDX #SEEK_DIRECTION_START
	JSR PROT_SeekFile

	; Init state
	LDA #$00
	STA ZP_WAV_EOFLAG

	; Pre-fill BUF_A (playback not started yet — SEI not needed)
	LDA #<AUDIO_BUF_A
	STA ZP_IRQ_API_DATA_LO
	LDA #>AUDIO_BUF_A
	STA ZP_IRQ_API_DATA_HI
	JSR ReadNextChunk

	; Pre-fill BUF_B
	LDA #<AUDIO_BUF_B
	STA ZP_IRQ_API_DATA_LO
	LDA #>AUDIO_BUF_B
	STA ZP_IRQ_API_DATA_HI
	JSR ReadNextChunk

	; Init playback pointer → BUF_A
	SEI
	LDA #<AUDIO_BUF_A
	STA ZP_WAV_PTR_LO
	LDA #>AUDIO_BUF_A
	STA ZP_WAV_PTR_HI
	LDA #AUDIO_BUF_A_END_HI
	STA ZP_WAV_END_HI
	LDA #$00
	STA ZP_WAV_ACTBUF
	STA ZP_WAV_FILL
	STA ZP_WAV_SILENCE      ; 0 = play normally (no stale guard yet)
	LDA #$01
	STA ZP_WAV_BUF_READY    ; 1 = BUF_B (inactive) is pre-filled and ready
	LDY #$00            ; Y fixed at 0 for PlaybackIRQ_Fast indirect read

	; Determine CIA1 timer value based on mode
	LDA #89             ; default: 11025 Hz (PLAYTYPE_MK3)
	LDX PLAYTYPE
	CPX #PLAYTYPE_MK3_22K
	BEQ SMK3_TIMER44
	CPX #PLAYTYPE_MK3_STEREO
	BNE SMK3_TIMER_SET
SMK3_TIMER44:
	LDA #44
SMK3_TIMER_SET:
	STA ZP_WAV_TIMERLO

	JSR MK3_ConfigureMode   ; reconfigure MK3 FIFO rate/frame_size if needed

	; Setup CIA1 Timer A
	LDA #$7F
	STA $DC0D           ; disable all CIA1 IRQs
	LDA $DC0D           ; ack pending
	LDA ZP_WAV_TIMERLO  ; 89 for 11025 Hz, 44 for 22050 Hz / stereo
	STA $DC04
	LDA #0
	STA $DC05
	LDA #$81            ; enable Timer A IRQ
	STA $DC0D
	LDA #<PlaybackIRQ_Fast
	STA $0314
	LDA #>PlaybackIRQ_Fast
	STA $0315
	LDA #(CRA_FORCE_LOAD + CRA_START)
	STA $DC0E

	CLI                 ; PLAYBACK STARTS

MK3MainLoop:
	; Check STOP key (CIA1 port A/B matrix scan: row 7 selects STOP column)
	LDA #$7F
	STA $DC00           ; select keyboard row 7
	LDA $DC01           ; read columns
	PHA
	LDA #$FF
	STA $DC00           ; restore: deselect all rows
	PLA
	AND #$80
	BEQ MK3_STOP        ; bit7 = 0 → STOP pressed

	; Check fill request
	LDA ZP_WAV_FILL
	BEQ MK3MainLoop

	; EOF set + fill request = last buffer was just drained → done
	LDA ZP_WAV_EOFLAG
	BNE MK3_STOP

	; Fill the INACTIVE buffer
	LDA ZP_WAV_ACTBUF
	BNE MK3_FILL_A      ; active=BUF_B → fill BUF_A
MK3_FILL_B:
	LDA #<AUDIO_BUF_B
	STA ZP_IRQ_API_DATA_LO
	LDA #>AUDIO_BUF_B
	STA ZP_IRQ_API_DATA_HI
	JMP MK3_DO_FILL
MK3_FILL_A:
	LDA #<AUDIO_BUF_A
	STA ZP_IRQ_API_DATA_LO
	LDA #>AUDIO_BUF_A
	STA ZP_IRQ_API_DATA_HI
MK3_DO_FILL:
	LDA #$00
	STA ZP_WAV_FILL
	JSR ReadNextChunk
	LDA #$00
	STA ZP_WAV_SILENCE      ; exit silence mode — buffer is now fresh
	JMP MK3MainLoop

MK3_STOP:
	SEI
	LDA #$7F
	STA $DC0D           ; disable CIA1 Timer A IRQ
	LDA $DC0D           ; ack pending
	CLI
	JSR CleanReturnToMenu
	RTS

; ============================================================
; PlaybackIRQ_Fast — CIA1 Timer A ISR, 11025 Hz
; Y register is kept 0 throughout playback (fixed offset for indirect read)
; Aligned to page boundary to avoid BNE crossing penalty
; ============================================================
.align $100
PlaybackIRQ_Fast:
	PHA                             ; 3
	LDA $DC0D                       ; 4 — ACK CIA1 (clears timer IRQ flag)

	LDA ZP_WAV_SILENCE              ; 3 — stale-read guard
	BNE PF_SILENT_PATH              ; 2 (not taken in normal case)

	LDA (ZP_WAV_PTR_LO),Y          ; 5 — Y=0 fixed throughout playback
	STA $DD01                       ; 4 — CIA2 DATA_B → DigiMax MK3 /PC2 latch

	INC ZP_WAV_PTR_LO               ; 5
	BNE PF_NO_PAGE                  ; 2/3
	INC ZP_WAV_PTR_HI               ; 5
	LDA ZP_WAV_PTR_HI               ; 3
	CMP ZP_WAV_END_HI               ; 3
	BEQ PF_SWAP                     ; 2/3
PF_NO_PAGE:
	PLA                             ; 4
	RTI                             ; 6
	; Normal path: 3+4+3+2+5+4+5+2+4+6 = 38 cycles ✓ (within 38-cycle budget at 22K)

PF_SILENT_PATH:
	; Inactive buffer not yet filled — feed MK3 FIFO with mid-scale silence.
	; ZP_WAV_PTR is not advanced; main loop clears ZP_WAV_SILENCE after fill.
	LDA #$80                        ; mid-scale for unsigned 8-bit PCM
	STA $DD01                       ; 4 — keep MK3 FIFO fed
	PLA
	RTI
	; Silence path: 3+4+3+3+2+4+4+6 = 29 cycles ✓

PF_SWAP:
	; Buffer boundary reached — swap active buffer, signal main loop to fill
	LDA ZP_WAV_ACTBUF
	EOR #$01
	STA ZP_WAV_ACTBUF
	BEQ PF_USE_A            ; new active = 0 → use BUF_A
PF_USE_B:
	LDA #<AUDIO_BUF_B
	STA ZP_WAV_PTR_LO
	LDA #>AUDIO_BUF_B
	STA ZP_WAV_PTR_HI
	LDA #AUDIO_BUF_B_END_HI
	STA ZP_WAV_END_HI
	JMP PF_REQ_FILL
PF_USE_A:
	LDA #<AUDIO_BUF_A
	STA ZP_WAV_PTR_LO
	LDA #>AUDIO_BUF_A
	STA ZP_WAV_PTR_HI
	LDA #AUDIO_BUF_A_END_HI
	STA ZP_WAV_END_HI
PF_REQ_FILL:
	LDA ZP_WAV_BUF_READY    ; was the inactive buffer fully filled?
	BEQ PF_SWAP_STALE
	LDA #$00
	STA ZP_WAV_BUF_READY    ; clear: main loop must refill this buffer next
	LDA #$01
	STA ZP_WAV_FILL
	PLA
	RTI
PF_SWAP_STALE:
	; Fill not complete — output silence until main loop catches up.
	; ZP_WAV_PTR already points to start of the new (not-yet-ready) buffer.
	LDA #$01
	STA ZP_WAV_SILENCE
	STA ZP_WAV_FILL         ; still request fill
	PLA
	RTI

; ============================================================
; ReadNextChunk — send COMMAND_READ_NEXT_CHUNK, receive
;                 BUFFER_PAGES*256 bytes via NMI into buffer
; In:  ZP_IRQ_API_DATA_LO/HI = target buffer base address
; Out: ZP_WAV_EOFLAG: set to $FF if Arduino reports last block
; ============================================================
ReadNextChunk:
	SEI

	; Mark buffer as filling (ISR will output silence if it reaches the end before we finish)
	LDA #$00
	STA ZP_WAV_BUF_READY

	; Install NMI vector → CARTRIDGENMIHANDLERX1 (X1 = 1 byte per NMI pulse)
	LDA NMITAB              ; = <CARTRIDGENMIHANDLERX1
	STA SOFTNMIVECTOR
	LDA #$80                ; high byte of $80AF ROM address
	STA SOFTNMIVECTOR+1

	; Reset transfer-done flag; set page count for NMI handler (X=pages, Y=index)
	LDA #$00
	STA ZP_IRQ_STATE_WAITHANDLE
	LDX #BUFFER_PAGES       ; NMI handler counts down X pages
	LDY #$00                ; byte index within current page

	; Send command byte + page count argument within current session
	LDA #COMMAND_READ_NEXT_CHUNK
	JSR PROT_Send
	LDA #BUFFER_PAGES
	JSR PROT_Send

	; Switch bank so CARTRIDGE_BANK_VALUE is readable
	#SETBANK PP_CONFIG_DEFAULT

	; Wait for Arduino status byte (0x80=more, 0x81=last)
	JSR PROT_WaitProcessing
	BCS RNC_ERROR

	; A = status from Arduino
	AND #$01                ; bit0: 0=more data, 1=last block
	BEQ RNC_NOT_EOF
	LDA #$FF
	STA ZP_WAV_EOFLAG
RNC_NOT_EOF:

	CLI                     ; enable CIA1 IRQ BEFORE waiting for NMI transfer

	; Wait for NMI handler to finish all BUFFER_PAGES pages
	CLV
	#WAITFOR ZP_IRQ_STATE_WAITHANDLE, BVC

	; Signal: buffer fully filled and ready for ISR to play
	LDA #$01
	STA ZP_WAV_BUF_READY
	RTS

RNC_ERROR:
	LDA #$FF
	STA ZP_WAV_EOFLAG
	LDA #$01
	STA ZP_WAV_BUF_READY    ; unblock ISR silence guard even on error
	CLI
	RTS

; ============================================================
; MK3_SP2_HIGH — drive SP2 line HIGH (CIA2 SDR output = $FF)
; MK3_SP2_LOW  — release SP2 line LOW (external pull-down takes over)
; MK3_SendCmd  — In: A = byte; sends to MK3 via CIA2 DATA_B ($DD01)
; ============================================================
MK3_SP2_HIGH:
	LDA $DD0F
	ORA #$40            ; CRB bit6=1: SDR as output
	STA $DD0F
	LDA #$FF
	STA $DD0C           ; SDR write → SP2 HIGH
	RTS

MK3_SP2_LOW:
	LDA $DD0F
	AND #$BF            ; CRB bit6=0: SDR as input → pull-down → SP2 LOW
	STA $DD0F
	RTS

MK3_SendCmd:
	STA $DD01           ; CIA2 DATA_B → triggers MK3 /PC2 INT0
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	RTS

; ============================================================
; MK3_ConfigureMode — reconfigure MK3 for selected PLAYTYPE
; Called from StartMK3Playback, inside SEI, before CIA1 setup.
;
; CIA1 timer N+1 rule: timer=89 → 985248/90=10947 Hz; timer=44 → 985248/45=21894 Hz.
; MK3 OCR1A N+1 rule: 16000000/(OCR1A+1). Calibrated to match C64 CIA1 rate.
;
; Mode 3 (PLAYTYPE_MK3):        OCR1A=1461 → 10944 Hz ≈ C64 10947 Hz (+2.6 B/s).
; Mode 4 (PLAYTYPE_MK3_22K):    OCR1A=730  → 21888 Hz ≈ C64 21894 Hz (+6.0 B/s).
; Mode 5 (PLAYTYPE_MK3_STEREO): OCR1A=1461 + frame_size=2 → 21889 B/s ≈ 21894 B/s.
; ============================================================
MK3_ConfigureMode:
	LDA PLAYTYPE
	CMP #PLAYTYPE_MK3
	BEQ MCM_Mode3       ; mode 3: flush + OCR1A + 4× oversample + stream_push

	JSR MK3_SP2_HIGH
	LDA #$42
	JSR MK3_SendCmd     ; CMD_FLUSH_FIFO → exits PARSER_STREAM_RECV → PARSER_IDLE

	LDA PLAYTYPE
	CMP #PLAYTYPE_MK3_22K
	BNE MCM_Stereo

MCM_22K:
	; OCR1A=730 → 16000000/731=21888 Hz ≈ C64 CIA 21894 Hz (drift +6 B/s, FIFO stable).
	; CMD_SET_RATE_L takes exactly 2 arg bytes (lo, hi) — no CMD_SET_RATE_H opcode.
	; Protocol arg-collection ignores is_cmd, but CMD_SET_RATE_H (0x21) would be
	; consumed as the high byte, giving a wrong OCR1A value. Send lo+hi directly.
	LDA #$20
	JSR MK3_SendCmd     ; CMD_SET_RATE_L
	LDA #$DA
	JSR MK3_SendCmd     ; OCR1A low byte  (730 = $02DA)
	LDA #$02
	JSR MK3_SendCmd     ; OCR1A high byte
	JMP MCM_Restart

MCM_Stereo:
	; OCR1A=1461 × frame_size=2 → 16000000/1462×2=21889 B/s ≈ C64 21894 B/s (+5 B/s).
	LDA #$20
	JSR MK3_SendCmd     ; CMD_SET_RATE_L
	LDA #$B5
	JSR MK3_SendCmd     ; OCR1A low byte  (1461 = $05B5)
	LDA #$05
	JSR MK3_SendCmd     ; OCR1A high byte
	LDA #$23
	JSR MK3_SendCmd     ; CMD_SET_FRAME_SIZE
	LDA #$02
	JSR MK3_SendCmd     ; frame_size=2 (L+R pair per tick)

MCM_Restart:
	LDA #$30
	JSR MK3_SendCmd     ; CMD_STREAM_PUSH → enters PARSER_STREAM_RECV
	JSR MK3_SP2_LOW

MCM_Done:
	RTS

MCM_Mode3:
	; Mode 3 (11025 Hz mono, 4× oversampling):
	;   OCR1A=1461 stored → timer_apply_period divides by 4 → OCR1A=365
	;   MK3 TIMER1 fires at 16000000/366 ≈ 43716 Hz ≈ 4 × 10929 Hz.
	;   C64 CIA1 sends at 985248/90=10947 Hz → MK3 slightly slower (+18 B/s FIFO fill).
	;   CMD_SET_OVERSAMPLE $04 activates linear interpolation in TIMER1_COMPA_vect.
	JSR MK3_SP2_HIGH
	LDA #$42
	JSR MK3_SendCmd     ; CMD_FLUSH_FIFO → PARSER_IDLE, FIFO clean
	LDA #$20
	JSR MK3_SendCmd     ; CMD_SET_RATE_L
	LDA #$B5
	JSR MK3_SendCmd     ; OCR1A low byte  (1461 = $05B5; firmware divides by 4 → 365)
	LDA #$05
	JSR MK3_SendCmd     ; OCR1A high byte
	LDA #$24
	JSR MK3_SendCmd     ; CMD_SET_OVERSAMPLE
	LDA #$04
	JSR MK3_SendCmd     ; factor = 4
	JMP MCM_Restart     ; → CMD_STREAM_PUSH + SP2_LOW + RTS


.include "../../Loader/CartLibStream.s"