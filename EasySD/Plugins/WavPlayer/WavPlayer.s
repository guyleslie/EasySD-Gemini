; WavPlayer.s — C64 WAV audio plugin for EasySD cartridge
; Plays 8-bit unsigned PCM mono WAV files via CIA1 Timer A IRQ.
;
; Playback modes:
;   0 = SID 4-bit digi  — upper nibble of sample -> $D418 master volume
;   1 = DigiMax 8-bit   — full sample byte -> CIA2 PORT B ($DD01)
;
; Streaming: Arduino IO2 double-buffer (64+64 bytes), /IO2 trigger at
; MODULATION_ADDRESS ($DF00), data read from ROML at CARTRIDGE_BANK_VALUE ($80AB).
; PAL CIA1 Timer A reload=89 -> 985248/90 = 10947 Hz ~= 11kHz.
;
; Exit: SEL button resets the C64, returning to EasySD menu.
;       On file-open error: PROT_ExitToMenu is called directly.

.enc "screen"    ; all .text literals use C64 screen codes

; ---- Plugin-local zero page ----
PLAYTYPE        = $A3           ; 0=SID 4-bit, 1=DigiMax 8-bit

; ---- Constants ----
PLAYTYPE_ONLYSID  = 0
PLAYTYPE_DIGIMAX  = 1
WAV_HEADER_SIZE   = 44          ; standard PCM WAV header size in bytes

; ---- Macro includes (must come before first use) ----
.include "../../Loader/DebugMacros.s"
.include "../../Loader/APIMacros.s"

; ============================================================
; Plugin entry point at $C000
; ============================================================

        *=$C000

PETGLPLUGINREAD                 ; standard plugin entry label
        JMP MAIN

; ============================================================
; MAIN — open file, select mode, start playback
; ============================================================
MAIN:
        JSR SAVESTATE           ; save VIC / $01 / $DD00 state
        JSR INIT                ; clear screen, disable IRQs, build SHIFT4BIT
        JSR PROT_StartTalking   ; initialise cartridge communication

        #LOADMEDIAPATH MEDIAPATH_BUF    ; recover path from $FF00 shadow

        DELAYFRAMES 5
        JSR PROT_DisableDisplay

        LDX #<MEDIAPATH_BUF
        LDY #>MEDIAPATH_BUF
        JSR PROT_SetNameZ
        BCS ERROR_OPENING_FILE

        LDX #01
        JSR PROT_OpenFile
        BCC OPENINGCONT
        JMP ERROR_OPENING_FILE

OPENINGCONT:
        JSR PROT_EnableDisplay
        DELAYFRAMES 5

        ; Display mode selection menu, returns PLAYTYPE in A
        JSR ShowModeSelector
        STA PLAYTYPE

        ; Clear screen before starting playback
        LDA #$93
        JSR CHROUT

        JMP STREAMFILE

; ---- Error path: file could not be opened ----
ERROR_OPENING_FILE:
        JSR PROT_EnableDisplay
        PRINTSTATUSANDWAIT OPENINGFILEFAILED, 200
        JSR RESTORESTATE        ; restore VIC/$01 before handing control back
        JSR PROT_ExitToMenu
        RTS                     ; never reached

; ============================================================
; SeekPastWavHeader — skip the 44-byte PCM WAV header
; ============================================================
SeekPastWavHeader:
        LDA #<WAV_HEADER_SIZE
        STA ZP_IRQ_API_SEEK_LO
        LDA #>WAV_HEADER_SIZE
        STA ZP_IRQ_API_SEEK_HI
        LDX #SEEK_DIRECTION_START
        JSR PROT_SeekFile
        RTS

