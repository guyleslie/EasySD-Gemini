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
    if (!sd.exists(buf)) { LOGE(SYS, "No SD menu file"); continue; }
    outFile = sd.open(buf, FILE_READ);
    if (outFile) {
      return true;
    }
    LOGE(SYS, "SD menu open fail");
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
  // Two leading SetPage(0) writes ensure the C64 sees a definite low→non-zero
  // edge on CARTRIDGE_BANK_VALUE before the response byte is latched.
  cartInterface.SetPage(0);
  cartInterface.SetPage(0);
  cartInterface.SetPage(response);
  if (waitAfterResponse!=0) delay(waitAfterResponse);
}

#define BUFFER_SIZE 16
void CartApi::HandleReadFile() {
  uint8_t fileBuffer[BUFFER_SIZE];
  GetArgumentsStatic(1);
  unsigned int dataLength = Arguments[0];
  unsigned int totalLength = dataLength*256;
  unsigned int actualLength = 0;
  unsigned int padLength = 0;
  bool readShort = false;
  bool readStalled = false;
  bool fileOpen = workingFile.isOpen();

  LOG_LOAD_READ_BEGIN(dataLength);
  cartInterface.ResetIndex();
  noInterrupts();
  cartInterface.SoftEndListening();

  if (!fileOpen) {
    HandleResponse(FILE_IS_NOT_OPENED, 0);
  } else {
    HandleResponse(SUCCESSFUL, 1);
    delayMicroseconds(1000);
    while (actualLength < totalLength) {
      if (workingFile.available() <= 0) {
        readShort = true;
        break;
      }

      unsigned int remaining = totalLength - actualLength;
      uint8_t toRead = (remaining < BUFFER_SIZE) ? (uint8_t)remaining : BUFFER_SIZE;
      // SdFat 1.x's millis()-based timeouts (waitNotBusy / readData) freeze
      // under noInterrupts(), so cache-miss SD reads can fail spuriously.
      // The C64's RL_RECEIVE_WAIT_STUB has a ~0.5 s window per page transfer,
      // so the few-ms SPI pause between bytes is harmless.
      interrupts();
      int readCount = workingFile.read(fileBuffer, toRead);
      noInterrupts();
      if (readCount <= 0) {
        readStalled = true;
        break;
      }

      for (int i = 0; i < readCount; i++) {
        cartInterface.TransmitByteFastStd(fileBuffer[i]);
      }
      actualLength += readCount;
      delayMicroseconds(100);
    }

    padLength = totalLength - actualLength;
    for (unsigned int i = 0; i < padLength; i++) {
      cartInterface.TransmitByteFast(0);
    }
  }

  interrupts();
  cartInterface.SoftStartListening();

  if (!fileOpen) {
    LOG_LOAD_READ_NO_FILE();
    return;
  }

  if (readStalled) {
    LOG_LOAD_READ_STALL(dataLength, actualLength, padLength);
    if (workingFile && workingFile.isOpen()) {
      workingFile.close();
    }
  } else if (readShort) {
    LOG_LOAD_READ_EOF(dataLength, actualLength, padLength);
  } else {
    LOG_LOAD_READ_OK(dataLength, actualLength, padLength);
  }
}

