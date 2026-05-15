ENTRY_TYPE_FILE = $00
ENTRY_TYPE_PRG  = $01
ENTRY_TYPE_CRT  = $02
ENTRY_TYPE_DIR  = $04
ENTRY_TYPE_KOA  = $08
ENTRY_TYPE_WAV  = $09
ENTRY_TYPE_CVD  = $0A

; ------------------------------------------------------------
; Filename / plugin-name helpers
;
; File type dispatch is driven by Arduino-provided ENTRY_TYPE_* metadata.
; Plugin files live in /PLUGINS/ and are opened using:
;   /PLUGINS/<EXT>PLUGIN.PRG
; ------------------------------------------------------------

EXT_LEN
	.BYTE 0

EXTBUF
	.FILL 3, 0

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


PLUGINNAME
	.FILL 64, 0

PLUGIN_PREFIX
	.TEXT "/PLUGINS/"
	.BYTE 0

PLUGIN_PRG
	.TEXT "PLUGIN.PRG"
	.BYTE 0
