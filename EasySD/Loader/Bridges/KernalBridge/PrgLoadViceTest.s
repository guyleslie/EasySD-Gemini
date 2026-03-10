; PrgLoadViceTest.s
; VICE-only PRG loading pipeline + P2TK setup test for KernalBridge.
; No Arduino hardware required.
;
; Tests:
;   Phase 1-3  — Normal load pipeline (header parse, copy, ZP-indirect jump, RTS return)
;   Phase 4    — P2TK trigger decision logic (4 ENDADDRESS boundary cases)
;   Phase 5    — Phase2_pages calculation for ENDADDR=$FFFF  (expected $40 = Phase 3)
;   Phase 6    — Phase 3 setup: copy P3_TAIL_CODE + P3_HANDLER, verify NMI vectors + $0341
;   Phase 7    — Normal P2TK NMI vector setup (pages != $40)
;
; Automation protocol (polled by test_vice_prgload.py via VICE binary monitor):
;   $CF60  PARSE   ($01 = load address parsed from MOCK_PRG header)
;   $CF61  COPY    ($01 = payload copied to $C000)
;   $CF62  EXEC    ($01 = mock payload set by code running at $C000)
;   $CF63  RETURN  ($01 = RTS returned cleanly to test harness)
;   $CF70  TRIG_C000  result for ENDADDR=$C000  (expected $01 = normal)
;   $CF71  TRIG_C002  result for ENDADDR=$C002  (expected $01 = normal)
;   $CF72  TRIG_C003  result for ENDADDR=$C003  (expected $02 = P2TK)
;   $CF73  TRIG_D000  result for ENDADDR=$D000  (expected $02 = P2TK)
;   $CF74  PAGES_FFFF Phase2_pages for ENDADDR=$FFFF  (expected $40)
;   $CF80  P3_MISMATCHES  mismatch count after Phase3 table copy  (expected $00)
;   $CF81  P3_NMI_LO      $FFFA after Phase3 NMI setup  (expected $6A)
;   $CF82  P3_NMI_HI      $FFFB after Phase3 NMI setup  (expected $03)
;   $CF83  P3_JMP_LO      $0341 after Phase3 NMI setup  (expected $43)
;   $CF84  NRM_NMI_LO     $FFFA after normal NMI setup  (expected $AF)
;   $CF85  NRM_NMI_HI     $FFFB after normal NMI setup  (expected $80)
;   $CF86  NRM_JMP_LO     $0341 after normal NMI setup  (expected $34)
;   $CF8F  DONE           $FF when all tests complete
;
; Visual protocol (border color):
;   YELLOW  -> test starting / parse phase
;   BLUE    -> copy in progress
;   GREEN   -> mock payload executed at $C000
;   LTBLUE  -> pipeline complete (RTS returned)
;   WHITE   -> P2TK tests in progress
;   CYAN    -> Phase 3 setup test in progress
;   BLACK   -> done (all tests complete)
;
; To build:  python Tools/build.py debug-vice
; To run:    python Tools/test_vice_prgload.py              (automated)
;            LOAD "prgtest.prg",8,1  then  RUN  in VICE    (manual / visual)
;
; Original design: 03/2026 - EasySD project

.enc "screen"

;==============================================================================
; Zero-page variables ($FB-$FE: plugin-safe range per CartZpMap.inc)
;==============================================================================
ZP_DEST_LO   = $FB         ; destination pointer lo (= parsed load address)
ZP_DEST_HI   = $FC         ; destination pointer hi
ZP_SRC_LO    = $FD         ; source pointer lo      (into MOCK_PRG payload)
ZP_SRC_HI    = $FE         ; source pointer hi

;==============================================================================
; Automation sentinel addresses  ($CF60-$CF8F)
;==============================================================================
SEN_PARSE       = $CF60
SEN_COPY        = $CF61
SEN_EXEC        = $CF62    ; set by mock payload at $C000
SEN_RETURN      = $CF63

SEN_TRIG_C000   = $CF70    ; exp $01 = normal
SEN_TRIG_C002   = $CF71    ; exp $01 = normal
SEN_TRIG_C003   = $CF72    ; exp $02 = P2TK
SEN_TRIG_D000   = $CF73    ; exp $02 = P2TK
SEN_PAGES_FFFF  = $CF74    ; exp $40

