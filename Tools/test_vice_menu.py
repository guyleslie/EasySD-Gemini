#!/usr/bin/env python3
"""
EasySD - VICE Automated Menu Test Suite

Tests C64 menu behavior via VICE's binary monitor protocol (TCP).
Builds debug-vice, launches x64sc in warp mode, and verifies menu
navigation by reading C64 memory and feeding keystrokes.

Architecture:
  ViceBinaryMonitor  — TCP client for VICE 3.9 binary monitor protocol
  ViceSymbols        — Parses 64tass --vice-labels output (.vs file)
  ViceProcess        — Launches/stops VICE (x64sc.exe)
  ViceMenuTester     — Test orchestrator with 9 test cases

Key injection uses direct C64 keyboard buffer writes ($0277/$C6)
instead of VICE's keyboard_feed command, which is unreliable when
the emulator is in stopped state.

Usage:
    python Tools/test_vice_menu.py                    # Run all tests
    python Tools/test_vice_menu.py --build            # Build first, then test
    python Tools/test_vice_menu.py --verbose          # Verbose output
    python Tools/test_vice_menu.py --keep-vice        # Don't close VICE after
    python Tools/test_vice_menu.py --vice-path <path> # Custom VICE location
    python Tools/test_vice_menu.py --port 6510        # Custom monitor port
"""

import atexit
import os
import re
import socket
import struct
import subprocess
import sys
import time
import argparse
from pathlib import Path

# ANSI colors
GREEN = '\033[92m'
RED = '\033[91m'
YELLOW = '\033[93m'
BLUE = '\033[94m'
CYAN = '\033[96m'
BOLD = '\033[1m'
RESET = '\033[0m'

# Default VICE path on this system
DEFAULT_VICE_PATH = r"E:\Apps\GTK3VICE-3.9-win64\bin\x64sc.exe"
DEFAULT_PORT = 6502

# Build paths (relative to repo root)
REPO_ROOT = Path(__file__).resolve().parent.parent
BUILD_DIR = REPO_ROOT / "IRQHack64" / "build"
PRG_PATH = BUILD_DIR / "irqhack64-debug.prg"
LABELS_PATH = BUILD_DIR / "symbol" / "IrqLoaderMenuNew.vs"

# C64 KERNAL keyboard buffer addresses
C64_KEYBUF = 0x0277      # Keyboard buffer (10 bytes)
C64_KEYBUF_LEN = 0x00C6  # Number of chars in keyboard buffer

# C64 hardware registers
C64_BORDER = 0xD020       # Border color register


# ============================================================================
# ViceSymbols — parse 64tass --vice-labels output
# ============================================================================

class ViceSymbols:
    """Parses VICE-format label file (al [C:]xxxx .LABEL_NAME)."""

    def __init__(self, path: Path):
        self.symbols: dict[str, int] = {}
        self._parse(path)

    def _parse(self, path: Path):
        # Handles "al C:xxxx .NAME", "al xxxx .NAME", and "al xxx .NAME" formats
        pattern = re.compile(r'^al\s+(?:C:)?([0-9a-fA-F]{1,6})\s+\.(\S+)')
        with open(path, 'r') as f:
            for line in f:
                m = pattern.match(line.strip())
                if m:
                    addr = int(m.group(1), 16)
                    name = m.group(2)
                    self.symbols[name] = addr

    def get(self, name: str) -> int | None:
        return self.symbols.get(name)

    def require(self, *names: str) -> dict[str, int]:
        """Return dict of name->addr, raising if any are missing."""
        result = {}
        missing = []
        for name in names:
            addr = self.symbols.get(name)
            if addr is None:
                missing.append(name)
            else:
                result[name] = addr
        if missing:
            raise KeyError(f"Missing required symbols: {', '.join(missing)}")
        return result

    def __len__(self):
        return len(self.symbols)


# ============================================================================
# ViceBinaryMonitor — VICE 3.9 binary monitor TCP protocol
# ============================================================================