; ============================================================
; STREAMFILE — seek past header, start IO2 stream, launch IRQ
; ============================================================
STREAMFILE:
        JSR SeekPastWavHeader

        ; Start Arduino IO2 double-buffer streaming.
        ; A=0 initialDelay, X=0 countStreamedBytes, Y=$80 EOF pad byte
        ; ($80 = mid-scale silence for unsigned 8-bit PCM)
        LDA #$00
        LDX #$00
        LDY #$80
        JSR PROT_Stream

        JSR SETUPMUSICTRANSFER  ; install IRQ handler, start CIA1, CLI
        JSR PROT_DisableDisplay

        ; CPU spins here forever.
        ; Playback runs entirely inside the CIA1 Timer A IRQ handler.
        ; To stop: press SEL -- the C64 resets and returns to the EasySD menu.
        JMP *

; ============================================================
; PlayRoutine — CIA1 Timer A ISR, SID 4-bit digi mode
;
; Each call reads one byte from the Arduino IO2 stream and
; outputs its upper nibble (0-15) to SID master volume $D418.
;
; PAL timing: CIA1 reload=89 -> period=90 cycles -> 10947 Hz ~= 11kHz
; Registers saved: A, Y  (X not used)
; ============================================================
.align $100
PlayRoutine:
        PHA                             ; save A
        TYA                             ; save Y via stack
        PHA

        #SETBANK PP_CONFIG_DEFAULT      ; expose ROML ($8000) + I/O ($D000)

        LDA MODULATION_ADDRESS          ; trigger /IO2 - Arduino drives data bus
        NOP                             ; ~2-cycle settling window
        LDA CARTRIDGE_BANK_VALUE        ; read byte from ROML bus at $80AB
        TAY                             ; byte -> Y as SHIFT4BIT index
        LDA SHIFT4BIT, Y               ; SHIFT4BIT[n] = n >> 4  -> range 0..15
        STA $D418                       ; SID master volume DAC

        #SETBANK PP_CONFIG_RAM_ON_ROM   ; restore normal banking

        LDA CIA_1_BASE + CIA_INT_MASK   ; ACK CIA1 Timer A IRQ

        PLA                             ; restore Y
        TAY
        PLA                             ; restore A
        RTI

; ============================================================
; PlayDigimax — CIA1 Timer A ISR, DigiMax 8-bit mode
;
; Each call reads one byte from the Arduino IO2 stream and
; writes it to CIA2 PORT B ($DD01).  The CIA2 /PC2 handshake
; line auto-pulses LOW on any PORT B write, strobing the
; TLC7226 DAC /WR input.
; NMIDIGI_InitNew selects DAC C (Left): CIA2 PA3=1, PA2=0.
;
; Registers saved: A only  (X, Y not used)
; ============================================================
.align $100
PlayDigimax:
        PHA                             ; save A

        #SETBANK PP_CONFIG_DEFAULT      ; expose ROML + I/O

        LDA MODULATION_ADDRESS          ; trigger /IO2
        NOP                             ; settling time
        LDA CARTRIDGE_BANK_VALUE        ; read byte from ROML bus
        STA CIA_2_BASE + DATA_B         ; $DD01 -> DigiMax DAC, /PC2 auto-latches

        #SETBANK PP_CONFIG_RAM_ON_ROM   ; restore banking

        LDA CIA_1_BASE + CIA_INT_MASK   ; ACK CIA1 Timer A IRQ

        PLA                             ; restore A
        RTI

; ============================================================
; SETUPMUSICTRANSFER — install chosen IRQ handler, start CIA1
; ============================================================
SETUPMUSICTRANSFER:
        SEI
        #SETBANK PP_CONFIG_RAM_ON_ROM

        LDA PLAYTYPE
        BNE SetupDigimax
        ; Fall through: SID 4-bit mode

SetupSidOnly:
        JSR DIGI_Init           ; prime SID voices for 4-bit digi output
        LDA #<PlayRoutine
        STA IRQVECTOR           ; $0314 - KERNAL IRQ dispatch vector lo
        LDA #>PlayRoutine
        STA IRQVECTOR+1
        JMP SetupInterrupt

SetupDigimax:
        JSR NMIDIGI_InitNew     ; configure CIA2 PORT A/B for DigiMax
        LDA #<PlayDigimax
        STA IRQVECTOR
        LDA #>PlayDigimax
        STA IRQVECTOR+1
        ; fall through to SetupInterrupt

