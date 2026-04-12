#include <SdFat.h>
#include <avr/eeprom.h>
#include <EEPROM.h>
#include "Arduino.h"
#include "CartApi.h"
#include "CartInterface.h"
#include "DirFunction.h"
#include "EasySD.h"
#include "FlashLib.h"
#include "petscii.c"
#include "FreeStack.h"
#include "EasySDLog.h"

extern SdFat  sd;
extern DirFunction dirFunc;
extern CartInterface cartInterface;

// ============================================================================
// EEPROM layout for last-directory persistence (redesigned, validated record)
// ============================================================================
// Explicit offsets (no struct — no compiler packing assumptions):
//   Byte 0-1:   magic (0xE5, 0xD0) — record signature
//   Byte 2:     version (0x01) — layout version for future migration
//   Byte 3:     pathLen — actual path length (1..63, 0 = invalid)
//   Byte 4-67:  path[64] — null-terminated absolute path
//   Byte 68-69: crc16 (lo, hi) — CRC16 checksum over version+pathLen+path[0..pathLen]
//   Byte 70:    committed (0xAA = fully written, anything else = torn/invalid)
// Total: 71 bytes (EEPROM[0..70])
// Write strategy: invalidate first (committed=0x00), then payload+CRC, finally committed=0xAA
// Read strategy: validate in order (magic → version → committed → pathLen → CRC → navigate)
//
// OLD FORMAT (legacy, NOT compatible): 2-byte magic + 64-byte raw path (bytes 0-65)
// The old format is NOT "backward compatible" — it is silently IGNORED by validation.
// Old byte 2 contains the path's first character (e.g. 0x2F = '/'), not version (0x01),
// so the version check will fail. The old record is discarded. First successful
// COMMAND_CHANGE_DIR rewrites EEPROM in the new format, replacing the old layout entirely.
#define EEPROM_LD_MAGIC0       0    // 0xE5
#define EEPROM_LD_MAGIC1       1    // 0xD0
#define EEPROM_LD_VERSION      2    // 0x01
#define EEPROM_LD_PATHLEN      3    // 1..63 (0 = invalid)
#define EEPROM_LD_PATH         4    // [64 bytes] path buffer
#define EEPROM_LD_CRC_LO      68    // CRC16 low byte
#define EEPROM_LD_CRC_HI      69    // CRC16 high byte
#define EEPROM_LD_COMMITTED   70    // 0xAA = complete, else = torn
#define EEPROM_LD_SIZE        71    // total record size

//volatile static uint8_t * streamBuffer;
// Static buffers for streaming (fix dangling pointer issue)
volatile static uint8_t streamingBuffer1[DOUBLE_BUFFER_SIZE];
volatile static uint8_t streamingBuffer2[DOUBLE_BUFFER_SIZE];
// Pointers initialized to static buffers (safe for ISR)
volatile static uint8_t * streamBuffer1 = streamingBuffer1;
volatile static uint8_t * streamBuffer2 = streamingBuffer2;
//volatile static uint8_t streamBufferIndex;
volatile static uint16_t streamBufferIndex;
volatile static unsigned long lastStreamRequestTime = 0;
//volatile static uint8_t chunkLength;
//volatile static uint8_t inChunkDelay;

// ============================================================================
// CRC16 helper — CCITT polynomial (0x1021)
// ============================================================================
static uint16_t crc16_update(uint16_t crc, uint8_t a) {
  crc ^= (uint16_t)a << 8;
  for (uint8_t i = 0; i < 8; i++)
    crc = (crc & 0x8000) ? (crc << 1) ^ 0x1021 : (crc << 1);
  return crc;
}

// ============================================================================
// Last-Directory Persistence Functions
// ============================================================================

// Saves the current directory path to EEPROM as a validated resume record.
// Called only after a successful COMMAND_CHANGE_DIR. Does not run at boot.
// If path is root, invalidates the record instead of writing it.
// Write order: committed=0x00 (invalidate), payload+CRC, committed=0xAA (commit).
void CartApi::SaveLastDir() {
  // If current path is root ("/"), invalidate any existing resume record.
  // This gives clean semantics: "no resume state" rather than "invalid save".
  if (dirFunc.currentPath[0] == '/' && dirFunc.currentPath[1] == '\0') {
    EEPROM.update(EEPROM_LD_COMMITTED, 0x00);
    return;
  }

  // Step 1: Invalidate old record first (crash-safe)
  EEPROM.update(EEPROM_LD_COMMITTED, 0x00);

  // Step 2: Write payload (magic, version, pathLen, path)
  uint8_t pathLen = strlen(dirFunc.currentPath);
  if (pathLen > 63) pathLen = 63;

  EEPROM.update(EEPROM_LD_MAGIC0, 0xE5);
  EEPROM.update(EEPROM_LD_MAGIC1, 0xD0);
  EEPROM.update(EEPROM_LD_VERSION, 0x01);
  EEPROM.update(EEPROM_LD_PATHLEN, pathLen);
  eeprom_update_block(dirFunc.currentPath, (void*)(EEPROM_LD_PATH), 64);

  // Step 3: Compute and write CRC16
  uint16_t crc = 0;
  crc = crc16_update(crc, 0x01);  // version
  crc = crc16_update(crc, pathLen);
  for (uint8_t i = 0; i <= pathLen; i++)  // include null terminator
    crc = crc16_update(crc, dirFunc.currentPath[i]);

  EEPROM.update(EEPROM_LD_CRC_LO, (uint8_t)(crc & 0xFF));
  EEPROM.update(EEPROM_LD_CRC_HI, (uint8_t)(crc >> 8));

  // Step 4: Commit (write last)
  EEPROM.update(EEPROM_LD_COMMITTED, 0xAA);
}

// Reads and validates the EEPROM resume record. Returns true if a valid
// saved path was found and successfully navigated. Returns false (stays at
// root) if the record is absent, corrupt, or the path no longer exists on SD.
// Validation order: magic → version → committed → pathLen → CRC → navigate.
// NOTE: Old 2-byte-magic format is NOT supported. It fails version check
// (old byte 2 is path's first char, not version 0x01) and is silently discarded.
bool CartApi::RestoreLastDir() {
  // Check magic bytes
  if (EEPROM.read(EEPROM_LD_MAGIC0) != 0xE5) return false;
  if (EEPROM.read(EEPROM_LD_MAGIC1) != 0xD0) return false;

  // Check version — rejects old format (which has path char in this byte, not 0x01)
  if (EEPROM.read(EEPROM_LD_VERSION) != 0x01) return false;

  // Check committed byte (torn write detection)
  if (EEPROM.read(EEPROM_LD_COMMITTED) != 0xAA) return false;

  // Check pathLen
  uint8_t pathLen = EEPROM.read(EEPROM_LD_PATHLEN);
  if (pathLen == 0 || pathLen > 63) return false;

  // Read path from EEPROM
  char path[64];
  eeprom_read_block(path, (void*)(EEPROM_LD_PATH), 64);

  // Validate null termination
  if (path[pathLen] != '\0') return false;

  // Skip root (no resume state for root)
  if (path[0] != '/' || path[1] == '\0') return false;

  // Verify CRC16
  uint16_t storedCrc = (uint16_t)EEPROM.read(EEPROM_LD_CRC_LO) |
                       ((uint16_t)EEPROM.read(EEPROM_LD_CRC_HI) << 8);
  uint16_t computedCrc = 0;
  computedCrc = crc16_update(computedCrc, 0x01);  // version
  computedCrc = crc16_update(computedCrc, pathLen);
  for (uint8_t i = 0; i <= pathLen; i++)  // include null terminator
    computedCrc = crc16_update(computedCrc, path[i]);

  if (storedCrc != computedCrc) return false;

  // All validation passed — navigate to the saved path
  bool success = dirFunc.NavigateToPath(path);
  return success;
}

void CartApi::Init() {
  eepromIndex = 0;
  lastDirPendingSave = false;
  lastDirIdleCounter = 0;
  /* Not talking at the moment */
  //TalkStatus = 0;
  cartInterface.SetPage(0);

  dirFunc.ReInit();
  // Always start from root on boot/menu init. Restoring the last directory adds
  // extra SD/path state during startup and is not required for current behavior.
  dirFunc.Prepare();
}

inline void HandleResponse(unsigned char response, uint16_t waitAfterResponse) {
  #ifdef TEST_TERMINAL_MODE
  Serial.write(response);
  #else
  cartInterface.SetPage(0);
  cartInterface.SetPage(0);
  cartInterface.SetPage(response);
  #endif
  //delayMicroseconds(waitAfterResponse);  
  if (waitAfterResponse!=0) delay(waitAfterResponse);
}