class ViceBinaryMonitor:
    """TCP client for VICE binary monitor protocol.

    Wire format (VICE 3.9, API version 0x02):
      Request:  STX(0x02) + api_ver(0x02) + body_len:u32le + req_id:u32le + cmd:u8 + body
      Response: STX(0x02) + api_ver(0x02) + body_len:u32le + resp_type:u8 + err:u8 + req_id:u32le + body

    Commands used:
      0x01 = memory_get
      0x02 = memory_set
      0x72 = keyboard_feed
      0x81 = ping
      0xAA = exit (resume)
      0xBB = quit
    """

    STX = 0x02
    API_VERSION = 0x02
    # Response header: STX(1) + api_ver(1) + body_len(4) + resp_type(1) + err(1) + req_id(4) = 12 bytes
    RESP_HEADER_SIZE = 12
    # Commands
    CMD_MEMORY_GET = 0x01
    CMD_MEMORY_SET = 0x02
    CMD_KEYBOARD_FEED = 0x72
    CMD_PING = 0x81
    CMD_EXIT = 0xAA
    CMD_QUIT = 0xBB

    def __init__(self, host: str = "127.0.0.1", port: int = DEFAULT_PORT,
                 timeout: float = 5.0, verbose: bool = False):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.verbose = verbose
        self.sock: socket.socket | None = None
        self._req_id = 0

    def connect(self, retries: int = 20, delay: float = 0.5) -> bool:
        """Connect to VICE binary monitor with retries."""
        for attempt in range(retries):
            try:
                self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self.sock.settimeout(self.timeout)
                self.sock.connect((self.host, self.port))
                # VICE may send events on connect — drain them
                self._drain_initial()
                if self.verbose:
                    print(f"  {CYAN}[MON]{RESET} Connected to {self.host}:{self.port}")
                return True
            except (ConnectionRefusedError, OSError):
                if self.sock:
                    self.sock.close()
                    self.sock = None
                if attempt < retries - 1:
                    time.sleep(delay)
        return False

    def _drain_initial(self):
        """Read and discard any data VICE sends on initial connect."""
        time.sleep(0.3)
        self.sock.setblocking(False)
        try:
            while True:
                data = self.sock.recv(4096)
                if not data:
                    break
                if self.verbose:
                    print(f"  {CYAN}[MON] drained {len(data)}B{RESET}")
        except BlockingIOError:
            pass
        finally:
            self.sock.setblocking(True)
            self.sock.settimeout(self.timeout)

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    def _next_id(self) -> int:
        self._req_id += 1
        return self._req_id

    def _send_request(self, command: int, body: bytes = b"") -> int:
        """Send a binary monitor request. Returns the request ID."""
        req_id = self._next_id()
        body_len = len(body)
        header = struct.pack("<BBIIB", self.STX, self.API_VERSION,
                             body_len, req_id, command)
        packet = header + body
        if self.verbose:
            print(f"  {CYAN}[MON] >> cmd=0x{command:02X} id={req_id} "
                  f"body={len(body)}B{RESET}")
        self.sock.sendall(packet)
        return req_id

    def _recv_response(self, expected_id: int | None = None) -> tuple[int, int, bytes]:
        """Receive a binary monitor response.
        Returns (response_type, error_code, body).
        Skips unsolicited responses (events) until we get our expected_id.
        """
        while True:
            header = self._recv_exact(self.RESP_HEADER_SIZE)
            stx = header[0]
            if stx != self.STX:
                raise ConnectionError(f"Bad STX: 0x{stx:02X}")
            body_length = struct.unpack_from("<I", header, 2)[0]
            resp_type = header[6]
            error_code = header[7]
            resp_id = struct.unpack_from("<I", header, 8)[0]

            body = self._recv_exact(body_length) if body_length > 0 else b""

            if self.verbose:
                print(f"  {CYAN}[MON] << type=0x{resp_type:02X} err={error_code} "
                      f"id={resp_id} body={len(body)}B{RESET}")

            if expected_id is not None and resp_id != expected_id:
                continue
            return resp_type, error_code, body

    def _recv_exact(self, n: int) -> bytes:
        """Receive exactly n bytes."""
        data = bytearray()
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("Connection closed")
            data.extend(chunk)
        return bytes(data)

    def ping(self) -> bool:
        """Send ping, verify response."""
        try:
            req_id = self._send_request(self.CMD_PING)
            _, error_code, _ = self._recv_response(req_id)
            return error_code == 0
        except (OSError, ConnectionError):
            return False

    def memory_get(self, start: int, end: int, memspace: int = 0,
                   bank_id: int = 0, side_effects: bool = False) -> bytes:
        """Read C64 memory. Returns raw bytes.
        Body: side_effects(1) + start(2) + end(2) + memspace(1) + bank_id(2)"""
        se = 1 if side_effects else 0
        body = struct.pack("<BHHBH", se, start, end, memspace, bank_id)
        req_id = self._send_request(self.CMD_MEMORY_GET, body)
        _, error_code, resp_body = self._recv_response(req_id)
        if error_code != 0:
            raise RuntimeError(f"memory_get error: {error_code}")
        # Response body: length:u16le + data
        if len(resp_body) >= 2:
            data_len = struct.unpack_from("<H", resp_body, 0)[0]
            return resp_body[2:2 + data_len]
        return resp_body

    def memory_set(self, start: int, data: bytes, memspace: int = 0,
                   bank_id: int = 0, side_effects: bool = False) -> bool:
        """Write bytes to C64 memory.
        Body: side_effects(1) + start(2) + end(2) + memspace(1) + bank_id(2) + data"""
        se = 1 if side_effects else 0
        end = start + len(data) - 1
        body = struct.pack("<BHHBH", se, start, end, memspace, bank_id) + data
        req_id = self._send_request(self.CMD_MEMORY_SET, body)
        _, error_code, _ = self._recv_response(req_id)
        return error_code == 0

    def read_byte(self, addr: int) -> int:
        """Read a single byte from C64 memory."""
        data = self.memory_get(addr, addr)
        return data[0]

    def read_word(self, addr: int) -> int:
        """Read a 16-bit word (little-endian) from C64 memory."""
        data = self.memory_get(addr, addr + 1)
        return data[0] | (data[1] << 8)

    def write_byte(self, addr: int, value: int) -> bool:
        """Write a single byte to C64 memory."""
        return self.memory_set(addr, bytes([value & 0xFF]))

    def keyboard_feed(self, text: str) -> bool:
        """Feed text into VICE keyboard buffer (unreliable in stopped state)."""
        encoded = text.encode('ascii')
        body = struct.pack("<B", len(encoded)) + encoded
        req_id = self._send_request(self.CMD_KEYBOARD_FEED, body)
        _, error_code, _ = self._recv_response(req_id)
        return error_code == 0

    def exit_monitor(self) -> bool:
        """Resume emulation (exit monitor/break state)."""
        try:
            req_id = self._send_request(self.CMD_EXIT)
            _, error_code, _ = self._recv_response(req_id)
            return error_code == 0
        except (OSError, ConnectionError):
            return False

    def quit_vice(self) -> bool:
        """Tell VICE to quit."""
        try:
            self._send_request(self.CMD_QUIT)
            return True
        except (OSError, ConnectionError):
            return False


