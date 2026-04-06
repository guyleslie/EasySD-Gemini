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

// EEPROM layout for last-visited directory persistence:
//   Byte 0: magic 0xE5
//   Byte 1: magic 0xD0
//   Bytes 2..N: null-terminated absolute path (max 63 chars + null = 64 bytes)
// Total used: up to 66 bytes of the ATmega328P's 1 KB internal EEPROM.
#define EEPROM_LASTDIR_MAGIC_0  0xE5
#define EEPROM_LASTDIR_MAGIC_1  0xD0
#define EEPROM_LASTDIR_ADDR     2    // path starts at byte 2

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

void CartApi::SaveLastDir() {
  EEPROM.update(0, EEPROM_LASTDIR_MAGIC_0);
  EEPROM.update(1, EEPROM_LASTDIR_MAGIC_1);
  eeprom_update_block(dirFunc.currentPath, (void*)EEPROM_LASTDIR_ADDR, 64);
}

void CartApi::RestoreLastDir() {
  if (EEPROM.read(0) != EEPROM_LASTDIR_MAGIC_0) return;
  if (EEPROM.read(1) != EEPROM_LASTDIR_MAGIC_1) return;

  char path[64];
  eeprom_read_block(path, (void*)EEPROM_LASTDIR_ADDR, 63);
  path[63] = '\0';

  // Root or invalid: nothing to restore
  if (path[0] != '/' || path[1] == '\0') return;

  // Navigate from root, segment by segment
  char* p = path + 1;  // skip leading '/'
  while (*p) {
    char* slash = strchr(p, '/');
    if (slash) *slash = '\0';
    bool ok = dirFunc.ChangeDirectory(p);
    if (slash) *slash = '/';
    if (!ok) {
      dirFunc.ToRoot();
      return;
    }
    if (!slash) break;
    p = slash + 1;
  }
}

