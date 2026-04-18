; HWTest.s — EasySD hardware diagnostic plugin
;
; Current integration model:
;   - Legacy dispatch is still extension based (.HWT -> /PLUGINS/HWTPLUGIN.PRG)
;   - This plugin itself now behaves like a standalone diagnostic screen
;
; Diagnostic flow:
;   1. Plugin entry at $C000 proves menu/plugin loading path works.
;   2. COMMAND_HWTEST must be acknowledged by the Arduino.
;   3. Arduino pushes one 256-byte NMI page; first 10 bytes are checked.
;
; Design goals:
;   - Own full-screen UI instead of writing into the menu status line.
;   - Stable real-hardware NMI receive path.
;   - Clean return to menu with VIC/$01/NMI vector restored.

.enc "screen"

.include "../../Loader/DebugMacros.s"

* = $C000
    JMP MAIN

ROW_TITLE      = 1
ROW_SUBTITLE   = 3
ROW_ROML       = 7
ROW_PROTO      = 8
ROW_NMI        = 9
ROW_DBUS       = 10
ROW_STATUS     = 13
ROW_RESULT     = 17

RESULT_OK        = 0
RESULT_COMM_FAIL = 1
RESULT_NMI_FAIL  = 2
RESULT_DBUS_FAIL = 3

MAIN
    JSR SAVESTATE
    JSR INIT_SCREEN
    JSR DRAW_LAYOUT
    JSR RUN_HWTEST
    JSR SHOW_RESULT
    LDX #150
    JSR WAITFRAMES
    JSR RESTORESTATE
    JSR PROT_EndTalking
    JSR PROT_ExitToMenu
    JMP *

RUN_HWTEST
    LDA #ROW_ROML
    STA CURRENT_ROW
    LDA #$05
    LDX #<ROWMSG_ROML_OK
    LDY #>ROWMSG_ROML_OK
    JSR PRINT_ROW

    LDA #ROW_STATUS
    STA CURRENT_ROW
    LDX #<TXT_RUNNING
    LDY #>TXT_RUNNING
    LDA #$01
    JSR PRINT_ROW

    LDA #ROW_PROTO
    STA CURRENT_ROW
    LDX #<ROWMSG_PROTO_WAIT
    LDY #>ROWMSG_PROTO_WAIT
    LDA #$07
    JSR PRINT_ROW

    LDA #ROW_NMI
    STA CURRENT_ROW
    LDX #<ROWMSG_NMI_WAIT
    LDY #>ROWMSG_NMI_WAIT
    LDA #$07
    JSR PRINT_ROW

    LDA #ROW_DBUS
    STA CURRENT_ROW
    LDX #<ROWMSG_DBUS_WAIT
    LDY #>ROWMSG_DBUS_WAIT
    LDA #$07
    JSR PRINT_ROW

    LDA NMITAB
    STA TEST_NMI_LO
    LDA #$80
    STA TEST_NMI_HI

    LDA #$01
    STA ZP_IRQ_API_DATA_LENGTH
    LDA #<TEST_BUFFER
    STA ZP_IRQ_API_DATA_LO
    LDA #>TEST_BUFFER
    STA ZP_IRQ_API_DATA_HI

    JSR PROT_StartTalking

    LDA SOFTNMIVECTOR
    STA SAVED_NMI_LO
    LDA SOFTNMIVECTOR+1
    STA SAVED_NMI_HI

    LDA TEST_NMI_LO
    STA SOFTNMIVECTOR
    LDA TEST_NMI_HI
    STA SOFTNMIVECTOR+1

    LDA #$00
    STA ZP_IRQ_STATE_WAITHANDLE

    #SETBANK PP_CONFIG_DEFAULT

    LDA #COMMAND_HWTEST
    JSR PROT_Send

    JSR PROT_DisableDisplay
    JSR HWT_WAIT_ACK
    BCS HWTEST_COMM_FAIL

    LDX ZP_IRQ_API_DATA_LENGTH
    LDY #$00
    JSR HWT_WAIT_NMI_DONE
    BCS HWTEST_NMI_FAIL

    JSR PROT_EnableDisplay

    LDA #ROW_PROTO
    STA CURRENT_ROW
    LDX #<ROWMSG_PROTO_OK
    LDY #>ROWMSG_PROTO_OK
    LDA #$05
    JSR PRINT_ROW

    LDA #ROW_NMI
    STA CURRENT_ROW
    LDX #<ROWMSG_NMI_OK
    LDY #>ROWMSG_NMI_OK
    LDA #$05
    JSR PRINT_ROW

    JSR VERIFY_BUFFER
    LDA HWT_RESULT
    BEQ HWTEST_SUCCESS

