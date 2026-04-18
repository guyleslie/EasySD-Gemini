; HWTest.s — EasySD hardware diagnostic plugin (minimal scaffold)
;
; Current version: display-only skeleton to validate plugin loading path.
; Sets full-screen C64 BASIC colors, prints title, waits for keypress,
; then returns to EasySD menu via protocol.
;
; SD card: create empty file HWTEST.HWT in any directory.
; Menu sees .HWT extension -> loads /PLUGINS/HWTPLUGIN.PRG -> runs this code.

.enc "screen"

.include "../../Loader/DebugMacros.s"

* = $C000
    JMP MAIN

MAIN
    JSR SAVESTATE

    ; --- Set up full-screen display with C64 BASIC colors ---
    #SETBANK PP_CONFIG_DEFAULT      ; $01 = $37: KERNAL + I/O visible

    ; VIC-II: default text mode, bank 0
    LDA $DD00
    AND #$FC
    ORA #$03
    STA $DD00

    LDA #$1B
    STA $D011                       ; screen on, 25 rows
    LDA #$08
    STA $D016                       ; 40 columns, no scroll
    LDA #$15
    STA $D018                       ; screen $0400, charset $1000

    ; Clear screen via KERNAL
    LDA #$93
    JSR CHROUT

    ; C64 BASIC default colors: border light blue ($0E), bg blue ($06)
    LDA #$0E
    STA $D020
    LDA #$06
    STA $D021

    ; Fill color RAM with light blue ($0E)
    LDA #$0E
    LDX #$00
_fill_color
    STA $D800, X
    STA $D900, X
    STA $DA00, X
    STA $DB00, X
    INX
    BNE _fill_color

    ; --- Print title centered on row 1 ---
    ; "EASYSD HARDWARE TEST" = 20 chars, centered at col 10 on row 1
    ; Row 1 screen address: $0400 + 40 = $0428, col 10 = $0432
    LDX #$00
_print_title
    LDA MSG_TITLE, X
    BEQ _print_done
    STA $0432, X                    ; screen RAM row 1, col 10
    INX
    CPX #40                         ; safety limit
    BNE _print_title
_print_done

    ; Set title color to white ($01)
    LDA #$01
    LDX #$00
_color_title
    CPX MSG_TITLE_LEN
    BEQ _color_done
    STA $D832, X                    ; color RAM row 1, col 10
    INX
    BNE _color_title
_color_done

    ; --- Print "PRESS ANY KEY" centered on row 12 ---
    ; Row 12: $0400 + 40*12 = $05E0, col 13 = $05ED
    LDX #$00
_print_key
    LDA MSG_KEY, X
    BEQ _print_key_done
    STA $05ED, X
    INX
    CPX #40
    BNE _print_key
_print_key_done

    ; Color for key prompt: light grey ($0F)
    LDA #$0F
    LDX #$00
_color_key
    CPX MSG_KEY_LEN
    BEQ _color_key_done
    STA $DBED, X
    INX
    BNE _color_key
_color_key_done

    ; --- Wait for any keypress ---
_wait_key
    JSR SCNKEY                      ; manual keyboard scan (works with SEI)
    JSR GETIN
    BEQ _wait_key

    ; --- Exit: restore state and return to menu ---
    JSR RESTORESTATE
    JSR PROT_StartTalking
    JSR PROT_EndTalking
    JSR PROT_ExitToMenu
    JMP *

; ---------------------------------------------------------------------------
; SAVESTATE / RESTORESTATE
; ---------------------------------------------------------------------------
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

; ---------------------------------------------------------------------------
; String data (screen codes, .enc "screen" active)
; ---------------------------------------------------------------------------
MSG_TITLE
    .text "EASYSD HARDWARE TEST"
    .byte 0
MSG_TITLE_LEN = * - MSG_TITLE - 1  ; 20

MSG_KEY
    .text "PRESS ANY KEY"
    .byte 0
MSG_KEY_LEN = * - MSG_KEY - 1      ; 13

; ---------------------------------------------------------------------------
; Variables
; ---------------------------------------------------------------------------
SAVED_01    .byte 0
SAVED_DD00  .byte 0
SAVED_D011  .byte 0
SAVED_D016  .byte 0
SAVED_D018  .byte 0
SAVED_D020  .byte 0
SAVED_D021  .byte 0

; ---------------------------------------------------------------------------
; CartLib include — provides PROT_StartTalking, PROT_EndTalking,
; PROT_ExitToMenu, PROT_Send, CHROUT, GETIN, SCNKEY, etc.
; ---------------------------------------------------------------------------
.include "../../Loader/CartLibStream.s"
.include "../../Loader/DebugStrings.s"
