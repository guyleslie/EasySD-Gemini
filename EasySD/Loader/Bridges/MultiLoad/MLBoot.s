;================================================================================
; MLBoot.s — Multi-Load Prologue Blob
;================================================================================
;
; PURPOSE:
;   Self-installing prologue PRG that the Arduino synthesises and transmits in
;   place of the user-selected first-part PRG when the selection lives under
;   /MULTILOAD/<game>/. Replaces the legacy EASYLOAD.PRG + MultiLoad.s MAIN
;   pipeline with a single hand-written blob built into FlashLib.h.
;
; FLOW:
;   1. Arduino patches MLBOOT_FIRSTPART_LEN/NAME with the on-disk filename and
;      sends the blob via the standard LoaderStub path.
;   2. C64 receives, lands at $C019 (MAIN).
;   3. MAIN calls RL_INSTALL — copies RL_STUB to $033C, RL_HANDLER+
;      RL_MINI_CARTLIB to $E800, patches $0330/$0331, writes RL_NMI_REDIRECT
;      to $FFFA/$FFFB.
;   4. MAIN sets up the Kernal filename pointer to MLBOOT_FIRSTPART_NAME and
;      issues JSR $FFD5 (Kernal LOAD) with device 8, SA=1.
;   5. The LOAD goes through $0330 → RL_STUB → RL_HANDLER → Arduino's existing
;      HandleOpenFile/HandleReadFile path. Arduino's CWD is /MULTILOAD/<game>/
;      because LoadAndLaunchFile re-navigated there before StartListening.
;   6. After LOAD, MAIN reads the load address from RL_HDR_BUF (briefly under
;      $01=$35), runs the SHOULD_RUN_BASIC decision tree, and launches the game
;      via either CLR+RUN (BASIC / hybrid) or JMP indirect (machine code).
;   7. In-game LOAD "X",8,1 calls hit the resident hook at $033C and stream
;      from the same SD directory through Arduino.
;
; LAYOUT (offsets locked — Arduino patches via these byte offsets):
;
;   $C000   JMP MAIN                         ; 3 bytes
;   $C003   .byte VERSION                    ; 1 byte sentinel (= 4 for MLBoot)
;   $C004   MLBOOT_FIRSTPART_LEN  .byte 0    ; patched per launch by Arduino
;   $C005   MLBOOT_FIRSTPART_NAME .fill 20,0 ; patched, NUL-padded
;   $C019   MAIN
;
; Filename field budget: 20 bytes incl. ".PRG" = 16-char PETSCII max.
;================================================================================

; Layout offsets — keep in sync with CartApi.cpp::SendMLBootBlob
MLBOOT_VERSION               = 4
MLBOOT_FIRSTPART_LEN_OFFSET  = $04
MLBOOT_FIRSTPART_NAME_OFFSET = $05
MLBOOT_FIRSTPART_NAME_MAX    = 20

;-----------------------------------------------------------------------
; Includes — MLBoot is a self-contained standalone-buildable blob, so it
; pulls in System/EasySD/CartZpMap directly (the prebuild_checks whitelist
; allows this in addition to CartLibStream.s — see Tools/build.py).
;-----------------------------------------------------------------------
.include "../../Common/System.inc"
.include "../../Common/EasySD.inc"
.include "../../CartZpMap.inc"

; CartLibCommon.s constants needed by RL_NMITAB and RL_WaitProcessing
; (mirrored here so MLBoot does not have to include CartLib.s).
CARTRIDGENMIHANDLERX1 = $80AF
CARTRIDGENMIHANDLERX4 = $80A0
CARTRIDGENMIHANDLERX8 = $808C
CARTRIDGE_BANK_VALUE  = $80AB

	*=$C000
	JMP MAIN

	.byte MLBOOT_VERSION             ; $C003 — version sentinel
MLBOOT_FIRSTPART_LEN:
	.byte 0                          ; $C004 — patched by Arduino
MLBOOT_FIRSTPART_NAME:
	.fill 20, 0                      ; $C005-$C018 — patched by Arduino

;================================================================================
; MAIN — entry point ($C019)
; Runs in default $01=$37 (BASIC ROM + Kernal ROM + I/O all visible).
;================================================================================

MAIN:
	;--- 1. Install resident LOAD hook (RL_STUB + RL_HANDLER images, vectors).
	JSR RL_INSTALL

	;--- 1b. Settle delay (~250 ms) — race fix.
	; Arduino's LoadAndLaunchFile() runs Init() + NavigateToPath() (~50–100 ms
	; combined) AFTER SendMLBootBlob and BEFORE cartInterface.StartListening()
	; attaches the IO2 ISR. Without this delay, RL_StartTalking's handshake
	; bytes ($64 $46 $17) are emitted before the ISR is live, the IDLE→
	; IDENTIFIER_3_OK transition never fires, EnableCartridge() (line 209 in
	; CartInterface.cpp) is never called, and CARTRIDGE_BANK_VALUE ($80AB)
	; reads junk RAM during RL_WaitProcessing — typically returns SEC and
	; MAIN's BCS branches to ml_load_error → reset to BASIC.
	; ~250 k cycles ≈ 250 ms at PAL 0.985 MHz / 244 ms at NTSC 1.022 MHz.
	LDX #200
ml_settle_outer:
	LDY #0