SEN_P3_MISMATCH = $CF80    ; exp $00
SEN_P3_NMI_LO   = $CF81    ; exp $6A
SEN_P3_NMI_HI   = $CF82    ; exp $03
SEN_P3_JMP_LO   = $CF83    ; exp $43
SEN_NRM_NMI_LO  = $CF84    ; exp $AF
SEN_NRM_NMI_HI  = $CF85    ; exp $80
SEN_NRM_JMP_LO  = $CF86    ; exp $34

SEN_DONE        = $CF8F    ; $FF = all tests complete

;==============================================================================
; Scratch variables for P2TK tests  ($CF90-$CF9F)
;==============================================================================
TRIG_ENDHI      = $CF90
TRIG_ENDLO      = $CF91
MISMATCH_CNT    = $CF92
FAKE_STARTLO    = $CF93
FAKE_STARTHI    = $CF94

;==============================================================================
; Hardware / KERNAL addresses
;==============================================================================
VIC_BORDER   = $D020
VIC_BG       = $D021
CHROUT       = $FFD2
GETIN        = $FFE4

;==============================================================================
; Screen layout (40 chars / row)
;==============================================================================
SCREEN       = $0400
LINE0        = SCREEN + 0*40
LINE1        = SCREEN + 1*40
LINE2        = SCREEN + 2*40
LINE3        = SCREEN + 3*40
LINE4        = SCREEN + 4*40
LINE5        = SCREEN + 5*40

MOCK_LOAD_ADDR  = $C000

;==============================================================================
; BASIC stub at $0801: 10 SYS 2061  (= $080D)
;==============================================================================
*=$0801
    .word $080b
    .word 10
    .byte $9e
    .text "2061"
    .byte 0
    .word 0

;==============================================================================
; Entry point at $080D
;==============================================================================
*=$080d
MAIN:
    ; Clear sentinels $CF60..$CF8F (48 bytes)
    LDX #$2F
    LDA #$00
-   STA SEN_PARSE, X
    DEX
    BPL -

    LDA #$93
    JSR CHROUT

    LDA #7
    STA VIC_BORDER
    LDA #0
    STA VIC_BG

    ;==========================================================================
    ; Phase 1: Parse MOCK_PRG 2-byte load address
    ;==========================================================================
    LDA MOCK_PRG
    STA ZP_DEST_LO
    LDA MOCK_PRG+1
    STA ZP_DEST_HI

    LDA #$01
    STA SEN_PARSE

    LDX #0
PRINT_P1:
    LDA MSG_PARSE, X
    STA LINE0, X
    INX
    CPX #MSG_PARSE_LEN
    BNE PRINT_P1

    ;==========================================================================
    ; Phase 2: Copy MOCK payload to load address
    ;==========================================================================
    LDA #6
    STA VIC_BORDER

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

    LDA #$01
    STA SEN_COPY

    LDX #0
PRINT_P2:
    LDA MSG_COPY, X
    STA LINE1, X
    INX
    CPX #MSG_COPY_LEN
    BNE PRINT_P2

    ;==========================================================================
    ; Phase 3: Launch via ZP indirect (mirrors KernalBridge MACHINELANG path)
    ;==========================================================================
    LDA #>(AFTER_RETURN-1)
    PHA
    LDA #<(AFTER_RETURN-1)
    PHA

    JMP (ZP_DEST_LO)

;==============================================================================
AFTER_RETURN:
    LDA #$01
    STA SEN_RETURN

    LDA #$0E
    STA VIC_BORDER

    LDX #0