#define BUFFER_SIZE 16
void CartApi::HandleReadFile() {
  uint8_t fileBuffer[BUFFER_SIZE];
  GetArgumentsStatic(1);  
  unsigned int dataLength = Arguments[0];
  unsigned int totalLength = dataLength*256;
  unsigned int actualLength = 0;  
  cartInterface.ResetIndex();
  noInterrupts();
  cartInterface.SoftEndListening();

  if (!workingFile.isOpen()) {
    HandleResponse(FILE_IS_NOT_OPENED, 0);
  } else {
    HandleResponse(SUCCESSFUL, 1);
    delayMicroseconds(1000);
    while (workingFile.available() > 0 && actualLength < totalLength) {
      int readCount = workingFile.read(fileBuffer, BUFFER_SIZE);
      if (readCount > 0) {
        for (int i = 0; i < readCount; i++) {
          cartInterface.TransmitByteFastStd(fileBuffer[i]);
        }
        actualLength += readCount;
      }
      delayMicroseconds(100);
    }
  }
  for (unsigned int i = 0;i<(totalLength - actualLength);i++) {
    cartInterface.TransmitByteFast(0);
  }

  interrupts();
  cartInterface.SoftStartListening();
}

void CartApi::HandleOpenFile() {
  GetArgumentsDynamic(1);
  uint8_t flags = Arguments[0];
  unsigned int fileNameLength = Arguments[1];

  if (fileNameLength == 0) { HandleResponse(INVALID_ARGUMENT, 1); return; }
  char* fileName = (char*)&Arguments[2];

  // Ensure NUL-termination within our buffer
  if (fileNameLength < MAX_ARGUMENTS_LENGTH) {
    fileName[fileNameLength] = 0;
  } else {
    fileName[MAX_ARGUMENTS_LENGTH - 1] = 0;
  }

  const char* openName = fileName;
  bool restoreCwd = false;
  char savedPath[64];

  // SdFat 2.x absolute LFN paths are unreliable. For absolute paths, temporarily
  // switch the CWD to the parent directory, open the basename, then restore CWD.
  if (fileName[0] == '/') {
    char* lastSlash = strrchr(fileName, '/');
    if (lastSlash == NULL || lastSlash[1] == '\0') {
      HandleResponse(INVALID_ARGUMENT, 1);
      return;
    }

    strncpy(savedPath, dirFunc.currentPath, sizeof(savedPath) - 1);
    savedPath[sizeof(savedPath) - 1] = '\0';
    openName = lastSlash + 1;
    restoreCwd = true;

    if (lastSlash == fileName) {
      if (strcmp(savedPath, "/") != 0 && !dirFunc.NavigateToPath("/")) {
        HandleResponse(DIR_NOT_FOUND, 1);
        return;
      }
    } else {
      *lastSlash = '\0';
      bool navOk = dirFunc.NavigateToPath(fileName);
      *lastSlash = '/';
      if (!navOk) {
        HandleResponse(DIR_NOT_FOUND, 1);
        return;
      }
    }
  }

  workingFile = sd.open(openName, flags);

  if (restoreCwd && strcmp(savedPath, dirFunc.currentPath) != 0) {
    if (!dirFunc.NavigateToPath(savedPath)) {
      LOGE(DIR, "Restore CWD FAIL");
      dirFunc.ToRoot();
    }
  }

  if (workingFile != NULL) {
    LOGI(FILE, "File opened successfully");
    HandleResponse(SUCCESSFUL, 1);
  } else  {
    LOGE(FILE, "File open failed");
    HandleResponse(FILE_CANNOT_BE_OPENED, 1);
  }
}
void CartApi::HandleCloseFile() {
  GetArgumentsStatic(0);

  if (!workingFile.isOpen()) {
    HandleResponse(FILE_IS_NOT_OPENED, 1);
    return;
  }
  LOGI(FILE, "File closed");
  workingFile.close();
  HandleResponse(SUCCESSFUL, 1);
}



void CartApi::HandleWriteFile() {
  GetArgumentsStatic(32);
  if (!workingFile.isOpen()) {
    HandleResponse(FILE_IS_NOT_OPENED, 0);
    return;
  }
  // write() returns size_t (unsigned): 0 on failure, count on success
  size_t bytesWritten = workingFile.write(Arguments, WRITE_BUFFER_SIZE);
  if (bytesWritten == 0 || workingFile.getWriteError()) {
    workingFile.clearWriteError();
    HandleResponse(FILE_WRITE_HAS_FAILED, 0);
  } else if (bytesWritten < WRITE_BUFFER_SIZE) {
    HandleResponse(WRITE_NOT_COMPLETE, 0);
  } else if (!workingFile.sync()) {
    HandleResponse(FILE_WRITE_HAS_FAILED, 0);
  } else {
    HandleResponse(SUCCESSFUL, 0);
  }
}

void CartApi::HandleDeleteFile() {
  GetArgumentsDynamic(1);
  // Arguments[0] = flags (reserved, sent by protocol but not currently used)
  unsigned int fileNameLength = Arguments[1];
  char* fileName = (char*)&Arguments[2];

  if (fileNameLength == 0) { HandleResponse(INVALID_ARGUMENT, 0); return; }
  if (fileNameLength < MAX_ARGUMENTS_LENGTH) {
    fileName[fileNameLength] = 0;
  } else {
    fileName[MAX_ARGUMENTS_LENGTH-1] = 0;
  }

  if (!sd.exists(fileName)) {
    HandleResponse(FILE_NOT_FOUND, 0);
  } else {
    if (sd.remove(fileName)) {
      HandleResponse(SUCCESSFUL, 0);
    } else {
      HandleResponse(FILE_DELETION_FAILED, 0);
    }
  }
}

void CartApi::HandleSeekFile() {
  GetArgumentsStatic(3);
  unsigned int seekDirection = Arguments[0];
  uint8_t low  = Arguments[1];
  uint8_t high = Arguments[2];
  unsigned int seekPosition = (high << 8) | low;

  if (!workingFile.isOpen()) {
    HandleResponse(FILE_IS_NOT_OPENED, 1);
    return;
  }
  bool ok = false;
  if (seekDirection == SEEK_FROM_BEGINNING)      ok = workingFile.seekSet(seekPosition);
  else if (seekDirection == SEEK_FROM_CURRENT)   ok = workingFile.seekCur(seekPosition);
  else if (seekDirection == SEEK_FROM_END)        ok = workingFile.seekEnd(seekPosition);
  HandleResponse(ok ? SUCCESSFUL : CANT_SEEK, 1);
}


void CartApi::HandleLongSeekFile() {
  GetArgumentsStatic(5);
  unsigned int seekDirection = Arguments[0];
  uint8_t low      = Arguments[1];
  uint8_t high     = Arguments[2];
  uint8_t upperLow = Arguments[3];
  uint8_t upperHigh = Arguments[4];
  uint32_t seekPosition = ((uint32_t)upperHigh << 24) | ((uint32_t)upperLow << 16)
                        | ((uint32_t)high << 8) | low;

  if (!workingFile.isOpen()) {
    HandleResponse(FILE_IS_NOT_OPENED, 0);
    return;
  }
  bool ok = false;
  if (seekDirection == SEEK_FROM_BEGINNING)      ok = workingFile.seekSet(seekPosition);
  else if (seekDirection == SEEK_FROM_CURRENT)   ok = workingFile.seekCur(seekPosition);
  else if (seekDirection == SEEK_FROM_END)        ok = workingFile.seekEnd(seekPosition);
  HandleResponse(ok ? SUCCESSFUL : CANT_SEEK, 0);
}


void CartApi::HandleGetInfoForFile() {
  GetArgumentsStatic(0);
  if (!workingFile.isOpen()) {
    HandleResponse(FILE_IS_NOT_OPENED, 0);
    return;
  }
  // Use fileSize() — value is cached by sd.open(), no SPI access.
  // dirEntry() re-reads the directory sector via SPI and hangs in this context
  // (confirmed: BUG-F). All callers (#GETFILEINFO) only need bytes 28-31 (size).
  uint32_t sz = workingFile.fileSize();
  HandleResponse(SUCCESSFUL, 1);
  noInterrupts();
  for (uint8_t i = 0; i < 28; i++) cartInterface.TransmitByteFast(0);
  cartInterface.TransmitByteFast((uint8_t)(sz));
  cartInterface.TransmitByteFast((uint8_t)(sz >> 8));
  cartInterface.TransmitByteFast((uint8_t)(sz >> 16));
  cartInterface.TransmitByteFast((uint8_t)(sz >> 24));
  for (uint16_t i = 32; i < 256; i++) cartInterface.TransmitByteFast(0);
  interrupts();
  delayMicroseconds(20);
}

