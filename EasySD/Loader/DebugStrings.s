;===============================================
; DebugStrings.s - Common DEBUG Status Strings
;===============================================
; Shared DEBUG strings for IRQHack64/EasySD plugins
; Used by PRINTSTATUSANDWAIT macro in DEBUG builds
;
; Usage in plugin:
;   .include "../../Loader/DebugStrings.s"
;   PRINTSTATUSANDWAIT OPENINGFILE, 100

;===============================================

.enc "screen"

;-----------------------------------------------
; Common File Operation Strings
;-----------------------------------------------
OPENINGFILE:
	.TEXT "OPENING FILE"
	.BYTE 0

OPENINGSUCCESS:
	.TEXT "FILE OPEN SUCCEEDED"
	.BYTE 0

OPENINGFAILED:
	.TEXT "OPENING FILE FAILED"
	.BYTE 0

READINGFILE:
	.TEXT "READING FILE"
	.BYTE 0

READINGFAILED:
	.TEXT "READING FAILED"
	.BYTE 0

CLOSINGFILE:
	.TEXT "CLOSING FILE"
	.BYTE 0

CLOSINGSUCCESS:
	.TEXT "FILE CLOSING SUCCEEDED"
	.BYTE 0

CLOSINGFAILED:
	.TEXT "CLOSING FAILED"
	.BYTE 0

;-----------------------------------------------
; Communication Strings
;-----------------------------------------------
STARTTALKING:
	.TEXT "SENDING START TALKING COMMAND"
	.BYTE 0

TALKINGSTARTED:
	.TEXT "STARTED TALKING"
	.BYTE 0

;-----------------------------------------------
; Plugin-Specific Strings
;-----------------------------------------------
KOALA_HEADER:
	.TEXT "EASYSD KOALA PLUGIN"
	.BYTE 0

;-----------------------------------------------
; End of DebugStrings.s
;-----------------------------------------------