PRINT_P3:
    LDA MSG_RETURN, X
    STA LINE2, X
    INX
    CPX #MSG_RETURN_LEN
    BNE PRINT_P3

    ;==========================================================================
    ; Phase 4: P2TK trigger decision — 4 ENDADDRESS boundary cases
    ;
    ; Mirrors KernalBridge MAIN trigger:
    ;   LDA ENDADDRESSHI : CMP #$C0
    ;   BCC NORMAL  (hi < $C0)
    ;   BNE P2TK    (hi > $C0)
    ;   LDA ENDADDRESSLO : CMP #$03
    ;   BCC NORMAL  (lo < $03)
    ;==========================================================================
    LDA #1
    STA VIC_BORDER

    ; Case 1: ENDADDR=$C000  -> expected NORMAL ($01)
    LDA #$C0
    STA TRIG_ENDHI
    LDA #$00
    STA TRIG_ENDLO
    JSR DO_TRIGGER_TEST
    STA SEN_TRIG_C000

    ; Case 2: ENDADDR=$C002  -> expected NORMAL ($01)
    LDA #$C0
    STA TRIG_ENDHI
    LDA #$02
    STA TRIG_ENDLO
    JSR DO_TRIGGER_TEST
    STA SEN_TRIG_C002

    ; Case 3: ENDADDR=$C003  -> expected P2TK ($02)
    LDA #$C0
    STA TRIG_ENDHI
    LDA #$03
    STA TRIG_ENDLO
    JSR DO_TRIGGER_TEST
    STA SEN_TRIG_C003

    ; Case 4: ENDADDR=$D000  -> expected P2TK ($02)
    LDA #$D0
    STA TRIG_ENDHI
    LDA #$00
    STA TRIG_ENDLO
    JSR DO_TRIGGER_TEST
    STA SEN_TRIG_D000

    ; Check all 4 results
    LDA SEN_TRIG_C000
    CMP #$01
    BNE trig_fail
    LDA SEN_TRIG_C002
    CMP #$01
    BNE trig_fail
    LDA SEN_TRIG_C003
    CMP #$02
    BNE trig_fail
    LDA SEN_TRIG_D000
    CMP #$02
    BNE trig_fail

    LDX #0
trig_ok_print:
    LDA MSG_TRIG_OK, X
    STA LINE3, X
    INX
    CPX #MSG_TRIG_OK_LEN
    BNE trig_ok_print
    JMP trig_done

trig_fail:
    LDX #0
trig_fail_print:
    LDA MSG_TRIG_FAIL, X
    STA LINE3, X
    INX
    CPX #MSG_TRIG_FAIL_LEN
    BNE trig_fail_print

trig_done:

    ;==========================================================================
    ; Phase 5: Phase2_pages for ENDADDR=$FFFF  (expected $40 = Phase 3 trigger)
    ;
    ; Mirrors DO_P2TK:
    ;   SEC
    ;   LDA ENDADDRESSLO : SBC #$02 : TAX  ; X = lo of (ENDADDR-$C002)
    ;   LDA ENDADDRESSHI : SBC #$C0 : TAY  ; Y = floor page count
    ;   TXA : BEQ + : INY                   ; round up if partial page
    ;==========================================================================
    LDA #$FF
    STA TRIG_ENDHI
    STA TRIG_ENDLO
    JSR DO_PAGES_CALC
    STY SEN_PAGES_FFFF

    ;==========================================================================
    ; Phase 6: Phase 3 setup verification
    ;
    ; Pre-fill $C003 with EXP_P3_TAIL_CODE, $C02A with EXP_P3_HANDLER.
    ; Run DO_P2TK_SETUP with Y=$40 (Phase 3 active).
    ; Byte-compare $0343/$036A against expected tables.
    ; Record NMI vector values and $0341.
    ;==========================================================================
    LDA #3
    STA VIC_BORDER

    ; Pre-fill $C003 with EXP_P3_TAIL_CODE (39 bytes)
    LDX #(P3_TAIL_LEN-1)
fill_tail:
    LDA EXP_P3_TAIL_CODE, X
    STA $C003, X
    DEX
    BPL fill_tail

    ; Pre-fill $C02A with EXP_P3_HANDLER (52 bytes)
    LDX #(P3_HANDLER_LEN-1)
fill_handler:
    LDA EXP_P3_HANDLER, X
    STA $C02A, X
    DEX
    BPL fill_handler

    ; Set fake STARTADDRESS ($0801 = standard BASIC start)
    LDA #$01
    STA FAKE_STARTLO
    LDA #$08
    STA FAKE_STARTHI

    ; Run Phase 3 setup (Y=$40 triggers Phase 3 path)
    LDY #$40
    JSR DO_P2TK_SETUP

    ; Compare $0343-$0369 vs EXP_P3_TAIL_CODE
    LDA #$00
    STA MISMATCH_CNT

    LDX #(P3_TAIL_LEN-1)
cmp_tail:
    LDA $0343, X
    CMP EXP_P3_TAIL_CODE, X
    BEQ cmp_tail_ok
    INC MISMATCH_CNT
cmp_tail_ok:
    DEX
    BPL cmp_tail

    ; Compare $036A-$039D vs EXP_P3_HANDLER
    LDX #(P3_HANDLER_LEN-1)
cmp_handler:
    LDA $036A, X
    CMP EXP_P3_HANDLER, X
    BEQ cmp_handler_ok
    INC MISMATCH_CNT
