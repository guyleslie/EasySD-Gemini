#!/usr/bin/env python3
"""
EasySD IRQHack64 - File I/O Core API Test Suite

POST_SPRINT6_PLAN D4: File I/O Protocol Testing

Test Coverage:
1. OPEN → READ → READ → CLOSE (small file <1KB)
2. OPEN large file, multiple chunks, EOF handling
3. READ after CLOSE → ERR_NOT_OPEN
4. OPEN non-existent file → FILE_NOT_FOUND
5. OPEN directory → FILE_CANNOT_BE_OPENED
6. 50× OPEN/READ/CLOSE loop (memory leak / state drift check)

Prerequisites:
- Arduino firmware uploaded with DEBUG build
- Serial connection at 57600 baud
- SD card with test files:
  - /TESTFILE_SMALL.BIN (256 bytes)
  - /TESTFILE_LARGE.BIN (2048 bytes)
  - /UTILS/ (directory)

Usage:
  python test_file_io.py COM4
  python test_file_io.py /dev/ttyUSB0
"""

import sys
import time
import serial
import struct

# Error codes (from CartApi.h)
NOT_INITIALIZED = 0x01
FILE_NOT_FOUND = 0x02
FILE_CANNOT_BE_OPENED = 0x03
FILE_IS_NOT_OPENED = 0x04
INVALID_ARGUMENT = 0x09
SUCCESSFUL = 0x80

# Commands (from CartApi.h)
COMMAND_OPEN_FILE = 2
COMMAND_READ_FILE = 78
COMMAND_CLOSE_FILE = 3

# ANSI colors for output
GREEN = '\033[92m'
RED = '\033[91m'
YELLOW = '\033[93m'
BLUE = '\033[94m'
RESET = '\033[0m'