void CartApi::Init() {
  eepromIndex = 0;
  /* Not talking at the moment */
  //TalkStatus = 0;
  cartInterface.SetPage(0);

  dirFunc.ReInit();
  RestoreLastDir();  // navigate to last-visited directory (no-op if EEPROM empty/corrupt)
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
  int streamState;
  cartInterface.ResetIndex();
  noInterrupts();
  cartInterface.SoftEndListening();  

  if (workingFile == NULL) {
      HandleResponse(NOT_INITIALIZED, 0);
  } else if (workingFile.isOpen()) {
    //HandleResponse(SUCCESSFUL, 100);
    HandleResponse(SUCCESSFUL, 1);
    delayMicroseconds(1000);
    while(workingFile.available() > 0 && actualLength<totalLength) {  
      int readCount = workingFile.read(fileBuffer, BUFFER_SIZE);
  
      if (readCount > 0) {
        for (int i = 0;i<readCount;i++) {     
            cartInterface.TransmitByteFastStd(fileBuffer[i]);
        }        
        actualLength = actualLength + readCount;
      }

      delayMicroseconds(100);
    } 
  } else {
    HandleResponse(FILE_IS_NOT_OPENED, 0);
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

  // Support both absolute and relative paths
  // Absolute paths (starting with '/') open from root
  // Relative paths use current directory set by sd.chdir() in DirFunction
  if (fileNameLength == 0) { HandleResponse(INVALID_ARGUMENT, 1); return; }
  char * fileName = (char *) &Arguments[2];

  // Ensure NUL-termination within our buffer
  if (fileNameLength < MAX_ARGUMENTS_LENGTH) {
    fileName[fileNameLength] = 0;
  } else {
    fileName[MAX_ARGUMENTS_LENGTH-1] = 0;
  }

  // SdFat automatically resolves relative paths using current directory
  // set by sd.chdir() (managed by DirFunction class)
  workingFile = sd.open(fileName, flags);

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
  //HandleResponse(SUCCESSFUL, 1000);

  if (workingFile == NULL) {
      LOGE(FILE, "File not initialized");
      //HandleResponse(NOT_INITIALIZED, 100);
      HandleResponse(NOT_INITIALIZED, 1);
  } else if (workingFile.isOpen()) {
    LOGI(FILE, "File closed");
    workingFile.close();
    //HandleResponse(SUCCESSFUL, 100);
    HandleResponse(SUCCESSFUL, 1);
  } else {
    //HandleResponse(FILE_IS_NOT_OPENED, 100);
    HandleResponse(FILE_IS_NOT_OPENED, 1);
  }

}



void CartApi::HandleWriteFile() {
  GetArgumentsStatic(32);
  if (workingFile == NULL) {
      HandleResponse(NOT_INITIALIZED, 0);
  } else if (workingFile.isOpen()) {
    // write() returns size_t (unsigned): 0 on failure, count on success
    size_t bytesWritten = workingFile.write(Arguments, WRITE_BUFFER_SIZE);
    if (bytesWritten == 0 || workingFile.getWriteError()) {
      workingFile.clearWriteError();
      HandleResponse(FILE_WRITE_HAS_FAILED, 0);
    } else if (bytesWritten < WRITE_BUFFER_SIZE) {
      HandleResponse(WRITE_NOT_COMPLETE, 0);
    } else if (!workingFile.sync()) {
      // sync() flushes cache to SD — critical for C64 data integrity
      HandleResponse(FILE_WRITE_HAS_FAILED, 0);
    } else {
      HandleResponse(SUCCESSFUL, 0);
    }
  } else {
    HandleResponse(FILE_IS_NOT_OPENED, 0);
  }
}

void CartApi::HandleDeleteFile() {
  GetArgumentsDynamic(1);
  uint8_t flags = Arguments[0];
  unsigned int fileNameLength = Arguments[1];
  char * fileName = (char *) &Arguments[2];

  // Ensure NUL-termination (same pattern as HandleOpenFile)
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

//TODO: Signed integer support should be added
void CartApi::HandleSeekFile() {
  GetArgumentsStatic(3);
  unsigned int seekDirection = Arguments[0];
  uint8_t low = Arguments[1];
  uint8_t high = Arguments[2];

  unsigned int seekPosition =  (high<<8) | low;
  
  if (workingFile == NULL) {
      HandleResponse(NOT_INITIALIZED, 0);
  } else if (workingFile.isOpen()) {
    bool status = false;
    if (seekDirection == SEEK_FROM_BEGINNING) {
      status = workingFile.seekSet(seekPosition);
    } else if (seekDirection == SEEK_FROM_CURRENT) {
      status = workingFile.seekCur(seekPosition);
    } else if (seekDirection == SEEK_FROM_END) {
      status = workingFile.seekEnd(seekPosition);    
    }

    if (status) {
      HandleResponse(SUCCESSFUL, 1); // Other solution???
    } else {
      HandleResponse(CANT_SEEK, 1);
    }
  } else {
    HandleResponse(FILE_IS_NOT_OPENED, 1);
  }
}


void CartApi::HandleLongSeekFile() {
  GetArgumentsStatic(5);
  unsigned int seekDirection = Arguments[0];
  uint8_t low = Arguments[1];
  uint8_t high = Arguments[2];
  uint8_t upperLow = Arguments[3];
  uint8_t upperHigh = Arguments[4];

  unsigned long seekPosition = (upperHigh<<24) | (upperLow<<16) | (high<<8) | low;
  
  if (workingFile == NULL) {
      HandleResponse(NOT_INITIALIZED, 0);
  } else if (workingFile.isOpen()) {
    bool status = false;
    if (seekDirection == SEEK_FROM_BEGINNING) {
      status = workingFile.seekSet(seekPosition);
    } else if (seekDirection == SEEK_FROM_CURRENT) {
      status = workingFile.seekCur(seekPosition);
    } else if (seekDirection == SEEK_FROM_END) {
      status = workingFile.seekEnd(seekPosition);    
    }

    if (status) {
      HandleResponse(SUCCESSFUL, 0);
    } else {
      HandleResponse(CANT_SEEK, 0);
    }
  } else {
    HandleResponse(FILE_IS_NOT_OPENED, 0);
  }

}


void CartApi::HandleGetInfoForFile() {
  GetArgumentsStatic(0);
  if (workingFile == NULL) {
      HandleResponse(NOT_INITIALIZED, 0);
  } else if (workingFile.isOpen()) {
    DirFat_t dir;  // SdFat 2.x: dir_t renamed to DirFat_t
    if (workingFile.dirEntry(&dir)) {
      HandleResponse(SUCCESSFUL, 1);
      noInterrupts();
      uint8_t * infoBuffer = (uint8_t *) &dir;
      for (uint8_t i = 0; i < 32; i++) {
        cartInterface.TransmitByteFast(*(infoBuffer + i));
      }
      for (uint16_t i = 32; i < 256; i++) {
        cartInterface.TransmitByteFast(0);
      }
      interrupts();
      delayMicroseconds(20);
    } else {
      HandleResponse(FILE_INFO_FAILED, 0);
    }


  } else {
    HandleResponse(FILE_IS_NOT_OPENED, 0);
  }

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

inline void CartApi::HandleReadDirectory() {
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
    //int padValue = (dirFunc.CurrentItemsCount % numberOfEntries) == 0 ? 0 : numberOfEntries - (dirFunc.CurrentItemsCount % numberOfEntries);
    uint8_t pagePadValue = (dirFunc.GetCount() % numberOfEntries) >0 ? 1 : 0;    
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
        if (actualTransferredBytes + 32 <maxBytesToTransfer) {
          // Print the file number and name.
          for (int i=0;(i<dirFunc.CurrentFileName.index) && (i<31);i++) {
//          for (int i=0;(i<dirFunc.CurrentFileName.index) && (i<20);i++) {
            //cartInterface.TransmitByteFast(cbm_ascii2petscii_c(tolower(dirFunc.CurrentFileName.value[i]))); 
            cartInterface.TransmitByteFast(tolower(dirFunc.CurrentFileName.value[i])); 
          }
          
          for (int i=dirFunc.CurrentFileName.index;i<31;i++) {
            cartInterface.TransmitByteFast(0x00);
          }

          if (dirFunc.IsDirectory) {
            cartInterface.TransmitByteFast(0x04);            
          } else {
            cartInterface.TransmitByteFast(0x00);                        
          }
                  
          actualTransferredBytes = actualTransferredBytes +32;        
          
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

  // Use basename-only navigation (Sprint 1: Enhanced error handling)
  bool success = dirFunc.ChangeDirectoryBasename(fileName);

  if (success) {
    dirFunc.Prepare();
    SaveLastDir();
    HandleResponse(SUCCESSFUL, 1);
  } else {
    LOGE(DIR, "CD FAILED");
    HandleResponse(DIR_NOT_FOUND, 1);
  }
}

void CartApi::HandleDeleteDirectory() {
  GetArgumentsDynamic(1);
  uint8_t flags = Arguments[0];
  unsigned int fileNameLength = Arguments[1];
  char * fileName = (char *) &Arguments[2];

  // Ensure NUL-termination
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
  uint8_t flags = Arguments[0];
  unsigned int fileNameLength = Arguments[1];
  char * fileName = (char *) &Arguments[2];

  // Ensure NUL-termination
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

  // Default behavior: acknowledge and then start transfer (will reset C64).
  HandleResponse(SUCCESSFUL, 0);
  TransferGame(fileName);  
}

void CartApi::HandleInvokeWithIndex() {  
/* Not implemented */  
}

void CartApi::HandleValueResponse(uint8_t value) {
  //HandleResponse( (value & 1) | 0x80, 20); //Embed least significant bit of value
  HandleResponse( (value & 1) | 0x80, 1); //Embed least significant bit of value
  //HandleResponse( (value & 0xFE)>>1, 20); //Embed rest of the value
  HandleResponse( (value & 0xFE)>>1, 1); //Embed rest of the value
}

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

void CartApi::HandleSetIO() {
}


void CartApi::HandleSetSource() {
  
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


  if (workingFile == NULL) {
      HandleResponse(NOT_INITIALIZED, 0);
  } else if (workingFile.isOpen()) {
      // No need to assign pointers - they're already initialized to static buffers
      //chunkLength = STREAMING_BUFFER_SIZE / countStreamedBytes;
      workingFile.read(streamingBuffer1, DOUBLE_BUFFER_SIZE);      
      HandleResponse(SUCCESSFUL, 0);         
      
      // Reset state for new stream
      streamBufferIndex = 0;
      usedBuffer = 0;
      currentByte = streamingBuffer1[0]; // Pre-load first byte
      streamBufferIndex = 1;             // Next request will get buffer[1]
      lastStreamRequestTime = millis();  // Initialize timeout timer

      cartInterface.EnableCartridge(); // EXROM LOW: ROML ($8000-$9FFF) = EEPROM, needed for CARTRIDGE_BANK_VALUE reads
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
  } else {
    HandleResponse(FILE_IS_NOT_OPENED, 0);
  }      
}

//void CartApi::HandleNonInterruptedStream() {
//  uint8_t streamingBuffer[NON_INTERRUPTED_BUFFER_SIZE];
//  streamBuffer1 = streamingBuffer;
//
//  streamBufferIndex = 0;
//  #ifdef EASYSD_DEBUG_SERIAL  
//  Serial.println(F("Got HandleNIStream"));
//  #endif    
//  GetArgumentsStatic(1);    
//  uint8_t countOf8Bytes = Arguments[0];  
//  //uint8_t delayBetweenBytes = Arguments[1];    
//
//  if (countOf8Bytes>NON_INTERRUPTED_BUFFER_SIZE/8) {
//    HandleResponse(INVALID_ARGUMENT, 0);
//  } else if (workingFile == NULL) {
//      HandleResponse(NOT_INITIALIZED, 0);
//  } else if (workingFile.isOpen()) {
//      HandleResponse(SUCCESSFUL, 0);   
//
//      //Disable receiving interrupt but keep the state of the communication channel on.
//      cartInterface.SoftEndListening(); 
//
//      //Preload the buffer
//      workingFile.read(streamingBuffer, NON_INTERRUPTED_BUFFER_SIZE);      
//      TIMSK2 = 0; // Disable timer 2 interrupts
//      attachInterrupt(digitalPinToInterrupt(IO2), CartApi::SingleBufferedStreaming, FALLING);               
//
//      while(1) {
//        if (streamBufferIndex == NON_INTERRUPTED_BUFFER_SIZE) {
//          if (streamBufferIndex == NON_INTERRUPTED_BUFFER_SIZE) {
//            if (streamBufferIndex == NON_INTERRUPTED_BUFFER_SIZE) {
//              Serial.println(F("Next"));
//              workingFile.read(streamingBuffer, NON_INTERRUPTED_BUFFER_SIZE);      
//              streamBufferIndex = 0;              
//            }
//          }
//        }
//      } 
//
//      TIMSK2 = 0x02; // Enable timer 2 interrupts (for milliseconds and so on)      
//  } else {
//    HandleResponse(FILE_IS_NOT_OPENED, 0);
//  }      
//}

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
  } else if (workingFile == NULL) {
      HandleResponse(NOT_INITIALIZED, 0);
  } else if (workingFile.isOpen()) {
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
      unsigned long niStartTime;
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
        
        // --- This is the key: Read next data into the buffer we just finished sending ---
        // Since we are outside the inner loop, we can afford a bit more time.
        // C64 is currently busy processing the 400 bytes we just sent.
        interrupts(); // Temporarily re-enable interrupts for SD card stability
        if (currentBuffer == 0) {
            workingFile.read((uint8_t*)streamBuffer1, bufferLength);
            currentBuffer = 1; // Next time we send buffer 2
        } else {
            workingFile.read((uint8_t*)streamBuffer2, bufferLength);
            currentBuffer = 0; // Next time we send buffer 1
        }
        noInterrupts();
      } 

ni_out:
      interrupts();
      TIMSK2 = 0x02; // Enable timer 2 interrupts
      cartInterface.StartListening();
  } else {
    HandleResponse(FILE_IS_NOT_OPENED, 0);
  }      
}



/*
void CartApi::HandleExitToMenu() {
  HandleResponse(SUCCESSFUL, 0);     
  #ifdef EASYSD_DEBUG_SERIAL  
  Serial.println(F("Exiting to menu"));
  #endif     
  cartInterface.EndListening();
  TransferMenu();
}
*/

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
          case COMMAND_SET_SOURCE : HandleSetSource();break;
          case COMMAND_INVOKE_WITH_NAME : HandleInvokeWithName();break;
          case COMMAND_STREAM : HandleStream();break;          
          case COMMAND_NI_STREAM : HandleNonInterruptedStream(); break;
          case COMMAND_READ_NEXT_CHUNK : HandleReadNextChunk(); break;
          case COMMAND_HWTEST : HandleHwTest(); break;
          case COMMAND_EXIT_TO_MENU : TransferMenu();break;            
        }

        //LOGD(PROTO, "Port clear!");

        cartInterface.SetPage(0);
      }
   }  
}  