void CartApi::HandleGetPath() {
  GetArgumentsStatic(0);
  const char* path = dirFunc.currentPath;
  HandleResponse(SUCCESSFUL, 1);
  noInterrupts();
  for (uint8_t i = 0; i < 64; i++) {
    cartInterface.TransmitByteFast(path[i]);
  }
  for (uint8_t i = 0; i < 192; i++) {
    cartInterface.TransmitByteFast(0);
  }
  interrupts();
  delayMicroseconds(20);
}

// Multi-Load V2: Navigate Arduino to an absolute path sent by the C64.
// Protocol: C64 sends COMMAND_GOTO_PATH then filename bytes (length-prefixed, via SendFileName).
// Arduino navigates from root to path and responds SUCCESSFUL or DIR_NOT_FOUND.
void CartApi::HandleGotoPath() {
  GetArgumentsDynamic(0);
  uint8_t pathLen = Arguments[0];

  if (pathLen == 0 || pathLen >= MAX_ARGUMENTS_LENGTH) {
    HandleResponse(INVALID_ARGUMENT, 1);
    return;
  }

  char* path = (char*)&Arguments[1];
  path[pathLen] = '\0';

  LOGI(DIR, "GotoPath: "); LOG_PRINTLN(path);

  bool ok = dirFunc.NavigateToPath(path);
  if (ok) {
    dirFunc.Prepare();
    HandleResponse(SUCCESSFUL, 1);
  } else {
    HandleResponse(DIR_NOT_FOUND, 1);
  }
}

void CartApi::HandleReadDirectory() {
  GetArgumentsStatic(3);
  uint8_t numberOfEntries = Arguments[0]; //Max number of directory entries to retrieve
  uint8_t dataLength = Arguments[1]; //Max number of pages of data to retrieve (each page is 256 byte)

  uint8_t startPage = Arguments[2]; //Starting page
 
  if (numberOfEntries == 0 || dataLength == 0) {
    HandleResponse(INVALID_ARGUMENT, 1);
  } else {
    HandleResponse(SUCCESSFUL, 1);    
    uint16_t actualTransferredBytes = 0;
    uint16_t maxBytesToTransfer = dataLength * 256;

    uint16_t itemIndex = 0;
    uint16_t startingIndex = numberOfEntries * startPage;
    
    dirFunc.Rewind();

    while (itemIndex<startingIndex && dirFunc.Iterate() && !dirFunc.IsFinished) {
      itemIndex++;      
    }


    
    uint8_t currentItemsCount = dirFunc.GetCount()>startingIndex + numberOfEntries ? numberOfEntries : dirFunc.GetCount() - startingIndex;
    uint8_t pagePadValue = (dirFunc.GetCount() % numberOfEntries) > 0 ? 1 : 0;
    uint8_t pageCount = (byte)(dirFunc.GetCount()/numberOfEntries + pagePadValue);  
  
    cartInterface.ResetIndex();
    #ifndef TEST_TERMINAL_MODE  
    noInterrupts();
    #endif
    
    cartInterface.TransmitByteFast(currentItemsCount);   
    cartInterface.TransmitByteFast(pageCount); 
  
    actualTransferredBytes = 2;
     
    uint8_t curItemIndex = 0;    
    //Send initial state of directories.
    while (curItemIndex<numberOfEntries && dirFunc.Iterate() && !dirFunc.IsFinished) {  
      if (!dirFunc.IsHidden) {  
        if (actualTransferredBytes + 64 <maxBytesToTransfer) {
          // Send up to 63 chars of the LFN preview, then the type flag.
          uint8_t flen = (uint8_t)strlen(dirFunc.currentFileName);
          if (flen > 63) flen = 63;
          for (uint8_t i = 0; i < flen; i++) {
            cartInterface.TransmitByteFast(tolower((uint8_t)dirFunc.currentFileName[i]));
          }
          for (uint8_t i = flen; i < 63; i++) {
            cartInterface.TransmitByteFast(0x00);
          }

          if (dirFunc.IsDirectory) {
            cartInterface.TransmitByteFast(0x04);
          } else {
            cartInterface.TransmitByteFast(0x00);
          }

          actualTransferredBytes = actualTransferredBytes +64;        
          
          curItemIndex++;
        } else {
          break; 
        }
      }
    }   
  
    for (int i = 0;i<(maxBytesToTransfer - actualTransferredBytes);i++) {
      cartInterface.TransmitByteFast(0x00);    
    }

    #ifndef TEST_TERMINAL_MODE 
    interrupts();
     
    delayMicroseconds(20);
    #endif    
  }
}

void CartApi::HandleChangeDirectory() {
  GetArgumentsDynamic(0);
  unsigned int fileNameLength = Arguments[0];

  if (fileNameLength == 0) {
    LOGE(DIR, "DIR: Empty directory name");
    HandleResponse(INVALID_ARGUMENT, 1);
    return;
  }

  char * fileName = (char *) &Arguments[1];

  // Ensure null termination
  if (fileNameLength < MAX_ARGUMENTS_LENGTH) {
    fileName[fileNameLength] = '\0';
  } else {
    fileName[MAX_ARGUMENTS_LENGTH - 1] = '\0';
  }

  bool success = dirFunc.ChangeDirectoryBasename(fileName);
  if (!success) {
    static char matchBuf[128];
    uint8_t len = (uint8_t)strlen(fileName);
    if (dirFunc.FindDirectoryByPrefix(fileName, len, matchBuf, sizeof(matchBuf))) {
      success = dirFunc.ChangeDirectoryBasename(matchBuf);
    }
  }

  if (success) {
    dirFunc.Prepare();
    // Deferred save: flag the last-dir for saving, but don't write to EEPROM here.
    // The write happens later during idle, to avoid blocking the protocol response.
    lastDirPendingSave = true;
    lastDirIdleCounter = 0;  // Reset idle counter to start waiting for idle window
    HandleResponse(SUCCESSFUL, 1);
  } else {
    LOGE(DIR, "CD FAILED");
    HandleResponse(DIR_NOT_FOUND, 1);
  }
}

void CartApi::HandleDeleteDirectory() {
  GetArgumentsDynamic(1);
  // Arguments[0] = flags (reserved, sent by protocol but not currently used)
  unsigned int fileNameLength = Arguments[1];
  char* fileName = (char*)&Arguments[2];

  if (fileNameLength == 0) { HandleResponse(INVALID_ARGUMENT, 0); return; }
  if (fileNameLength < MAX_ARGUMENTS_LENGTH) {
    fileName[fileNameLength] = 0;
  } else {
    fileName[MAX_ARGUMENTS_LENGTH-1] = 0;
  }

  if (!sd.exists(fileName)) {
    HandleResponse(DIR_NOT_FOUND, 0);
  } else {
    if (sd.rmdir(fileName)) {
      HandleResponse(SUCCESSFUL, 0);
    } else {
      HandleResponse(DIR_DELETION_FAILED, 0);
    }
  }
}

void CartApi::HandleCreateDirectory() {
  GetArgumentsDynamic(1);
  // Arguments[0] = flags (reserved, sent by protocol but not currently used)
  unsigned int fileNameLength = Arguments[1];
  char* fileName = (char*)&Arguments[2];

  if (fileNameLength == 0) { HandleResponse(INVALID_ARGUMENT, 0); return; }
  if (fileNameLength < MAX_ARGUMENTS_LENGTH) {
    fileName[fileNameLength] = 0;
  } else {
    fileName[MAX_ARGUMENTS_LENGTH-1] = 0;
  }

  if (sd.exists(fileName)) {
    HandleResponse(DIR_ALREADY_EXISTS, 0);
  } else {
    if (sd.mkdir(fileName)) {
      HandleResponse(SUCCESSFUL, 0);
    } else {
      HandleResponse(DIR_CREATION_FAILED, 0);
    }
  }
}

// ============================================================================
// HELPER FUNCTIONS: File matching and TAP conversion
// ============================================================================

unsigned char IsMatchLast(char * container, char * val) {
  int lastIndexContainer = strlen(container) - 1;
  int lastIndexVal = strlen(val) - 1;

  for (int i = 0; i<=lastIndexVal;i++) {
    if (container[lastIndexContainer - i] != val[lastIndexVal - i]) {
      return 0;
    }
  }

  return 1;

}