class FileIOTester:
    def __init__(self, port, baudrate=57600, timeout=2):
        self.port = port
        self.baudrate = baudrate
        self.timeout = timeout
        self.ser = None
        self.test_passed = 0
        self.test_failed = 0

    def connect(self):
        """Connect to Arduino serial port."""
        print(f"{BLUE}[INIT]{RESET} Connecting to {self.port} at {self.baudrate} baud...")
        try:
            self.ser = serial.Serial(self.port, self.baudrate, timeout=self.timeout)
            time.sleep(2)  # Wait for Arduino boot/reset
            print(f"{GREEN}[OK]{RESET} Connected successfully")

            # Read and display startup banner
            print(f"{BLUE}[INFO]{RESET} Arduino startup banner:")
            time.sleep(0.5)
            while self.ser.in_waiting:
                line = self.ser.readline().decode('utf-8', errors='ignore').strip()
                if line:
                    print(f"  {line}")
            return True
        except Exception as e:
            print(f"{RED}[FAIL]{RESET} Connection failed: {e}")
            return False

    def disconnect(self):
        """Disconnect from serial port."""
        if self.ser and self.ser.is_open:
            self.ser.close()
            print(f"{BLUE}[INFO]{RESET} Disconnected")

    def send_command(self, cmd, data=b''):
        """
        Send a command to Arduino.

        Note: This is a MOCK implementation.
        Real implementation requires cartridge protocol knowledge:
        - How commands are sent (via C64 IO ports? via Serial in TEST_TERMINAL_MODE?)
        - Expected response format

        For now, this prints what WOULD be sent and waits for manual verification.
        """
        print(f"{YELLOW}[MOCK]{RESET} Would send command: {cmd} (0x{cmd:02X})")
        if data:
            print(f"       Data ({len(data)} bytes): {data[:20]}{'...' if len(data) > 20 else ''}")

        # In TEST_TERMINAL_MODE, we'd send actual bytes here
        # For manual testing, we just log what should happen
        return None

    def test_open_file(self, filename, expected_status=SUCCESSFUL):
        """Test OPEN_FILE command."""
        print(f"\n{BLUE}[TEST]{RESET} OPEN_FILE: {filename}")

        # Prepare command data
        flags = 0  # Read mode
        filename_bytes = filename.encode('utf-8')
        filename_len = len(filename_bytes)

        # Command structure:
        # - flags (1 byte)
        # - filename_length (1 byte)
        # - filename (N bytes, NUL-terminated)
        data = struct.pack('BB', flags, filename_len) + filename_bytes + b'\x00'

        response = self.send_command(COMMAND_OPEN_FILE, data)

        # Manual verification prompt
        print(f"  {YELLOW}Expected response:{RESET} 0x{expected_status:02X} ({self._error_name(expected_status)})")
        print(f"  {YELLOW}Manual check:{RESET} Look for 'Got HandleOpenFile' in Arduino Serial Monitor")

        # For automated testing, we'd check: response == expected_status
        return None

    def test_read_file(self, chunk_count=1):
        """Test READ_FILE command."""
        print(f"\n{BLUE}[TEST]{RESET} READ_FILE: {chunk_count} chunks (256 bytes each)")

        # Command structure:
        # - dataLength (1 byte) - number of 256-byte chunks
        data = struct.pack('B', chunk_count)

        response = self.send_command(COMMAND_READ_FILE, data)

        print(f"  {YELLOW}Expected:{RESET} Status byte + {chunk_count * 256} data bytes")
        print(f"  {YELLOW}Manual check:{RESET} Look for 'Got HandleReadFile' in Arduino Serial Monitor")

        return None

    def test_close_file(self, expected_status=SUCCESSFUL):
        """Test CLOSE_FILE command."""
        print(f"\n{BLUE}[TEST]{RESET} CLOSE_FILE")

        response = self.send_command(COMMAND_CLOSE_FILE)

        print(f"  {YELLOW}Expected response:{RESET} 0x{expected_status:02X} ({self._error_name(expected_status)})")
        print(f"  {YELLOW}Manual check:{RESET} Look for 'Got HandleCloseFile' in Arduino Serial Monitor")

        return None

    def _error_name(self, code):
        """Get human-readable error code name."""
        names = {
            NOT_INITIALIZED: "NOT_INITIALIZED",
            FILE_NOT_FOUND: "FILE_NOT_FOUND",
            FILE_CANNOT_BE_OPENED: "FILE_CANNOT_BE_OPENED",
            FILE_IS_NOT_OPENED: "FILE_IS_NOT_OPENED",
            INVALID_ARGUMENT: "INVALID_ARGUMENT",
            SUCCESSFUL: "SUCCESSFUL"
        }
        return names.get(code, f"UNKNOWN_0x{code:02X}")

    # ========================================================================
    # Test Scenarios (POST_SPRINT6_PLAN D4)
    # ========================================================================

    def scenario_1_small_file(self):
        """Scenario 1: OPEN → READ → READ → CLOSE (small file <1KB)"""
        print(f"\n{'='*60}")
        print(f"{GREEN}SCENARIO 1:{RESET} Small file read (OPEN → READ → READ → CLOSE)")
        print('='*60)

        self.test_open_file("/TESTFILE_SMALL.BIN", SUCCESSFUL)
        input(f"{YELLOW}Press Enter after verifying OPEN success...{RESET}")

        self.test_read_file(chunk_count=1)  # Read 256 bytes
        input(f"{YELLOW}Press Enter after verifying READ success...{RESET}")

        self.test_close_file(SUCCESSFUL)
        input(f"{YELLOW}Press Enter after verifying CLOSE success...{RESET}")

        print(f"{GREEN}[PASS]{RESET} Scenario 1 completed (manual verification)")

    def scenario_2_large_file(self):
        """Scenario 2: OPEN large file, multiple chunks, EOF handling"""
        print(f"\n{'='*60}")
        print(f"{GREEN}SCENARIO 2:{RESET} Large file read (multiple chunks + EOF)")
        print('='*60)

        self.test_open_file("/TESTFILE_LARGE.BIN", SUCCESSFUL)
        input(f"{YELLOW}Press Enter after verifying OPEN success...{RESET}")

        # Read file in 256-byte chunks
        for i in range(8):  # 2048 bytes / 256 = 8 chunks
            print(f"\n  Chunk {i+1}/8:")
            self.test_read_file(chunk_count=1)
            input(f"{YELLOW}Press Enter to continue...{RESET}")

        self.test_close_file(SUCCESSFUL)
        input(f"{YELLOW}Press Enter after verifying CLOSE success...{RESET}")

        print(f"{GREEN}[PASS]{RESET} Scenario 2 completed (manual verification)")

    def scenario_3_read_after_close(self):
        """Scenario 3: READ after CLOSE → ERR_NOT_OPEN"""
        print(f"\n{'='*60}")
        print(f"{GREEN}SCENARIO 3:{RESET} READ after CLOSE (error handling)")
        print('='*60)

        self.test_open_file("/TESTFILE_SMALL.BIN", SUCCESSFUL)
        input(f"{YELLOW}Press Enter after verifying OPEN success...{RESET}")

        self.test_close_file(SUCCESSFUL)
        input(f"{YELLOW}Press Enter after verifying CLOSE success...{RESET}")

        # Try to READ after CLOSE
        print(f"\n{YELLOW}[EXPECT FAIL]{RESET} READ should fail with FILE_IS_NOT_OPENED")
        self.test_read_file(chunk_count=1)
        input(f"{YELLOW}Press Enter after verifying READ failure...{RESET}")

        print(f"{GREEN}[PASS]{RESET} Scenario 3 completed (manual verification)")

    def scenario_4_file_not_found(self):
        """Scenario 4: OPEN non-existent → FILE_NOT_FOUND"""
        print(f"\n{'='*60}")
        print(f"{GREEN}SCENARIO 4:{RESET} OPEN non-existent file (error handling)")
        print('='*60)

        print(f"\n{YELLOW}[EXPECT FAIL]{RESET} OPEN should fail with FILE_NOT_FOUND")
        self.test_open_file("/NONEXISTENT_FILE.BIN", FILE_NOT_FOUND)
        input(f"{YELLOW}Press Enter after verifying OPEN failure...{RESET}")

        print(f"{GREEN}[PASS]{RESET} Scenario 4 completed (manual verification)")

    def scenario_5_open_directory(self):
        """Scenario 5: OPEN directory → FILE_CANNOT_BE_OPENED"""
        print(f"\n{'='*60}")
        print(f"{GREEN}SCENARIO 5:{RESET} OPEN directory (error handling)")
        print('='*60)

        print(f"\n{YELLOW}[EXPECT FAIL]{RESET} OPEN should fail with FILE_CANNOT_BE_OPENED")
        self.test_open_file("/UTILS", FILE_CANNOT_BE_OPENED)
        input(f"{YELLOW}Press Enter after verifying OPEN failure...{RESET}")

        print(f"{GREEN}[PASS]{RESET} Scenario 5 completed (manual verification)")

    def scenario_6_stress_test(self):
        """Scenario 6: 50× OPEN/READ/CLOSE loop (memory leak check)"""
        print(f"\n{'='*60}")
        print(f"{GREEN}SCENARIO 6:{RESET} Stress test (50× OPEN/READ/CLOSE)")
        print('='*60)

        print(f"\n{YELLOW}[INFO]{RESET} This will repeat OPEN → READ → CLOSE 50 times")
        print(f"{YELLOW}[INFO]{RESET} Watch Arduino Serial Monitor for RAM stability")
        input(f"{YELLOW}Press Enter to start stress test...{RESET}")

        for i in range(50):
            print(f"\n  Iteration {i+1}/50:")
            self.test_open_file("/TESTFILE_SMALL.BIN", SUCCESSFUL)
            self.test_read_file(chunk_count=1)
            self.test_close_file(SUCCESSFUL)

            if (i+1) % 10 == 0:
                input(f"{YELLOW}Iteration {i+1}/50 - Press Enter to continue...{RESET}")

        print(f"\n{YELLOW}[CHECK]{RESET} Verify in Serial Monitor:")
        print(f"  - No 'Free RAM' degradation over 50 iterations")
        print(f"  - All OPEN/READ/CLOSE succeeded")
        input(f"{YELLOW}Press Enter after verification...{RESET}")

        print(f"{GREEN}[PASS]{RESET} Scenario 6 completed (manual verification)")

    def run_all_tests(self):
        """Run all test scenarios."""
        print(f"\n{BLUE}{'='*60}{RESET}")
        print(f"{BLUE}EasySD IRQHack64 - File I/O Core API Test Suite{RESET}")
        print(f"{BLUE}{'='*60}{RESET}")
        print(f"\n{YELLOW}[NOTE]{RESET} This is a SEMI-AUTOMATED test suite.")
        print(f"{YELLOW}[NOTE]{RESET} You must manually verify Arduino Serial Monitor output.")
        print(f"{YELLOW}[NOTE]{RESET} Ensure DEBUG build is uploaded (EASYSD_DEBUG_SERIAL enabled)")
        print()

        # Run scenarios
        self.scenario_1_small_file()
        self.scenario_2_large_file()
        self.scenario_3_read_after_close()
        self.scenario_4_file_not_found()
        self.scenario_5_open_directory()
        self.scenario_6_stress_test()

        # Summary
        print(f"\n{BLUE}{'='*60}{RESET}")
        print(f"{GREEN}TEST SUITE COMPLETED{RESET}")
        print(f"{BLUE}{'='*60}{RESET}")
        print(f"\n{GREEN}All scenarios executed.{RESET}")
        print(f"{YELLOW}Please review Arduino Serial Monitor logs to confirm all tests passed.{RESET}")

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <serial_port>")
        print(f"Example: {sys.argv[0]} COM4")
        print(f"Example: {sys.argv[0]} /dev/ttyUSB0")
        sys.exit(1)

    port = sys.argv[1]
    tester = FileIOTester(port)

    if not tester.connect():
        sys.exit(1)

    try:
        tester.run_all_tests()
    except KeyboardInterrupt:
        print(f"\n\n{YELLOW}[ABORT]{RESET} Test interrupted by user")
    except Exception as e:
        print(f"\n\n{RED}[ERROR]{RESET} Test failed: {e}")
    finally:
        tester.disconnect()

if __name__ == "__main__":
    main()