HWTEST_DBUS_FAIL
    LDA #RESULT_DBUS_FAIL
    STA TEST_RESULT
    LDA #ROW_DBUS
    STA CURRENT_ROW
    LDX #<ROWMSG_DBUS_FAIL
    LDY #>ROWMSG_DBUS_FAIL
    LDA #$02
    JSR PRINT_ROW
    JMP HWTEST_DONE

HWTEST_COMM_FAIL
    JSR PROT_EnableDisplay
    LDA #RESULT_COMM_FAIL
    STA TEST_RESULT
    LDA #ROW_PROTO
    STA CURRENT_ROW
    LDX #<ROWMSG_PROTO_FAIL
    LDY #>ROWMSG_PROTO_FAIL
    LDA #$02
    JSR PRINT_ROW
    LDA #ROW_NMI
    STA CURRENT_ROW
    LDX #<ROWMSG_NMI_SKIP
    LDY #>ROWMSG_NMI_SKIP
    LDA #$0f
    JSR PRINT_ROW
    LDA #ROW_DBUS
    STA CURRENT_ROW
    LDX #<ROWMSG_DBUS_SKIP
    LDY #>ROWMSG_DBUS_SKIP
    LDA #$0f
    JSR PRINT_ROW
    JMP HWTEST_DONE

HWTEST_NMI_FAIL
    JSR PROT_EnableDisplay
    LDA #RESULT_NMI_FAIL
    STA TEST_RESULT
    LDA #ROW_PROTO
    STA CURRENT_ROW
    LDX #<ROWMSG_PROTO_OK
    LDY #>ROWMSG_PROTO_OK
    LDA #$05
    JSR PRINT_ROW
    LDA #ROW_NMI
    STA CURRENT_ROW
    LDX #<ROWMSG_NMI_FAIL
    LDY #>ROWMSG_NMI_FAIL
    LDA #$02
    JSR PRINT_ROW
    LDA #ROW_DBUS
    STA CURRENT_ROW
    LDX #<ROWMSG_DBUS_SKIP
    LDY #>ROWMSG_DBUS_SKIP
    LDA #$0f
    JSR PRINT_ROW
    JMP HWTEST_DONE

HWTEST_SUCCESS
    LDA #RESULT_OK
    STA TEST_RESULT
    LDA #ROW_DBUS
    STA CURRENT_ROW
    LDX #<ROWMSG_DBUS_OK
    LDY #>ROWMSG_DBUS_OK
    LDA #$05
    JSR PRINT_ROW

HWTEST_DONE
    LDA SAVED_NMI_LO
    STA SOFTNMIVECTOR
    LDA SAVED_NMI_HI
    STA SOFTNMIVECTOR+1
    RTS

VERIFY_BUFFER
    LDA #$00
    STA HWT_RESULT
    LDX #$00
_verify
    LDA HWT_PATTERNS, X
    EOR TEST_BUFFER, X
    BEQ _next
    ORA HWT_RESULT
    STA HWT_RESULT
_next
    INX
    CPX #10
    BNE _verify
    RTS

SHOW_RESULT
    LDA #ROW_STATUS
    STA CURRENT_ROW
    LDA TEST_RESULT
    BEQ _success
    CMP #RESULT_COMM_FAIL
    BEQ _comm_fail
    CMP #RESULT_NMI_FAIL
    BEQ _nmi_fail

    LDX #<TXT_DONE_FAIL
    LDY #>TXT_DONE_FAIL
    LDA #$02
    JSR PRINT_ROW

    LDA #ROW_RESULT
    STA CURRENT_ROW
    LDX #<MSG_DBUS_FAIL
    LDY #>MSG_DBUS_FAIL
    LDA #$02
    JSR PRINT_ROW
    RTS