# ============================================================================
# ViceProcess — launch/stop VICE
# ============================================================================

class ViceProcess:
    """Manages VICE x64sc process lifecycle."""

    def __init__(self, vice_path: str, port: int = DEFAULT_PORT,
                 verbose: bool = False):
        self.vice_path = vice_path
        self.port = port
        self.verbose = verbose
        self.proc: subprocess.Popen | None = None

    def start(self, prg_path: Path, labels_path: Path | None = None) -> bool:
        """Launch VICE with binary monitor enabled."""
        if not Path(self.vice_path).exists():
            print(f"{RED}[ERR]{RESET} VICE not found: {self.vice_path}")
            return False

        cmd = [
            self.vice_path,
            "-binarymonitor",
            "-binarymonitoraddress", f"ip4://127.0.0.1:{self.port}",
            "+sound",
            "-warp",
            "-autostart", str(prg_path),
        ]

        if self.verbose:
            print(f"  {CYAN}[VICE]{RESET} {' '.join(cmd)}")

        kwargs = {
            "stdout": subprocess.DEVNULL,
            "stderr": subprocess.DEVNULL,
        }
        if os.name == "nt":
            kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP

        self.proc = subprocess.Popen(cmd, **kwargs)
        atexit.register(self._cleanup)

        if self.verbose:
            print(f"  {CYAN}[VICE]{RESET} PID {self.proc.pid}")
        return True

    def is_running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def stop(self):
        """Terminate VICE process."""
        if self.proc:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=5)
            except (subprocess.TimeoutExpired, OSError):
                try:
                    self.proc.kill()
                except OSError:
                    pass
            self.proc = None

    def _cleanup(self):
        """atexit handler for crash safety."""
        self.stop()


# ============================================================================
# ViceMenuTester — test orchestrator
# ============================================================================