// ------------------------------------------------------------
// Standard TAP -> PRG conversion (KERNAL/CBM tape blocks only)
// ------------------------------------------------------------
//
// This is intentionally NOT a universal TAP decoder. It supports only the
// standard Commodore KERNAL tape format wrapped in a .TAP container.
//
// References (format/encoding):
// - TAP header and pulse encoding: C64-Wiki / VICE docs
// - Datassette pulse-length encoding: byte marker = LONG+MEDIUM,
//   bit0 = SHORT+MEDIUM, bit1 = MEDIUM+SHORT, LSB-first + odd parity
//
// Turbo/custom loaders are expected to fail fast.

enum TapPulseClass : uint8_t { TAP_PULSE_SHORT = 0, TAP_PULSE_MEDIUM = 1, TAP_PULSE_LONG = 2 };

static TapPulseClass ClassifyTapPulseUnit(uint16_t unit) {
  // TAP payload units are cycles/8. VICE default classification ranges:
  // short: 0x24-0x36, medium: 0x37-0x49, long: 0x4A-0x64.
  // We use a relaxed thresholding to tolerate motor speed variations.
  if (unit < 0x37) return TAP_PULSE_SHORT;
  if (unit < 0x4A) return TAP_PULSE_MEDIUM;
  return TAP_PULSE_LONG;
}

struct TapPulseReader {
  File *f;
  uint8_t version;

  bool readPulseUnit(uint16_t &outUnit) {
    int b = f->read();
    if (b < 0) return false;
    uint8_t ub = (uint8_t)b;

    if (ub != 0) {
      outUnit = ub;
      return true;
    }

    // ub == 0: special handling
    if (version == 0) {
      // v0: 0 is treated as 256 (or overflow); good enough for classification
      outUnit = 256;
      return true;
    }

    // v1: next 3 bytes = exact cycle count (LSB first)
    int b0 = f->read();
    int b1 = f->read();
    int b2 = f->read();
    if (b0 < 0 || b1 < 0 || b2 < 0) return false;
    uint32_t cycles = (uint32_t)(uint8_t)b0 | ((uint32_t)(uint8_t)b1 << 8) | ((uint32_t)(uint8_t)b2 << 16);
    // Convert cycles to units of cycles/8 (rounded)
    outUnit = (uint16_t)((cycles + 4) / 8);
    if (outUnit == 0) outUnit = 1;
    return true;
  }
};

static bool TapReadNextByte(TapPulseReader &pr, uint8_t &outByte, uint32_t maxPulsesToScan = 500000) {
  // Scan for byte marker: LONG + MEDIUM
  uint16_t u1 = 0, u2 = 0;
  TapPulseClass p1, p2;

  for (uint32_t scanned = 0; scanned < maxPulsesToScan; scanned++) {
    if (!pr.readPulseUnit(u1)) return false;
    if (!pr.readPulseUnit(u2)) return false;
    p1 = ClassifyTapPulseUnit(u1);
    p2 = ClassifyTapPulseUnit(u2);
    if (p1 == TAP_PULSE_LONG && p2 == TAP_PULSE_MEDIUM) {
      // decode 8 bits + parity, LSB first
      uint8_t v = 0;
      uint8_t ones = 0;
      for (uint8_t bit = 0; bit < 8; bit++) {
        uint16_t a, b;
        if (!pr.readPulseUnit(a)) return false;
        if (!pr.readPulseUnit(b)) return false;
        TapPulseClass pa = ClassifyTapPulseUnit(a);
        TapPulseClass pb = ClassifyTapPulseUnit(b);

        uint8_t bitval;
        if (pa == TAP_PULSE_SHORT && (pb == TAP_PULSE_MEDIUM || pb == TAP_PULSE_LONG)) {
          bitval = 0;
        } else if ((pa == TAP_PULSE_MEDIUM || pa == TAP_PULSE_LONG) && pb == TAP_PULSE_SHORT) {
          bitval = 1;
        } else {
          // not standard encoding
          return false;
        }

        v |= (bitval << bit);
        ones += bitval;
      }

      // parity bit (odd)
      {
        uint16_t a, b;
        if (!pr.readPulseUnit(a)) return false;
        if (!pr.readPulseUnit(b)) return false;
        TapPulseClass pa = ClassifyTapPulseUnit(a);
        TapPulseClass pb = ClassifyTapPulseUnit(b);
        uint8_t parity;
        if (pa == TAP_PULSE_SHORT && (pb == TAP_PULSE_MEDIUM || pb == TAP_PULSE_LONG)) {
          parity = 0;
        } else if ((pa == TAP_PULSE_MEDIUM || pa == TAP_PULSE_LONG) && pb == TAP_PULSE_SHORT) {
          parity = 1;
        } else {
          return false;
        }
        ones += parity;
        if ((ones & 1) == 0) {
          // not odd parity => likely not standard
          return false;
        }
      }

      outByte = v;
      return true;
    }
  }

  return false;
}

static bool TapFindCountdown(TapPulseReader &pr, uint8_t startVal, uint32_t maxBytesToScan = 200000) {
  // Find sequence startVal, startVal-1, ..., startVal-8 (9 bytes)
  uint8_t window[9];
  for (uint8_t i = 0; i < 9; i++) window[i] = 0;
  uint32_t filled = 0;

  for (uint32_t i = 0; i < maxBytesToScan; i++) {
    uint8_t b;
    if (!TapReadNextByte(pr, b)) return false;
    // shift
    for (uint8_t k = 0; k < 8; k++) window[k] = window[k + 1];
    window[8] = b;
    if (filled < 9) filled++;
    if (filled < 9) continue;

    bool match = true;
    for (uint8_t k = 0; k < 9; k++) {
      if (window[k] != (uint8_t)(startVal - k)) { match = false; break; }
    }
    if (match) return true;
  }
  return false;
}

static bool TapReadStandardBlock(TapPulseReader &pr, uint8_t *payload192) {
  // Countdown (copy 1): $89..$81
  if (!TapFindCountdown(pr, 0x89)) return false;

  uint8_t checksum = 0;
  for (uint16_t i = 0; i < 192; i++) {
    uint8_t b;
    if (!TapReadNextByte(pr, b)) return false;
    payload192[i] = b;
    checksum ^= b;
  }

  uint8_t chk1;
  if (!TapReadNextByte(pr, chk1)) return false;
  // If checksum mismatch, still continue (tapes can be noisy), but it's a strong signal.
  // We'll fail here to keep scope strict.
  if (chk1 != checksum) return false;

  // Countdown (copy 2): $09..$01
  if (!TapFindCountdown(pr, 0x09)) return false;
  uint8_t checksum2 = 0;
  for (uint16_t i = 0; i < 192; i++) {
    uint8_t b;
    if (!TapReadNextByte(pr, b)) return false;
    checksum2 ^= b;
  }
  uint8_t chk2;
  if (!TapReadNextByte(pr, chk2)) return false;
  if (chk2 != checksum2) return false;

  return true;
}

static bool MakeOutputPrgName(const char *tapName, char *outPrgName, size_t outLen) {
  size_t n = strlen(tapName);
  if (n + 1 >= outLen) return false;
  strncpy(outPrgName, tapName, outLen);
  outPrgName[outLen - 1] = 0;

  // find last '.'
  int lastDot = -1;
  for (size_t i = 0; i < n; i++) {
    if (tapName[i] == '.') lastDot = (int)i;
  }
  if (lastDot < 0) {
    if (n + 4 >= outLen) return false;
    strcat(outPrgName, ".prg");
    return true;
  }
  if ((size_t)lastDot + 4 >= outLen) return false;
  outPrgName[lastDot] = 0;
  strcat(outPrgName, ".prg");
  return true;
}

