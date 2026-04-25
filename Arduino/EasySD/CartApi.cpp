#include <SdFat.h>
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

// Shared SRAM overlay — IO2 streaming, NI streaming, and command argument
// parsing are mutually exclusive at runtime.  Their buffers live in one union
// so only max(128, 400, 130) = 400 bytes are consumed instead of 658.
// Safety: every Handle*() copies Arguments to locals BEFORE touching stream/NI
// buffers, so the overlap never causes data loss.
static union {
  struct {
    volatile uint8_t stream1[DOUBLE_BUFFER_SIZE];
    volatile uint8_t stream2[DOUBLE_BUFFER_SIZE];
  } io2;
  uint8_t ni[NON_INTERRUPTED_BUFFER_SIZE];
  uint8_t args[MAX_ARGUMENTS_LENGTH + 2];
} sharedBuf;
// Pointers initialized to static buffers (safe for ISR)
volatile static uint8_t * streamBuffer1 = sharedBuf.io2.stream1;
volatile static uint8_t * streamBuffer2 = sharedBuf.io2.stream2;
volatile static uint16_t streamBufferIndex;
volatile static unsigned long lastStreamRequestTime = 0;

static uint16_t ReadAndPadBuffer(File &file, uint8_t *buffer, uint16_t length, uint8_t padValue) {
  int readCount = file.read(buffer, length);
  if (readCount < 0) readCount = 0;

  for (uint16_t i = (uint16_t)readCount; i < length; i++) {
    buffer[i] = padValue;
  }

  return (uint16_t)readCount;
}

static bool OpenMenuFromSdRoot(File &outFile) {
  static const char kName0[] PROGMEM = "easysd.prg";
  static const char kName1[] PROGMEM = "EASYSD.PRG";
  static const char * const kNames[] PROGMEM = { kName0, kName1 };
  char buf[12];

  for (uint8_t i = 0; i < 2; i++) {
    strcpy_P(buf, (const char *)pgm_read_ptr(&kNames[i]));
    if (!sd.exists(buf)) continue;
    outFile = sd.open(buf, FILE_READ);
    if (outFile) {
      LOGI(PRG, "Menu from SD");
      return true;
    }
  }

  return false;
}

void CartApi::Init() {
  Arguments = sharedBuf.args;
  m_argsOk = true;
  cartInterface.SetPage(0);

  dirFunc.ReInit();
  dirFunc.Prepare();
}

inline void HandleResponse(unsigned char response, uint16_t waitAfterResponse) {
  #ifdef TEST_TERMINAL_MODE
  Serial.write(response);
  #else
  // Two leading SetPage(0) writes ensure the C64 sees a definite low→non-zero
  // edge on CARTRIDGE_BANK_VALUE before the response byte is latched.
  cartInterface.SetPage(0);
  cartInterface.SetPage(0);
  cartInterface.SetPage(response);
  #endif
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
  // Keep 256-byte page framing deterministic for the C64 receiver.
  cartInterface.ResetIndex();
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
  // Keep 256-byte page framing deterministic for the C64 receiver.
  cartInterface.ResetIndex();
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
    HandleResponse(SUCCESSFUL, 1);
  } else {
    HandleResponse(DIR_NOT_FOUND, 1);
  }
}