SetupInterrupt:
        LDA #$00
        STA CIA_1_BASE + TIMER_A_HI             ; timer high byte = 0
        LDA #89                                 ; PAL: 985248 / 90 = 10947 Hz
        STA CIA_1_BASE + TIMER_A_LO
        LDA #$81                                ; enable Timer A IRQ
        STA CIA_1_BASE + CIA_INT_MASK
        LDA #(CRA_FORCE_LOAD + CRA_START)       ; continuous mode, force load
        STA CIA_1_BASE + CIA_TIMER_A_CTRL
        LDA CIA_1_BASE + CIA_INT_MASK           ; ACK any latched interrupt before CLI
        CLI                                     ; IRQ playback begins here
        RTS

; ============================================================
; DIGI_Init — prepare SID for 4-bit digi playback
; Sets all three voices to PULSE waveform + TEST bit + max sustain.
; Required before using SID $D418 as a 4-bit DAC.
; ============================================================
DIGI_Init:
        LDA #$FF
        STA $D406               ; voice 1 SR: sustain=F, release=F
        STA $D406 + 7           ; voice 2
        STA $D406 + 14          ; voice 3
        LDA #$49                ; PULSE + TEST + GATE
        STA $D404               ; voice 1 control register
        STA $D404 + 7           ; voice 2
        STA $D404 + 14          ; voice 3
        RTS

; ============================================================
; NMIDIGI_InitNew — configure CIA2 for DigiMax DAC output
; PA3=1, PA2=0 -> TLC7226 A1=1, A0=0 -> DAC C (Left channel).
; Any PORT B write auto-pulses /PC2 LOW -> TLC7226 /WR strobe.
; ============================================================
NMIDIGI_InitNew:
        LDA CIA_2_BASE + DDR_A
        ORA #$0C                ; set PA3 + PA2 as output
        STA CIA_2_BASE + DDR_A
        LDA CIA_2_BASE + DATA_A
        ORA #$08                ; PA3=1 - selects DAC C (Left)
        STA CIA_2_BASE + DATA_A
        LDA #$FF
        STA CIA_2_BASE + DDR_B  ; PORT B all-output (DigiMax data lines)
        RTS

; ============================================================
; INIT — screen clear, interrupt disable, lookup table build
; ============================================================
INIT:
        CLD
        LDA #$93
        JSR CHROUT              ; KERNAL: clear screen
        LDA #$00
        STA $D020               ; black border
        LDA #$0B
        STA $D021               ; dark grey background
        JSR INITPC
        JSR DISABLEINTERRUPTS
        JSR PREPARESHIFTBIT
        RTS

; INITPC — fill all 1000 color RAM positions with $0F (white)
INITPC:
        LDX #$00
        LDA #$0F
INITPC_LOOP:
        STA $D800, X
        STA $D900, X
        STA $DA00, X
        STA $DB00, X
        INX
        BNE INITPC_LOOP
        RTS

; DISABLEINTERRUPTS — silence all interrupt sources
DISABLEINTERRUPTS:
        LDY #$7F
        STY $DC0D               ; disable all CIA1 IRQs
        STY $DD0D               ; disable all CIA2 IRQs
        LDA $DC0D               ; ACK any pending CIA1 interrupt
        LDA $DD0D               ; ACK any pending CIA2 interrupt
        ASL $D019               ; ACK VIC raster interrupt
        LDA #$00
        STA $D01A               ; disable VIC raster interrupt enable
        RTS

; PREPARESHIFTBIT — build 256-byte table: SHIFT4BIT[n] = n >> 4
; Used by PlayRoutine to extract the upper nibble of each sample byte.
PREPARESHIFTBIT:
        LDX #0
PRSB_LOOP:
        TXA
        LSR
        LSR
        LSR
        LSR
        STA SHIFT4BIT, X
        INX
        BNE PRSB_LOOP
        RTS