// Returns one of: SUCCESSFUL, TAP_BAD_TAP, TAP_UNSUPPORTED, TAP_WRITE_FAILED
static uint8_t ConvertStandardTapToPrg(SdFat &sd, const char *tapName, char *outPrgName, size_t outLen) {
  if (!MakeOutputPrgName(tapName, outPrgName, outLen)) return TAP_WRITE_FAILED;

  File tap = sd.open(tapName, FILE_READ);
  if (!tap) return FILE_CANNOT_BE_OPENED;

  // Read TAP header (20 bytes)
  uint8_t header[20];
  if (tap.read(header, 20) != 20) { tap.close(); return TAP_BAD_TAP; }
  const char sig[] = "C64-TAPE-RAW";
  if (memcmp(header, sig, 12) != 0) { tap.close(); return TAP_BAD_TAP; }
  uint8_t version = header[12];
  if (!(version == 0 || version == 1)) { tap.close(); return TAP_BAD_TAP; }

  TapPulseReader pr;
  pr.f = &tap;
  pr.version = version;

  // Read first standard block = header block
  uint8_t block[192];
  if (!TapReadStandardBlock(pr, block)) { tap.close(); return TAP_UNSUPPORTED; }

  uint8_t fileType = block[0];
  uint16_t startAddr = (uint16_t)block[1] | ((uint16_t)block[2] << 8);
  uint16_t endAddrPlus1 = (uint16_t)block[3] | ((uint16_t)block[4] << 8);

  // Only PRG-like types
  if (!(fileType == 0x01 || fileType == 0x03)) { tap.close(); return TAP_UNSUPPORTED; }
  if (endAddrPlus1 <= startAddr) { tap.close(); return TAP_BAD_TAP; }
  uint32_t remaining = (uint32_t)endAddrPlus1 - (uint32_t)startAddr;

  // Create output PRG
  if (sd.exists(outPrgName)) sd.remove(outPrgName);
  File prg = sd.open(outPrgName, FILE_WRITE);
  if (!prg) { tap.close(); return TAP_WRITE_FAILED; }

  // PRG header: load address
  if (prg.write((uint8_t)(startAddr & 0xFF)) != 1) { prg.close(); tap.close(); return TAP_WRITE_FAILED; }
  if (prg.write((uint8_t)(startAddr >> 8)) != 1) { prg.close(); tap.close(); return TAP_WRITE_FAILED; }

  // Read subsequent blocks and dump sequential data until remaining == 0
  while (remaining > 0) {
    if (!TapReadStandardBlock(pr, block)) { prg.close(); tap.close(); return TAP_UNSUPPORTED; }
    uint16_t toWrite = (remaining > 192) ? 192 : (uint16_t)remaining;
    if (prg.write(block, toWrite) != toWrite) { prg.close(); tap.close(); return TAP_WRITE_FAILED; }
    remaining -= toWrite;
  }

  prg.flush();
  prg.close();
  tap.close();
  return SUCCESSFUL;
}

// ============================================================================
// CartApi PUBLIC METHODS
// ============================================================================

void CartApi::HandleInvokeWithName() {
  GetArgumentsDynamic(1);
  uint8_t flags = Arguments[0];
  unsigned int fileNameLength = Arguments[1];
  char * fileName = (char *) &Arguments[2];

  // Flags are passed from the C64 in X register.
  // Bit0: 1=auto-run (default), 0=convert/save only (TAP only)
  const uint8_t FLAG_AUTORUN = 0x01;

  // Special case: TAP convert & save only.
  if ((IsMatchLast(fileName, ".tap") || IsMatchLast(fileName, ".TAP")) && ((flags & FLAG_AUTORUN) == 0)) {
    char outPrg[64];
    uint8_t tapRes = ConvertStandardTapToPrg(sd, fileName, outPrg, sizeof(outPrg));
    HandleResponse(tapRes, 0);
    return;
  }

  // NUL-terminate the received filename (GetArgumentsDynamic does not do this).
  Arguments[2 + fileNameLength] = '\0';

  // For absolute paths (e.g. "/PRG/dizzy 2 1  -cmm.prg"), sd.exists() with an
  // absolute path containing LFN components can fail in SdFat 2.x.
  // The CWD is already set to the parent directory by DirFunction during menu
  // navigation, so we use just the basename with the current directory.
  const char* openName = fileName;
  if (fileName[0] == '/') {
    const char* lastSlash = strrchr(fileName, '/');
    if (lastSlash) openName = lastSlash + 1;
  }

  // Verify file exists before committing to C64 — once SUCCESSFUL is sent,
  // C64 expects a reset; if the file is missing we cannot send an error after.
  // The C64 protocol sends at most 31 chars per filename. For files with names
  // longer than 31 chars the received name is a truncated prefix. When
  // sd.exists() fails, scan the CWD using SdFat's getName() to find the full
  // LFN that starts with the received prefix (case-insensitive).
  if (!sd.exists(openName)) {
    // Static: avoids large stack allocation inside a path that may be hot.
    static char matchBuf[128];
    uint8_t len = strlen(openName);
    if (!dirFunc.FindByPrefix(openName, len, matchBuf, sizeof(matchBuf))) {
      HandleResponse(FILE_NOT_FOUND, 0);
      return;
    }
    openName = matchBuf;
  }

  HandleResponse(SUCCESSFUL, 0);
  LoadAndLaunchFile(openName);
}

void CartApi::HandleValueResponse(uint8_t value) {
  //HandleResponse( (value & 1) | 0x80, 20); //Embed least significant bit of value
  HandleResponse( (value & 1) | 0x80, 1); //Embed least significant bit of value
  //HandleResponse( (value & 0xFE)>>1, 20); //Embed rest of the value
  HandleResponse( (value & 0xFE)>>1, 1); //Embed rest of the value
}

// ============================================================================
// MCU INTERNAL EEPROM command handlers (COMMAND_READ/SEEK/WRITE_EEPROM)
// These access the ATmega328P's built-in 1 KB EEPROM via EEPROM.h / avr/eeprom.h.
// They have NO connection to the cartridge ROML chip (external AT28C64B /
// M27C64A on the PCB) — that chip is programmed externally and is read-only at
// runtime via the ROML ($8000-$9FFF) address space.
// ============================================================================

void CartApi::IncrementEepromAddress() {
    eepromIndex++;
    if (eepromIndex>1024) eepromIndex = 0;
}

void CartApi::HandleReadEeprom() {
  #ifndef __AVR__    
  EEPROM.begin(EEPROM_SIZE);
  #endif
  uint8_t value = EEPROM.read(eepromIndex);
  #ifndef __AVR__    
  EEPROM.end();
  #endif  
  HandleValueResponse( value );
  IncrementEepromAddress();
}

void CartApi::HandleSeekEeprom() {
  GetArgumentsStatic(2);    
  uint8_t hi = Arguments[0];
  uint8_t low = Arguments[1];
  eepromIndex = (hi<<8) | low;  
  HandleResponse(SUCCESSFUL, 0);   
}

void CartApi::HandleWriteEeprom() {
  #ifndef __AVR__    
  EEPROM.begin(EEPROM_SIZE);
  #endif
  GetArgumentsStatic(1);    
  uint8_t value = Arguments[0];  
  EEPROM.write(eepromIndex, value); 

  #ifndef __AVR__    
  EEPROM.end();
  #endif  
  
  IncrementEepromAddress();
  HandleResponse(SUCCESSFUL, 0); 
}

void CartApi::HandleEndTalking() {
  //cartInterface.EndListening();
  cartInterface.ResetReceive();
}

void CartApi::HandleSetPort() {
  GetArgumentsStatic(1);    
  uint8_t value = Arguments[0];  
  cartInterface.SetPage(value);
  HandleResponse(SUCCESSFUL, 0);   
}


volatile static uint8_t currentByte = 0;
volatile static uint8_t usedBuffer = 0;

void CartApi::DoubleBufferedStreaming() {  
    lastStreamRequestTime = millis();
    cartInterface.SetPage(currentByte);

    if (usedBuffer == 0) {
      currentByte = streamBuffer1[streamBufferIndex];
    } else if (usedBuffer == 1) {
      currentByte = streamBuffer2[streamBufferIndex];
    }
    
    streamBufferIndex++;    
    if (streamBufferIndex == DOUBLE_BUFFER_SIZE) {
      streamBufferIndex = 0;
      usedBuffer = 1-usedBuffer;
    }            
}


void CartApi::SingleBufferedStreaming() {
    uint8_t val = streamBuffer1[streamBufferIndex];
    // FIX: Read PORT registers (output state), not PIN registers
    PORTD = (PORTD & 0x0F) | (val & 0xF0);
    PORTC = (PORTC & 0xF0) | (val & 0x0F);

    streamBufferIndex++;
}


