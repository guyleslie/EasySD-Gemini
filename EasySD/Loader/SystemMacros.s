;===============================================
; SystemMacros.s - Tier 1 Base System Macros
;===============================================
; IRQHack64 foundational macro library
; These macros form the architectural foundation and
; establish contracts for hardware access patterns.
;
; Usage:
;   .include "SystemMacros.s"
;   #READCART $02
;   #SETBANK PP_CONFIG_ALL_RAM
;
; Created: 2025-12-27 (Sprint 1)
; Category: Tier 1 (Sacred - Globally Consistent)
;===============================================

;-----------------------------------------------
; READCART - Read from cartridge bank and store
;-----------------------------------------------
; Reads byte from cartridge bank and stores to memory.
; This is the most common pattern in the codebase (422 occurrences).
;
; ARCHITECTURAL CONTRACT:
;   - Single atomic operation (LDA + STA)
;   - Always reads from CARTRIDGE_BANK_VALUE
;   - Immediate store to specified address
;
; Parameters:
;   \1 = Target address (absolute or zero page)
;
; Registers affected: A
; Flags affected: N, Z
; Bytes: 5 (LDA abs = 3, STA abs = 3; or LDA abs = 3, STA zp = 2)
;
; Example:
;   #READCART $02      ; Store to zero page $02
;   #READCART $C000    ; Store to absolute address $C000
;   #READCART MYVAR    ; Store to labeled address
;
; Replaces:
;   LDA CARTRIDGE_BANK_VALUE
;   STA \1
;-----------------------------------------------
READCART .macro
	LDA CARTRIDGE_BANK_VALUE
	STA \1
	.endm

;-----------------------------------------------
; READCART_MODULATED - Modulated cartridge read
;-----------------------------------------------
; Performs modulated cartridge read sequence.
; Required in timing-critical or hardware-synchronized contexts
; where the modulation address must be accessed first.
;
; ARCHITECTURAL CONTRACT:
;   - Modulation address read establishes timing
;   - Followed by cartridge bank read
;   - Completes with immediate store
;
; Parameters:
;   \1 = Target address
;
; Registers affected: A
; Flags affected: N, Z
; Bytes: 8 (LDA abs = 3, LDA abs = 3, STA abs = 3; or 7 for zp store)
;
; Example:
;   #READCART_MODULATED $02
;   #READCART_MODULATED BUFFER, X    ; Indexed addressing
;
; Replaces:
;   LDA MODULATION_ADDRESS
;   LDA CARTRIDGE_BANK_VALUE
;   STA \1
;
; Common usage: CvdPlayer NMI handler (411 occurrences)
;-----------------------------------------------
READCART_MODULATED .macro
	LDA MODULATION_ADDRESS
	LDA CARTRIDGE_BANK_VALUE
	STA \1
	.endm

;-----------------------------------------------
; SETBANK - Set processor port memory configuration
;-----------------------------------------------
; Configures C64 memory banking via processor port ($01).
; Controls visibility of RAM, ROM (BASIC/KERNAL), and I/O.
;
; ARCHITECTURAL CONTRACT:
;   - Uses only predefined configuration constants
;   - Immediate mode only (no computed values)
;   - Affects global memory map
;
; Parameters:
;   \1 = Configuration value (must be constant):
;        PP_CONFIG_ALL_RAM      ($34) - All RAM, no ROM/IO
;        PP_CONFIG_RAM_ON_ROM   ($35) - RAM + I/O visible
;        PP_CONFIG_RAM_ON_BASIC ($36) - RAM + I/O + KERNAL
;        PP_CONFIG_DEFAULT      ($37) - BASIC + KERNAL + I/O (default)
;
; Registers affected: A
; Flags affected: N, Z
; Bytes: 4 (LDA imm = 2, STA zp = 2)
;
; Example:
;   #SETBANK PP_CONFIG_ALL_RAM      ; Max RAM access
;   #SETBANK PP_CONFIG_DEFAULT      ; Restore default
;
; Replaces:
;   LDA #\1
;   STA PROCESSOR_PORT
;
; Warning: Changing bank configuration affects interrupt handlers!
;          Always restore original configuration when done.
;-----------------------------------------------
SETBANK .macro
	LDA #\1
	STA PROCESSOR_PORT
	.endm

