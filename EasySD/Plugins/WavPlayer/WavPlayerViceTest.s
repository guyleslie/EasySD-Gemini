; WavPlayerViceTest.s
; VICE-only audio pipeline test for WavPlayer.
; No Arduino hardware required.
;
; Tests the CIA1 Timer A + SHIFT4BIT + SID master volume chain
; that WavPlayer relies on in production.
;
; Generates a ~430 Hz sawtooth tone:
;   - CIA1 Timer A fires at 11025 Hz (reload = 89 PAL cycles)
;   - Each interrupt reads one byte from TESTBUFFER via SHIFT4BIT
;   - Output goes to SID master volume register ($D418)
;   - Border color increments each interrupt (visual confirmation)
;
; Expected result in VICE:
;   - Audible ~430 Hz tone through SID emulation
;   - Border cycles through colors rapidly (interrupt alive indicator)
;   - Press STOP to exit back to BASIC
;
; To build:  python Tools/build.py debug-vice
; To run:    LOAD "wavtest.prg",8  then  RUN  in VICE (x64sc)
; Also runs through the PRG plugin on real hardware for C64-side verification.
;
; Original WavPlayer: 04/08/2018 - Istanbul / I.R.on

.enc "screen"

;==============================================================================
; Zero-page variables ($FB-$FE: plugin-safe range per CartZpMap.inc)
;==============================================================================
BUFIDX   = $FB          ; current read position in TESTBUFFER (0..255, wraps)

;==============================================================================
; Hardware addresses
;==============================================================================
CIA1_PRA     = $DC00    ; Port A: keyboard column select (output, active-low)
CIA1_PRB     = $DC01    ; Port B: keyboard row read (input, active-low)
CIA1_DDRA    = $DC02    ; Port A data-direction register
CIA1_DDRB    = $DC03    ; Port B data-direction register
CIA1_TA_LO   = $DC04    ; Timer A low byte (reload value)
CIA1_TA_HI   = $DC05    ; Timer A high byte (reload value)
CIA1_ICR     = $DC0D    ; Interrupt control (read=status, write=mask)
CIA1_CRA     = $DC0E    ; Control register A

VIC_BORDER   = $D020
VIC_BG       = $D021
SID_VOL      = $D418    ; SID master volume (bits 0-3 = 0..15, 4-bit PCM)

;==============================================================================
; PAL clock: 985248 Hz / 11025 Hz ≈ 89 cycles per sample
;==============================================================================
CIA_RELOAD   = 89

;==============================================================================
; BASIC stub at $0801: 10 SYS 2061  ($080D)
;
; $0801: next-line ptr → $080B
; $0803: line number   → 10
; $0805: SYS token     → $9E
; $0806: "2061"        → 4 bytes
; $080A: EOL           → $00
; $080B: BASIC end     → $0000
; $080D: machine code start (= 2061 decimal)
;==============================================================================
*=$0801
    .word $080b         ; pointer to next BASIC line
    .word 10            ; line number 10
    .byte $9e           ; SYS keyword token
    .text "2061"        ; target address as ASCII (= $080D)
    .byte 0             ; end of BASIC line
    .word 0             ; end of BASIC program

;==============================================================================
; Entry point
;==============================================================================
*=$080d

MAIN:
    SEI

    ;--- Disable all interrupt sources ---
    LDA #$7F
    STA CIA1_ICR        ; CIA1: disable all timer interrupts
    STA $DD0D           ; CIA2: same
    LDA CIA1_ICR        ; ACK any pending CIA1 interrupt
    LDA $DD0D           ; ACK any pending CIA2 interrupt
    LDA #$00
    STA $D01A           ; VIC: disable raster IRQ
    ASL $D019           ; VIC: ACK any pending raster interrupt

    ;--- Set $01=$35: I/O visible at $D000, KERNAL hidden (RAM at $E000) ---
    ; This lets us install our own IRQ vector at $FFFE/$FFFF in RAM.
    LDA #$35
    STA $01

    ;--- Install IRQ vector in RAM ---
    LDA #<CIAIRQ
    STA $FFFE
    LDA #>CIAIRQ
    STA $FFFF

    ;--- CIA1 keyboard port directions ---
    LDA #$FF
    STA CIA1_DDRA       ; Port A = output (column drive)
    LDA #$00
    STA CIA1_DDRB       ; Port B = input  (row read)

    ;--- SID: 3 voices in 4-bit PCM mode ---
    ; Gate on + triangle waveform, maximum sustain — same setup as WavPlayer
    LDA #$FF
    STA $D406           ; Voice 1: sustain=F, release=F
    LDA #$49            ; %01001001: triangle waveform + gate bit
    STA $D404           ; Voice 1 control
    LDA #$FF
    STA $D406+7         ; Voice 2
    LDA #$49
    STA $D404+7
    LDA #$FF
    STA $D406+14        ; Voice 3
    LDA #$49
    STA $D404+14

    ;--- Build SHIFT4BIT table (x >> 4, range 0..15) ---
    JSR PREPARESHIFTBIT

    ;--- Initialize ---
    LDA #$00
    STA BUFIDX          ; start at position 0 in TESTBUFFER
    STA VIC_BORDER      ; black border (interrupt will cycle it)
    STA VIC_BG          ; black background

    ;--- CIA1 Timer A: 89-cycle reload, continuous ---
    LDA #<CIA_RELOAD
    STA CIA1_TA_LO
    LDA #>CIA_RELOAD
    STA CIA1_TA_HI
    LDA #$81            ; write: set bit 7 (set mode) + bit 0 (Timer A enable)
    STA CIA1_ICR
    LDA #$11            ; CRA: %00010001 = FORCE_LOAD | START (continuous mode)
    STA CIA1_CRA

    CLI                 ; let the interrupts fire

    ;==========================================================================
    ; Main loop: poll STOP key
    ; STOP key: column 7 ($DC00=$7F), row 7 (bit 7 of $DC01 = 0 when pressed)
    ;==========================================================================