void CartApi::HandleStream() {
  #define STREAM_TIMEOUT_MS 100 // 100 milliseconds timeout for streaming

  // Note: streamingBuffer1/2 are now static (file scope), not local
  // This fixes the dangling pointer bug where ISR would access stack memory

  GetArgumentsStatic(3);
  uint8_t initialDelay = Arguments[0];
  uint8_t countStreamedBytes = Arguments[1];
  uint8_t delayBetweenBytes = Arguments[2];


  if (!workingFile.isOpen()) {
    HandleResponse(FILE_IS_NOT_OPENED, 0);
  } else {
      workingFile.read(streamingBuffer1, DOUBLE_BUFFER_SIZE);
      HandleResponse(SUCCESSFUL, 0);
      
      // Reset state for new stream
      streamBufferIndex = 0;
      usedBuffer = 0;
      currentByte = streamingBuffer1[0]; // Pre-load first byte
      streamBufferIndex = 1;             // Next request will get buffer[1]
      lastStreamRequestTime = millis();  // Initialize timeout timer

      // EXROM LOW: cartridge ROML chip (AT28C64B / M27C64A) becomes visible to
      // C64 at $8000-$9FFF. Required so the C64's CIA1 ISR can read
      // CARTRIDGE_BANK_VALUE from the chip during streaming.
      cartInterface.EnableCartridge();
      TIMSK2 = 0; // Disable timer 2 interrupts
      attachInterrupt(digitalPinToInterrupt(IO2), CartApi::DoubleBufferedStreaming, FALLING);

     
      while(1) {
        while(usedBuffer == 0) {
          if (!selRead()) goto out; // Original check
          if (millis() - lastStreamRequestTime > STREAM_TIMEOUT_MS) goto out; // Timeout check
        }
        workingFile.read(streamingBuffer1, DOUBLE_BUFFER_SIZE);
        while(usedBuffer == 1) {
          if (!selRead()) goto out; // Original check
          if (millis() - lastStreamRequestTime > STREAM_TIMEOUT_MS) goto out; // Timeout check
        }
        workingFile.read(streamingBuffer2, DOUBLE_BUFFER_SIZE);         
      }
out:
      TIMSK2 = 0x02; // Enable timer 2 interrupts (for milliseconds and so on)
      cartInterface.DisableCartridge(); // EXROM HIGH: clean state before returning to command mode
      cartInterface.StartListening();
  }
}


void CartApi::HandleReadNextChunk() {
  uint8_t fileBuffer[BUFFER_SIZE];   // BUFFER_SIZE = 16
  GetArgumentsStatic(1);
  uint8_t numPages = Arguments[0];
  uint32_t totalBytes = (uint32_t)numPages * 256;

  if (!workingFile.isOpen()) {
    HandleResponse(FILE_IS_NOT_OPENED, 0);
    return;
  }

  // 0x80 = more data remaining; 0x81 = this is the last block (EOF)
  uint32_t avail = workingFile.available();
  uint8_t statusByte = (avail <= totalBytes) ? 0x81 : 0x80;

  // Send status first — C64's PROT_WaitProcessing polls CARTRIDGE_BANK_VALUE.
  // delayMicroseconds(1000) gives C64 ~1ms to set up the NMI transfer handler.
  HandleResponse(statusByte, 1);
  delayMicroseconds(1000);

  // Transmit exactly numPages*256 bytes via NMI push
  noInterrupts();
  uint32_t sent = 0;
  while (sent < totalBytes) {
    uint16_t toRead = (uint16_t)min((uint32_t)BUFFER_SIZE, totalBytes - sent);
    if (workingFile.available() > 0) {
      int readCount = workingFile.read(fileBuffer, toRead);
      for (int i = 0; i < readCount; i++) {
        cartInterface.TransmitByteFastMK3(fileBuffer[i]);
      }
      sent += (uint32_t)readCount;
    } else {
      // Pad with mid-scale silence (0x80 = silence for unsigned 8-bit audio)
      cartInterface.TransmitByteFastMK3(0x80);
      sent++;
    }
  }
  interrupts();
}


void CartApi::HandleHwTest() {
  // Send 10 known bit-pattern bytes via NMI, then pad to 256 bytes (1 full page).
  // C64 verifies each pattern to confirm data bus and NMI wire integrity.
  static const uint8_t pat[10] = {
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x55, 0xAA
  };
  HandleResponse(SUCCESSFUL, 1);  // 1ms: C64 reads response, sets up NMI handler
  noInterrupts();
  for (uint8_t i = 0; i < 10; i++)
    cartInterface.TransmitByteFastStd(pat[i]);
  for (uint16_t i = 10; i < 256; i++)
    cartInterface.TransmitByteFastStd(0x00);
  interrupts();
  cartInterface.SoftStartListening();
}


void CartApi::HandleNonInterruptedStream() {
  uint16_t bufferIndex = 0;
  uint16_t bufferLength;
  uint8_t currentBuffer = 0; // 0 for buffer1, 1 for buffer2
  
  GetArgumentsStatic(1);
  uint8_t countOf8Bytes = Arguments[0];  

  if (countOf8Bytes > DOUBLE_BUFFER_SIZE / 8) {
    HandleResponse(INVALID_ARGUMENT, 0);
  } else if (!workingFile.isOpen()) {
    HandleResponse(FILE_IS_NOT_OPENED, 0);
  } else {
      HandleResponse(SUCCESSFUL, 0);

      // Disable receiving interrupt but keep the state of the communication channel on.
      cartInterface.SoftEndListening(); 
      bufferLength = countOf8Bytes * 8;
           
      // Pre-load BOTH buffers to ensure a smooth start
      workingFile.read((uint8_t*)streamBuffer1, bufferLength);      
      workingFile.read((uint8_t*)streamBuffer2, bufferLength);      
      
      TIMSK2 = 0; // Disable timer 2 interrupts (millis etc.) for maximum timing precision

      noInterrupts();
      uint8_t portDVal = (PORTD & 0x0F);
      uint8_t portCVal = (PORTC & 0xF0);
      uint8_t * activeBuffer;

      while(1) {
        // Select current buffer to transmit
        activeBuffer = (currentBuffer == 0) ? (uint8_t*)streamBuffer1 : (uint8_t*)streamBuffer2;

        for (bufferIndex = 0; bufferIndex < bufferLength; bufferIndex++) {
            /* Synchronization block for each byte */
            // Note: We don't use millis() inside the inner loop for speed, 
            // but we need a way to detect timeout or reset.
            // A simple cycle counter could work, but selRead() is safer.

            while (PIND & 0x08) {
               if (!selRead()) goto ni_out; // Exit on C64 Reset
            }
            while ((PIND & 0x08) == 0);  // Wait for rising edge
            
            uint8_t val = activeBuffer[bufferIndex];
            PORTD = portDVal | (val & 0xF0);
            PORTC = portCVal | (val & 0x0F);            
        }   
        
        // --- Refill the buffer we just finished sending ---
        // C64 is currently busy processing the 400 bytes we just sent.
        // interrupts() re-enabled here for SD card stability.
        // EOF check: if read() returns 0 the file is exhausted — exit cleanly.
        // The C64 detects end-of-stream via its CVD_SIZE frame counter and will
        // call PROT_StartTalking to re-establish the session after this exit.
        interrupts();
        if (currentBuffer == 0) {
            if (workingFile.read((uint8_t*)streamBuffer1, bufferLength) == 0) goto ni_out;
            currentBuffer = 1; // Next time we send buffer 2
        } else {
            if (workingFile.read((uint8_t*)streamBuffer2, bufferLength) == 0) goto ni_out;
            currentBuffer = 0; // Next time we send buffer 1
        }
        noInterrupts();
      } 

ni_out:
      interrupts();
      TIMSK2 = 0x02; // Enable timer 2 interrupts
      cartInterface.StartListening();
  }
}




int16_t CartApi::AwaitByte(int16_t maxTryCount) {
  int16_t value = -1;
  for (uint8_t x = 0;x<100;x++) {
    for (int16_t i = 0;i<maxTryCount;i++) {
        value = cartInterface.Read();
        if (value>=0) {
          return value;
        }
    }
  }

  LOGE(SYS, "AW Fail");
  

  return value;  
}


int16_t CartApi::GetByte() {
  return cartInterface.Read();
}

// Argument length is known priorhand
void CartApi::GetArgumentsStatic(int16_t argumentsLength) {  
  for (int16_t i = 0;i<argumentsLength;) {
    int16_t value = AwaitByte(32000);
    if (value>=0) {
      Arguments[i] = value;        
      i++;
    }
  }   
}

//Only initial N argument count is known. Size of the remaining arguments is specified by length next to the known arguments.
void CartApi::GetArgumentsDynamic(int16_t argumentsLength) {
  GetArgumentsStatic(argumentsLength);
  int16_t dynamicLength = AwaitByte(32000);
  // FIX: Use logical OR (||) instead of bitwise OR (|)
  if (dynamicLength == -1 || dynamicLength>(MAX_ARGUMENTS_LENGTH-1)) return;
  
  Arguments[argumentsLength] = dynamicLength;
  
  for (int16_t i = 1;i<=dynamicLength;i++) {
    int16_t value = AwaitByte(32000);
    if (value==-1) return;    
    Arguments[i + argumentsLength] = value;  
  }   
}


