;===============================================
; APIMacros.s - Tier 2 API & File Operation Macros
;===============================================
; IRQHack64 high-level API abstraction macros
; These macros provide convenient wrappers around
; IRQHack64 cartridge API functions.
;
; Usage:
;   .include "APIMacros.s"
;   #OPENFILE FILENAME_BUFFER, #31, #FLAGS_READ
;   #GETFILEINFO FILE_INFO_BUFFER
;   #CLOSEFILE
;
; Created: 2025-12-28 (Sprint 2)
; Category: Tier 2 (Project Standard Macros)
;===============================================

;-----------------------------------------------
; OPENFILE - Open file with standard sequence
;-----------------------------------------------
; Opens a file using the IRQHack64 file API.
; Combines PROT_SetName and PROT_OpenFile calls.
;
; ARCHITECTURAL CONTRACT:
;   - Sets filename from buffer
;   - Opens file with specified flags
;   - Carry flag indicates success/failure
;   - A register contains error code if failed
;
; Parameters:
;   \1 = Filename buffer address (16-bit)
;   \2 = Filename length (immediate value, e.g., #31)
;   \3 = Open flags (immediate value, e.g., #01 for read)
;
; Registers affected: A, X, Y
; Flags affected: N, Z, C (Carry clear = success, set = error)
; Bytes: ~15 bytes
;
; Example:
;   #OPENFILE FILE_PATH_BUF, #31, #01
;   BCC file_opened_ok
;   JMP error_handler
;   file_opened_ok:
;
; Replaces:
;   LDX #<FILE_PATH_BUF
;   LDY #>FILE_PATH_BUF
;   LDA #31
;   JSR PROT_SetName
;   LDX #01
;   JSR PROT_OpenFile
;
; Common usage: All plugins that load files
; Frequency: 12 occurrences in codebase
;
; Notes:
;   - Must call PROT_DisableDisplay before if needed
;   - Check carry flag after call for errors
;   - Remember to call CLOSEFILE when done
;-----------------------------------------------
OPENFILE .macro
	LDX #<\1
	LDY #>\1
	LDA \2
	JSR PROT_SetName
	LDX \3
	JSR PROT_OpenFile
	.endm

;-----------------------------------------------
; GETFILEINFO - Get file information
;-----------------------------------------------
; Retrieves FAT directory entry for currently open file.
; Information includes file size, attributes, dates, etc.
;
; ARCHITECTURAL CONTRACT:
;   - Sets buffer pointer in ZP_IRQ_API_DATA_LO/HI
;   - Calls PROT_GetInfoForFile
;   - Returns 32-byte FAT directory entry
;   - Carry flag indicates success/failure
;
; Parameters:
;   \1 = Buffer address for FAT entry (must be 32+ bytes)
;
; Registers affected: A, Y
; Flags affected: N, Z, C (Carry clear = success, set = error)
; Bytes: ~13 bytes
;
; Example:
;   #GETFILEINFO FILEINFO_BUFFER
;   BCC info_read_ok
;   JMP error_handler
;   info_read_ok:
;   ; File size is at FILEINFO_BUFFER + 28..31 (4 bytes, little-endian)
;
; Replaces:
;   LDA #<FILEINFO_BUFFER
;   STA ZP_IRQ_API_DATA_LO
;   LDA #>FILEINFO_BUFFER
;   STA ZP_IRQ_API_DATA_HI
;   LDY #$00
;   JSR PROT_GetInfoForFile
;
; Common usage: Plugins that need exact file size
; Frequency: 8 occurrences in codebase
;
; FAT Directory Entry Layout:
;   +00..10: Filename (8.3 format, space-padded)
;   +11: Attributes
;   +28..31: File size (32-bit little-endian)
;
; Notes:
;   - Must have file open first (call OPENFILE)
;   - File size extraction: LDA BUFFER+28/29/30/31
;-----------------------------------------------
GETFILEINFO .macro
	LDA #<\1
	STA ZP_IRQ_API_DATA_LO
	LDA #>\1
	STA ZP_IRQ_API_DATA_HI
	LDY #$00
	JSR PROT_GetInfoForFile
	.endm

;-----------------------------------------------
; CLOSEFILE - Close currently open file
;-----------------------------------------------
; Closes the currently open file.
; Simple wrapper for PROT_CloseFile.
;
; ARCHITECTURAL CONTRACT:
;   - Closes current file handle
;   - Returns status in A register
;   - Should always succeed if file was open
;
; Parameters: None
;
; Registers affected: A
; Flags affected: N, Z
; Bytes: 3 (JSR absolute)
;
; Example:
;   #CLOSEFILE
;
; Replaces:
;   JSR PROT_CloseFile
;
; Common usage: Cleanup after file operations
; Frequency: 17 occurrences in codebase
;
; Notes:
;   - Always call after file operations complete
;   - Safe to call even if file wasn't successfully opened
;   - Consider adding error checking for critical code
;-----------------------------------------------
CLOSEFILE .macro
	JSR PROT_CloseFile
	.endm

;-----------------------------------------------
; EXTRACTFILESIZE - Extract 32-bit file size from FAT entry
;-----------------------------------------------
; Extracts the 4-byte file size from FAT directory entry
; and stores it in specified destination.
;
; ARCHITECTURAL CONTRACT:
;   - Reads bytes 28..31 from FAT entry buffer
;   - Stores to 4 consecutive bytes starting at destination
;   - Little-endian byte order preserved
;
; Parameters:
;   \1 = Source FAT entry buffer (must contain valid FAT data)
;   \2 = Destination address for 32-bit size
;
; Registers affected: A
; Flags affected: N, Z
; Bytes: 16 (4× LDA abs + STA abs)
;
; Example:
;   #GETFILEINFO FATBUFFER
;   BCS error
;   #EXTRACTFILESIZE FATBUFFER, FILESIZE
;   ; Now FILESIZE contains 32-bit file size
;
; Replaces:
;   LDA FATBUFFER + 28
;   STA FILESIZE
;   LDA FATBUFFER + 29
;   STA FILESIZE + 1
;   LDA FATBUFFER + 30
;   STA FILESIZE + 2
;   LDA FATBUFFER + 31
;   STA FILESIZE + 3
;
; Common usage: After GETFILEINFO to get exact file size
; Frequency: ~8 occurrences in codebase (paired with GETFILEINFO)
;
; Notes:
;   - FAT entry byte 28-31 = file size (LSB first)
;   - Maximum file size: 4GB (FAT32)
;   - For files >64KB, use streaming API
;-----------------------------------------------
EXTRACTFILESIZE .macro
	LDA \1 + 28
	STA \2
	LDA \1 + 29
	STA \2 + 1
	LDA \1 + 30
	STA \2 + 2
	LDA \1 + 31
	STA \2 + 3
	.endm

;-----------------------------------------------
; SETADDR - Load a 2-byte address into a ZP pointer pair
;-----------------------------------------------
; Sets up a 16-bit zero page pointer to point to a given label.
;
; ARCHITECTURAL CONTRACT:
;   - Always writes low byte first, then high byte
;   - Uses immediate addressing mode (#<\1 / #>\1)
;   - Destination must be a zero page address pair (\2 and \2+1)
;
; Parameters:
;   \1 = source label (16-bit address)
;   \2 = destination ZP low byte (high byte is \2+1)
;
; Registers affected: A
; Flags affected: N, Z
; Bytes: 8 (LDA imm=2, STA zp=2, LDA imm=2, STA zp=2)
;
; Example:
;   #SETADDR GENERALBUFFER, ZP_IRQ_API_DATA_LO
;
; Replaces:
;   LDA #<GENERALBUFFER
;   STA ZP_IRQ_API_DATA_LO
;   LDA #>GENERALBUFFER
;   STA ZP_IRQ_API_DATA_HI
;
; Common usage: File API buffer setup, stream target setup
; Frequency: ~6 occurrences in KernalBridge
;-----------------------------------------------
SETADDR .macro
	LDA #<\1
	STA \2
	LDA #>\1
	STA \2 + 1
	.endm

;-----------------------------------------------
; LOADMEDIAPATH - Recover media file path from FILE_PATH_SHADOW into a buffer
;-----------------------------------------------
; The C64 menu writes the selected media file's absolute path to BOTH
; FILE_PATH_BUF ($033C) and FILE_PATH_SHADOW ($FF00) before invoking a plugin.
; The cart-loader launch sequence wipes $0002-$03FF and overwrites
; $033C-$043B with the LoaderStub, so by the time the plugin runs the path
; at FILE_PATH_BUF is gone. The shadow at $FF00 lives in RAM under the
; KERNAL ROM and survives the launch — IRQLoader/LoaderStub do not touch it,
; and 6502 writes to $E000-$FFFF always reach RAM regardless of $01.
;
; This macro briefly switches $01 to $35 (HIRAM=0) so reads from $FFxx return
; RAM, copies up to FILE_PATH_SHADOW_MAX bytes (or until a null terminator)
; into the supplied destination buffer, then restores $01.
;
; ARCHITECTURAL CONTRACT:
;   - Caller must hold IRQ disabled before invoking. PROT_StartTalking does
;     SEI + PROT_DisableInterrupts, so calling LOADMEDIAPATH after
;     PROT_StartTalking is safe.
;   - Destination buffer must be at least FILE_PATH_SHADOW_MAX bytes (64).
;   - Brief NMI exposure during banking switch: callers should ensure CIA2
;     timer NMIs are disabled (KILLCIA / PROT_DisableInterrupts already do).
;
; Parameters:
;   \1 = Destination buffer address (16-bit, plugin-local RAM)
;
; Registers affected: A, Y
;-----------------------------------------------
LOADMEDIAPATH .macro
	LDA $01
	PHA
	LDA #$35
	STA $01
	LDY #0
_lmp_copy
	LDA FILE_PATH_SHADOW, Y
	STA \1, Y
	BEQ _lmp_done
	INY
	CPY #FILE_PATH_SHADOW_MAX
	BNE _lmp_copy
_lmp_done
	PLA
	STA $01
	.endm

;===============================================
; End of APIMacros.s
;===============================================
; For display control, see existing functions:
;   - PROT_DisableDisplay (turn off screen)
;   - PROT_EnableDisplay (turn on screen)
; These are already efficient JSR calls and don't
; need macro wrappers.
;===============================================
