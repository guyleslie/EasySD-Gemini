#ifndef _CARTAPI_H
#define _CARTAPI_H
#include <Arduino.h>
#include <SdFat.h>
#include "DirFunction.h"
#include "CartInterface.h"

// ============================================================================
// Protocol response codes ($01-$7F = error, $80+ = success)
// ============================================================================
#define NOT_INITIALIZED       0x01
#define FILE_NOT_FOUND        0x02
#define FILE_CANNOT_BE_OPENED 0x03
#define FILE_IS_NOT_OPENED    0x04
#define FILE_WRITE_HAS_FAILED 0x05
#define WRITE_NOT_COMPLETE    0x06
#define FILE_DELETION_FAILED  0x07
#define CANT_SEEK             0x08
#define INVALID_ARGUMENT      0x09
#define NOT_IMPLEMENTED       0x0A
#define DIR_NOT_FOUND         0x0B
#define DIR_DELETION_FAILED   0x0C
#define DIR_ALREADY_EXISTS    0x0D
#define DIR_CREATION_FAILED   0x0E
#define FILE_INFO_FAILED      0x0F  // reserved; kept for protocol completeness
#define INVALID_SOURCE_TYPE   0x10
#define INVALID_CONTENT       0x11
#define TAP_UNSUPPORTED       0x12  // TAP format not standard KERNAL
#define TAP_BAD_TAP           0x13  // TAP header/checksum invalid
#define TAP_WRITE_FAILED      0x14  // TAP->PRG SD write error

#define SUCCESSFUL            0x80

// ============================================================================
// Command codes — must match EasySD.inc on the C64 side
// ============================================================================
#define COMMAND_READ_FILE           78
#define COMMAND_OPEN_FILE            2
#define COMMAND_CLOSE_FILE           3
#define COMMAND_WRITE_FILE           4
#define COMMAND_DELETE_FILE          5
#define COMMAND_SEEK_FILE            6
#define COMMAND_LONG_SEEK_FILE       7
#define COMMAND_GET_INFO_FOR_FILE    8
#define COMMAND_GET_PATH             9
#define COMMAND_READ_DIR            10
#define COMMAND_CHANGE_DIR          11
#define COMMAND_DELETE_DIR          12
#define COMMAND_CREATE_DIR          13
#define COMMAND_GOTO_PATH           14  // Multi-Load V2: navigate to absolute path
// MCU internal EEPROM commands — these operate on the ATmega328P's built-in
// 1 KB EEPROM (avr/eeprom.h / EEPROM.h), NOT on the cartridge ROML chip
// (the external AT28C64B / M27C64A on the PCB that the C64 reads via ROML).
#define COMMAND_READ_EEPROM         15  // Read one byte from MCU internal EEPROM
#define COMMAND_SEEK_EEPROM         16  // Set MCU internal EEPROM read/write pointer
#define COMMAND_WRITE_EEPROM        17  // Write one byte to MCU internal EEPROM
#define COMMAND_SET_PORT            20
#define COMMAND_SET_IO              21  // defined in protocol; currently no handler
#define COMMAND_INVOKE_WITH_NAME    23
#define COMMAND_INVOKE_WITH_INDEX   24  // defined in protocol; currently no handler
#define COMMAND_STREAM              25
#define COMMAND_NI_STREAM           26
#define COMMAND_READ_NEXT_CHUNK     27  // NMI-buffered chunk transfer (MK3 WAV path)
#define COMMAND_END_TALKING         30
#define COMMAND_EXIT_TO_MENU        31
#define COMMAND_HWTEST              32
#define COMMAND_CHANGE_DIR_INDEX    33  // menu-only: change directory by visible entry index

// ============================================================================
// Seek direction constants
// ============================================================================
#define SEEK_FROM_BEGINNING 0
#define SEEK_FROM_CURRENT   1
#define SEEK_FROM_END       2

// ============================================================================
// Buffer sizes — 64B each fits ATmega328P SRAM budget (2KB total).
// Streaming is double-buffered: two 64B buffers alternate during IO2 ISR.
// ============================================================================
#define WRITE_BUFFER_SIZE       32
#define MAX_ARGUMENTS_LENGTH   128
#define STREAMING_BUFFER_SIZE   64
#define DOUBLE_BUFFER_SIZE      64
#define NON_INTERRUPTED_BUFFER_SIZE 64

class CartApi {

 protected:
  File    workingFile;
  uint8_t Arguments[MAX_ARGUMENTS_LENGTH + 2];
  int     eepromIndex;
  bool    m_argsOk;   // false after GetArguments* timeout — handler should bail

  static constexpr uint16_t ARGS_TIMEOUT_MS = 500;  // per-byte timeout

  int16_t GetByte();
  int16_t AwaitByte(uint16_t timeoutMs);
  void GetArgumentsDynamic(int16_t argumentsLength);
  void GetArgumentsStatic(int16_t argumentsLength);

  void HandleReadFile();
  void HandleOpenFile();
  void HandleCloseFile();
  void HandleWriteFile();
  void HandleDeleteFile();
  void HandleSeekFile();
  void HandleLongSeekFile();
  void HandleGetInfoForFile();
  void HandleGetPath();
  void HandleGotoPath();
  void HandleReadDirectory();
  void HandleChangeDirectory();
  void HandleChangeDirectoryIndex();
  void HandleDeleteDirectory();
  void HandleCreateDirectory();
  void HandleReadEeprom();
  void HandleSeekEeprom();
  void HandleWriteEeprom();
  void IncrementEepromAddress();
  void HandleValueResponse(uint8_t value);
  void HandleSetPort();
  void HandleEndTalking();
  void HandleInvokeWithName();
  void HandleStream();
  void HandleNonInterruptedStream();
  void HandleReadNextChunk();
  void HandleHwTest();

  static void DoubleBufferedStreaming();
  static void SingleBufferedStreaming();

 public:
  void SendHeader(unsigned char startLow, unsigned char startHigh,
                  unsigned char transferPages, long dataLength,
                  unsigned char type, unsigned char transferMode);
  void Init();
  void HandleApi();
  void SendLoaderStub();
  void TransferMenu();
  void ResetNoCartridge();
  void LoadAndLaunchFile(const char* path);
#ifdef EASYSD_DEBUG_SERIAL
  void UpdateFile();
  void ReceiveFile();
#endif
};

#endif