cmp_handler_ok:
    DEX
    BPL cmp_handler

    LDA MISMATCH_CNT
    STA SEN_P3_MISMATCH

    ; $FFFA/$FFFB are in KERNAL ROM space — must disable KERNAL to read RAM values
    SEI
    LDA #$34
    STA $01
    LDA $FFFA
    STA SEN_P3_NMI_LO
    LDA $FFFB
    STA SEN_P3_NMI_HI
    LDA #$37
    STA $01
    CLI
    LDA $0341
    STA SEN_P3_JMP_LO

    ; Print phase 6 result
    LDA MISMATCH_CNT
    BNE p3_fail

    LDX #0
p3_ok_print:
    LDA MSG_P3_OK, X
    STA LINE4, X
    INX
    CPX #MSG_P3_OK_LEN
    BNE p3_ok_print
    JMP p3_done

p3_fail:
    LDX #0
p3_fail_print:
    LDA MSG_P3_FAIL, X
    STA LINE4, X
    INX
    CPX #MSG_P3_FAIL_LEN
    BNE p3_fail_print

p3_done:

    ;==========================================================================
    ; Phase 7: Normal P2TK NMI vector setup (Phase2_pages != $40)
    ;==========================================================================
    LDY #$10
    JSR DO_P2TK_SETUP

    ; $FFFA/$FFFB are in KERNAL ROM space — must disable KERNAL to read RAM values
    SEI
    LDA #$34
    STA $01
    LDA $FFFA
    STA SEN_NRM_NMI_LO
    LDA $FFFB
    STA SEN_NRM_NMI_HI
    LDA #$37
    STA $01
    CLI
    LDA $0341
    STA SEN_NRM_JMP_LO

    LDA SEN_NRM_NMI_LO
    CMP #$AF
    BNE nrm_fail
    LDA SEN_NRM_NMI_HI
    CMP #$80
    BNE nrm_fail
    LDA SEN_NRM_JMP_LO
    CMP #$34
    BNE nrm_fail

    LDX #0
nrm_ok_print:
    LDA MSG_NMI_OK, X
    STA LINE5, X
    INX
    CPX #MSG_NMI_OK_LEN
    BNE nrm_ok_print
    JMP nrm_done

nrm_fail:
    LDX #0
nrm_fail_print:
    LDA MSG_NMI_FAIL, X
    STA LINE5, X
    INX
    CPX #MSG_NMI_FAIL_LEN
    BNE nrm_fail_print

nrm_done:

    ;==========================================================================
    ; All tests complete
    ;==========================================================================
    LDA #$FF
    STA SEN_DONE

    LDA #0
    STA VIC_BORDER

    ; Restore CIA1 Port A (mock payload may have left it non-$FF)
    LDA #$FF
    STA $DC00

WAIT_KEY:
    JSR GETIN
    BEQ WAIT_KEY

    CLC
    LDX #6
    LDY #0
    JSR $FFF0
    RTS

;==============================================================================
; DO_TRIGGER_TEST
; Mirrors KernalBridge P2TK trigger decision.
; Input:  TRIG_ENDHI, TRIG_ENDLO
; Output: A = $01 (normal) or $02 (P2TK)
;==============================================================================
DO_TRIGGER_TEST:
    LDA TRIG_ENDHI
    CMP #$C0
    BCC trig_ret_normal
    BNE trig_ret_p2tk
    ; hi == $C0: check lo
    LDA TRIG_ENDLO
    CMP #$03
    BCC trig_ret_normal
trig_ret_p2tk:
    LDA #$02
    RTS
trig_ret_normal:
    LDA #$01
    RTS

;==============================================================================
; DO_PAGES_CALC
; Mirrors DO_P2TK Phase2_pages computation.
; Input:  TRIG_ENDHI, TRIG_ENDLO
; Output: Y = Phase2_pages = ceil((ENDADDR - $C002) / 256)
;==============================================================================
DO_PAGES_CALC:
    SEC
    LDA TRIG_ENDLO
    SBC #$02
    TAX
    LDA TRIG_ENDHI
    SBC #$C0
    TAY
    TXA
    BEQ pages_no_partial
    INY
pages_no_partial:
    RTS