class ViceMenuTester:
    """Runs automated tests against the C64 menu in VICE."""

    def __init__(self, vice_path: str, port: int = DEFAULT_PORT,
                 verbose: bool = False, keep_vice: bool = False):
        self.vice_path = vice_path
        self.port = port
        self.verbose = verbose
        self.keep_vice = keep_vice
        self.mon: ViceBinaryMonitor | None = None
        self.vice: ViceProcess | None = None
        self.sym: ViceSymbols | None = None

    def setup(self) -> bool:
        """Launch VICE, connect monitor, load symbols."""
        if not PRG_PATH.exists():
            print(f"{RED}[ERR]{RESET} PRG not found: {PRG_PATH}")
            print(f"       Run: python Tools/build.py debug-vice")
            return False

        if not LABELS_PATH.exists():
            print(f"{RED}[ERR]{RESET} Labels file not found: {LABELS_PATH}")
            print(f"       Run: python Tools/build.py debug-vice")
            return False

        self.sym = ViceSymbols(LABELS_PATH)
        if self.verbose:
            print(f"  {CYAN}[SYM]{RESET} Loaded {len(self.sym)} symbols from {LABELS_PATH.name}")

        try:
            self.sym.require("CURRENTROW", "CURPAGEITEMS", "DIRLEVEL")
        except KeyError as e:
            print(f"{RED}[ERR]{RESET} {e}")
            return False

        # Launch VICE
        print(f"{BLUE}[INIT]{RESET} Launching VICE...")
        self.vice = ViceProcess(self.vice_path, self.port, self.verbose)
        if not self.vice.start(PRG_PATH):
            return False

        # Connect binary monitor
        print(f"{BLUE}[INIT]{RESET} Connecting to binary monitor on port {self.port}...")
        self.mon = ViceBinaryMonitor("127.0.0.1", self.port,
                                     verbose=self.verbose)
        if not self.mon.connect():
            print(f"{RED}[ERR]{RESET} Could not connect to VICE monitor")
            self.vice.stop()
            return False

        if not self.mon.ping():
            print(f"{RED}[ERR]{RESET} VICE monitor ping failed")
            self.teardown()
            return False

        self.mon.exit_monitor()
        print(f"{GREEN}[OK]{RESET} VICE running, monitor connected\n")

        # Wait for C64 menu to fully load.
        # Poll CURPAGEITEMS until non-zero (menu has drawn initial directory).
        print(f"{BLUE}[INIT]{RESET} Waiting for C64 menu to load...")
        curpage_addr = self.sym.get("CURPAGEITEMS")
        deadline = time.time() + 30.0
        while time.time() < deadline:
            self.mon.exit_monitor()
            time.sleep(1.0)
            try:
                val = self.mon.read_byte(curpage_addr)
                if val != 0 and val != 0xFF:
                    if self.verbose:
                        print(f"  {CYAN}[INIT]{RESET} CURPAGEITEMS={val}, menu ready")
                    # Let the menu finish rendering fully
                    self.mon.exit_monitor()
                    time.sleep(1.0)
                    break
            except Exception:
                pass
        else:
            print(f"{RED}[ERR]{RESET} Timeout waiting for menu to load")
            self.teardown()
            return False
        return True

    def teardown(self):
        """Clean up VICE and monitor."""
        if self.mon:
            if self.keep_vice:
                # Resume emulation so user can interact with VICE
                self.mon.exit_monitor()
                self.mon.close()
            else:
                self.mon.quit_vice()
                time.sleep(0.5)
                self.mon.close()
        if self.vice and not self.keep_vice:
            self.vice.stop()

    # ==================================================================
    # Key injection — direct C64 keyboard buffer write
    # ==================================================================

    def _inject_key(self, petscii_code: int):
        """Write a key directly into the C64 KERNAL keyboard buffer.

        This is more reliable than VICE's keyboard_feed command because
        it works regardless of VICE's stopped/running state.

        The C64 KERNAL GETIN ($FFE4) reads from:
          $0277-$0280 = keyboard buffer (10 bytes)
          $00C6       = number of characters in buffer
        """
        self.mon.write_byte(C64_KEYBUF, petscii_code)
        self.mon.write_byte(C64_KEYBUF_LEN, 1)

    def _press_key(self, petscii_code: int, settle: float = 0.5):
        """Inject a key and let the C64 process it.

        1. Write key to C64 keyboard buffer (while VICE is stopped)
        2. Resume emulation
        3. Wait for C64 to process the keystroke
        """
        self._inject_key(petscii_code)
        self.mon.exit_monitor()
        time.sleep(settle)

    def _wait_for_value(self, sym_name: str, expected: int,
                        timeout: float = 5.0, poll_interval: float = 0.3) -> bool:
        """Poll a symbol's value until it matches expected, with resume cycles.

        After each memory_get (which stops VICE), we resume emulation
        and wait before polling again. Returns True if the value was reached.
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            val = self._read_sym_byte(sym_name)
            if val == expected:
                return True
            if self.verbose:
                print(f"  {CYAN}[POLL]{RESET} {sym_name}={val}, waiting for {expected}")
            self.mon.exit_monitor()
            time.sleep(poll_interval)
        return False

    def _read_sym_byte(self, name: str) -> int:
        """Read a byte from a symbol's address."""
        addr = self.sym.get(name)
        if addr is None:
            raise KeyError(f"Symbol not found: {name}")
        return self.mon.read_byte(addr)

    def _navigate_to_row(self, target_row: int, max_presses: int = 20) -> bool:
        """Navigate cursor to target row using UP key presses.

        Returns True if target row reached. Each UP press:
        1. Read current row (VICE stops)
        2. If at target, done
        3. Inject UP key + resume + wait
        """
        for _ in range(max_presses):
            row = self._read_sym_byte("CURRENTROW")
            if row == target_row:
                return True
            self._press_key(0x2B, settle=0.3)  # '+' = UP
        row = self._read_sym_byte("CURRENTROW")
        return row == target_row

    def _read_pathbuffer(self) -> str:
        """Read null-terminated string from PATHBUFFER ($033C), max 96 bytes."""
        data = self.mon.memory_get(0x033C, 0x033C + 95)
        result = []
        for b in data:
            if b == 0:
                break
            result.append(chr(b))
        return ''.join(result)

    # ==================================================================
    # Test cases
    # ==================================================================

    def test_init(self) -> bool:
        """Test 1: Verify initial state after menu loads."""
        curpage = self._read_sym_byte("CURPAGEITEMS")
        currow = self._read_sym_byte("CURRENTROW")
        dirlevel = self._read_sym_byte("DIRLEVEL")
        border = self.mon.read_byte(C64_BORDER)

        ok = curpage == 5 and currow == 0 and dirlevel == 0
        if self.verbose or not ok:
            print(f"  CURPAGEITEMS={curpage} (exp 5), "
                  f"CURRENTROW={currow} (exp 0), "
                  f"DIRLEVEL={dirlevel} (exp 0), "
                  f"BORDER=${border:02X}")
        return ok

    def test_nav_down(self) -> bool:
        """Test 2: Press DOWN (-), CURRENTROW should increment."""
        before = self._read_sym_byte("CURRENTROW")
        self._press_key(0x2D)  # '-' = DOWN
        after = self._read_sym_byte("CURRENTROW")

        ok = after == before + 1
        if self.verbose or not ok:
            print(f"  CURRENTROW: {before} -> {after} (exp {before + 1})")
        return ok

    def test_nav_up(self) -> bool:
        """Test 3: Press UP (+), CURRENTROW should decrement."""
        before = self._read_sym_byte("CURRENTROW")
        self._press_key(0x2B)  # '+' = UP
        after = self._read_sym_byte("CURRENTROW")

        ok = after == before - 1
        if self.verbose or not ok:
            print(f"  CURRENTROW: {before} -> {after} (exp {before - 1})")
        return ok

    def test_nav_wrap(self) -> bool:
        """Test 4: Cursor wraps at list boundaries."""
        # Navigate to row 0
        if not self._navigate_to_row(0):
            if self.verbose:
                print(f"  Could not reach row 0")
            return False

        # Press UP at row 0 — should wrap to bottom (CURPAGEITEMS - 1)
        self._press_key(0x2B)  # '+' = UP
        row = self._read_sym_byte("CURRENTROW")
        curpage = self._read_sym_byte("CURPAGEITEMS")
        expected = curpage - 1

        ok = row == expected
        if self.verbose or not ok:
            print(f"  Wrap UP at 0: CURRENTROW={row} (exp {expected})")
        return ok

    def test_enter_dir(self) -> bool:
        """Test 5: Enter 'games' dir (row 0), DIRLEVEL->1, CURPAGEITEMS->6."""
        # Navigate to row 0 ("games" directory)
        if not self._navigate_to_row(0):
            if self.verbose:
                print(f"  Could not reach row 0")
            return False

        # Read state before
        border_before = self.mon.read_byte(C64_BORDER)
        dirlevel_before = self._read_sym_byte("DIRLEVEL")

        if self.verbose:
            print(f"  Before: DIRLEVEL={dirlevel_before}, BORDER=${border_before:02X}")

        # Press ENTER to enter directory
        self._press_key(0x0D, settle=0.3)

        # Poll until DIRLEVEL changes (directory entry completed)
        if not self._wait_for_value("DIRLEVEL", 1, timeout=5.0):
            dirlevel = self._read_sym_byte("DIRLEVEL")
            curpage = self._read_sym_byte("CURPAGEITEMS")
            print(f"  DIRLEVEL={dirlevel} (exp 1), CURPAGEITEMS={curpage} (exp 6)")
            return False

        # Let the menu finish rendering after directory change
        self.mon.exit_monitor()
        time.sleep(0.5)

        dirlevel = self._read_sym_byte("DIRLEVEL")
        curpage = self._read_sym_byte("CURPAGEITEMS")
        border_after = self.mon.read_byte(C64_BORDER)

        ok = dirlevel == 1 and curpage == 6
        if self.verbose or not ok:
            print(f"  DIRLEVEL={dirlevel} (exp 1), CURPAGEITEMS={curpage} (exp 6), "
                  f"BORDER: ${border_before:02X}->${border_after:02X}")
        if ok and border_before == border_after:
            if self.verbose:
                print(f"  {YELLOW}[WARN]{RESET} BORDER unchanged (expected INC in NEWCONTENT)")
        return ok

    def test_go_back(self) -> bool:
        """Test 6: Select '..' in DIR2 (row 0), press Enter, DIRLEVEL->0."""
        # Navigate to row 0 (".." parent directory)
        if not self._navigate_to_row(0):
            if self.verbose:
                print(f"  Could not reach row 0")
            return False

        border_before = self.mon.read_byte(C64_BORDER)

        # Press ENTER on ".."
        self._press_key(0x0D, settle=0.3)

        # Poll until DIRLEVEL changes back to 0
        if not self._wait_for_value("DIRLEVEL", 0, timeout=5.0):
            dirlevel = self._read_sym_byte("DIRLEVEL")
            curpage = self._read_sym_byte("CURPAGEITEMS")
            print(f"  DIRLEVEL={dirlevel} (exp 0), CURPAGEITEMS={curpage} (exp 5)")
            return False

        self.mon.exit_monitor()
        time.sleep(0.5)

        dirlevel = self._read_sym_byte("DIRLEVEL")
        curpage = self._read_sym_byte("CURPAGEITEMS")
        border_after = self.mon.read_byte(C64_BORDER)

        ok = dirlevel == 0 and curpage == 5
        if self.verbose or not ok:
            print(f"  DIRLEVEL={dirlevel} (exp 0), CURPAGEITEMS={curpage} (exp 5), "
                  f"BORDER: ${border_before:02X}->${border_after:02X}")
        return ok

    def test_screen_verify(self) -> bool:
        """Test 7: Read screen RAM, verify 'games' is displayed.

        The menu uses PRINTASCIIFILENAME which converts:
          ASCII -> PETSCII (via FROMASCII) -> screen code (subtract $3F)
        For lowercase letters a-z ($61-$7A):
          FROMASCII: EOR #$20 -> uppercase ($41-$5A)
          Then: ORA #$80 -> $C1-$DA
          Screen code: $C1-$3F = ... no, let's trace exactly:

        Actually PRINTASCIIFILENAME calls FROMASCII then subtracts $3F.
        For 'g' ($67):
          FROMASCII: $67 >= $5B and < $7F -> EOR $20 -> $47
          Then in FILENAMEPRINT_A: $47 >= $3F -> SBC $3F (with CLC before SBC = -$40)
          $47 - $40 = $07

        So lowercase ASCII letters map to screen codes 1-26, same as
        PETSCII uppercase screen codes. "games" = [7, 1, 13, 5, 19].
        """
        # COLS[1] = $0454 (first file entry row, after header at COLS[0]=$042C)
        # But SETCURRENTROW adds +2 to COLS index, and the arrow character
        # is at the COLLOW-1 position (SETCURRENTROWHEAD subtracts 1).
        # The filename starts at the COLLOW position (offset 0 in PRINTASCIIFILENAME).
        # SETCURRENTROW for row 0: COLS+2 = COLS[1] = $0454
        # SETCURRENTROWHEAD: $0454 - 1 - 1 = $0452 (SBC #01 with CLC = subtract 2)
        # Filename is printed at (COLLOW),Y starting Y=0
        # So filename starts at $0452? No...
        #
        # Let me re-read SETCURRENTROWHEAD:
        #   STX CURRENTROW
        #   TXA; ASL; TAX
        #   LDA COLS+2,X   ; for row 0: COLS+2 = low byte of $0454 = $54
        #   CLC; SBC #01   ; CLC + SBC = subtract 2: $54 - 2 = $52
        #   STA COLLOW
        #   INX
        #   LDA COLS+2,X   ; high byte = $04
        #   STA COLHIGH
        # So COLLOW/HIGH = $0452
        #
        # But PRINTPAGE calls SETCURRENTROW (not SETCURRENTROWHEAD):
        #   LDA COLS+2,X   ; $54
        #   STA COLLOW     ; no subtraction
        # So filenames are printed at $0454 for row 0.
        #
        # The arrow is placed via SETCURRENTROWHEAD ($0452) at offset 0.
        # So arrow is at $0452, and filename at $0454 (2 bytes after arrow).
        #
        # Actually wait: SETCURRENTROWHEAD does CLC; SBC #01
        # CLC clears carry, then SBC subtracts (1 + !carry) = (1 + 1) = 2
        # No: SBC with carry clear subtracts (operand + 1) = (1 + 1) = 2
        # So COLLOW = $54 - 2 = $52, COLHIGH = $04
        # Arrow at ($0452),Y=0 = $0452
        #
        # Then after arrow, the main loop goes back and for PRINTPAGE:
        # SETCURRENTROW: COLLOW = $54 (no subtraction), PRINTASCIIFILENAME at ($0454),Y=0
        #
        # So: "games" screen codes start at $0454.

        expected = [7, 1, 13, 5, 19]  # g=7, a=1, m=13, e=5, s=19
        data = self.mon.memory_get(0x0454, 0x0454 + len(expected) - 1)
        actual = list(data)

        ok = actual == expected
        if self.verbose or not ok:
            # Also show what characters we think they are
            chars = ''.join(chr(c + 0x60) if 1 <= c <= 26 else '?' for c in actual)
            print(f"  Screen @ $0454: {actual} (exp {expected}) = \"{chars}\"")
        return ok

    def test_prg_select_root(self) -> bool:
        """Test 8: Select PRG in root, verify PATHBUFFER and mock execution."""
        # Navigate to row 1 ("giana.prg" in root)
        if not self._navigate_to_row(1):
            if self.verbose:
                print(f"  Could not reach row 1")
            return False

        # Clear sentinels ($CF50-$CF52)
        self.mon.memory_set(0xCF50, bytes([0, 0, 0]))

        # Press ENTER to select PRG
        self._press_key(0x0D, settle=0.3)

        # Poll DEBUG_PRG_EXECUTED ($CF51) until $42 (mock PRG ran)
        deadline = time.time() + 5.0
        executed = False
        while time.time() < deadline:
            val = self.mon.read_byte(0xCF51)
            if val == 0x42:
                executed = True
                break
            self.mon.exit_monitor()
            time.sleep(0.3)

        if not executed:
            val = self.mon.read_byte(0xCF51)
            print(f"\n  DEBUG_PRG_EXECUTED=${val:02X} (exp $42) — mock PRG did not run")
            return False

        # Verify all sentinels and PATHBUFFER
        reached = self.mon.read_byte(0xCF50)
        sentinel = self.mon.read_byte(0xCF52)
        path = self._read_pathbuffer()

        ok = reached == 0x01 and sentinel == 0xDE and path == "/giana.prg"
        if self.verbose or not ok:
            print(f"  DEBUG_PRG_REACHED=${reached:02X} (exp $01), "
                  f"DEBUG_PRG_SENTINEL=${sentinel:02X} (exp $DE)")
            print(f"  PATHBUFFER=\"{path}\" (exp \"/giana.prg\")")

        # Verify menu returned (CURRENTROW is readable)
        self.mon.exit_monitor()
        time.sleep(0.5)
        try:
            row = self._read_sym_byte("CURRENTROW")
            if self.verbose:
                print(f"  Menu returned, CURRENTROW={row}")
        except Exception as e:
            print(f"\n  Menu did not return: {e}")
            return False

        return ok

    def test_prg_select_subdir(self) -> bool:
        """Test 9: Enter subdir, select PRG, verify absolute path in PATHBUFFER."""
        # Enter /games/ (press ENTER on row 0)
        if not self._navigate_to_row(0):
            if self.verbose:
                print(f"  Could not reach row 0")
            return False

        self._press_key(0x0D, settle=0.3)

        # Poll until DIRLEVEL == 1
        if not self._wait_for_value("DIRLEVEL", 1, timeout=5.0):
            dirlevel = self._read_sym_byte("DIRLEVEL")
            print(f"\n  Could not enter /games/ (DIRLEVEL={dirlevel})")
            return False

        self.mon.exit_monitor()
        time.sleep(0.5)

        # Navigate to row 3 ("bubble.prg")
        if not self._navigate_to_row(3):
            if self.verbose:
                print(f"  Could not reach row 3")
            return False

        # Clear sentinels ($CF50-$CF52)
        self.mon.memory_set(0xCF50, bytes([0, 0, 0]))

        # Press ENTER to select PRG
        self._press_key(0x0D, settle=0.3)

        # Poll DEBUG_PRG_EXECUTED ($CF51) until $42
        deadline = time.time() + 5.0
        executed = False
        while time.time() < deadline:
            val = self.mon.read_byte(0xCF51)
            if val == 0x42:
                executed = True
                break
            self.mon.exit_monitor()
            time.sleep(0.3)

        if not executed:
            val = self.mon.read_byte(0xCF51)
            print(f"\n  DEBUG_PRG_EXECUTED=${val:02X} (exp $42) — mock PRG did not run")
            return False

        # Verify sentinels and path
        reached = self.mon.read_byte(0xCF50)
        sentinel = self.mon.read_byte(0xCF52)
        path = self._read_pathbuffer()

        ok = reached == 0x01 and sentinel == 0xDE and path == "/games/bubble.prg"
        if self.verbose or not ok:
            print(f"  DEBUG_PRG_REACHED=${reached:02X} (exp $01), "
                  f"DEBUG_PRG_SENTINEL=${sentinel:02X} (exp $DE)")
            print(f"  PATHBUFFER=\"{path}\" (exp \"/games/bubble.prg\")")

        # Verify menu returned
        self.mon.exit_monitor()
        time.sleep(0.5)
        try:
            row = self._read_sym_byte("CURRENTROW")
            if self.verbose:
                print(f"  Menu returned, CURRENTROW={row}")
        except Exception as e:
            print(f"\n  Menu did not return: {e}")
            return False

        # Go back to root for cleanup
        if not self._navigate_to_row(0):
            if self.verbose:
                print(f"  {YELLOW}[WARN]{RESET} Could not reach row 0 for cleanup")
        else:
            self._press_key(0x0D, settle=0.3)
            if not self._wait_for_value("DIRLEVEL", 0, timeout=5.0):
                if self.verbose:
                    print(f"  {YELLOW}[WARN]{RESET} Could not return to root for cleanup")
            else:
                self.mon.exit_monitor()
                time.sleep(0.3)

        return ok

    # ==================================================================
    # Run all tests
    # ==================================================================

    def run_all(self) -> bool:
        """Execute all 9 test cases. Returns True if all pass."""
        tests = [
            ("INIT", self.test_init),
            ("NAV_DOWN", self.test_nav_down),
            ("NAV_UP", self.test_nav_up),
            ("NAV_WRAP", self.test_nav_wrap),
            ("ENTER_DIR", self.test_enter_dir),
            ("GO_BACK", self.test_go_back),
            ("SCREEN_VERIFY", self.test_screen_verify),
            ("PRG_SELECT_ROOT", self.test_prg_select_root),
            ("PRG_SELECT_SUBDIR", self.test_prg_select_subdir),
        ]

        print(f"{BOLD}{'=' * 60}{RESET}")
        print(f"{BOLD} EasySD VICE Menu Test Suite{RESET}")
        print(f"{BOLD}{'=' * 60}{RESET}\n")

        passed = 0
        failed = 0

        for i, (name, test_fn) in enumerate(tests, 1):
            print(f"{BLUE}[{i}/{len(tests)}]{RESET} {name}...", end=" ", flush=True)
            try:
                ok = test_fn()
            except Exception as e:
                ok = False
                print(f"\n  {RED}Exception: {e}{RESET}")

            if ok:
                print(f"{GREEN}PASS{RESET}")
                passed += 1
            else:
                print(f"{RED}FAIL{RESET}")
                failed += 1

        # Summary
        total = passed + failed
        print(f"\n{BOLD}{'=' * 60}{RESET}")
        if failed == 0 and passed > 0:
            print(f"{GREEN}{BOLD} ALL {passed} TESTS PASSED{RESET}")
        elif failed > 0:
            print(f"{RED}{BOLD} {failed} TESTS FAILED{RESET} out of {total}")
        else:
            print(f"{YELLOW} No test results{RESET}")
        print(f"{BOLD}{'=' * 60}{RESET}")

        return failed == 0 and passed > 0