void TransferInfo(long transferLength, long padBytes, byte transferPages)
{
    (void)transferLength; (void)padBytes; (void)transferPages;
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

/*
byte CurrentPageIndex = 0;
byte Count = 0;
byte CurrentIndex = 0;
unsigned int CurrentItemsCount = 0; //TODO : Throw it away
unsigned int PageCount = 0; //TODO : Throw it away
*/


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

  // Phase 1: EXROM LOW only — data bus stays tristate so EEPROM can present
  // CBM80 ($8004-$8008) undisturbed. ATmega output sinks 40 mA vs EEPROM
  // source 4 mA, so any non-tristate Arduino output overrides the EEPROM and
  // the CBM80 check fails even with the chip installed.
  cartInterface.EnableExromOnly();
  cartInterface.ResetC64();

  delay(300);  // CBM80 window: EEPROM drives bus, sets $0318 NMI vector

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

/*
  unsigned char pagePadValue = (dirFunc.GetCount() % dirFunc.NMax) >0 ? 1 : 0;
  uint8_t currentItemsCount = dirFunc.GetCount()>dirFunc.NMax ? dirFunc.NMax : dirFunc.GetCount(); //TODO: Extemely rubbish... bad design...
  int padValue = (currentItemsCount % dirFunc.NMax) == 0 ? 0 : dirFunc.NMax - (currentItemsCount % dirFunc.NMax);
  PageCount = (byte)(dirFunc.GetCount()/dirFunc.NMax + pagePadValue);    
  CurrentIndex = 0;
  CurrentPageIndex = 0;
 
  

  cartInterface.TransmitByteFast(CurrentItemsCount); 
  
  cartInterface.TransmitByteFast(PageCount); 
  
  cartInterface.TransmitByteFast(CurrentPageIndex); 

  cartInterface.TransmitByteFast(cartInterface.TransferMode);   

  for (int i = 0;i<12;i++)     cartInterface.TransmitByteFast(0); //Fill reserved area
  unsigned int n = 0;
  dirFunc.Rewind();
  //Send initial state of directories.
  while (n<dirFunc.NMax && dirFunc.Iterate()) {   
    if (!dirFunc.IsHidden) {
      #ifdef EASYSD_DEBUG_SERIAL       
      Serial.println(dirFunc.CurrentFileName.value);    
      #endif
      for (int i=0;(i<dirFunc.CurrentFileName.index) && (i<32);i++) {
        cartInterface.TransmitByteFast(cbm_ascii2petscii_c(tolower(dirFunc.CurrentFileName.value[i]))); 
      }      
      
      for (int i=dirFunc.CurrentFileName.index;i<32;i++) {
        cartInterface.TransmitByteFast(0x00);
      }
  
      n++;
    }
  }    

  #ifdef EASYSD_DEBUG_SERIAL 
  Serial.print(F("ITM CNT:")); Serial.println(n);
  #endif

  for (int i = n;i<dirFunc.NMax;i++) {
    for (int j = 0;j<32;j++) {
      cartInterface.TransmitByteFast(0x00); 
    } 
  } 

*/  
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
  //delay(500);
  cartInterface.StartListening();

  if (readFromFile && workingFile) workingFile.close();
}