void CartApi::HandleReadDirectory() {
  GetArgumentsStatic(3);
  uint8_t numberOfEntries = Arguments[0];
  uint8_t dataLength = Arguments[1];
  uint8_t startPage = Arguments[2];

  LOGI(DIR, "RD");
  LOG_PRINT_F(" pg="); LOG_PRINT(startPage);
  LOG_PRINT_F(" cnt="); LOG_PRINT(dirFunc.GetCount());
  LOG_PRINT_F(" sub="); LOG_PRINTLN(dirFunc.InSubDir);

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


    // Guard against uint8_t underflow: if startingIndex >= count (stale page
    // index from C64), return 0 items instead of wrapping to ~245 which would
    // cause PRINTPAGE to loop hundreds of times and corrupt the C64 stack.
    uint8_t currentItemsCount;
    if (startingIndex >= (uint16_t)dirFunc.GetCount()) {
      currentItemsCount = 0;
    } else if ((uint16_t)dirFunc.GetCount() >= startingIndex + numberOfEntries) {
      currentItemsCount = numberOfEntries;
    } else {
      currentItemsCount = (uint8_t)(dirFunc.GetCount() - startingIndex);
    }
    uint8_t pagePadValue = (dirFunc.GetCount() % numberOfEntries) > 0 ? 1 : 0;
    uint8_t pageCount = (byte)(dirFunc.GetCount()/numberOfEntries + pagePadValue);  
  
    LOG_PRINT_F(" items="); LOG_PRINT(currentItemsCount);
    LOG_PRINT_F(" pages="); LOG_PRINTLN(pageCount);

    cartInterface.ResetIndex();
    #ifndef TEST_TERMINAL_MODE  
    noInterrupts();
    #endif
    
    cartInterface.TransmitByteFast(currentItemsCount);   
    cartInterface.TransmitByteFast(pageCount); 
  
    actualTransferredBytes = 2;
     
    uint8_t curItemIndex = 0;
    // Iterate() now skips hidden files internally, so every returned
    // entry is visible and ready to transmit.
    while (curItemIndex < numberOfEntries && dirFunc.Iterate() && !dirFunc.IsFinished) {
      if (actualTransferredBytes + 32 < maxBytesToTransfer) {
        uint8_t flen = (uint8_t)strlen(dirFunc.currentFileName);
        if (flen > 31) flen = 31;
        for (uint8_t i = 0; i < flen; i++) {
          cartInterface.TransmitByteFast((uint8_t)dirFunc.currentFileName[i]);
        }
        for (uint8_t i = flen; i < 31; i++) {
          cartInterface.TransmitByteFast(0x00);
        }
        cartInterface.TransmitByteFast(dirFunc.IsDirectory ? 0x04 : 0x00);
        actualTransferredBytes += 32;
        curItemIndex++;
      } else {
        break;
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
    LOGE(DIR, "CD: empty name");
    HandleResponse(INVALID_ARGUMENT, 1);
    return;
  }

  char * fileName = (char *) &Arguments[1];

  if (fileNameLength < MAX_ARGUMENTS_LENGTH) {
    fileName[fileNameLength] = '\0';
  } else {
    fileName[MAX_ARGUMENTS_LENGTH - 1] = '\0';
  }

  bool success = dirFunc.ChangeDirectoryBasename(fileName);

  if (success) {
    // Restore the proven post-chdir refresh path: after a successful basename
    // change, rebuild the directory handle/count before the menu asks for the
    // next page. This matches the older stable flow more closely than relying
    // on the deeper ChangeDirectory chain alone.
    dirFunc.Prepare();
    HandleResponse(SUCCESSFUL, 1);
  } else {
    LOGE(DIR, "CD FAIL");
    HandleResponse(DIR_NOT_FOUND, 1);
  }
}

void CartApi::HandleChangeDirectoryIndex() {
  GetArgumentsStatic(2);

  const uint8_t pageIndex = Arguments[0];
  const uint8_t rowIndex = Arguments[1];

  LOGI(DIR, "CDI");
  LOG_PRINT_F(" pg="); LOG_PRINT(pageIndex);
  LOG_PRINT_F(" row="); LOG_PRINT(rowIndex);
  LOG_PRINT_F(" cnt="); LOG_PRINT(dirFunc.GetCount());
  LOG_PRINT_F(" sub="); LOG_PRINTLN(dirFunc.InSubDir);

  if (rowIndex >= 21) {
    LOGE(DIR, "CDI row>=21");
    HandleResponse(INVALID_ARGUMENT, 1);
    return;
  }

  const uint16_t visibleIndex = static_cast<uint16_t>(pageIndex) * 21u + rowIndex;

  // Two-step process to avoid stack overflow: FindDirectoryNameByVisibleIndex
  // has a local File object (~32B); calling ChangeDirectoryBasename from within
  // it would keep that object on the stack during the deep ChangeDirectory →
  // sd.chdir → ResyncDirFromCwd → CountEntries chain (~280B total).  By
  // splitting, the File is released before the chdir chain starts.
  char* selectedName = reinterpret_cast<char*>(&Arguments[2]);
  const size_t selectedNameSize = MAX_ARGUMENTS_LENGTH;

  bool success = dirFunc.FindDirectoryNameByVisibleIndex(
      visibleIndex, selectedName, selectedNameSize);
  if (success) {
    success = dirFunc.ChangeDirectoryBasename(selectedName);
  }

  if (success) {
    LOGI(DIR, "CDI OK: ");
    LOG_PRINTLN(dirFunc.currentPath);
    HandleResponse(SUCCESSFUL, 1);
  } else {
    LOGE(DIR, "CDI FAIL");
    LOG_PRINT_F(" vis="); LOG_PRINTLN(visibleIndex);
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
// HELPER FUNCTIONS: File matching
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

// ============================================================================
// CartApi PUBLIC METHODS
// ============================================================================

void CartApi::HandleInvokeWithName() {
  GetArgumentsDynamic(1);
  unsigned int fileNameLength = Arguments[1];
  char * fileName = (char *) &Arguments[2];
  char savedPath[64];
  bool restoreCwd = false;

  // NUL-terminate the received filename (GetArgumentsDynamic does not do this).
  Arguments[2 + fileNameLength] = '\0';

  // For absolute paths (e.g. "/PLUGINS/PRGPLUGIN.PRG"), the target file is NOT
  // in the current CWD — temporarily navigate to the parent directory, open by
  // basename, then restore CWD afterwards.  Same pattern as HandleOpenFile.
  const char* openName = fileName;
  if (fileName[0] == '/') {
    const char* lastSlash = strrchr(fileName, '/');
    if (lastSlash == NULL || lastSlash[1] == '\0') {
      HandleResponse(INVALID_ARGUMENT, 0);
      return;
    }

    strncpy(savedPath, dirFunc.currentPath, sizeof(savedPath) - 1);
    savedPath[sizeof(savedPath) - 1] = '\0';
    openName = lastSlash + 1;
    restoreCwd = true;

    if (lastSlash == fileName) {
      // Parent is root "/"
      if (strcmp(savedPath, "/") != 0 && !dirFunc.NavigateToPath("/")) {
        HandleResponse(DIR_NOT_FOUND, 0);
        return;
      }
    } else {
      // Temporarily NUL-terminate to get parent path, then restore
      *const_cast<char*>(lastSlash) = '\0';
      bool navOk = dirFunc.NavigateToPath(fileName);
      *const_cast<char*>(lastSlash) = '/';
      if (!navOk) {
        HandleResponse(DIR_NOT_FOUND, 0);
        return;
      }
    }
  }

  // Verify file exists before committing to C64 — once SUCCESSFUL is sent,
  // C64 expects a reset; if the file is missing we cannot send an error after.
  // The C64 protocol sends at most 31 chars per filename. For files with names
  // longer than 31 chars the received name is a truncated prefix. When
  // sd.exists() fails, scan the CWD using SdFat's getName() to find the full
  // LFN that starts with the received prefix (case-insensitive).
  if (!sd.exists(openName)) {
    static char matchBuf[64];
    uint8_t len = strlen(openName);
    if (!dirFunc.FindByPrefix(openName, len, matchBuf, sizeof(matchBuf))) {
      if (restoreCwd) dirFunc.NavigateToPath(savedPath);
      HandleResponse(FILE_NOT_FOUND, 0);
      return;
    }
    openName = matchBuf;
  }

  // Restore CWD before launch — LoadAndLaunchFile needs the game directory
  // as CWD (not /PLUGINS/) so that preserveLaunchPath captures the right path.
  if (restoreCwd) {
    dirFunc.NavigateToPath(savedPath);
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

void CartApi::HandleEndTalking() {
  // End session cleanly: hide cartridge and reset receiver state.
  cartInterface.DisableCartridge();
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

  // IO2 stream uses the shared static backing storage via streamBuffer1/2.
  // The buffers are never active at the same time as NI streaming.

  GetArgumentsStatic(3);
  uint8_t initialDelay = Arguments[0];
  uint8_t countStreamedBytes = Arguments[1];
  uint8_t delayBetweenBytes = Arguments[2];


  if (!workingFile.isOpen()) {
    HandleResponse(FILE_IS_NOT_OPENED, 0);
  } else {
      ReadAndPadBuffer(workingFile, (uint8_t*)streamBuffer1, DOUBLE_BUFFER_SIZE, 0x00);
      ReadAndPadBuffer(workingFile, (uint8_t*)streamBuffer2, DOUBLE_BUFFER_SIZE, 0x00);
      HandleResponse(SUCCESSFUL, 0);
      
      // Reset state for new stream
      streamBufferIndex = 0;
      usedBuffer = 0;
      currentByte = streamBuffer1[0];    // Pre-load first byte
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
          if (millis() - lastStreamRequestTime > STREAM_TIMEOUT_MS) goto out; // Timeout check
        }
        ReadAndPadBuffer(workingFile, (uint8_t*)streamBuffer1, DOUBLE_BUFFER_SIZE, 0x00);
        while(usedBuffer == 1) {
          if (millis() - lastStreamRequestTime > STREAM_TIMEOUT_MS) goto out; // Timeout check
        }
        ReadAndPadBuffer(workingFile, (uint8_t*)streamBuffer2, DOUBLE_BUFFER_SIZE, 0x00);
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
  // Busy-loop guard while global interrupts are disabled. If IO2 gets stuck
  // high/low (noise or aborted transfer), we must escape instead of wedging.
  const uint16_t IO2_EDGE_TIMEOUT_LOOPS = 0xFFFF;
  
  GetArgumentsStatic(1);
  if (!m_argsOk) return;
  uint8_t countOf8Bytes = Arguments[0];  

  if (countOf8Bytes > NON_INTERRUPTED_BUFFER_SIZE / 8) {
    HandleResponse(INVALID_ARGUMENT, 0);
  } else if (!workingFile.isOpen()) {
    HandleResponse(FILE_IS_NOT_OPENED, 0);
  } else {
      HandleResponse(SUCCESSFUL, 0);

      // Disable receiving interrupt but keep the state of the communication channel on.
      cartInterface.SoftEndListening(); 
      bufferLength = countOf8Bytes * 8;
      bool stopAfterCurrentBuffer = ReadAndPadBuffer(workingFile, sharedBuf.ni, bufferLength, 0x00) < bufferLength;
      
      TIMSK2 = 0; // Disable timer 2 interrupts (millis etc.) for maximum timing precision

      noInterrupts();
      uint8_t portDVal = (PORTD & 0x0F);
      uint8_t portCVal = (PORTC & 0xF0);

      while(1) {
        for (bufferIndex = 0; bufferIndex < bufferLength; bufferIndex++) {
            /* Synchronization block for each byte */
            // Note: We don't use millis() inside the inner loop for speed.
            // If IO2 stops toggling, the loop counter below aborts the stream.
            uint16_t waitLoops = 0;

            while (PIND & 0x08) {
               if (++waitLoops == IO2_EDGE_TIMEOUT_LOOPS) goto ni_out;
            }
            waitLoops = 0;
            while ((PIND & 0x08) == 0) {
              if (++waitLoops == IO2_EDGE_TIMEOUT_LOOPS) goto ni_out;
            }  // Wait for rising edge
            
            uint8_t val = sharedBuf.ni[bufferIndex];
            PORTD = portDVal | (val & 0xF0);
            PORTC = portCVal | (val & 0x0F);            
        }   

        if (stopAfterCurrentBuffer) goto ni_out;
        
        // --- Refill the buffer we just finished sending ---
        // C64 is currently busy processing the 400 bytes we just sent.
        // interrupts() re-enabled here for SD card stability.
        // EOF check: if read() returns 0 the file is exhausted — exit cleanly.
        // The C64 detects end-of-stream via its CVD_SIZE frame counter and will
        // call PROT_StartTalking to re-establish the session after this exit.
        interrupts();
        stopAfterCurrentBuffer = ReadAndPadBuffer(workingFile, sharedBuf.ni, bufferLength, 0x00) < bufferLength;
        noInterrupts();
      } 

ni_out:
      interrupts();
      TIMSK2 = 0x02; // Enable timer 2 interrupts
      cartInterface.DisableCartridge(); // Always return to BASIC-safe bus state
      cartInterface.StartListening();
  }
}




int16_t CartApi::AwaitByte(uint16_t timeoutMs) {
  unsigned long startMs = millis();
  int16_t value;
  do {
    value = cartInterface.Read();
    if (value >= 0) return value;
  } while ((unsigned long)(millis() - startMs) < timeoutMs);

  LOGE(SYS, "AW timeout");
  return -1;
}


int16_t CartApi::GetByte() {
  return cartInterface.Read();
}

// Argument length is known beforehand. Sets m_argsOk = false on timeout.
void CartApi::GetArgumentsStatic(int16_t argumentsLength) {
  m_argsOk = true;
  for (int16_t i = 0; i < argumentsLength; i++) {
    int16_t value = AwaitByte(ARGS_TIMEOUT_MS);
    if (value >= 0) {
      Arguments[i] = value;
    } else {
      // Timeout: zero-fill remaining args and flag error
      for (; i < argumentsLength; i++) Arguments[i] = 0;
      m_argsOk = false;
      return;
    }
  }
}

// Initial N argument count is known. Remaining length is sent in-band.
// Sets m_argsOk = false on timeout at any stage.
void CartApi::GetArgumentsDynamic(int16_t argumentsLength) {
  GetArgumentsStatic(argumentsLength);
  if (!m_argsOk) return;

  int16_t dynamicLength = AwaitByte(ARGS_TIMEOUT_MS);
  if (dynamicLength == -1 || dynamicLength > (MAX_ARGUMENTS_LENGTH - 1)) {
    m_argsOk = false;
    return;
  }

  Arguments[argumentsLength] = dynamicLength;

  for (int16_t i = 1; i <= dynamicLength; i++) {
    int16_t value = AwaitByte(ARGS_TIMEOUT_MS);
    if (value == -1) {
      m_argsOk = false;
      return;
    }
    Arguments[i + argumentsLength] = value;
  }
}


void CartApi::HandleApi() {  
  static unsigned long lastSessionActivityMs = 0;
  static bool sessionSawCommand = false;
  uint8_t state = cartInterface.ReceiveHandler();

  if (state == IN_TRANSMISSION) {    
      if (lastSessionActivityMs == 0) {
        lastSessionActivityMs = millis();
        sessionSawCommand = false;
      }

      int16_t command = GetByte();
      if (command>=0) {
        lastSessionActivityMs = millis();
        sessionSawCommand = true;
        m_argsOk = true;  // assume OK; GetArguments* will clear on timeout
        cartInterface.SetPage(0);

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
          case COMMAND_CHANGE_DIR_INDEX : HandleChangeDirectoryIndex(); break;
          case COMMAND_DELETE_DIR : HandleDeleteDirectory(); break;
          case COMMAND_CREATE_DIR : HandleCreateDirectory(); break;      
          case COMMAND_END_TALKING : HandleEndTalking(); break;
          case COMMAND_INVOKE_WITH_NAME : HandleInvokeWithName();break;
          case COMMAND_STREAM : HandleStream();break;          
          case COMMAND_NI_STREAM : HandleNonInterruptedStream(); break;
          case COMMAND_READ_NEXT_CHUNK : HandleReadNextChunk(); break;
          case COMMAND_HWTEST : HandleHwTest(); break;
          case COMMAND_EXIT_TO_MENU : TransferMenu();break;            
          default:
            // False-positive handshake or line noise can inject random command
            // bytes. Drop session immediately so we don't block the main loop.
            LOGE(SYS, "Unknown cmd");
            cartInterface.DisableCartridge();
            cartInterface.ResetReceive();
            lastSessionActivityMs = 0;
            sessionSawCommand = false;
            return;
        }

        // If a handler timed out reading arguments, the C64 is likely dead
        // or sent a partial command. Reset receive state so the next
        // PROT_StartTalking can re-establish a session cleanly.
        if (!m_argsOk) {
          LOGE(SYS, "Cmd timeout, reset recv");
          cartInterface.DisableCartridge();
          cartInterface.ResetReceive();
          lastSessionActivityMs = 0;
          sessionSawCommand = false;
          return;
        }

        cartInterface.SetPage(0);
      } else {
        // Only reap sessions that never delivered a single command byte.
        // The EasySD menu intentionally keeps one long-lived session open
        // while the user navigates, so resetting an otherwise healthy idle
        // menu session causes the slow-navigation lockups seen on hardware.
        if (!sessionSawCommand &&
            (unsigned long)(millis() - lastSessionActivityMs) > 250UL) {
          LOGE(SYS, "Session pre-cmd reset");
          cartInterface.DisableCartridge();
          cartInterface.ResetReceive();
          lastSessionActivityMs = 0;
          sessionSawCommand = false;
        }
      }
   } else {
      lastSessionActivityMs = 0;
      sessionSawCommand = false;
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
  LOGI(SYS, "TransferMenu");

  cartInterface.EndListening();

  if (workingFile && workingFile.isOpen()) {
    workingFile.close();
  }
  dirFunc.ReInit();
  
  unsigned char readFromFile = 0;  
  
  if (OpenMenuFromSdRoot(workingFile)) {
    readFromFile = 1;
  }

  //int menu_data_length = (readFromFile? workingFile.size() : data_len) ;
  int menu_data_length = (readFromFile? workingFile.size() : data_len) ;

  // Phase 1: EXROM LOW only — data bus stays tristate so the cartridge ROML
  // chip (AT28C64B / M27C64A) can present CBM80 ($8004-$8008) undisturbed.
  // ATmega output sinks 40 mA vs chip source 4 mA, so any non-tristate Arduino
  // output overrides the chip and the CBM80 check fails even with it installed.
  cartInterface.EnableExromOnly();
  // ResetC64() = ResetLow(1ms) + ResetHigh(). The C64 was running BASIC (cold
  // boot default or long-press reset) or the menu/loaded program (subsequent calls).
  // /RESET HIGH → C64 starts → ROML chip presents CBM80 → NMI vector installed.
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

  // Close the menu source file: keeps SdFat state clean.
  // The file is no longer needed — the menu PRG is now in C64 RAM.
  if (readFromFile && workingFile) workingFile.close();

  // Wait until the reset/menu boot sequence has produced a stable PHI2 clock
  // again before accepting a fresh IO2 protocol session from the C64.
  cartInterface.WaitForStablePhi2(32, 250);
  delay(20);
  cartInterface.StartListening();
}


void CartApi::LoadAndLaunchFile(const char* selectedFileName) {
  const size_t BUF_SIZE = 16;
  uint8_t buf[BUF_SIZE];
  char launchPath[64];
  const bool preserveLaunchPath = (dirFunc.pathDepth > 0);
  cartInterface.EndListening();

  // Preserve the launch directory for any subdir launch — MultiLoad's
  // EASYLOAD.PRG needs it for level-loading, and ordinary subdir PRGs are
  // harmless to preserve (SEL/TransferMenu calls ReInit → root anyway).
  if (preserveLaunchPath) {
    strncpy(launchPath, dirFunc.currentPath, sizeof(launchPath) - 1);
    launchPath[sizeof(launchPath) - 1] = '\0';
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
    
    // Timing-critical PRG transfer path:
    // keep global interrupts disabled so UART TX/RX ISRs (serial logging) cannot
    // jitter NMI byte pacing and break real-hardware burst transfers.
    noInterrupts();
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
    interrupts();
    
    delayMicroseconds(30);
    workingFile.close();               // close before chdir — prevents SdFat state corruption
    cartInterface.DisableCartridge();  // EXROM HIGH + data bus tristate — clean state after transfer
    Init();
    if (preserveLaunchPath) {
      dirFunc.NavigateToPath(launchPath);
    }

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
  cartInterface.ReleaseToBasic(true);
}