void CartApi::HandleOpenFile() {
  GetArgumentsDynamic(1);
  uint8_t protocolFlags = Arguments[0];
  unsigned int fileNameLength = Arguments[1];

  // Protocol historically uses SdFat 1.x flag values: 1=O_READ, 2=O_WRITE.
  // SdFat 2.x changed those bits: O_RDONLY=0, O_WRONLY=1, O_RDWR=2.
  // Without translation, raw 1 from C64 opens write-only → read() always fails.
  uint8_t flags;
  bool wantRead  = (protocolFlags & 0x01) != 0;
  bool wantWrite = (protocolFlags & 0x02) != 0;
  if (wantRead && wantWrite)      flags = O_RDWR | O_CREAT;
  else if (wantWrite)             flags = O_WRONLY | O_CREAT;
  else                            flags = O_RDONLY;

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
  // Reuse NI-buffer tail (bytes 130–193) instead of a local array — saves 64B of
  // stack.  ni[130+] is never active during command dispatch; args occupies only
  // ni[0..129].  All callers of HandleOpenFile are serialised (no re-entrancy).
  char* savedPath = reinterpret_cast<char*>(sharedBuf.ni + 130);

  // SdFat 2.x absolute LFN paths are unreliable. For absolute paths, temporarily
  // switch the CWD to the parent directory, open the basename, then restore CWD.
  if (fileName[0] == '/') {
    char* lastSlash = strrchr(fileName, '/');
    if (lastSlash == NULL || lastSlash[1] == '\0') {
      HandleResponse(INVALID_ARGUMENT, 1);
      return;
    }

    strncpy(savedPath, dirFunc.currentPath, 63);
    savedPath[63] = '\0';
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

  // Resolve LFN→SFN if the file already exists.  SdFat 2.x sd.open() can
  // fail for LFN names with spaces/lowercase even when the file is on disk;
  // opening by SFN is reliable.  If FindFileSFN returns false the file does
  // not exist yet — the original name is kept so O_CREAT paths can write a
  // brand-new file under its user-chosen LFN.
  static char sfnBuf[16];
  if (dirFunc.FindFileSFN(openName, (uint8_t)strlen(openName), sfnBuf, sizeof(sfnBuf))) {
    openName = sfnBuf;
  }

  LOG_LOAD_OPEN(openName);
  workingFile = sd.open(openName, flags);

  if (restoreCwd && strcmp(savedPath, dirFunc.currentPath) != 0) {
    if (!dirFunc.NavigateToPath(savedPath)) {
      LOGE(DIR, "Restore CWD FAIL");
      dirFunc.ToRoot();
    }
  }

  if (workingFile != NULL) {
    LOGI(FILE, "File opened successfully");
    LOG_LOAD_OPEN_OK();
    HandleResponse(SUCCESSFUL, 1);
  } else  {
    LOGE(FILE, "File open failed");
    LOG_LOAD_OPEN_FAIL();
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
  LOG_LOAD_CLOSE();
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

  // Resolve LFN→SFN so sd.remove() works for files with spaces/lowercase.
  // sd.exists check is folded into the resolver: no match means no file.
  static char sfnBuf[16];
  if (!dirFunc.FindFileSFN(fileName, (uint8_t)strlen(fileName),
                           sfnBuf, sizeof(sfnBuf))) {
    HandleResponse(FILE_NOT_FOUND, 0);
    return;
  }
  if (sd.remove(sfnBuf)) {
    HandleResponse(SUCCESSFUL, 0);
  } else {
    HandleResponse(FILE_DELETION_FAILED, 0);
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
    LOG_LOAD_INFO_NO_FILE();
    HandleResponse(FILE_IS_NOT_OPENED, 0);
    return;
  }
  // Use fileSize() — value is cached by sd.open(), no SPI access.
  // dirEntry() re-reads the directory sector via SPI and hangs in this context
  // (confirmed: BUG-F). All callers (#GETFILEINFO) only need bytes 28-31 (size).
  uint32_t sz = workingFile.fileSize();
  LOG_LOAD_INFO_SIZE(sz);
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
    noInterrupts();
    
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

    interrupts();
     
    delayMicroseconds(20);
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

  // Resolve LFN→SFN so sd.rmdir() works for dirs with spaces/lowercase.
  static char sfnBuf[16];
  if (!dirFunc.FindDirSFN(fileName, (uint8_t)strlen(fileName),
                          sfnBuf, sizeof(sfnBuf))) {
    HandleResponse(DIR_NOT_FOUND, 0);
    return;
  }
  if (sd.rmdir(sfnBuf)) {
    HandleResponse(SUCCESSFUL, 0);
  } else {
    HandleResponse(DIR_DELETION_FAILED, 0);
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

static bool EndsWithIgnoreCase(const char* value, const char* suffix) {
  size_t valueLen = strlen(value);
  size_t suffixLen = strlen(suffix);
  if (valueLen < suffixLen) return false;

  value += valueLen - suffixLen;
  for (size_t i = 0; i < suffixLen; i++) {
    char a = value[i];
    char b = suffix[i];
    if (a >= 'A' && a <= 'Z') a = a - 'A' + 'a';
    if (b >= 'A' && b <= 'Z') b = b - 'A' + 'a';
    if (a != b) return false;
  }
  return true;
}

static void SendHeaderToAddress(uint8_t launchLow, uint8_t launchHigh,
                                uint8_t actualLow, uint8_t actualHigh,
                                uint8_t transferPages, long dataLength,
                                uint8_t type, uint8_t transferMode) {
  long endAddress = (actualLow + actualHigh * 256L) + dataLength + 1;
  uint8_t endHigh = endAddress / 256;
  uint8_t endLow = endAddress % 256;

  cartInterface.TransmitByteSlow(launchLow);
  cartInterface.TransmitByteSlow(launchHigh);
  cartInterface.TransmitByteSlow(transferPages);
  cartInterface.TransmitByteSlow(actualLow);
  cartInterface.TransmitByteSlow(actualHigh);
  cartInterface.TransmitByteSlow(endLow);
  cartInterface.TransmitByteSlow(endHigh);
  cartInterface.TransmitByteSlow(type);
  cartInterface.TransmitByteSlow(transferMode);
  cartInterface.TransmitByteSlow(0);
}

static bool RestorePathIfProvided(const char* returnPath) {
  if (returnPath == NULL || returnPath[0] == '\0') {
    return true;
  }
  return dirFunc.NavigateToPath(returnPath);
}

// Leaves interrupts disabled so cartridge writes can be chained without a gap.
static bool TransmitFileBytes(File& file, uint32_t byteCount, uint8_t* buf, uint8_t bufSize) {
  bool readOk = true;

  while (byteCount > 0) {
    uint8_t want = byteCount > bufSize ? bufSize : (uint8_t)byteCount;
    interrupts();
    int readCount = file.read(buf, want);
    noInterrupts();
    if (readCount <= 0) {
      readCount = 0;
      readOk = false;
    }

    for (int i = 0; i < readCount; i++) {
      cartInterface.TransmitByteFast(buf[i]);
    }
    for (uint8_t i = readCount; i < want; i++) {
      cartInterface.TransmitByteFast(0x00);
    }
    byteCount -= want;
  }

  return readOk;
}

static void TransmitMemoryBytes(const uint8_t* data, uint16_t byteCount) {
  for (uint16_t i = 0; i < byteCount; i++) {
    cartInterface.TransmitByteFast(data[i]);
  }
}

static void TransmitZeroBytes(uint32_t byteCount) {
  while (byteCount-- > 0) {
    cartInterface.TransmitByteFast(0x00);
  }
}

// ============================================================================
// CartApi PUBLIC METHODS
// ============================================================================

void CartApi::HandleKoalaInvoke(char* mediaPath, const char* returnPath) {
  const uint16_t KOA_LOAD_ADDR = 0x2000;
  const uint16_t KOA_PAYLOAD_SIZE = 10001;
  const uint16_t KOA_PLUGIN_ADDR = 0xC000;
  const uint32_t KOA_GAP_SIZE = (uint32_t)KOA_PLUGIN_ADDR - KOA_LOAD_ADDR - KOA_PAYLOAD_SIZE;
  const uint16_t KOA_PLUGIN_BUFFER_OFFSET = 194;
  const uint16_t KOA_PLUGIN_PAYLOAD_MAX = NON_INTERRUPTED_BUFFER_SIZE - KOA_PLUGIN_BUFFER_OFFSET;
  const size_t BUF_SIZE = 16;
  uint8_t buf[BUF_SIZE];
  uint8_t* pluginPayload = sharedBuf.ni + KOA_PLUGIN_BUFFER_OFFSET;
  File pluginFile;

  if (workingFile && workingFile.isOpen()) {
    workingFile.close();
  }

  // HandleInvokeWithName has already moved CWD to the media file's parent and
  // resolved the same basename/prefix form that regular PRG launch uses.
  workingFile = sd.open(mediaPath, FILE_READ);
  if (!workingFile) {
    LOGE(SYS, "KOA media open");
    RestorePathIfProvided(returnPath);
    HandleResponse(FILE_NOT_FOUND, 0);
    return;
  }

  uint32_t mediaSize = workingFile.size();
  uint16_t mediaSkip = 0;
  if (mediaSize == 10003UL) {
    mediaSkip = 2;
  } else if (mediaSize != KOA_PAYLOAD_SIZE) {
    LOGE(SYS, "KOA media bad");
    workingFile.close();
    RestorePathIfProvided(returnPath);
    HandleResponse(INVALID_CONTENT, 0);
    return;
  }

  if (mediaSkip != 0 && !workingFile.seek(mediaSkip)) {
    LOGE(SYS, "KOA media seek");
    workingFile.close();
    RestorePathIfProvided(returnPath);
    HandleResponse(CANT_SEEK, 0);
    return;
  }

  pluginFile = sd.open("/PLUGINS/KOAPLUGIN.PRG", FILE_READ);
  if (!pluginFile) {
    LOGE(SYS, "KOA plugin missing");
    workingFile.close();
    RestorePathIfProvided(returnPath);
    HandleResponse(FILE_NOT_FOUND, 0);
    return;
  }

  uint32_t pluginSize = pluginFile.size();
  if (pluginSize <= 2 || pluginSize - 2 > KOA_PLUGIN_PAYLOAD_MAX) {
    LOGE(SYS, "KOA plugin size");
    pluginFile.close();
    workingFile.close();
    RestorePathIfProvided(returnPath);
    HandleResponse(INVALID_CONTENT, 0);
    return;
  }

  uint8_t pluginLow = pluginFile.read();
  uint8_t pluginHigh = pluginFile.read();
  if (pluginLow != 0x00 || pluginHigh != 0xC0) {
    LOGE(SYS, "KOA plugin addr");
    pluginFile.close();
    workingFile.close();
    RestorePathIfProvided(returnPath);
    HandleResponse(INVALID_CONTENT, 0);
    return;
  }

  uint16_t pluginPayloadSize = (uint16_t)(pluginSize - 2);
  int pluginRead = pluginFile.read(pluginPayload, pluginPayloadSize);
  pluginFile.close();
  if (pluginRead != (int)pluginPayloadSize) {
    LOGE(SYS, "KOA plugin read");
    workingFile.close();
    RestorePathIfProvided(returnPath);
    HandleResponse(INVALID_CONTENT, 0);
    return;
  }

  long transferLength = (long)((uint32_t)KOA_PLUGIN_ADDR - KOA_LOAD_ADDR + pluginPayloadSize);
  long padBytes = (transferLength % 256 == 0) ? 0 : 256 - (transferLength % 256);
  byte transferPages = (byte)(transferLength / 256 + (padBytes > 0 ? 1 : 0));

  LOGI(SYS, "KOA transfer");
  HandleResponse(SUCCESSFUL, 0);
  cartInterface.EndListening();
  cartInterface.ResetIndex();
  cartInterface.EnableCartridge();
  cartInterface.ResetC64();
  delay(200);

  noInterrupts();
  SendHeaderToAddress(0x00, 0xC0, 0x00, 0x20, transferPages, transferLength,
                      TYPE_STANDARD_PRG, cartInterface.TransferMode);

  #ifdef USERAMLAUNCHER
  SendLoaderStub();
  #endif

  bool mediaReadOk = TransmitFileBytes(workingFile, KOA_PAYLOAD_SIZE, buf, BUF_SIZE);
  TransmitZeroBytes(KOA_GAP_SIZE);
  TransmitMemoryBytes(pluginPayload, pluginPayloadSize);
  if (padBytes > 0) {
    TransmitZeroBytes((uint32_t)padBytes);
  }
  interrupts();

  delayMicroseconds(30);
  workingFile.close();
  cartInterface.DisableCartridge();

  if (!mediaReadOk) {
    LOGE(SYS, "KOA read short");
  }
  LOGI(SYS, "KOA launched");
}

void CartApi::HandleInvokeWithName() {
  GetArgumentsDynamic(1);
  unsigned int fileNameLength = Arguments[1];
  char * fileName = (char *) &Arguments[2];
  // Reuse NI-buffer tail (bytes 130–193) instead of a local array — saves 64B of
  // stack.  ni[130+] is beyond the args overlap (ni[0..129]) and is never touched
  // by IO2/NI streaming during command dispatch.  Sequential use only.
  // savedPath shares this region with launchPath in LoadAndLaunchFile: the
  // user's CWD captured here is what LoadAndLaunchFile restores after the launch
  // sequence (ResetC64 + Init() resets CWD to root).
  char* savedPath = reinterpret_cast<char*>(sharedBuf.ni + 130);

  // NUL-terminate the received filename (GetArgumentsDynamic does not do this).
  Arguments[2 + fileNameLength] = '\0';

  // Capture the user's CWD as the post-launch return path. This must persist
  // across any chdir done below for sd.open(), and across Init() in
  // LoadAndLaunchFile (which resets dirFunc state to root).
  strncpy(savedPath, dirFunc.currentPath, 63);
  savedPath[63] = '\0';

  bool isKoa = EndsWithIgnoreCase(fileName, ".koa");

  // For absolute paths (e.g. "/PLUGINS/PRGPLUGIN.PRG"), the target file is NOT
  // in the current CWD — navigate to the parent directory so SdFat 2.x can open
  // the basename reliably (absolute LFN paths are flaky in SdFat 2.x). The CWD
  // stays at the parent into LoadAndLaunchFile so its sd.open() succeeds; the
  // user's CWD is restored from savedPath/launchPath after launch.
  const char* openName = fileName;
  if (fileName[0] == '/') {
    const char* lastSlash = strrchr(fileName, '/');
    if (lastSlash == NULL || lastSlash[1] == '\0') {
      HandleResponse(INVALID_ARGUMENT, 0);
      return;
    }

    openName = lastSlash + 1;

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

  // Resolve the basename to its 8.3 SFN before any sd.open() downstream.
  // SdFat 2.x sd.open()/sd.exists() can fail for LFN names with spaces or
  // lowercase even when the file is on disk; the SFN form (PICBRA~1.KOA)
  // opens reliably for the same entry.  FindFileSFN iterates via openNext
  // (which handles LFN entries) and writes the SFN into sfnBuf.
  // sfnBuf needs at most 13 bytes (8.3 + null) — 16 for safety.
  static char sfnBuf[16];
  uint8_t nameLen = strlen(openName);
  if (!dirFunc.FindFileSFN(openName, nameLen, sfnBuf, sizeof(sfnBuf))) {
    // Restore user CWD before erroring so menu state stays consistent.
    dirFunc.NavigateToPath(savedPath);
    HandleResponse(FILE_NOT_FOUND, 0);
    return;
  }
  openName = sfnBuf;

  if (isKoa) {
    HandleKoalaInvoke((char*)openName, savedPath);
    return;
  }

  // Do NOT restore CWD here: LoadAndLaunchFile's sd.open(openName) needs the
  // parent directory as CWD. The user's CWD lives in savedPath (shared memory
  // with launchPath in LoadAndLaunchFile) and is restored after launch.
  HandleResponse(SUCCESSFUL, 0);
  LoadAndLaunchFile(openName);
}

void CartApi::HandleEndTalking() {
  // End session cleanly: hide cartridge and reset receiver state.
  cartInterface.DisableCartridge();
  cartInterface.ResetReceive();
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



void CartApi::HandleStream() {
  #define STREAM_TIMEOUT_MS 100 // 100 milliseconds timeout for streaming

  // IO2 stream uses the shared static backing storage via streamBuffer1/2.
  // The buffers are never active at the same time as NI streaming.

  GetArgumentsStatic(3);
  uint8_t initialDelay = Arguments[0];
  uint8_t countStreamedBytes = Arguments[1];
  uint8_t padValue = Arguments[2];


  if (!workingFile.isOpen()) {
    HandleResponse(FILE_IS_NOT_OPENED, 0);
  } else {
      ReadAndPadBuffer(workingFile, (uint8_t*)streamBuffer1, DOUBLE_BUFFER_SIZE, padValue);
      ReadAndPadBuffer(workingFile, (uint8_t*)streamBuffer2, DOUBLE_BUFFER_SIZE, padValue);
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
        ReadAndPadBuffer(workingFile, (uint8_t*)streamBuffer1, DOUBLE_BUFFER_SIZE, padValue);
        while(usedBuffer == 1) {
          if (millis() - lastStreamRequestTime > STREAM_TIMEOUT_MS) goto out; // Timeout check
        }
        ReadAndPadBuffer(workingFile, (uint8_t*)streamBuffer2, DOUBLE_BUFFER_SIZE, padValue);
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


void CartApi::HandleNonInterruptedStream() {
  uint16_t bufferIndex = 0;
  uint16_t bufferLength;
  // Busy-loop guard while global interrupts are disabled. If IO2 gets stuck
  // high/low (noise or aborted transfer), we must escape instead of wedging.
  // ~8-10 cycles per inner iteration on AVR-GCC at -Os → 0xFFFF iterations
  // ≈ 33-41 ms. That covers byte-to-byte and block-to-block gaps comfortably
  // (C64 decompression budget is ~12 ms / block; SD refill is ~5-10 ms).
  // The FIRST byte after PROT_NIStream needs a longer budget: the C64 plugin
  // (e.g. CvdPlayer) takes ~40 ms (DELAYFRAMES + IRQ vector setup + raster
  // wait at $241) before its first JSR NMI_000 fires the very first IO2
  // strobe. Without an extended first-byte budget the AVR times out and
  // DisableCartridge()s before the C64 even starts streaming, causing the
  // plugin to read RAM garbage and hang on a grey screen.
  const uint16_t IO2_EDGE_TIMEOUT_LOOPS = 0xFFFF;
  const uint8_t  IO2_FIRST_BYTE_RETRIES = 6;        // 6 × ~35 ms ≈ 210 ms
  
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
      bool firstByte = true;

      while(1) {
        for (bufferIndex = 0; bufferIndex < bufferLength; bufferIndex++) {
            /* Synchronization block for each byte */
            // Note: We don't use millis() inside the inner loop for speed.
            // If IO2 stops toggling, the loop counter below aborts the stream.
            // First byte gets IO2_FIRST_BYTE_RETRIES extra timeout windows to
            // absorb the C64's IRQ-setup gap; subsequent bytes use the
            // single-window cap (matches the original timing budget).
            uint8_t retriesLeft = firstByte ? IO2_FIRST_BYTE_RETRIES : 1;
            uint16_t waitLoops = 0;

            while (PIND & 0x08) {
               if (++waitLoops == IO2_EDGE_TIMEOUT_LOOPS) {
                 if (--retriesLeft == 0) goto ni_out;
                 waitLoops = 0;
               }
            }
            waitLoops = 0;
            while ((PIND & 0x08) == 0) {
              if (++waitLoops == IO2_EDGE_TIMEOUT_LOOPS) goto ni_out;
            }  // Wait for rising edge

            uint8_t val = sharedBuf.ni[bufferIndex];
            PORTD = portDVal | (val & 0xF0);
            PORTC = portCVal | (val & 0x0F);
            firstByte = false;
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

        // Log every successfully decoded command byte. The dedicated handlers
        // also log per-command activity, but this single line is the canonical
        // record of what arrived from the C64 — useful for spotting timing
        // corruption (random unknown commands) and for cross-checking the
        // [LOAD]/[FILE] traces that follow.
        // (LOGI emits "[INFO][SYS] rx" with newline; the cmd value follows on
        // the next line, matching the existing "Unknown cmd / cmd=N" pattern.)
        LOGI(SYS, "rx");
        LOG_PRINT_F(" cmd="); LOG_PRINTLN(command);

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
          case COMMAND_EXIT_TO_MENU : TransferMenu();break;
          default:
            // False-positive handshake or line noise can inject random command
            // bytes. Drop session immediately so we don't block the main loop.
            LOGE(SYS, "Unknown cmd");
            LOG_PRINT_F(" cmd="); LOG_PRINTLN(command);
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
  LOG_LOAD_MENU();

  cartInterface.EndListening();

  if (workingFile && workingFile.isOpen()) {
    workingFile.close();
  }
  dirFunc.ReInit();
  
  unsigned char readFromFile = 0;
  LOG_PRINT_F("Menu RAM="); LOG_PRINTLN(FreeStack());
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
  // launchPath shares the NI-buffer tail with savedPath in the caller. The
  // caller (HandleInvokeWithName) populates this region with the user's CWD
  // before invoking us — that is what we restore after the launch sequence
  // (ResetC64 + Init() reset dirFunc state to root). Do NOT strncpy from
  // dirFunc.currentPath here: when invoking a plugin, currentPath is the
  // plugin's parent dir (e.g. /PLUGINS), not the user's launch dir (e.g. /CVD).
  char* launchPath = reinterpret_cast<char*>(sharedBuf.ni + 130);
  const bool preserveLaunchPath = (launchPath[0] != '\0');
  cartInterface.EndListening();

  unsigned char crtFile = 0;
  unsigned char booter = 0;
  uint16_t contentLength = 0;

  workingFile = sd.open(selectedFileName);

  if (workingFile ) {
    contentLength = workingFile.size();
    LOG_LOAD_LAUNCH(selectedFileName, contentLength);

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

    // Attach IO2 listening BEFORE the post-launch SD housekeeping (Init + optional
    // NavigateToPath). Once the LoaderStub jumps to plugin code (within ~1-2 ms
    // of DisableCartridge), the plugin's INIT + PROT_StartTalking can start
    // sending I/R/Q identifier bytes within ~5-15 ms. The SD operations below
    // take 10-50 ms — if we attach later, the plugin's identifier bytes arrive
    // into a detached IO2 input and are lost, the handshake never completes,
    // and the C64 hangs forever in PROT_WaitProcessing.
    cartInterface.StartListening();

    // CRITICAL: pump ReceiveHandler() until the plugin's PROT_StartTalking
    // handshake completes (receiveState reaches IN_TRANSMISSION) — or a
    // generous timeout elapses.
    //
    // Background: the bit-level ISR only assembles bytes once receiveState ==
    // IN_TRANSMISSION. During the identifier phase (IDLE → IDENTIFIER_*_OK →
    // IN_TRANSMISSION) byte assembly is done by ReceiveHandler() in the main
    // loop. If we drop straight into Init()+NavigateToPath() (20-60 ms of
    // blocking SD work) before the handshake finishes, the main loop is
    // suspended, ReceiveHandler() is never called, the ISR-set bitState gets
    // overwritten by the next edge before any code can promote it to a byte,
    // and the I/R/Q bytes are silently lost. Result: no HS OK, the plugin
    // hangs in PROT_OpenFile waiting for an AVR response that never arrives.
    //
    // Once IN_TRANSMISSION, byte assembly happens entirely inside the ISR
    // (queued for HandleApi to consume), so subsequent SD ops are safe.
    {
      const unsigned long handshakeWaitStartMs = millis();
      uint8_t lastLoggedState = 99;
      while ((unsigned long)(millis() - handshakeWaitStartMs) < 250UL) {
        uint8_t state = cartInterface.ReceiveHandler();
        if (state != lastLoggedState) {
          // Log every receiveState transition during the handshake wait so
          // we can see how far the plugin's PROT_StartTalking progressed:
          // 0=IDLE, 1=IDENTIFIER_1_OK, 2=IDENTIFIER_2_OK, 3=IDENTIFIER_3_OK,
          // 5=IN_TRANSMISSION (HS OK).
          LOG_PRINT_F("hsst="); LOG_PRINTLN(state);
          lastLoggedState = state;
        }
        if (state == IN_TRANSMISSION) break;
      }
      LOG_PRINT_F("hswait_end_ms="); LOG_PRINTLN(millis() - handshakeWaitStartMs);
    }

    Init();
    if (preserveLaunchPath) {
      dirFunc.NavigateToPath(launchPath);
    }

    LOGI(PRG, "Launched - C64 running game");
    LOG_LOAD_DONE();

    } else {
      LOGE(SYS, "FILENOTFOUND!");
    }
}

void CartApi::ResetNoCartridge() {
  cartInterface.ReleaseToBasic(true);
}