; ============================================================
; State save / restore — called at plugin entry and error exit
; ============================================================
FORCEIO:
        LDA $01
        ORA #$04                ; ensure I/O ($D000-$DFFF) is visible
        STA $01
        RTS

SAVESTATE:
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

RESTORESTATE:
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

SAVED_01:   .byte 0
SAVED_DD00: .byte 0
SAVED_D011: .byte 0
SAVED_D016: .byte 0
SAVED_D018: .byte 0
SAVED_D020: .byte 0
SAVED_D021: .byte 0
SAVED_D022: .byte 0
SAVED_D023: .byte 0

; ============================================================
; ShowModeSelector — 2-item playback mode selection menu
; Returns selected PLAYTYPE in A (0=SID, 1=DigiMax)
; Key handling: DOWN ($11) / UP ($91) toggle, RETURN ($0D) confirms.
; Uses polled SCNKEY+GETIN - CIA IRQs are disabled during menu.
; ============================================================
MENU_CURSOR:    .byte 0         ; current selection: 0=SID, 1=DigiMax

MENU_ROW_SID    = $0400 + 3*40 + 4
MENU_ROW_DIGI   = $0400 + 5*40 + 4

STR_TITLE:      .text "WAV PLAYER - SELECT MODE"
                .byte 0
STR_SID:        .text "SID 4-BIT"
                .byte 0
STR_DIGIMAX:    .text "DIGIMAX"
                .byte 0

ShowModeSelector:
        LDA #$00
        STA $D020
        STA $D021
        LDA #$93
        JSR CHROUT

        LDA #0
        STA MENU_CURSOR

        LDA #<STR_TITLE
        STA $FB
        LDA #>STR_TITLE
        STA $FC
        LDA #<($0400 + 1*40 + 4)
        STA $FD
        LDA #>($0400 + 1*40 + 4)
        STA $FE
        JSR PrintStringAt

MSSEL_LOOP:
        JSR MS_Render
        JSR SCNKEY
        JSR GETIN
        BEQ MSSEL_LOOP

        CMP #$11                ; cursor DOWN
        BEQ MSSEL_TOGGLE
        CMP #$91                ; cursor UP
        BEQ MSSEL_TOGGLE
        CMP #$0D                ; RETURN - confirm
        BEQ MSSEL_SELECT
        JMP MSSEL_LOOP

MSSEL_TOGGLE:
        LDA MENU_CURSOR
        EOR #$01                ; toggle 0 <-> 1
        STA MENU_CURSOR
        JMP MSSEL_LOOP

MSSEL_SELECT:
        LDA MENU_CURSOR
        RTS

MS_Render:
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
        RTS
MSR_DIGI_NORMAL:
        JSR PrintStringAt
        RTS

PrintStringAt:
        LDY #0
PSA_LOOP:
        LDA ($FB), Y
        BEQ PSA_DONE
        STA ($FD), Y
        INY
        JMP PSA_LOOP
PSA_DONE:
        RTS

PrintStringInvAt:
        LDY #0
PSI_LOOP:
        LDA ($FB), Y
        BEQ PSI_DONE
        ORA #$80
        STA ($FD), Y
        INY
        JMP PSI_LOOP
PSI_DONE:
        RTS

; ============================================================
; WAITFRAMES — wait X raster frames (used by DELAYFRAMES macro in DEBUG builds)
; ============================================================
WAITFRAMES:
WFLOOP:
        LDY #$90
WFRASTER:
        CPY $D012
        BNE WFRASTER
        LDY #50
WFDELAY:
        DEY
        BNE WFDELAY
        DEX
        BNE WFLOOP
        RTS

; ============================================================
; Data
; ============================================================
OPENINGFILEFAILED:  .text "OPENING WAV FILE FAILED"
                    .byte 0

MEDIAPATH_BUF:  .fill 256, 0

.align $100
SHIFT4BIT:  .fill 256, 0

.include "../../Loader/CartLibStream.s"