;-----------------------------------------------
; SAVEREGS - Save all CPU registers to stack
;-----------------------------------------------
; Preserves A, X, Y registers in correct order for restoration.
; MUST be paired with RESTOREREGS.
;
; ARCHITECTURAL CONTRACT:
;   - Stack order: A, X, Y (push order)
;   - Always paired with RESTOREREGS
;   - No intervening stack operations allowed
;
; Stack usage: +3 bytes
; Registers affected: None (all preserved on stack)
; Flags affected: None preserved (use PHP/PLP if needed)
; Bytes: 5 (PHA=1, TXA=1, PHA=1, TYA=1, PHA=1)
;
; Example:
;   #SAVEREGS
;   ; ... your code that modifies A, X, Y ...
;   #RESTOREREGS
;
; Replaces:
;   PHA
;   TXA
;   PHA
;   TYA
;   PHA
;
; Common usage: IRQ handlers, subroutines that must preserve state
; Frequency: 152 save/restore pairs in codebase
;-----------------------------------------------
SAVEREGS .macro
	PHA
	TXA
	PHA
	TYA
	PHA
	.endm

;-----------------------------------------------
; RESTOREREGS - Restore all CPU registers from stack
;-----------------------------------------------
; Restores A, X, Y registers in correct order.
; MUST be paired with SAVEREGS.
;
; ARCHITECTURAL CONTRACT:
;   - Stack order: Y, X, A (pop order - reverse of push)
;   - Always paired with SAVEREGS
;   - Pops exactly 3 bytes
;
; Stack usage: -3 bytes (pops what SAVEREGS pushed)
; Registers affected: A, X, Y (restored to saved values)
; Flags affected: N, Z from final PLA
; Bytes: 5 (PLA=1, TAY=1, PLA=1, TAX=1, PLA=1)
;
; Example:
;   #SAVEREGS
;   ; ... your code ...
;   #RESTOREREGS
;
; Replaces:
;   PLA
;   TAY
;   PLA
;   TAX
;   PLA
;
; Note: If you need flags preserved too, use:
;       PHP / #SAVEREGS / ... / #RESTOREREGS / PLP
;-----------------------------------------------
RESTOREREGS .macro
	PLA
	TAY
	PLA
	TAX
	PLA
	.endm

;-----------------------------------------------
; WAITFOR - Wait for status bit condition
;-----------------------------------------------
; Polls memory location until bit condition is met.
; Uses BIT instruction for non-destructive testing.
;
; ARCHITECTURAL CONTRACT:
;   - Uses BIT for flag testing (N, V, Z flags set)
;   - Infinite loop until condition met (NO TIMEOUT)
;   - Branch instruction determines exit condition
;
; Parameters:
;   \1 = Address to poll
;   \2 = Branch instruction (BEQ, BNE, BPL, BMI, BVC, BVS)
;
; Registers affected: A (contains final value of \1)
; Flags affected: N, Z, V (from BIT instruction)
; Bytes: Variable (typically 6-7 bytes)
;
; Example:
;   #WAITFOR CARTRIDGE_BANK_VALUE, BEQ  ; Wait until zero
;   #WAITFOR $D012, BNE                 ; Wait until raster != current
;   #WAITFOR STATUS_REG, BPL            ; Wait until bit 7 clear
;
; Replaces:
;   -
;       BIT \1
;       \2 -
;
; Warning: This creates an INFINITE LOOP if condition never met!
;          Use only when condition is guaranteed to occur.
;
; Advanced usage with custom labels:
;   MYLABEL #WAITFOR $D012, BNE
;   ; Now you can JMP MYLABEL to re-wait
;-----------------------------------------------
WAITFOR .macro
-
	BIT \1
	\2 -
	.endm

