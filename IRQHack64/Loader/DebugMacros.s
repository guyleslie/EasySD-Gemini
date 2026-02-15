;===============================================
; DebugMacros.s - Common DEBUG Display Macros
;===============================================
; Shared DEBUG macros for IRQHack64/EasySD plugins
; Visual status display and timing utilities
;
; Usage in plugin:
;   .include "../../Loader/DebugMacros.s"
;   PRINTSTATUSANDWAIT OPENINGFILE, 100
;
; Created: 2025-12-18
; Replaces duplicated macros across all plugins
;===============================================

;-----------------------------------------------
; PRINTSTATUSANDWAIT - Conditional debug display
;-----------------------------------------------
; Displays status message and waits (only in DEBUG=1 builds)
; Parameters:
;   \1 = String label (e.g., OPENINGFILE)
;   \2 = Frame count to wait
;-----------------------------------------------
PRINTSTATUSANDWAIT	.macro
.if DEBUG = 1
	PRINTSTATUS \1
	DELAYFRAMES \2
.else
	DELAYFRAMES 1
.endif
	.endm

;-----------------------------------------------
; DELAYFRAMES - Conditional frame delay
;-----------------------------------------------
; Waits specified number of frames (only in DEBUG=1 builds)
; Parameters:
;   \1 = Frame count
;-----------------------------------------------
DELAYFRAMES	.macro
.if DEBUG = 1
	LDX #\1
	JSR WAITFRAMES
.endif
	.endm

;-----------------------------------------------
; PRINTSTATUS - Display message on top line
;-----------------------------------------------
; Clears top screen line and prints string
; String must be in SCREEN CODE format (.enc "screen")
; Parameters:
;   \1 = String label
;-----------------------------------------------
PRINTSTATUS	.macro
	; Clear top line (40 chars at $0400-$0427)
	LDX #0
-
	LDA #$20
	STA $0400, X
	INX
	CPX #40
	BNE -
	; Print string (already in SCREEN CODE format from .enc "screen")
	LDX #0
NEXTCHAR
	LDA \1, X
	BEQ OUTPRINT
	STA $0400, X
	INX
	BNE NEXTCHAR
OUTPRINT
	.endm

;-----------------------------------------------
; WAITFRAMES - Wait routine (must be in plugin)
;-----------------------------------------------
; NOTE: Each plugin must implement its own WAITFRAMES
; subroutine, as it depends on local timing needs.
;
; Typical implementation:
;   WAITFRAMES:
;       LDY #$90
;   -   CPY $D012
;       BNE -
;       LDY #50
;   -   DEY
;       BNE -
;       DEX
;       BNE WAITFRAMES
;       RTS
;-----------------------------------------------

;-----------------------------------------------
; End of DebugMacros.s
;-----------------------------------------------