ml_settle_inner:
	DEY
	BNE ml_settle_inner
	DEX
	BNE ml_settle_outer

	;--- 2. Set up Kernal filename pointer.
	LDA MLBOOT_FIRSTPART_LEN
	STA KERNAL_FILENAME_LENGTH       ; $B7
	LDA #<MLBOOT_FIRSTPART_NAME
	STA KERNAL_FILENAME_LOW          ; $BB
	LDA #>MLBOOT_FIRSTPART_NAME
	STA KERNAL_FILENAME_HIGH         ; $BC

	;--- 3. Device 8, secondary address 1 (= use the PRG header's load address).
	LDA #1
	STA KERNAL_SECONDARY_ADDRESS     ; $B9
	LDA #8
	STA KERNAL_DEVICE_NUMBER         ; $BA

	;--- 4. Kernal LOAD. Goes through $0330 → RL_STUB → RL_HANDLER → Arduino.
	;   Returns: A=0 ok / error code, X/Y = end address (exclusive).
	;   C set on error.
	LDA #0                           ; LOAD operation (vs VERIFY=1)
	JSR $FFD5
	BCS ml_load_error

	;--- 5. Cache end address and read the load address from RL_HDR_BUF.
	;   RL_HANDLER stored the PRG header at $E8C4..$E8C5 under $01=$35.
	;   We are back in $01=$37 here so Kernal ROM is mapped at $E000-$FFFF;
	;   reading $E8C4 directly would see ROM, not the header. Switch banking
	;   briefly to copy the load address out into ZP scratch.
	STX $8D                          ; end_lo  (post-LOAD: byte after last)
	STY $8E                          ; end_hi

	SEI
	LDA #PP_CONFIG_RAM_ON_ROM        ; $35 — Kernal RAM visible
	STA PROCESSOR_PORT
	LDA RL_HDR_BUF                   ; $E8C4
	STA $8B                          ; load_lo
	LDA RL_HDR_BUF + 1
	STA $8C                          ; load_hi
	LDA #PP_CONFIG_DEFAULT           ; $37 — restore default banking
	STA PROCESSOR_PORT

	;--- 6. İlker Fıçıcılar's fix: program system pointers so BASIC/CLR
	;   does not overwrite the loaded program.
	LDA $8D
	STA $2D
	STA $2F
	STA $AE                          ; LOAD_START_LO
	LDA $8E
	STA $2E
	STA $30
	STA $AF                          ; LOAD_START_HI

	;--- 7. Re-init system regs for game launch (mirror of LoaderStub.65s).
	LDA #$08                         ; current device = 8
	STA KERNAL_DEVICE_NUMBER
	LDA #$1B                         ; %00011011 — VIC display enabled
	STA VIC_CONTROL_1
	LDA #$81                         ; %10000001 — CIA1 timer-A IRQ enable (jiffy)
	STA CIA_1_BASE + CIA_INT_MASK    ; $DC0D
	CLI

	;--- 8. SHOULD_RUN_BASIC decision tree (mirror of LoaderStub.65s).
	JSR ml_should_run_basic
	BCS ml_launch_machine

	;--- BASIC launch path -----------------------------------------------
	JSR $A659                        ; "CLR"
	JMP $A7AE                        ; "RUN"

ml_launch_machine:
	JMP ($008B)                      ; jump indirect via load-address ZP slot

ml_load_error:
	; Soft-fail with visible diagnostic: red border + black bg for ~2 s so the
	; user can distinguish "MLBoot LOAD failed" from a generic crash, then
	; system-reset to BASIC. RL_INSTALL has patched $0330/$0331 but the cold
	; start re-initialises the Kernal vectors so the hook becomes inert.
	LDA #$02
	STA BORDER                       ; $D020 — red
	LDA #$00
	STA SCREEN                       ; $D021 — black
	LDX #200
ml_err_outer:
	LDY #0
ml_err_inner:
	DEY
	BNE ml_err_inner
	DEX
	BNE ml_err_outer
	JMP RESETROUTINE                 ; $FCE2

;================================================================================
; ml_should_run_basic — mirror of LoaderStub.65s SHOULD_RUN_BASIC.
;   In:  $8B/$8C = load address, $8D/$8E = end address (exclusive)
;   Out: C=0 → BASIC RUN, C=1 → JMP indirect to load address
;================================================================================

ml_should_run_basic:
	LDA $8C
	CMP #$08
	BNE ml_chk_hybrid
	LDA $8B
	CMP #$01
	BNE ml_machine
	; Load address is $0801 — check if first BASIC line is non-empty.
	; $00 means end-of-line immediately (empty BASIC header e.g. Last Ninja+);
	; treat as machine code so the indirect JMP lands on real code.
	LDA $0805
	BEQ ml_machine
ml_basic:
	CLC
	RTS
ml_machine:
	SEC
	RTS

ml_chk_hybrid:
	BCS ml_machine                   ; load address > $08xx → not BASIC
	LDA $8E
	CMP #$08
	BCC ml_machine                   ; end < $08xx
	BNE ml_chk_sys
	LDA $8D
	CMP #$09
	BCC ml_machine                   ; end < $0809
ml_chk_sys:
	LDA $0805
	CMP #$9E
	BNE ml_machine
	CLC                              ; $9E found → hybrid BASIC PRG
	RTS

;================================================================================
; ResidentLoader (RL_STUB_IMAGE, RL_HANDLER_IMAGE, RL_INSTALL, RL_UNINSTALL)
; Included verbatim. Image .logical addresses ($033C / $E800) drive label
; resolution; the bytes are physically appended to MLBoot's $C000+ region
; and copied to their runtime addresses by RL_INSTALL.
;================================================================================
.include "../../ResidentLoader.s"

;================================================================================
; Overflow guard — must not reach I/O space at $D000.
;================================================================================
.if * > $D000
	.error "MLBoot blob overflow: exceeds $D000 (I/O space)"
.endif