# ============================================================================
# Build helper
# ============================================================================

def run_build():
    """Run debug-vice build."""
    print(f"{BLUE}[BUILD]{RESET} Running: python Tools/build.py debug-vice\n")
    result = subprocess.run(
        [sys.executable, str(REPO_ROOT / "Tools" / "build.py"), "debug-vice"],
        cwd=str(REPO_ROOT),
    )
    if result.returncode != 0:
        print(f"{RED}[ERR]{RESET} Build failed")
        return False
    print()
    return True


# ============================================================================
# Main
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="EasySD VICE Automated Menu Test Suite")
    parser.add_argument("--build", "-b", action="store_true",
                        help="Build debug-vice before testing")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Verbose output (monitor traffic, memory reads)")
    parser.add_argument("--keep-vice", "-k", action="store_true",
                        help="Keep VICE open after tests complete")
    parser.add_argument("--vice-path", default=DEFAULT_VICE_PATH,
                        help=f"Path to x64sc (default: {DEFAULT_VICE_PATH})")
    parser.add_argument("--port", "-p", type=int, default=DEFAULT_PORT,
                        help=f"Binary monitor port (default: {DEFAULT_PORT})")

    args = parser.parse_args()

    if args.build:
        if not run_build():
            sys.exit(1)

    tester = ViceMenuTester(
        vice_path=args.vice_path,
        port=args.port,
        verbose=args.verbose,
        keep_vice=args.keep_vice,
    )

    if not tester.setup():
        sys.exit(1)

    exit_code = 0
    try:
        if not tester.run_all():
            exit_code = 1
    except KeyboardInterrupt:
        print(f"\n{YELLOW}[ABORT]{RESET} Interrupted")
        exit_code = 1
    finally:
        tester.teardown()

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
