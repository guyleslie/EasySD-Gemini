TYPE_PROGRAM = 0
TYPE_CHECK_PLUGIN	= 1

ENTRY_TYPE_FILE = $00
ENTRY_TYPE_PRG  = $01
ENTRY_TYPE_CRT  = $02
ENTRY_TYPE_IRQ  = $03
ENTRY_TYPE_DIR  = $04
ENTRY_TYPE_KOA  = $08
ENTRY_TYPE_WAV  = $09
ENTRY_TYPE_CVD  = $0A

; ------------------------------------------------------------
; Filename / plugin-name helpers
;
; Goal (2025-12): plugins live in /PLUGINS/ and are opened using
; absolute paths. Extension-based dispatch becomes deterministic:
;   /PLUGINS/<EXT>PLUGIN.PRG
;
; CHECKFILENAME extracts only the first 1..3 chars of the extension
; (after the last '.'). Plugin dispatch therefore expects 3-char media
; extensions such as .WAV, .KOA, .CVD.
; If no valid extension -> TYPE_PROGRAM.
; ------------------------------------------------------------

PERIOD_POSITION
	.BYTE 0
FILENAME_ACTUAL_LENGTH
	.BYTE 0
EXT_LEN
	.BYTE 0

EXTBUF
	.FILL 3, 0

; Send low in A , high in X
CHECKFILENAME
	STA $06
	STX $07

	LDA #$00
	STA PERIOD_POSITION
	STA EXT_LEN
	STA EXTBUF
	STA EXTBUF+1
	STA EXTBUF+2

	LDY #0
_find_last_dot
	LDA ($06), Y
	BEQ _end_scan
	CMP #$2E
	BNE _next
	STY PERIOD_POSITION
_next
	INY
	BNE _find_last_dot

_end_scan
	STY FILENAME_ACTUAL_LENGTH
	LDA PERIOD_POSITION
	BEQ _no_extension

	; dot must not be last char
	CLC
	ADC #1
	CMP FILENAME_ACTUAL_LENGTH
	BEQ _no_extension

	; copy up to 3 chars extension into EXTBUF
	LDY PERIOD_POSITION
	INY
	LDX #0
_copy_ext
	LDA ($06), Y
	BEQ _have_ext
	STA EXTBUF, X
	INX
	INY
	CPX #3
	BNE _copy_ext

_have_ext
	STX EXT_LEN
	LDA #TYPE_CHECK_PLUGIN
	RTS

_no_extension
	LDA #TYPE_PROGRAM
	RTS


; Build "/PLUGINS/<EXT>PLUGIN.PRG" into PLUGINNAME (0-terminated).
BUILDPLUGINNAME_PRG
	LDX #0
_copy_prefix_prg
	LDA PLUGIN_PREFIX, X
	BEQ _prefix_done_prg
	STA PLUGINNAME, X
	INX
	BNE _copy_prefix_prg
_prefix_done_prg
	LDY #0
_copy_ext_prg
	CPY EXT_LEN
	BEQ _ext_done_prg
	LDA EXTBUF, Y
	STA PLUGINNAME, X
	INX
	INY
	BNE _copy_ext_prg
_ext_done_prg
	LDY #0
_copy_suffix_prg
	LDA PLUGIN_PRG, Y
	STA PLUGINNAME, X
	BEQ _done_prg
	INX
	INY
	BNE _copy_suffix_prg
_done_prg
	RTS

SETEXT_KOA
	LDA #3
	STA EXT_LEN
	LDA #$6B		; k
	STA EXTBUF
	LDA #$6F		; o
	STA EXTBUF+1
	LDA #$61		; a
	STA EXTBUF+2
	LDA #TYPE_CHECK_PLUGIN
	RTS

SETEXT_WAV
	LDA #3
	STA EXT_LEN
	LDA #$77		; w
	STA EXTBUF
	LDA #$61		; a
	STA EXTBUF+1
	LDA #$76		; v
	STA EXTBUF+2
	LDA #TYPE_CHECK_PLUGIN
	RTS

SETEXT_CVD
	LDA #3
	STA EXT_LEN
	LDA #$63		; c
	STA EXTBUF
	LDA #$76		; v
	STA EXTBUF+1
	LDA #$64		; d
	STA EXTBUF+2
	LDA #TYPE_CHECK_PLUGIN
	RTS


; Case-insensitive PRG check: accepts .prg, .PRG, .Prg, etc.
; ORA #$20 forces ASCII uppercase → lowercase before comparing.
; A is preserved on the SEC (not-PRG) path because the caller
; needs the CHECKFILENAME return value for TYPE_PROGRAM/TYPE_CHECK_PLUGIN dispatch.
ISPRG
	PHA			; save A (CHECKFILENAME result)
	LDA EXT_LEN
	CMP #3
	BNE _isprg_no
	LDA EXTBUF
	ORA #$20		; force lowercase ('P'→'p', 'p'→'p')
	CMP #$70		; 'p'
	BNE _isprg_no
	LDA EXTBUF+1
	ORA #$20
	CMP #$72		; 'r'
	BNE _isprg_no
	LDA EXTBUF+2
	ORA #$20
	CMP #$67		; 'g'
	BNE _isprg_no
	PLA			; discard saved A (balance stack)
	CLC
	RTS
_isprg_no
	PLA			; restore A (CHECKFILENAME result)
	SEC
	RTS

; Case-insensitive KOA check.
ISKOA
	LDA EXT_LEN
	CMP #3
	BNE _iskoa_no
	LDA EXTBUF
	ORA #$20
	CMP #$6B		; 'k'
	BNE _iskoa_no
	LDA EXTBUF+1
	ORA #$20
	CMP #$6F		; 'o'
	BNE _iskoa_no
	LDA EXTBUF+2
	ORA #$20
	CMP #$61		; 'a'
	BNE _iskoa_no
	CLC
	RTS
_iskoa_no
	SEC
	RTS

; Case-insensitive direct launch whitelist for non-PRG executable formats.
; Most 3-letter extensions are media plugin inputs. If their plugin is missing,
; the menu must not fall back to launching the media bytes as a PRG.
ISDIRECTLAUNCH
	LDA EXT_LEN
	CMP #3
	BNE _direct_no

	LDA EXTBUF
	ORA #$20
	CMP #$63		; 'c'
	BNE _check_irq
	LDA EXTBUF+1
	ORA #$20
	CMP #$72		; 'r'
	BNE _direct_no
	LDA EXTBUF+2
	ORA #$20
	CMP #$74		; 't'
	BNE _direct_no
	CLC
	RTS

_check_irq
	CMP #$69		; 'i'
	BNE _direct_no
	LDA EXTBUF+1
	ORA #$20
	CMP #$72		; 'r'
	BNE _direct_no
	LDA EXTBUF+2
	ORA #$20
	CMP #$71		; 'q'
	BNE _direct_no
	CLC
	RTS

_direct_no
	SEC
	RTS


PLUGINNAME
	.FILL 64, 0

PLUGIN_PREFIX
	.TEXT "/PLUGINS/"
	.BYTE 0

PLUGIN_PRG
	.TEXT "PLUGIN.PRG"
	.BYTE 0