;-----------------------------------------------
; WAIT_TRANSFER_DONE - Spin until NMI DMA transfer completes
;-----------------------------------------------
; Polls ZP_IRQ_STATE_WAITHANDLE bit 6, which the NMI receive handler sets
; (via ORA #$40) once all expected bytes have been delivered to RAM.
; Uses BIT so the accumulator is preserved across the wait.
;
; PRECONDITION: CLV must be called before this macro so the loop is entered
;               on the first iteration (V starts clear).
;
; Registers affected: N, V, Z flags (from BIT); A unchanged
; Replaces the opaque: CLV / #WAITFOR ZP_IRQ_STATE_WAITHANDLE, BVC
;-----------------------------------------------
WAIT_TRANSFER_DONE .macro
-
	BIT ZP_IRQ_STATE_WAITHANDLE   ; V = bit 6: 0=still receiving, 1=all done
	BVC -                         ; loop while transfer incomplete
	.endm

;-----------------------------------------------
; WAITVALUE - Wait for specific value (alternative)
;-----------------------------------------------
; Polls memory location until it equals specific value.
; More convenient than WAITFOR for equality checks.
;
; ARCHITECTURAL CONTRACT:
;   - Uses LDA for value comparison
;   - Sets all flags (N, Z) from comparison
;   - Infinite loop until match
;
; Parameters:
;   \1 = Address to poll
;   \2 = Expected value
;
; Registers affected: A (contains final value)
; Flags affected: N, Z
; Bytes: ~8 (LDA abs = 3, CMP imm = 2, BNE rel = 2)
;
; Example:
;   #WAITVALUE CARTRIDGE_BANK_VALUE, $00    ; Wait for zero
;   #WAITVALUE $D012, $FF                   ; Wait for raster line $FF
;
; Replaces:
;   -
;       LDA \1
;       CMP #\2
;       BNE -
;
; Note: Use WAITFOR with BEQ for zero tests (shorter code)
;-----------------------------------------------
WAITVALUE .macro
-
	LDA \1
	CMP #\2
	BNE -
	.endm

; NOTE: SETADDR is defined in APIMacros.s (Tier 2). Not redefined here to avoid
;       duplicate errors when both SystemMacros.s and APIMacros.s are in scope.

;-----------------------------------------------
; COUNTLOOP - Register-based countdown loop
;-----------------------------------------------
; Creates a countdown loop using X register.
; Executes loop body exactly N times.
;
; ARCHITECTURAL CONTRACT:
;   - X register is the loop counter
;   - Counts down from N to 1 (N iterations)
;   - Loop body must preserve X or increment/decrement correctly
;
; Parameters:
;   \1 = Loop count (immediate value or label)
;
; Registers affected: X (destroyed, ends at 0)
; Flags affected: N, Z (from DEX)
; Bytes: Variable depending on loop body
;
; Example:
;   #COUNTLOOP #$10
;       NOP             ; Loop body - executes 16 times
;       NOP
;   #ENDLOOP
;
;   #COUNTLOOP FRAME_COUNT
;       JSR DELAY
;   #ENDLOOP
;
; Replaces:
;   LDX #\1
;   -
;       ; loop body
;       DEX
;       BNE -
;
; Note: Loop body code is placed BETWEEN #COUNTLOOP and #ENDLOOP
; Warning: Loop body must NOT modify X register!
;-----------------------------------------------
COUNTLOOP .macro
	LDX \1
-
	.endm

;-----------------------------------------------
; ENDLOOP - End of COUNTLOOP block
;-----------------------------------------------
; Terminates a COUNTLOOP block.
; MUST be paired with COUNTLOOP.
;
; Example:
;   #COUNTLOOP #8
;       LDA (ZP_PTR),Y
;       STA BUFFER,Y
;       INY
;   #ENDLOOP
;
; Generates:
;   DEX
;   BNE -
;-----------------------------------------------
ENDLOOP .macro
	DEX
	BNE -
	.endm

;===============================================
; End of SystemMacros.s
;===============================================
; Next tier: Memory & API Macros (Sprint 2)
;===============================================
