; PrgLoadViceTest.s
; VICE-only PRG loading pipeline test for KernalBridge.
; No Arduino hardware required.
;
; Tests the core KernalBridge PRG load sequence in isolation:
;   1. Parse 2-byte little-endian load address from embedded MOCK_PRG header
;   2. Copy payload bytes to load address    (simulates the NMI byte transfer)
;   3. Jump to loaded code via ZP indirect pointer  ($FB/$FC = ZP_DEST)
;   4. Loaded code executes, RTS returns via pre-pushed return address on stack
;
; MOCK_PRG is an 18-byte machine-code stub that:
;   - Sets border to green (#5)   = "I am running at the load address"
;   - Polls STOP key (CIA1 col 7, row 7)
;   - Returns via RTS when STOP is pressed
;
; Visual protocol (border color = test phase indicator):
;   YELLOW  -> test starting, parsing MOCK_PRG header
;   BLUE    -> copy loop in progress
;   GREEN   -> mock PRG running at $C000 (copy + jump succeeded)
;   LTBLUE  -> mock PRG returned via RTS (full pipeline passed)
;
; Expected result in VICE:
;   1. Yellow border + "PARSE OK" on screen row 0
;   2. Blue border  + "COPY  OK" on screen row 1
;   3. Green border — press STOP to trigger RTS from mock payload
;   4. Light blue border + "RETURNED OK" on row 2 — press any key to exit BASIC
;
; To build: python Tools/build.py debug-vice
; To run:   LOAD "prgtest.prg",8,1   then   RUN   in VICE (x64sc)
;
; Original design: 03/2026 - EasySD project

.enc "screen"

;==============================================================================
; Zero-page variables ($FB-$FE: plugin-safe range per CartZpMap.inc)
;==============================================================================
ZP_DEST_LO   = $FB          ; destination pointer lo (= parsed load address)
ZP_DEST_HI   = $FC          ; destination pointer hi
ZP_SRC_LO    = $FD          ; source pointer lo      (into MOCK_PRG payload)
ZP_SRC_HI    = $FE          ; source pointer hi

;==============================================================================
; Hardware / KERNAL addresses
;==============================================================================
CIA1_PRA     = $DC00        ; Port A: keyboard column select (output, active-low)
CIA1_PRB     = $DC01        ; Port B: keyboard row read (input, active-low)
VIC_BORDER   = $D020
VIC_BG       = $D021
CHROUT       = $FFD2        ; KERNAL: character output
GETIN        = $FFE4        ; KERNAL: get character from keyboard

;==============================================================================
; Screen layout
;   Screen RAM at $0400, 40 chars per line
;==============================================================================
SCREEN       = $0400
LINE0        = SCREEN + 0*40    ; phase 1 result: "PARSE OK"
LINE1        = SCREEN + 1*40    ; phase 2 result: "COPY  OK"
LINE2        = SCREEN + 2*40    ; phase 3 result: "RETURNED OK"

;==============================================================================
; MOCK_PRG constants
;   Payload size is computed from MOCK_PAYLOAD_END - MOCK_PAYLOAD_START
;   below. 64tass resolves this across passes.
;==============================================================================
MOCK_LOAD_ADDR = $C000          ; target address of mock payload after copy
                                ; $C000: above BASIC area, below cartridge ROM

;==============================================================================
; BASIC stub at $0801: 10 SYS 2061  ($080D)
;
; $0801: next-line ptr -> $080B
; $0803: line number  -> 10
; $0805: SYS token    -> $9E
; $0806: "2061"       -> 4 bytes ASCII  (= $080D decimal)
; $080A: EOL          -> $00
; $080B: BASIC end    -> $0000
; $080D: machine code start
;==============================================================================
*=$0801
    .word $080b         ; pointer to next BASIC line
    .word 10            ; line number 10
    .byte $9e           ; SYS keyword token
    .text "2061"        ; target address as ASCII digits
    .byte 0             ; end of BASIC line
    .word 0             ; end of BASIC program

;==============================================================================
; Entry point at $080D
;==============================================================================
*=$080d
MAIN:
    ;--- Setup: clear screen, black background ---
    LDA #$93            ; PETSCII: clear screen character
    JSR CHROUT          ; KERNAL CHROUT: clear screen and home cursor

    LDA #7              ; YELLOW border = "test starting / parse phase"
    STA VIC_BORDER
    LDA #0
    STA VIC_BG

    ;==========================================================================
    ; Phase 1: Parse MOCK_PRG 2-byte little-endian header -> load address
    ;
    ; Mirrors KernalBridge: read GENERALBUFFER[0..1] after IRQ_ReadFileNoCallback,
    ; here reading from the embedded MOCK_PRG instead of from the Arduino.
    ;==========================================================================
    LDA MOCK_PRG        ; byte 0: load address lo
    STA ZP_DEST_LO
    LDA MOCK_PRG+1      ; byte 1: load address hi
    STA ZP_DEST_HI

    ; Print "PARSE OK" on LINE0
    LDX #0
PRINT_P1:
    LDA MSG_PARSE, X
    STA LINE0, X
    INX
    CPX #MSG_PARSE_LEN
    BNE PRINT_P1

    ;==========================================================================
    ; Phase 2: Copy MOCK payload to load address
    ;
    ; Mirrors the NMI byte-transfer loop: each byte that the Arduino sends via
    ; TransferHandler (CartLib.s) ends up at (ZP_IRQ_API_DATA_LO),Y.
    ; Here we simulate it with a simple software copy loop.
    ;==========================================================================
    LDA #6              ; BLUE border = "copy in progress"
    STA VIC_BORDER

    ; Source pointer: MOCK_PRG + 2  (skip the 2-byte header)
    LDA #<(MOCK_PRG+2)
    STA ZP_SRC_LO
    LDA #>(MOCK_PRG+2)
    STA ZP_SRC_HI

    LDY #0
COPY_LOOP:
    LDA (ZP_SRC_LO), Y
    STA (ZP_DEST_LO), Y
    INY
    CPY #MOCK_PAYLOAD_LEN
    BNE COPY_LOOP

    ; Print "COPY OK" on LINE1
    LDX #0
PRINT_P2:
    LDA MSG_COPY, X
    STA LINE1, X
    INX
    CPX #MSG_COPY_LEN
    BNE PRINT_P2

    ;==========================================================================
    ; Phase 3: Launch via ZP indirect (mirrors KernalBridge MACHINELANG path)
    ;
    ; KernalBridge stores load address in $FB/$FC and does JMP ($00FB).
    ; To get a clean RTS return from the mock payload, we push (AFTER_RETURN-1)
    ; onto the stack first — a standard 6502 fake-JSR technique.
    ;==========================================================================
    LDA #>(AFTER_RETURN-1)
    PHA
    LDA #<(AFTER_RETURN-1)
    PHA

    JMP (ZP_DEST_LO)    ; -> MOCK_LOAD_ADDR ($C000)
                        ; mock payload runs, ends with RTS -> AFTER_RETURN

;==============================================================================
; AFTER_RETURN: arrived here when mock payload exits via RTS
;==============================================================================
AFTER_RETURN:
    LDA #$0E            ; LIGHT BLUE border = "full pipeline passed"
    STA VIC_BORDER

    ; Print "RETURNED OK" on LINE2
    LDX #0
PRINT_P3:
    LDA MSG_RETURN, X
    STA LINE2, X
    INX
    CPX #MSG_RETURN_LEN
    BNE PRINT_P3

    ; Restore CIA1 Port A: mock payload left it at $7F (col 7 asserted).
    ; KERNAL GETIN expects $FF (all columns deasserted).
    LDA #$FF
    STA CIA1_PRA

    ; Wait for any key via KERNAL GETIN (keyboard IRQ still running from BASIC)
WAIT_KEY:
    JSR GETIN
    BEQ WAIT_KEY

    LDA #$0E            ; restore standard C64 border color
    STA VIC_BORDER

    ; Position cursor below the test output so BASIC READY prompt doesn't
    ; overwrite our messages. KERNAL PLOT (C=0): LDX=row, LDY=col.
    ; BASIC appends CR + "READY." after RTS, so READY ends up 2 rows below
    ; the PLOT position -> LDX #4 -> READY on row 6.
    CLC
    LDX #2              ; cursor -> row 2, BASIC READY -> row 4
    LDY #0              ; column 0
    JSR $FFF0           ; KERNAL PLOT: set cursor position

    RTS                 ; return to BASIC

;==============================================================================
; Screen messages (uppercase, .enc "screen" maps to PETSCII screen codes)
;==============================================================================
MSG_PARSE:
    .text "PARSE OK  LOAD=$C000     "
MSG_PARSE_LEN = * - MSG_PARSE

MSG_COPY:
    .text "COPY  OK  18 BYTES       "
MSG_COPY_LEN = * - MSG_COPY

MSG_RETURN:
    .text "RETURNED OK VIA RTS      "
MSG_RETURN_LEN = * - MSG_RETURN


;==============================================================================
; MOCK_PRG: embedded test payload
;
; Format: [2-byte little-endian load address] [raw machine code payload]
;
; Load address $C000 rationale:
;   - Above BASIC workspace ($0801-$9FFF heap), no conflict with test harness
;   - EasySD cartridge ROML occupies $8000-$9FFF, not $C000 — RAM is writable
;   - KernalBridge itself loads to $C000 in production, so this mirrors reality
;
; Payload machine code (18 bytes, will execute at $C000 after the copy loop):
;   All operands are absolute hardware addresses — correct wherever this runs.
;
;   Offset  Addr   Bytes          Mnemonic
;   ------  -----  -------------  --------------------
;   0       $C000  A9 05          LDA #5
;   2       $C002  8D 20 D0       STA $D020    ; GREEN border = "I'm alive at $C000"
;   5       $C005  A9 7F          LDA #$7F     ; assert keyboard column 7 (STOP col)
;   7       $C007  8D 00 DC       STA $DC00
;   10      $C00A  AD 01 DC       LDA $DC01    ; read keyboard rows
;   13      $C00D  29 80          AND #$80     ; bit 7 = STOP row (0 = pressed)
;   15      $C00F  D0 F4          BNE $C005    ; loop while STOP not pressed
;              (offset $F4 = -12 from PC=$C011 -> $C005)
;   17      $C011  60             RTS          ; return -> AFTER_RETURN via stack
;==============================================================================
MOCK_PRG:
    .byte <MOCK_LOAD_ADDR, >MOCK_LOAD_ADDR  ; 2-byte little-endian header

MOCK_PAYLOAD_START = *
    .byte $A9, $05              ; LDA #5
    .byte $8D, $20, $D0        ; STA $D020         (green border)
    .byte $A9, $7F              ; LDA #$7F
    .byte $8D, $00, $DC        ; STA $DC00         (assert STOP column)
    .byte $AD, $01, $DC        ; LDA $DC01         (read keyboard rows)
    .byte $29, $80              ; AND #$80          (isolate STOP bit)
    .byte $D0, $F4              ; BNE $C005         (loop while not pressed)
    .byte $60                   ; RTS               (-> AFTER_RETURN)
MOCK_PAYLOAD_END = *

MOCK_PAYLOAD_LEN = MOCK_PAYLOAD_END - MOCK_PAYLOAD_START   ; must be 18
