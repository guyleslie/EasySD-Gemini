; HWTest.s — EasySD Hardware Signal Diagnostic Plugin
; Tests signal integrity between C64 expansion port and Arduino.
;
; Tests performed (sequential, status line display):
;   1. ROML/EXROM  — implicit: if this code runs, ROML and EXROM are wired correctly
;   2. SW SERIAL   — implicit: CMD_HWTEST must be received by Arduino to get a response
;   3. NMI + DATA BUS — Arduino sends 10 known bit-patterns via NMI; C64 verifies each
;
; Display: writes to menu status line (row 24, $07C0 screen / $DBC0 color RAM).
; Auto-exits to menu after test completes (~1.5s result display).
;
; SD card: create empty file HWTEST.HWT in any directory.
; Menu sees .HWT extension → loads /PLUGINS/HWTPLUGIN.PRG → runs this code.

.enc "screen"

.include "../../Loader/DebugMacros.s"

    * = $C000
    JMP MAIN

MAIN
    JSR SAVESTATE

    ; Phase 0: announce start (white)
    LDA #$01
    LDX #<MSG_START
    LDY #>MSG_START
    JSR HWT_STATUSLINE
    LDX #20
    JSR WAITFRAMES

    ; Phase 1: ROML/EXROM — implicit OK (we are running from $C000 via CartLib at $8000)
    LDA #$05                    ; green
    LDX #<MSG_ROML_OK
    LDY #>MSG_ROML_OK
    JSR HWT_STATUSLINE
    LDX #15
    JSR WAITFRAMES

    ; Phase 2: NMI + DATA BUS test — show "testing" (white)
    LDA #$01
    LDX #<MSG_TESTING
    LDY #>MSG_TESTING
    JSR HWT_STATUSLINE

    ; Set up NMI handler: SOFTNMIVECTOR ($0318/$0319) → EEPROM TransferHandler (X1 speed)
    LDA NMITAB                  ; low byte of CARTRIDGENMIHANDLERX1 (from CartLib.s)
    STA SOFTNMIVECTOR           ; $0318 = low byte
    LDA #$80                    ; high byte = $80 (CartLib lives at $8000-$9FFF)
    STA SOFTNMIVECTOR+1         ; $0319 = $80

    LDA #$00
    STA ZP_IRQ_STATE_WAITHANDLE ; $64 = clear (NMI handler sets this when done)

    LDA #$01
    STA ZP_IRQ_API_DATA_LENGTH  ; $6B = 1 page (256 bytes total to receive)

    LDA #<TEST_BUFFER
    STA ZP_IRQ_API_DATA_LO      ; $6C = target buffer low byte
    LDA #>TEST_BUFFER
    STA ZP_IRQ_API_DATA_HI      ; $6D = target buffer high byte

    #SETBANK PP_CONFIG_DEFAULT  ; $01 = $37: I/O, KERNAL, BASIC visible (NMI dispatch via KERNAL)

    LDX #$01                    ; X = page count for NMI handler (counts down per 256 bytes)
    LDY #$00                    ; Y = byte index within page (counts 0..255)

    ; Send CMD_HWTEST to Arduino via software serial
    JSR PROT_StartTalking       ; SEI + CIA disable + send identifiers $64,$46,$17
    LDA #COMMAND_HWTEST         ; = 32
    JSR PROT_Send

    ; Wait for SUCCESSFUL (0x80) response — polls CARTRIDGE_BANK_VALUE ($80AB)
    JSR PROT_WaitProcessing
    BCS _comm_fail              ; CS = error or no response

    ; Receive 256 NMI bytes into TEST_BUFFER — tight poll on ZP_IRQ_STATE_WAITHANDLE
    ; NMI handler (TransferHandler in EEPROM) sets $64 to $64 when all pages done.
    CLV
    #WAITFOR ZP_IRQ_STATE_WAITHANDLE, BVC

    ; Phase 3: verify TEST_BUFFER[0..9] against expected bit patterns
    LDA #$00
    STA HWT_RESULT              ; 0 = all OK so far

    LDX #$00
_verify
    LDA HWT_PATTERNS, X
    EOR TEST_BUFFER, X          ; XOR: 0 = match, non-zero = which bits differ
    BEQ _next
    ORA HWT_RESULT
    STA HWT_RESULT
_next
    INX
    CPX #10
    BNE _verify

    LDA HWT_RESULT
    BNE _dbus_fail

    ; All tests passed
    LDA #$05                    ; green
    LDX #<MSG_NMI_OK
    LDY #>MSG_NMI_OK
    JSR HWT_STATUSLINE
    JMP _done