void CartApi::HandleApi() {  
  uint8_t state = cartInterface.ReceiveHandler();

  if (state == IN_TRANSMISSION) {    
      int16_t command = GetByte();
      if (command>=0) {
        cartInterface.SetPage(0);

        //LOG_PRINT_F("Free RAM: ");
        //LOG_PRINTLN(FreeRam());
        //LOG_PRINT_F("FreeStack: "); LOG_PRINTLN(FreeStack());

        switch(command) {
          case COMMAND_READ_FILE : HandleReadFile(); break;
          case COMMAND_OPEN_FILE : HandleOpenFile(); break;
          case COMMAND_CLOSE_FILE : HandleCloseFile(); break;
          case COMMAND_WRITE_FILE : HandleWriteFile(); break;
          case COMMAND_DELETE_FILE : HandleDeleteFile(); break;
          case COMMAND_SEEK_FILE : HandleSeekFile(); break;
          case COMMAND_LONG_SEEK_FILE : HandleLongSeekFile(); break;
          case COMMAND_GET_INFO_FOR_FILE : HandleGetInfoForFile(); break;
          case COMMAND_GET_PATH : HandleGetPath(); break;
          case COMMAND_GOTO_PATH : HandleGotoPath(); break;
          case COMMAND_READ_DIR : HandleReadDirectory(); break;
          case COMMAND_CHANGE_DIR : HandleChangeDirectory(); break;
          case COMMAND_DELETE_DIR : HandleDeleteDirectory(); break;
          case COMMAND_CREATE_DIR : HandleCreateDirectory(); break;      
          case COMMAND_READ_EEPROM : HandleReadEeprom(); break;
          case COMMAND_SEEK_EEPROM : HandleSeekEeprom(); break;
          case COMMAND_WRITE_EEPROM : HandleWriteEeprom(); break;
          case COMMAND_END_TALKING : HandleEndTalking(); break;
          case COMMAND_INVOKE_WITH_NAME : HandleInvokeWithName();break;
          case COMMAND_STREAM : HandleStream();break;          
          case COMMAND_NI_STREAM : HandleNonInterruptedStream(); break;
          case COMMAND_READ_NEXT_CHUNK : HandleReadNextChunk(); break;
          case COMMAND_HWTEST : HandleHwTest(); break;
          case COMMAND_EXIT_TO_MENU : TransferMenu();break;            
        }

        //LOGD(PROTO, "Port clear!");

        cartInterface.SetPage(0);
        // Reset idle counter on every command
        lastDirIdleCounter = 0;
      }
   } else {
     // Idle: increment counter and check for deferred save
     lastDirIdleCounter++;

     // Save last-dir only after sufficient idle time (~50 cycles = ~50-100ms idle)
     // This ensures the save happens in a relaxed window, not during protocol critical path
     if (lastDirPendingSave && lastDirIdleCounter > 50) {
       SaveLastDir();
       lastDirPendingSave = false;
       lastDirIdleCounter = 0;
     }
   }
}  




void CartApi::SendLoaderStub() {
  #ifdef __AVR__
  for (int i = 0;i<stub_len;i++) {
    cartInterface.TransmitByteFastStd(pgm_read_byte(stubData + i));
  }
  #endif

  #ifdef ESP8266
  for (int i = 0;i<stub_len;i++) {
    cartInterface.TransmitByteFastStd(*(stubData + i));
  }
  #endif


  for (int i = stub_len;i<256;i++) {
    cartInterface.TransmitByteFastStd(0x20); //Send space character
  }

  cartInterface.ResetIndex();
}

bool StartsWith(char *str,const char *pre)
{
    size_t lenpre = strlen(pre),
           lenstr = strlen(str);
    return lenstr < lenpre ? false : strncmp(pre, str, lenpre) == 0;
}


void CartApi::SendHeader(unsigned char startLow, unsigned char startHigh, unsigned char transferPages, long dataLength, unsigned char type, unsigned char transferMode) {
  long endAddress = (startLow + startHigh*256) + dataLength + 1;

  unsigned char endHigh = endAddress/256;
  unsigned char endLow = endAddress%256;
  
  cartInterface.TransmitByteSlow(startLow);
  cartInterface.TransmitByteSlow(startHigh);
  cartInterface.TransmitByteSlow(transferPages);
  cartInterface.TransmitByteSlow(startLow);
  cartInterface.TransmitByteSlow(startHigh);  
  cartInterface.TransmitByteSlow(endLow);
  cartInterface.TransmitByteSlow(endHigh);  
  cartInterface.TransmitByteSlow(type); 
  cartInterface.TransmitByteSlow(transferMode); //Reserved
  cartInterface.TransmitByteSlow(0); //Reserved
}

void CartApi::TransferMenu() {
  static const unsigned char PROGMEM p_easysd[11] = {'e', 'a', 's', 'y', 's', 'd', '.', 'p', 'r', 'g', 0};
  char easysd[11];

  for (uint8_t i = 0;i<11;i++) {
    easysd[i] = pgm_read_byte(p_easysd+i);
  }

  LOGI(SYS, "TransferMenu");

  cartInterface.EndListening();  
   
  dirFunc.ReInit();
  dirFunc.Prepare();
  
  unsigned char readFromFile = 0;  
  
  if (sd.exists(easysd)) {
    workingFile = sd.open(easysd);
    if (workingFile) {
      LOGI(PRG, "Menu from SD");
      readFromFile = 1;
    } 
  }

  //int menu_data_length = (readFromFile? workingFile.size() : data_len) ;
  int menu_data_length = (readFromFile? workingFile.size() : data_len) ;

  // Phase 1: EXROM LOW only — data bus stays tristate so the cartridge ROML
  // chip (AT28C64B / M27C64A) can present CBM80 ($8004-$8008) undisturbed.
  // ATmega output sinks 40 mA vs chip source 4 mA, so any non-tristate Arduino
  // output overrides the chip and the CBM80 check fails even with it installed.
  cartInterface.EnableExromOnly();
  cartInterface.ResetC64();

  delay(300);  // CBM80 window: cartridge ROML chip drives bus, sets $0318 NMI vector

  // Phase 2: data bus OUTPUT — safe now, NMI handler is already installed
  cartInterface.EnableDataBus();

  unsigned char low;
  unsigned char high;

  if (!readFromFile) {
    low = pgm_read_byte(cartridgeData);
    high = pgm_read_byte(cartridgeData+1);
  } else {
    low = workingFile.read();
    high = workingFile.read();
  }

  long transferLength = menu_data_length - 2;
  long padBytes = (transferLength%256==0) ? 0 : 256 - transferLength%256;
  byte transferPages = (byte)(transferLength/256 + (padBytes>0 ? 1 : 0));

  SendHeader(low, high, transferPages,transferLength, TYPE_MENU, cartInterface.TransferMode); 
  cartInterface.ResetIndex();
  
  #ifdef  USERAMLAUNCHER
  SendLoaderStub();
  #endif

  noInterrupts();
  if (!readFromFile) {
    for (int i=2;i<menu_data_length;i++) {
     unsigned char value = pgm_read_byte(cartridgeData+i);    
     cartInterface.TransmitByteFast(value); 
    }  
  } else {
    for (int i=2;i<menu_data_length;i++) {
     unsigned char value = workingFile.read();   
     cartInterface.TransmitByteFast(value); 
    }     
  }

  if (padBytes>0) {
    for (int i=0;i<padBytes;i++) {    
      cartInterface.TransmitByteFast(0x00); 
    }
  }
  interrupts();
//  #ifdef EASYSD_DEBUG_SERIAL
//  Serial.print(F("CNT:"));Serial.println(dirFunc.GetCount());
//
//  Serial.print(F("PG ITEM CNT:"));Serial.println(CurrentItemsCount);
//  Serial.print(F("PG CNT:"));Serial.println(PageCount);
//
//  TransferInfo(transferLength, padBytes, transferPages);
//  #endif

  delayMicroseconds(30);
  cartInterface.DisableCartridge();

  // ========================================================================
  // Last-directory restore: delayed auto-restore
  // ========================================================================
  // Close the menu source file before restore: keeps SdFat state clean.
  // The file is no longer needed — the menu PRG is now in C64 RAM.
  if (readFromFile && workingFile) workingFile.close();

  // Restore the last saved directory now — before StartListening() activates
  // the command loop — so the first COMMAND_READ_DIR response reflects the
  // saved path. If restore fails for any reason, dirFunc stays at root
  // (safe fallback). The C64 does not need to know about restore — it simply
  // gets the correct directory listing in the first response.
  RestoreLastDir();

  // ========================================================================
  // Now the command loop is ready
  // ========================================================================
  cartInterface.StartListening();
}