;==============================================================================
; DO_P2TK_SETUP
; Mirrors DO_P2TK BVC stub + Launcher + Phase3 conditional + NMI vector setup.
; Input:  Y = Phase2_pages, FAKE_STARTLO/FAKE_STARTHI
; Output: writes to $033B-$0342, $0334-$033A, $FFFA/$FFFB
;         Phase 3 (Y=$40): also fills $0343/$036A from $C003/$C02A, sets $0341=$43
;         Normal (Y!=$40): sets $0341=$34, NMI vector = $80AF
;
; Caller must pre-fill $C003 (P3_TAIL_LEN bytes) and $C02A (P3_HANDLER_LEN bytes)
; before calling with Y=$40, otherwise the copy loop output is undefined.
;==============================================================================
DO_P2TK_SETUP:
    ; BVC wait-stub at $033B (8 bytes)
    LDA #$B8
    STA $033B               ; CLV
    LDA #$24
    STA $033C               ; BIT zp
    LDA #$64
    STA $033D               ;   ZP_IRQ_STATE_WAITHANDLE
    LDA #$50
    STA $033E               ; BVC rel
    LDA #$FC
    STA $033F               ;   -4
    LDA #$4C
    STA $0340               ; JMP abs
    LDA #$34
    STA $0341               ;   lo: $0334 (may be overridden below)
    LDA #$03
    STA $0342               ;   hi

    ; Launcher at $0334 (7 bytes)
    LDA #$A9
    STA $0334               ; LDA #imm
    LDA #$37
    STA $0335               ;   $37 = PP_CONFIG_DEFAULT
    LDA #$85
    STA $0336               ; STA zp
    LDA #$01
    STA $0337               ;   $01 = PROCESSOR_PORT
    LDA #$4C
    STA $0338               ; JMP abs
    LDA FAKE_STARTLO
    STA $0339
    LDA FAKE_STARTHI
    STA $033A

    ; Phase 3 conditional
    CPY #$40
    BNE setup_normal_nmi

    ; Copy P3_TAIL_CODE (39 bytes, $C003) -> $0343
    LDX #(P3_TAIL_LEN-1)
setup_copy_tail:
    LDA $C003, X
    STA $0343, X
    DEX
    BPL setup_copy_tail

    ; Copy P3_HANDLER (52 bytes, $C02A) -> $036A
    LDX #(P3_HANDLER_LEN-1)
setup_copy_handler:
    LDA $C02A, X
    STA $036A, X
    DEX
    BPL setup_copy_handler

    ; Override BVC JMP lo -> $43 (target $0343)
    LDA #$43
    STA $0341

    ; NMI vector -> P3_HANDLER at $036A
    LDA #$6A
    STA $FFFA
    LDA #$03
    STA $FFFB
    BNE setup_done          ; A=$03 != 0, always branches

setup_normal_nmi:
    ; NMI vector -> CARTRIDGENMIHANDLERX1 at $80AF
    LDA #$AF
    STA $FFFA
    LDA #$80
    STA $FFFB

setup_done:
    RTS

;==============================================================================
; Screen messages
;==============================================================================
MSG_PARSE:
    .text "PARSE OK  LOAD=$C000        "
MSG_PARSE_LEN = * - MSG_PARSE

MSG_COPY:
    .text "COPY  OK  11 BYTES          "
MSG_COPY_LEN = * - MSG_COPY

MSG_RETURN:
    .text "RETURNED OK VIA RTS         "
MSG_RETURN_LEN = * - MSG_RETURN

MSG_TRIG_OK:
    .text "P2TK TRIG  OK               "
MSG_TRIG_OK_LEN = * - MSG_TRIG_OK

MSG_TRIG_FAIL:
    .text "P2TK TRIG  FAIL             "
MSG_TRIG_FAIL_LEN = * - MSG_TRIG_FAIL

MSG_P3_OK:
    .text "PHASE3 SETUP  OK            "
MSG_P3_OK_LEN = * - MSG_P3_OK

MSG_P3_FAIL:
    .text "PHASE3 SETUP  FAIL          "
MSG_P3_FAIL_LEN = * - MSG_P3_FAIL

MSG_NMI_OK:
    .text "NMI VECTOR  OK              "
MSG_NMI_OK_LEN = * - MSG_NMI_OK

MSG_NMI_FAIL:
    .text "NMI VECTOR  FAIL            "
MSG_NMI_FAIL_LEN = * - MSG_NMI_FAIL