_nmi_fail
    LDX #<TXT_DONE_FAIL
    LDY #>TXT_DONE_FAIL
    LDA #$02
    JSR PRINT_ROW

    LDA #ROW_RESULT
    STA CURRENT_ROW
    LDX #<MSG_NMI_FAIL
    LDY #>MSG_NMI_FAIL
    LDA #$02
    JSR PRINT_ROW
    RTS

_comm_fail
    LDX #<TXT_DONE_FAIL
    LDY #>TXT_DONE_FAIL
    LDA #$02
    JSR PRINT_ROW

    LDA #ROW_RESULT
    STA CURRENT_ROW
    LDX #<MSG_COMM_FAIL
    LDY #>MSG_COMM_FAIL
    LDA #$02
    JSR PRINT_ROW
    RTS

_success
    LDX #<TXT_DONE_OK
    LDY #>TXT_DONE_OK
    LDA #$05
    JSR PRINT_ROW

    LDA #ROW_RESULT
    STA CURRENT_ROW
    LDX #<MSG_ALL_OK
    LDY #>MSG_ALL_OK
    LDA #$05
    JSR PRINT_ROW
    RTS

DRAW_LAYOUT
    LDA #ROW_TITLE
    STA CURRENT_ROW
    LDX #<MSG_TITLE
    LDY #>MSG_TITLE
    LDA #$0e
    JSR PRINT_ROW

    LDA #ROW_SUBTITLE
    STA CURRENT_ROW
    LDX #<MSG_SUBTITLE
    LDY #>MSG_SUBTITLE
    LDA #$0f
    JSR PRINT_ROW

    LDA #ROW_ROML
    STA CURRENT_ROW
    LDX #<ROWMSG_ROML_WAIT
    LDY #>ROWMSG_ROML_WAIT
    LDA #$0e
    JSR PRINT_ROW

    LDA #ROW_PROTO
    STA CURRENT_ROW
    LDX #<ROWMSG_PROTO_WAIT
    LDY #>ROWMSG_PROTO_WAIT
    LDA #$0e
    JSR PRINT_ROW

    LDA #ROW_NMI
    STA CURRENT_ROW
    LDX #<ROWMSG_NMI_WAIT
    LDY #>ROWMSG_NMI_WAIT
    LDA #$0e
    JSR PRINT_ROW

    LDA #ROW_DBUS
    STA CURRENT_ROW
    LDX #<ROWMSG_DBUS_WAIT
    LDY #>ROWMSG_DBUS_WAIT
    LDA #$0e
    JSR PRINT_ROW
    RTS

INIT_SCREEN
    CLD
    #SETBANK PP_CONFIG_DEFAULT
    JSR PROT_EnableDisplay

    LDA $DD00
    AND #$FC
    ORA #$03
    STA $DD00

    LDA #$1B
    STA $D011
    LDA #$08
    STA $D016
    LDA #$15
    STA $D018

    LDA #$93
    JSR CHROUT

    LDA #$0e
    STA $D020
    LDA #$06
    STA $D021

    LDA #$0e
    JSR FILL_COLOR_RAM
    RTS

FILL_COLOR_RAM
    LDX #$00
_color_loop
    STA $D800, X
    STA $D900, X
    STA $DA00, X
    STA $DB00, X
    INX
    BNE _color_loop
    RTS

PRINT_ROW
    STX ZP_STR_LO
    STY ZP_STR_HI
    STA CURRENT_COLOR

    LDX CURRENT_ROW
    LDA ROW_SCREEN_LO, X
    STA ZP_DST_LO
    LDA ROW_SCREEN_HI, X
    STA ZP_DST_HI
    LDA ROW_COLOR_LO, X
    STA ZP_COL_LO
    LDA ROW_COLOR_HI, X
    STA ZP_COL_HI

    LDY #$00
_copy
    LDA (ZP_STR_LO), Y
    BEQ _pad
    STA (ZP_DST_LO), Y
    LDA CURRENT_COLOR
    STA (ZP_COL_LO), Y
    INY
    CPY #40
    BNE _copy
    RTS

_pad
    LDA #$20