_comm_fail
    ; Arduino did not respond — SW serial or NMI path broken
    LDA #$02                    ; red
    LDX #<MSG_COMM_FAIL
    LDY #>MSG_COMM_FAIL
    JSR HWT_STATUSLINE
    JMP _done

_dbus_fail
    ; Received wrong bit patterns — data bus wiring error
    LDA #$02                    ; red
    LDX #<MSG_DBUS_FAIL
    LDY #>MSG_DBUS_FAIL
    JSR HWT_STATUSLINE

_done
    LDX #90                     ; ~1.5s at PAL 50Hz, ~1.25s at NTSC 60Hz
    JSR WAITFRAMES
    JSR RESTORESTATE
    JSR PROT_DisableDisplay
    JSR PROT_ExitToMenu
    JMP *

; ---------------------------------------------------------------------------
; HWT_STATUSLINE — write null-terminated string to menu status line (row 24)
; Entry:  A = color value ($01=white $02=red $05=green $0B=dark gray)
;         X = string address low byte
;         Y = string address high byte
; String convention: 3 leading bytes skipped (Y index starts at 3, matches
;   SL_WRITE in EasySDMenu.s). Cols 0-2 (frame border) are left untouched.
;   Trailing null ($00) causes remainder of line to be padded with spaces.
; Uses ZP $8B/$8C as pointer (free per CartZpMap.inc).
; ---------------------------------------------------------------------------
HWT_STATUSLINE
    STX $8B                     ; string ptr lo
    STY $8C                     ; string ptr hi
    TAX                         ; save color in X (avoids $FB-$FE navigation ptrs)
    LDY #$03                    ; start at column 3 (skip frame border cols 0-2)
_hsl_copy
    LDA ($8B), Y
    BEQ _hsl_pad
    STA $07C0, Y                ; screen RAM row 24 col Y
    TXA
    STA $DBC0, Y                ; color RAM row 24 col Y
    INY
    CPY #$25                    ; stop at col 37 (leave cols 37-39 for frame border)
    BNE _hsl_copy
    RTS
_hsl_pad
    LDA #$20                    ; space (screen code = $20, same as ASCII)
_hsl_pad_loop
    STA $07C0, Y
    INY
    CPY #$25
    BNE _hsl_pad_loop
    RTS

; ---------------------------------------------------------------------------
; WAITFRAMES — raster-synchronized frame delay
; Entry: X = number of frames to wait
; ---------------------------------------------------------------------------
WAITFRAMES
_wf_outer
    LDA #$90                    ; wait for raster line $90 (144)
_wf_raster
    CMP $D012
    BNE _wf_raster
    LDY #50                     ; short busy-loop for sub-frame stability
_wf_inner
    DEY
    BNE _wf_inner
    DEX
    BNE _wf_outer
    RTS

; ---------------------------------------------------------------------------
; SAVESTATE / RESTORESTATE — save/restore VIC registers and processor port
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
; String data — convention: 3 leading spaces (bytes 0-2 skipped by HWT_STATUSLINE),
; actual display text from byte 3. Screen-code encoded (.enc "screen" active).
; ---------------------------------------------------------------------------
MSG_START
    .text "   EASYSD HW TEST..."
    .byte 0
MSG_ROML_OK
    .text "   ROML: OK"
    .byte 0
MSG_TESTING
    .text "   NMI+DBUS TESTING..."
    .byte 0
MSG_NMI_OK
    .text "   NMI+DBUS: OK"
    .byte 0
MSG_COMM_FAIL
    .text "   FAIL: NO ARDUINO RESPONSE"
    .byte 0
MSG_DBUS_FAIL
    .text "   FAIL: DATABUS ERROR"
    .byte 0

; Expected NMI test patterns: single-bit (D0-D7) + alternating (0x55, 0xAA)
HWT_PATTERNS
    .byte $01,$02,$04,$08,$10,$20,$40,$80,$55,$AA

; Plugin variables (1 byte each, assembled into binary)
SAVED_01    .byte 0
SAVED_DD00  .byte 0
SAVED_D011  .byte 0
SAVED_D016  .byte 0
SAVED_D018  .byte 0
SAVED_D020  .byte 0
SAVED_D021  .byte 0
HWT_RESULT  .byte 0

; CartLib include last — provides PROT_StartTalking, PROT_Send, PROT_WaitProcessing,
; PROT_ExitToMenu, PROT_DisableDisplay, NMITAB, SOFTNMIVECTOR, ZP_IRQ_* constants, macros.
.include "../../Loader/CartLibStream.s"
.include "../../Loader/DebugStrings.s"

; TEST_BUFFER: 256 bytes at the address immediately following CartLib code.
; Declared as label only — no bytes emitted. RAM here is available at runtime;
; the NMI TransferHandler writes incoming bytes into this area.
TEST_BUFFER