;==============================================================================
; MOCK_PRG: embedded test payload
;
; Load address $C000 (2-byte little-endian header), then 11-byte payload:
;   $C000  A9 05      LDA #5             GREEN border
;   $C002  8D 20 D0   STA $D020
;   $C005  A9 01      LDA #$01
;   $C007  8D 62 CF   STA $CF62          SEN_EXEC = $01
;   $C00A  60         RTS                return -> AFTER_RETURN
;
; Note: original payload polled STOP key (CIA1 $DC01 bit 7), which stalled
; the VICE binary monitor test runner. Now returns immediately after sentinel.
;==============================================================================
MOCK_PRG:
    .byte <MOCK_LOAD_ADDR, >MOCK_LOAD_ADDR

MOCK_PAYLOAD_START = *
    .byte $A9, $05              ; LDA #5
    .byte $8D, $20, $D0         ; STA $D020   (green border)
    .byte $A9, $01              ; LDA #$01
    .byte $8D, $62, $CF         ; STA $CF62   (SEN_EXEC)
    .byte $60                   ; RTS
MOCK_PAYLOAD_END = *

MOCK_PAYLOAD_LEN = MOCK_PAYLOAD_END - MOCK_PAYLOAD_START   ; = 11

;==============================================================================
; EXP_P3_TAIL_CODE — expected bytes for P3_TAIL_CODE (39 bytes at $C003)
;
; Copies TAIL_BUF ($03BB-$03C0) -> $FFFA-$FFFF, then JMP $0334.
; Must match KernalBridge.s P3_TAIL_CODE exactly.
; test_vice_prgload.py also verifies prgplugin.prg binary has these bytes at $C003.
;==============================================================================
EXP_P3_TAIL_CODE:
    .byte $AD, $BB, $03, $8D, $FA, $FF  ; LDA $03BB : STA $FFFA
    .byte $AD, $BC, $03, $8D, $FB, $FF  ; LDA $03BC : STA $FFFB
    .byte $AD, $BD, $03, $8D, $FC, $FF  ; LDA $03BD : STA $FFFC
    .byte $AD, $BE, $03, $8D, $FD, $FF  ; LDA $03BE : STA $FFFD
    .byte $AD, $BF, $03, $8D, $FE, $FF  ; LDA $03BF : STA $FFFE
    .byte $AD, $C0, $03, $8D, $FF, $FF  ; LDA $03C0 : STA $FFFF
    .byte $4C, $34, $03                 ; JMP $0334
P3_TAIL_LEN = * - EXP_P3_TAIL_CODE     ; = 39

;==============================================================================
; EXP_P3_HANDLER — expected bytes for P3_HANDLER (52 bytes at $C02A)
;
; NMI handler with tail-byte interception for last page ($FF00-$FFFF).
; Must match KernalBridge.s P3_HANDLER exactly.
;==============================================================================
EXP_P3_HANDLER:
    .byte $AD, $AB, $80  ; +0  LDA $80AB
    .byte $E0, $01       ; +3  CPX #$01
    .byte $F0, $11       ; +5  BEQ +17 -> .phase3
    .byte $91, $6C       ; +7  STA ($6C),Y
    .byte $C8            ; +9  INY
    .byte $F0, $01       ; +10 BEQ +1  -> .endofblock
    .byte $40            ; +12 RTI
    .byte $E6, $6D       ; +13 INC $6D
    .byte $CA            ; +15 DEX
    .byte $F0, $01       ; +16 BEQ +1  -> .endoftransfer
    .byte $40            ; +18 RTI
    .byte $A9, $64       ; +19 LDA #$64
    .byte $85, $64       ; +21 STA $64
    .byte $40            ; +23 RTI
    .byte $C0, $FA       ; +24 CPY #$FA
    .byte $B0, $04       ; +26 BCS +4  -> .save_tail
    .byte $91, $6C       ; +28 STA ($6C),Y
    .byte $C8            ; +30 INY
    .byte $40            ; +31 RTI
    .byte $84, $77       ; +32 STY $77
    .byte $AA            ; +34 TAX
    .byte $98            ; +35 TYA
    .byte $38            ; +36 SEC
    .byte $E9, $FA       ; +37 SBC #$FA
    .byte $A8            ; +39 TAY
    .byte $8A            ; +40 TXA
    .byte $99, $BB, $03  ; +41 STA $03BB,Y
    .byte $A4, $77       ; +44 LDY $77
    .byte $A2, $01       ; +46 LDX #$01
    .byte $C8            ; +48 INY
    .byte $F0, $DA       ; +49 BEQ -38 -> .endofblock
    .byte $40            ; +51 RTI
P3_HANDLER_LEN = * - EXP_P3_HANDLER    ; = 52