/*

void CartApi::TransferDirectory(int startIndex) {  
  cartInterface.EndListening();  
  cartInterface.StartListening();      
  cartInterface.EnableCartridge();

  long fileNamesDataLength = 16 + 20 * 32; // 16 byte header + 
  long transferLength = fileNamesDataLength;
  long padBytes = (transferLength%256==0) ? 0 : 256 - transferLength%256;  
  byte transferPages = (byte)(transferLength/256 + (padBytes>0 ? 1 : 0));  

  unsigned char pagePadValue = (dirFunc.GetCount() % dirFunc.NMax) >0 ? 1 : 0;
  CurrentItemsCount = dirFunc.GetCount()-startIndex>dirFunc.NMax ? dirFunc.NMax : dirFunc.GetCount()-startIndex;
  int padValue = (CurrentItemsCount % dirFunc.NMax) == 0 ? 0 : dirFunc.NMax - (CurrentItemsCount % dirFunc.NMax);
  PageCount = (byte)(dirFunc.GetCount()/dirFunc.NMax + pagePadValue);      

  cartInterface.ResetIndex();
  #ifdef EASYSD_DEBUG_SERIAL   
  Serial.println(F("XFER DIR")); 
  Serial.print(F("CNT:"));Serial.println(dirFunc.GetCount());
  Serial.print(F("PP ITEM CNT:"));Serial.println(CurrentItemsCount);
  Serial.print(F("PG CNT:"));Serial.println(PageCount);
  Serial.print(F("CP:"));Serial.println(CurrentPageIndex);  
  #endif

  noInterrupts();
  cartInterface.TransmitByteFast(CurrentItemsCount); 
  
  cartInterface.TransmitByteFast(PageCount); 
  
  cartInterface.TransmitByteFast(CurrentPageIndex); 

  cartInterface.TransmitByteFast(cartInterface.TransferMode);   

  for (int i = 0;i<12;i++)     cartInterface.TransmitByteFast(0); //Fill reserved area
  
  unsigned int n = 0;
  int itemIndex = 0;
  dirFunc.Rewind();
  //Send initial state of directories.
  while (n<255 && itemIndex<dirFunc.NMax && dirFunc.Iterate() && !dirFunc.IsFinished) {  
    if (!dirFunc.IsHidden) {  
      if (n>=CurrentIndex) {
        // Print the file number and name. 
        #ifdef EASYSD_DEBUG_SERIAL         
        Serial.println(dirFunc.CurrentFileName.value);
        #endif
        
        for (int i=0;(i<dirFunc.CurrentFileName.index) && (i<32);i++) {
          cartInterface.TransmitByteFast(cbm_ascii2petscii_c(tolower(dirFunc.CurrentFileName.value[i]))); 
          //TransmitByteFastNew(0x42);
        }
        
        for (int i=dirFunc.CurrentFileName.index;i<32;i++) {
          cartInterface.TransmitByteFast(0x00);
        }
        
        itemIndex++;
      }
      n++;
    } 
  }   

  #ifdef EASYSD_DEBUG_SERIAL   
  Serial.print(F("FL CNT:")); Serial.println(n);
  #endif
  for (int i = itemIndex;i<dirFunc.NMax;i++) {
    for (int j = 0;j<32;j++) {
      cartInterface.TransmitByteFast(0x00); 
    } 
  }  
  
  if (padBytes>0) {
    for (int i=0;i<padBytes;i++) {    
      cartInterface.TransmitByteFast(0xEA); 
    }
  }
  interrupts();
  #ifdef EASYSD_DEBUG_SERIAL   
  TransferInfo(transferLength, padBytes, transferPages);
  #endif
  
  delayMicroseconds(20);
  cartInterface.DisableCartridge();
  #ifdef EASYSD_DEBUG_SERIAL
  Serial.println(F("Done"));    
  #endif
}

void CartApi::TransferDirectoryNext() {
  if (CurrentIndex<dirFunc.GetCount()-dirFunc.NMax) {
    CurrentIndex = CurrentIndex + dirFunc.NMax;
    CurrentPageIndex++;
  }
  
  TransferDirectory(CurrentIndex);
}

void CartApi::TransferDirectoryPrevious() {
  if (CurrentIndex>=dirFunc.NMax) {
    CurrentIndex = CurrentIndex - dirFunc.NMax;
    CurrentPageIndex--;
  }
  
  TransferDirectory(CurrentIndex);  
}

void CartApi::TransferDirectoryCurrent() {
  TransferDirectory(CurrentIndex);  
}

void CartApi::InvokeSelected(int selected, unsigned int args) {
  #ifdef EASYSD_DEBUG_SERIAL   
  Serial.print(F("SEL:"));Serial.println(selected);
  #endif
  unsigned int n = 0;
  unsigned int i = 0;
  dirFunc.Rewind();
  while (n<255 && dirFunc.Iterate()) { 
    i = i + 1; 
    if (!dirFunc.IsFinished && !dirFunc.IsHidden) {  
      #ifdef EASYSD_DEBUG_SERIAL       
      //Serial.print(F("n : "));Serial.println(n);      
      //Serial.print(F("Current page index : "));Serial.println(currentIndex);
      #endif
      if (n>=CurrentIndex) {        
        if (n-CurrentIndex == selected) {
          #ifdef EASYSD_DEBUG_SERIAL 
          Serial.print(F("SEL FL:")); Serial.println(dirFunc.CurrentFileName.value);
          #endif
          if (dirFunc.IsDirectory) {
            #ifdef EASYSD_DEBUG_SERIAL 
            Serial.println(F("DIR!"));
            #endif
            if (!strcmp(dirFunc.CurrentFileName.value, "..")) {
              #ifdef EASYSD_DEBUG_SERIAL
              Serial.println(F("TO ROOT"));
              #endif
              dirFunc.GoBack();
            } else {
              dirFunc.ChangeDirectory(dirFunc.CurrentFileName.value);
            }
            dirFunc.Prepare();
            SaveLastDir();
            CurrentPageIndex = 0;            
            CurrentIndex = 0;
            TransferDirectory(CurrentIndex);
            break;             
          } else {            
            dirFunc.SetSelected(selected);
            TransferGame(dirFunc.CurrentFileName);                                
//            if (IsMatchLast(dirFunc.CurrentFileName.value, ".wav") || IsMatchLast(dirFunc.CurrentFileName.value, ".WAV")) {
//              TransferSound(dirFunc.CurrentFileName.value);
//            } else if (args==0) {
//              TransferGame(dirFunc.CurrentFileName);                    
//            } else {
//              LoadData(args);
//            }
          }
        }       
      }
      n++; 
    } 
  }   
}
*/