_pad_loop
    STA (ZP_DST_LO), Y
    LDA CURRENT_COLOR
    STA (ZP_COL_LO), Y
    INY
    CPY #40
    BNE _pad_loop
    RTS

WAITFRAMES
_wf_outer
    LDA #$90
_wf_raster
    CMP $D012
    BNE _wf_raster
    LDY #50
_wf_inner
    DEY
    BNE _wf_inner
    DEX
    BNE _wf_outer
    RTS

HWT_WAIT_ACK
    LDX #$40
_hwa_outer
    LDY #$00
_hwa_inner
    LDA CARTRIDGE_BANK_VALUE
    BEQ _hwa_next
    BPL _hwa_fail
    CLC
    RTS
_hwa_next
    DEY
    BNE _hwa_inner
    DEX
    BNE _hwa_outer
_hwa_fail
    SEC
    RTS

HWT_WAIT_NMI_DONE
    LDX #$ff
    LDY #$00
_hwn_loop
    BIT ZP_IRQ_STATE_WAITHANDLE
    BVS _hwn_ok
    DEY
    BNE _hwn_loop
    DEX
    BNE _hwn_loop
    SEC
    RTS
_hwn_ok
    CLC
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
    RTS

RESTORESTATE
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
    RTS

MSG_TITLE
    .text "            EASYSD HARDWARE TEST"
    .byte 0
MSG_SUBTITLE
    .text "       VERIFYING EASYSD LINK TO THE C64"
    .byte 0
MSG_ALL_OK
    .text "             HARDWARE TEST PASSED"
    .byte 0
MSG_COMM_FAIL
    .text "          COMMAND PATH DID NOT RESPOND"
    .byte 0
MSG_NMI_FAIL
    .text "          NMI TRANSFER DID NOT COMPLETE"
    .byte 0
MSG_DBUS_FAIL
    .text "          PATTERN CHECK DID NOT MATCH"
    .byte 0

TXT_RUNNING
    .text "               RUNNING TEST..."
    .byte 0
TXT_DONE_OK
    .text "              TEST COMPLETE: PASS"
    .byte 0
TXT_DONE_FAIL
    .text "              TEST COMPLETE: FAIL"
    .byte 0

ROWMSG_ROML_WAIT
    .text "    CARTRIDGE ENTRY                 WAIT"
    .byte 0
ROWMSG_ROML_OK
    .text "    CARTRIDGE ENTRY                 OK"
    .byte 0
ROWMSG_PROTO_WAIT
    .text "    COMMAND ACK                     WAIT"
    .byte 0
ROWMSG_PROTO_OK
    .text "    COMMAND ACK                     OK"
    .byte 0
ROWMSG_PROTO_FAIL
    .text "    COMMAND ACK                     FAIL"
    .byte 0
ROWMSG_NMI_WAIT
    .text "    NMI BYTE TRANSFER               WAIT"
    .byte 0
ROWMSG_NMI_OK
    .text "    NMI BYTE TRANSFER               OK"
    .byte 0
ROWMSG_NMI_FAIL
    .text "    NMI BYTE TRANSFER               FAIL"
    .byte 0
ROWMSG_NMI_SKIP
    .text "    NMI BYTE TRANSFER               SKIP"
    .byte 0
ROWMSG_DBUS_WAIT
    .text "    DATA BUS PATTERN                WAIT"
    .byte 0
ROWMSG_DBUS_OK
    .text "    DATA BUS PATTERN                OK"
    .byte 0
ROWMSG_DBUS_FAIL
    .text "    DATA BUS PATTERN                FAIL"
    .byte 0
ROWMSG_DBUS_SKIP
    .text "    DATA BUS PATTERN                SKIP"
    .byte 0

HWT_PATTERNS
    .byte $01,$02,$04,$08,$10,$20,$40,$80,$55,$AA