LOOP:
    LDA #$7F
    STA CIA1_PRA        ; assert column 7
    LDA CIA1_PRB        ; read rows
    AND #$80            ; bit 7 = STOP key (0 = pressed)
    BNE LOOP            ; keep looping while STOP not pressed

    ;==========================================================================
    ; Exit: stop CIA, silence SID, restore environment
    ;==========================================================================
    SEI

    LDA #$7F
    STA CIA1_ICR        ; CIA1: disable all interrupts
    LDA CIA1_ICR        ; ACK any pending
    LDA #$00
    STA CIA1_CRA        ; stop Timer A

    STA SID_VOL         ; silence SID master volume
    STA $D404           ; voice 1: gate off
    STA $D404+7         ; voice 2
    STA $D404+14        ; voice 3

    LDA #$37            ; restore $01: KERNAL + BASIC + I/O
    STA $01

    LDA #$0E            ; light blue (standard C64 border)
    STA VIC_BORDER

    CLI
    RTS                 ; return to BASIC

;==============================================================================
; CIA1 Timer A interrupt handler (fires ~11025 times per second)
;
; Reads one 8-bit sample from TESTBUFFER, converts to 4-bit via
; SHIFT4BIT, writes to SID master volume. Same logic as WavPlayer's
; PlayRoutineSimple, but reading from an embedded buffer instead of
; the Arduino EEPROM.
;==============================================================================
CIAIRQ:
    PHA
    TXA
    PHA
    TYA
    PHA

    LDX BUFIDX
    LDA TESTBUFFER, X   ; get next 8-bit sample from test tone
    INX                  ; advance (wraps from 255 → 0 automatically)
    STX BUFIDX
    TAY
    LDA SHIFT4BIT, Y    ; convert 8-bit → 4-bit volume (x >> 4)
    STA SID_VOL         ; output to SID master volume register

    INC VIC_BORDER      ; cycle border color: visual "interrupt alive" indicator

    LDA CIA1_ICR        ; acknowledge CIA1 Timer A interrupt (must read to clear)

    PLA
    TAY
    PLA
    TAX
    PLA
    RTI

;==============================================================================
; PREPARESHIFTBIT: fill SHIFT4BIT[x] = x >> 4  (0..15)
; Same routine as WavPlayer.s
;==============================================================================
PREPARESHIFTBIT:
    LDX #0
-   TXA
    LSR
    LSR
    LSR
    LSR
    STA SHIFT4BIT, X
    INX
    BNE -
    RTS

;==============================================================================
; TESTBUFFER: 256-byte sawtooth test tone
;
; byte[i] = (i × 10) mod 256
; Period ≈ 25.6 samples at 11025 Hz → frequency ≈ 430 Hz
; The buffer loops continuously → sustained tone
;==============================================================================
.align $100
TESTBUFFER:
.for i=0, i<256, i=i+1
    .byte <(i * 10)
.next

;==============================================================================
; SHIFT4BIT lookup table (256 bytes, page-aligned)
; Filled at runtime by PREPARESHIFTBIT.
; SHIFT4BIT[x] = x >> 4 maps 8-bit sample (0..255) to 4-bit volume (0..15)
;==============================================================================
.align $100
SHIFT4BIT:
    .fill 256