void CartApi::LoadAndLaunchFile(const char* selectedFileName) {
  const size_t BUF_SIZE = 16;
  uint8_t buf[BUF_SIZE];  
  cartInterface.EndListening();

  // If a TAP is selected, try to convert it to a PRG on the SD card first.
  // Only standard (KERNAL/CBM) tape blocks are supported.
  if (IsMatchLast(selectedFileName, ".tap") || IsMatchLast(selectedFileName, ".TAP")) {
    char outPrg[64];
    LOGI(PRG, "TAP: converting...");
    uint8_t tapRes = ConvertStandardTapToPrg(sd, selectedFileName, outPrg, sizeof(outPrg));
    if (tapRes == SUCCESSFUL) {
      LOGI(PRG, "TAP->PRG OK");
      // Load the converted PRG immediately
      LoadAndLaunchFile(outPrg);
    } else {
      LOGE(PRG, "TAP FAIL");
      // Go back to menu so the C64 isn't left waiting for a transfer.
      TransferMenu();
    }
    return;
  }

  unsigned char crtFile = 0;
  unsigned char booter = 0;
  uint16_t contentLength = 0;

  workingFile = sd.open(selectedFileName);
  
  if (workingFile ) {
    contentLength = workingFile.size();

    if (strcmp(selectedFileName, "keybooter.prg") == 0 || ( IsMatchLast(selectedFileName, ".irq") || IsMatchLast(selectedFileName, ".IRQ") ) ) {
      booter = 1;
      LOGI(PRG, "BOOTER!");
    }
    if ( IsMatchLast(selectedFileName, ".crt") || IsMatchLast(selectedFileName, ".CRT") ) {
      crtFile = 1;
      LOGI(PRG, "CRT");
    }
    
    if (crtFile) workingFile.seek(80);

    long transferLength = crtFile ? contentLength - 80 : contentLength - 2;
    long padBytes = (transferLength%256==0) ? 0 : 256 - transferLength%256; 
    byte transferPages = (byte)(transferLength/256 + (padBytes>0 ? 1 : 0));
    cartInterface.ResetIndex();
    cartInterface.EnableCartridge();
    cartInterface.ResetC64();
  
    delay(200);
    //delay(500);
    
    int c = 0;
    int index = 0;
    unsigned char low;
    unsigned char high;
    unsigned char data;
    int readCount = 0;
    //TODO : Put input mechanics elsewhere...
    //pressTime = millis();

    uint8_t initialBuff[2];
    if (!crtFile) {
        low = workingFile.read();
        high = workingFile.read();
    } else {
      low = 0;
      high = 0x80;
    }
    
    SendHeader(low, high, transferPages, transferLength, (crtFile ? TYPE_CARTRIDGE : (booter ? TYPE_BOOTER : TYPE_STANDARD_PRG)), cartInterface.TransferMode); 

    #ifdef  USERAMLAUNCHER
    SendLoaderStub();
    #endif

    while(workingFile.available() > 0) {      
      readCount = workingFile.read(buf, sizeof(buf));
  
      if (readCount > 0) {
        for (int i = 0;i<readCount;i++) {     
            cartInterface.TransmitByteFast(buf[i]);
        }
      }
    }        
        
    if (padBytes>0) {
      for (int i=0;i<padBytes;i++) {    
        cartInterface.TransmitByteFast(0x00); 
      }
    }   
    
    delayMicroseconds(30);
    workingFile.close();               // close before chdir — prevents SdFat state corruption
    cartInterface.DisableCartridge();  // EXROM HIGH + data bus tristate — clean state after transfer
    Init();

    cartInterface.StartListening();
    //interrupts();

    LOGI(SYS, "Done");

    } else {
      LOGE(SYS, "FILENOTFOUND!");
    }

    //if (booter)   cartApi.HandleApi();

    //SendTestProgramToSecondaryLoader();
}

#ifdef EASYSD_DEBUG_SERIAL
// Serial communication function - only for DEBUG/development mode
void CartApi::ReceiveFile() {
  long startTransfer = millis();
  cartInterface.EndListening();
  cartInterface.EnableCartridge();
  cartInterface.ResetC64();
  cartInterface.ResetIndex();
  delay(200);
  unsigned int receivedCount = 0;
  unsigned int dataLength = 0;
  unsigned char low = 0;  
  unsigned char high = 0;  
  int endCondition = 0;
  
  while (receivedCount<4) {
    //if ((millis() - startTransfer) > 10000) break;
    if (Serial.available() > 0) {
      if ((millis() - startTransfer) > 20000) break;
      unsigned char data=Serial.read();    
      if (receivedCount == 0) {
        dataLength = data;
      } else if (receivedCount == 1) {
        dataLength = data * 256 + dataLength;
      } else if (receivedCount == 2) {
        low = data;
      } else if (receivedCount == 3) {
        high = data;
      }
      receivedCount++;
    }
  }

  long transferLength = dataLength - 2;
  long padBytes = (transferLength%256==0) ? 0 : 256 - transferLength%256; 
  byte transferPages = (byte)(transferLength/256 + (padBytes>0 ? 1 : 0));  

  cartInterface.ResetIndex();

  SendHeader(low, high, transferPages, transferLength, TYPE_PRG_TRANSMISSION,cartInterface.TransferMode);  //End address is not specifically correct. Should be corrected in IrqHackSend program.
  
  receivedCount = 0;

  cartInterface.ResetIndex();
  #ifdef  USERAMLAUNCHER
  SendLoaderStub();
  #endif
  
  while (receivedCount<transferLength) {
    //if ((millis() - startTransfer) > 10000) break;
    
    if (Serial.available() > 0) {    
      //if ((millis() - startTransfer) > 10000) break;     
      unsigned char data=Serial.read();    
      cartInterface.TransmitByteFast(data); 
      receivedCount++;      
    }
  }
  
  if ((millis() - startTransfer) < 10000) {
    if (padBytes>0) {
      for (int i=0;i<padBytes;i++) {    
        cartInterface.TransmitByteFast(0xEA); 
      }
    }  
  }
  delayMicroseconds(20);
  cartInterface.DisableCartridge();
  cartInterface.StartListening();
}
#endif // EASYSD_DEBUG_SERIAL



#ifdef EASYSD_DEBUG_SERIAL
// Serial communication function - only for DEBUG/development mode
void CartApi::UpdateFile() {
  cartInterface.EndListening();
  const size_t BUF_SIZE = 64;
  uint8_t buf[BUF_SIZE];
  long startTransfer = millis();

  unsigned int receivedCount = 0;
  unsigned int dataLength = 0;

  char fileName[20];

  int readByte = -1;  
  unsigned char fileNameIndex = 0; 

  while (readByte!=0) {
      if ((millis() - startTransfer) > 20000) break;    
      if (Serial.available()>0) {
        readByte = Serial.read();
        fileName[fileNameIndex] = readByte;
        fileNameIndex++;
      }
  }

  while (receivedCount<2) {
    if (Serial.available() > 0) {
      if ((millis() - startTransfer) > 20000) break;
      unsigned char data=Serial.read();    
      if (receivedCount == 0) {
        dataLength = data;
      } else if (receivedCount == 1) {
        dataLength = data * 256 + dataLength;
      } 
      receivedCount++;
    }
  }

  sd.remove(fileName);
    File workingFile = sd.open(fileName, FILE_WRITE | O_CREAT);
    if (workingFile != NULL) {

      receivedCount = 0;
      int bufferIndex = 0;
      int padSize = dataLength % BUF_SIZE;
      while (receivedCount<dataLength) {
        if ((millis() - startTransfer) > 120000) {
          LOGE(FILE, "Timed out");
          break;
        } else {        
          if (Serial.available() > 0) {    
            buf[bufferIndex] = Serial.read();    
            bufferIndex++;
            receivedCount++;      
            if (bufferIndex == BUF_SIZE) {
              workingFile.write(buf, BUF_SIZE);
              bufferIndex = 0;
            }
          }
        }
      }

      if (padSize>0) {
        workingFile.write(buf, padSize);
      }

      workingFile.close();
    } else  {
      LOGE(FILE, "File open failed");
    }  

    cartInterface.StartListening();
}
#endif // EASYSD_DEBUG_SERIAL


void CartApi::ResetNoCartridge() {
  cartInterface.DisableCartridge();
  cartInterface.ResetC64();
}