ROW_SCREEN_LO
    .byte <($0400 + 40 * 0), <($0400 + 40 * 1), <($0400 + 40 * 2), <($0400 + 40 * 3), <($0400 + 40 * 4)
    .byte <($0400 + 40 * 5), <($0400 + 40 * 6), <($0400 + 40 * 7), <($0400 + 40 * 8), <($0400 + 40 * 9)
    .byte <($0400 + 40 * 10), <($0400 + 40 * 11), <($0400 + 40 * 12), <($0400 + 40 * 13), <($0400 + 40 * 14)
    .byte <($0400 + 40 * 15), <($0400 + 40 * 16), <($0400 + 40 * 17), <($0400 + 40 * 18), <($0400 + 40 * 19)
    .byte <($0400 + 40 * 20), <($0400 + 40 * 21), <($0400 + 40 * 22), <($0400 + 40 * 23), <($0400 + 40 * 24)

ROW_SCREEN_HI
    .byte >($0400 + 40 * 0), >($0400 + 40 * 1), >($0400 + 40 * 2), >($0400 + 40 * 3), >($0400 + 40 * 4)
    .byte >($0400 + 40 * 5), >($0400 + 40 * 6), >($0400 + 40 * 7), >($0400 + 40 * 8), >($0400 + 40 * 9)
    .byte >($0400 + 40 * 10), >($0400 + 40 * 11), >($0400 + 40 * 12), >($0400 + 40 * 13), >($0400 + 40 * 14)
    .byte >($0400 + 40 * 15), >($0400 + 40 * 16), >($0400 + 40 * 17), >($0400 + 40 * 18), >($0400 + 40 * 19)
    .byte >($0400 + 40 * 20), >($0400 + 40 * 21), >($0400 + 40 * 22), >($0400 + 40 * 23), >($0400 + 40 * 24)

ROW_COLOR_LO
    .byte <($D800 + 40 * 0), <($D800 + 40 * 1), <($D800 + 40 * 2), <($D800 + 40 * 3), <($D800 + 40 * 4)
    .byte <($D800 + 40 * 5), <($D800 + 40 * 6), <($D800 + 40 * 7), <($D800 + 40 * 8), <($D800 + 40 * 9)
    .byte <($D800 + 40 * 10), <($D800 + 40 * 11), <($D800 + 40 * 12), <($D800 + 40 * 13), <($D800 + 40 * 14)
    .byte <($D800 + 40 * 15), <($D800 + 40 * 16), <($D800 + 40 * 17), <($D800 + 40 * 18), <($D800 + 40 * 19)
    .byte <($D800 + 40 * 20), <($D800 + 40 * 21), <($D800 + 40 * 22), <($D800 + 40 * 23), <($D800 + 40 * 24)

ROW_COLOR_HI
    .byte >($D800 + 40 * 0), >($D800 + 40 * 1), >($D800 + 40 * 2), >($D800 + 40 * 3), >($D800 + 40 * 4)
    .byte >($D800 + 40 * 5), >($D800 + 40 * 6), >($D800 + 40 * 7), >($D800 + 40 * 8), >($D800 + 40 * 9)
    .byte >($D800 + 40 * 10), >($D800 + 40 * 11), >($D800 + 40 * 12), >($D800 + 40 * 13), >($D800 + 40 * 14)
    .byte >($D800 + 40 * 15), >($D800 + 40 * 16), >($D800 + 40 * 17), >($D800 + 40 * 18), >($D800 + 40 * 19)
    .byte >($D800 + 40 * 20), >($D800 + 40 * 21), >($D800 + 40 * 22), >($D800 + 40 * 23), >($D800 + 40 * 24)

SAVED_01      .byte 0
SAVED_DD00    .byte 0
SAVED_D011    .byte 0
SAVED_D016    .byte 0
SAVED_D018    .byte 0
SAVED_D020    .byte 0
SAVED_D021    .byte 0
SAVED_NMI_LO  .byte 0
SAVED_NMI_HI  .byte 0
TEST_NMI_LO   .byte 0
TEST_NMI_HI   .byte 0
HWT_RESULT    .byte 0
TEST_RESULT   .byte 0
CURRENT_ROW   .byte 0
CURRENT_COLOR .byte 0

ZP_STR_LO = $8B
ZP_STR_HI = $8C
ZP_DST_LO = $8D
ZP_DST_HI = $8E
ZP_COL_LO = $8F
ZP_COL_HI = $90

.include "../../Loader/CartLibStream.s"
.include "../../Loader/DebugStrings.s"

TEST_BUFFER