void CartApi::TransferGame(StringPrint selectedFile) {
  TransferGame(selectedFile.value);
}

void CartApi::TransferGame(char * selectedFileName) {
  int streamState;  
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
      TransferGame(outPrg);
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
    
    //noInterrupts();
    
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
    cartInterface.DisableCartridge();  // EXROM HIGH + data bus tristate — clean state after transfer
    Init();

    cartInterface.StartListening();
    //interrupts();

    LOGI(SYS, "Done");
    TransferInfo(transferLength, padBytes, transferPages);

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
  TransferInfo(transferLength, padBytes, transferPages);

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


/*
void CartApi::SendTestProgramToSecondaryLoader() {
  #ifdef EASYSD_DEBUG_SERIAL
  Serial.println(F("Loading secondary loader"));
  #endif  

  cartInterface.InitCustomTransfer();
  delay(500);
  
  unsigned long timeRunning = micros();
  for (int i = 0;i<test_data_len;i++) {
    cartInterface.TransmitCustomByteAsync(*(testProgram + i));
  }

  for (int i = test_data_len;i<256;i++) {
      cartInterface.TransmitByteAsync(0x20); 
  }
  unsigned long elapsed = micros() - timeRunning;
  cartInterface.EndCustomTransfer();    
  Serial.print("Done - it took "); Serial.print(elapsed); Serial.println(" microseconds");
}
*/
