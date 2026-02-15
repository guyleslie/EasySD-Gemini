#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Sprint 1 Directory Navigation Test Script
Automatikus tesztelés serial porton keresztül

Usage:
  py test_directory_navigation.py COM4
"""

import serial
import time
import sys

def send_command(ser, cmd, wait_time=1.0):
    """Send command and read response"""
    print(f"\n{'='*70}")
    print(f"SENDING COMMAND: '{cmd}'")
    print('='*70)

    # Clear input buffer
    ser.reset_input_buffer()

    # Send command
    ser.write(cmd.encode('ascii'))
    time.sleep(0.1)

    # Wait and read response
    time.sleep(wait_time)

    response = b""
    while ser.in_waiting > 0:
        response += ser.read(ser.in_waiting)
        time.sleep(0.1)

    try:
        response_str = response.decode('ascii', errors='replace')
        print(response_str)
    except:
        print(f"RAW: {response}")

    return response


def test_print_status(ser):
    """Test 'p' command - Print current status"""
    print("\n" + "🔍 TEST 1: Print Current Status".center(70, "="))
    send_command(ser, 'p', wait_time=0.5)


def test_enter_directory(ser, dirname):
    """Test 'd' command - Enter directory"""
    print(f"\n" + f"📂 TEST: Enter Directory '{dirname}'".center(70, "="))
    send_command(ser, 'd', wait_time=0.5)
    time.sleep(0.5)

    # Send directory name
    print(f"Sending directory name: {dirname}")
    ser.write(dirname.encode('ascii'))
    ser.write(b'\n')
    time.sleep(1.5)

    # Read response
    response = b""
    while ser.in_waiting > 0:
        response += ser.read(ser.in_waiting)
        time.sleep(0.1)

    try:
        response_str = response.decode('ascii', errors='replace')
        print(response_str)
        return "OK" in response_str or "SUCCESS" in response_str
    except:
        print(f"RAW: {response}")
        return False


def test_go_back(ser):
    """Test '..' navigation"""
    print("\n" + "⬆️  TEST: Go Back (..)".center(70, "="))
    return test_enter_directory(ser, '..')


def test_reset_to_root(ser):
    """Test 'r' command - Reset to root"""
    print("\n" + "🏠 TEST: Reset to Root".center(70, "="))
    send_command(ser, 'r', wait_time=0.5)


def main():
    if len(sys.argv) < 2:
        print("Usage: python test_directory_navigation.py COM4")
        sys.exit(1)

    port = sys.argv[1]
    baudrate = 57600

    print("\n" + "="*70)
    print("SPRINT 1 DIRECTORY NAVIGATION TEST")
    print("="*70)
    print(f"Port: {port}")
    print(f"Baudrate: {baudrate}")
    print("="*70)

    try:
        # Open serial port
        print(f"\nOpening serial port {port}...")
        ser = serial.Serial(port, baudrate, timeout=1)
        time.sleep(2)  # Wait for Arduino to reset

        # Clear any initial output
        ser.reset_input_buffer()
        initial = ser.read(ser.in_waiting)
        if initial:
            print("\nInitial output:")
            print(initial.decode('ascii', errors='replace'))

        # Run tests
        print("\n\n" + "🚀 STARTING TESTS".center(70, "=") + "\n")

        # Test 1: Print status
        test_print_status(ser)

        # Test 2: Try entering a directory (you'll need to know what's on your SD)
        print("\n\nNOTE: The following tests require actual directories on your SD card.")
        print("Modify the script to test with your actual directory names.\n")

        # Example: test_enter_directory(ser, "GAMES")
        # Example: test_go_back(ser)
        # Example: test_reset_to_root(ser)

        # Final status
        test_print_status(ser)

        print("\n\n" + "✅ TESTS COMPLETE".center(70, "=") + "\n")

        ser.close()

    except serial.SerialException as e:
        print(f"\nERROR: Could not open serial port {port}")
        print(f"Details: {e}")
        print("\nMake sure:")
        print("  1. Arduino is connected to the correct port")
        print("  2. No other program (Arduino IDE) is using the port")
        sys.exit(1)
    except KeyboardInterrupt:
        print("\n\nTest interrupted by user")
        if 'ser' in locals() and ser.is_open:
            ser.close()
        sys.exit(0)


if __name__ == "__main__":
    main()
