#include <SdFat.h>
#include "Arduino.h"
#include "CartApi.h"
#include "CartInterface.h"
#include "DirFunction.h"
#include "EasySD.h"
#include "FlashLib.h"
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

// Watermark state for HandleReadDirectory's O(N) two-pass sort.
// s_wm_name / s_wm_isDir remember the full name and type of the last entry
// sent on the previous page so pass-1 can skip all already-sent entries in
// a single forward scan rather than repeating M full directory passes.
// Declared here (before Init()) so Init() can reset them after a PRG launch.
static char    s_wm_name[32]      = {'\0'}; // full LFN of last sent entry
static uint8_t s_wm_isDir         = 1;      // isDir of last sent entry (1=dir,0=file)
static uint8_t s_sortCachedPage   = 0xFF;   // page whose end is in s_wm_*
// Two-level history so backward-by-1 navigation hits the cache instead of rebuilding.
// s_wm_prev = W_in for page s_sortCachedPage   (= end of s_sortCachedPage-1)
// s_wm_pp   = W_in for page s_sortCachedPage-1 (= end of s_sortCachedPage-2)
static char    s_wm_prev_name[32]  = {'\0'};
static uint8_t s_wm_prev_isDir     = 1;
static char    s_wm_pp_name[32]    = {'\0'};
static uint8_t s_wm_pp_isDir       = 1;
static const uint16_t INVALID_DIR_IDX = 0xFFFF;
static const uint16_t PAGE_DIRIDX_CACHE_OFFSET = NON_INTERRUPTED_BUFFER_SIZE - (21u * 2u);
static uint8_t  s_pageEntryCount = 0;
static uint8_t  s_pageEntryPage = 0xFF;
// Shared SFN resolution buffer — only one command handler runs at a time,
// so a single file-scope buffer replaces four separate static locals (-48 B SRAM).
static char s_sfnBuf[16];

static void SetCachedPageDirIdx(uint8_t row, uint16_t dirIdx) {
  uint16_t offset = PAGE_DIRIDX_CACHE_OFFSET + (uint16_t)row * 2u;
  sharedBuf.ni[offset] = (uint8_t)(dirIdx & 0xFF);
  sharedBuf.ni[offset + 1] = (uint8_t)(dirIdx >> 8);
}

static uint16_t GetCachedPageDirIdx(uint8_t row) {
  uint16_t offset = PAGE_DIRIDX_CACHE_OFFSET + (uint16_t)row * 2u;
  return (uint16_t)sharedBuf.ni[offset] | ((uint16_t)sharedBuf.ni[offset + 1] << 8);
}

static void ClearCachedPageDirIdx() {
  for (uint8_t i = 0; i < 21; i++) SetCachedPageDirIdx(i, INVALID_DIR_IDX);
}

static void InvalidatePageEntryCache() {
  s_pageEntryCount = 0;
  s_pageEntryPage = 0xFF;
}

static uint16_t ReadAndPadBuffer(File &file, uint8_t *buffer, uint16_t length, uint8_t padValue) {
  int readCount = file.read(buffer, length);
  if (readCount < 0) readCount = 0;

  for (uint16_t i = (uint16_t)readCount; i < length; i++) {
    buffer[i] = padValue;
  }

  return (uint16_t)readCount;
}

static bool ReadAndPadFinalAware(File &file, uint8_t *buffer, uint16_t length, uint8_t padValue) {
  const uint16_t readCount = ReadAndPadBuffer(file, buffer, length, padValue);

  // Short reads are padded final blocks. Exact block-size EOF is also final:
  // without this, an exact 400-byte multiple makes NI wait for one extra C64
  // IO2 request that the CVD player correctly never sends after its size
  // counter reaches zero.
  return readCount < length || file.available() == 0;
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

  // Invalidate the sort-page watermark cache.  After a PRG launch, chdir,
  // or SD error the directory context has changed; stale watermarks would
  // cause the next multi-page scan to skip or duplicate entries.  The first
  // HandleReadDirectory for page 0 resets the chain anyway, but resetting
  // here guards against any edge-case where a non-zero page is requested
  // before page 0 (e.g. after an unusual recovery path).
  s_sortCachedPage  = 0xFF;
  s_wm_name[0]      = '\0'; s_wm_isDir      = 1;
  s_wm_prev_name[0] = '\0'; s_wm_prev_isDir = 1;
  s_wm_pp_name[0]   = '\0'; s_wm_pp_isDir   = 1;
  InvalidatePageEntryCache();

  dirFunc.ReInit();
  dirFunc.Prepare();
}

static inline void FlushSerialBeforeProtocolResponse() {
#if defined(EASYSD_DEBUG_SERIAL) || defined(EASYSD_RELEASE_LOG)
  // Serial logging is useful only if it does not perturb the IO2 pulse decoder.
  // Most command handlers log before raising the response byte. If UART TX
  // interrupts are still draining those logs when the C64 sends the next command,
  // pulse timing can be mis-measured as a random command byte. Flush only when
  // global interrupts are enabled; some transfer handlers call HandleResponse()
  // inside noInterrupts(), where Serial.flush() would wait forever.
  if (SREG & 0x80) {
    Serial.flush();
  }
#endif
}

inline void HandleResponse(unsigned char response, uint16_t waitAfterResponse) {
  FlushSerialBeforeProtocolResponse();

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
  if (dirFunc.FindFileSFN(openName, (uint8_t)strlen(openName), s_sfnBuf, sizeof(s_sfnBuf))) {
    openName = s_sfnBuf;
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
  if (!dirFunc.FindFileSFN(fileName, (uint8_t)strlen(fileName),
                           s_sfnBuf, sizeof(s_sfnBuf))) {
    HandleResponse(FILE_NOT_FOUND, 0);
    return;
  }
  if (sd.remove(s_sfnBuf)) {
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

// One slot in the in-place sort buffer overlaid on sharedBuf.ni.
// 19 bytes * 21 = 399 bytes <= NON_INTERRUPTED_BUFFER_SIZE (400).
struct DirSortSlot {
  char     key[16];   // first 15 chars of LFN + NUL (sort key, may be truncated)
  uint16_t dirIdx;    // FAT directory-entry index for pass-2 GetLFNByDirIdx
  uint8_t  isDir;     // 1 = subdirectory, 0 = file
};

// Compare two directory entries in EasySD display order:
//   subdirectories before files, then alphabetically case-insensitive.
// Returns < 0 if (isDir_a, name_a) sorts before (isDir_b, name_b).
static int cmpDirEntry(uint8_t isDir_a, const char* name_a,
                       uint8_t isDir_b, const char* name_b) {
  if (isDir_a != isDir_b) return isDir_a ? -1 : 1;  // dirs sort first
  return strcasecmp(name_a, name_b);
}

// Insert one entry into a sorted DirSortSlot array (ascending order).
// The array keeps only the 'cap' best (smallest) entries seen so far.
static void sortSlotInsert(DirSortSlot* slots, uint8_t& numSlots, uint8_t cap,
                           const char* key, uint16_t dIdx, uint8_t isDir) {
  if (numSlots < cap) {
    // Shift existing larger entries right, then insert at correct position.
    uint8_t pos = numSlots;
    while (pos > 0 && cmpDirEntry(isDir, key, slots[pos-1].isDir, slots[pos-1].key) < 0) {
      slots[pos] = slots[pos-1];
      pos--;
    }
    memcpy(slots[pos].key, key, 16);
    slots[pos].dirIdx = dIdx;
    slots[pos].isDir  = isDir;
    numSlots++;
  } else if (cmpDirEntry(isDir, key, slots[cap-1].isDir, slots[cap-1].key) < 0) {
    // Buffer full but this entry beats the worst: evict last and re-insert.
    uint8_t pos = cap - 1;
    while (pos > 0 && cmpDirEntry(isDir, key, slots[pos-1].isDir, slots[pos-1].key) < 0) {
      slots[pos] = slots[pos-1];
      pos--;
    }
    memcpy(slots[pos].key, key, 16);
    slots[pos].dirIdx = dIdx;
    slots[pos].isDir  = isDir;
  }
}

void CartApi::HandleReadDirectory() {
  // Clear the bank register immediately so the C64's WAITFOR loop sees 0
  // while we run pass 1 (SD scan).  HandleResponse() sets it to SUCCESSFUL
  // after the scan completes, and the C64 proceeds instantly.
  cartInterface.SetPage(0);

  GetArgumentsStatic(3);
  // Copy args to locals before sharedBuf is repurposed for the sort buffer.
  const uint8_t numberOfEntries = Arguments[0];
  const uint8_t dataLength      = Arguments[1];
  const uint8_t startPage       = Arguments[2];

  LOGI(DIR, "RD");
  LOG_PRINT_F(" pg="); LOG_PRINT(startPage);
  LOG_PRINT_F(" cnt="); LOG_PRINT(dirFunc.GetCount());
  LOG_PRINT_F(" sub="); LOG_PRINTLN(dirFunc.InSubDir);

  if (numberOfEntries == 0 || dataLength == 0) {
    HandleResponse(INVALID_ARGUMENT, 1);
    return;
  }

  const uint16_t maxBytesToTransfer = (uint16_t)dataLength * 256;
  const uint16_t startingIndex = (uint16_t)numberOfEntries * startPage;

  // Guard against stale page index: return 0 items instead of wrapping.
  uint8_t currentItemsCount;
  if (startingIndex >= (uint16_t)dirFunc.GetCount()) {
    currentItemsCount = 0;
  } else if ((uint16_t)dirFunc.GetCount() >= startingIndex + numberOfEntries) {
    currentItemsCount = numberOfEntries;
  } else {
    currentItemsCount = (uint8_t)(dirFunc.GetCount() - startingIndex);
  }
  const uint8_t pagePadValue = (dirFunc.GetCount() % numberOfEntries) > 0 ? 1 : 0;
  const uint8_t pageCount = (uint8_t)(dirFunc.GetCount() / numberOfEntries + pagePadValue);

  LOG_PRINT_F(" items="); LOG_PRINT(currentItemsCount);
  LOG_PRINT_F(" pages="); LOG_PRINTLN(pageCount);

  // ".." occupies sorted position 0 when in a subdirectory.
  const bool dotdotOnThisPage = (dirFunc.InSubDir != 0 && startingIndex == 0);
  // Number of real (non-"..") entries the sort scan must collect.
  const uint8_t scanTarget = currentItemsCount - (dotdotOnThisPage ? 1 : 0);

  // ----- Watermark setup -----
  // Three-level chain remembers the last three page boundaries:
  //   s_wm_name     = end of page s_sortCachedPage   → watermark for page +1 (forward)
  //   s_wm_prev_name = end of page s_sortCachedPage-1 → watermark for page  0 (same-page reload)
  //   s_wm_pp_name   = end of page s_sortCachedPage-2 → watermark for page -1 (backward-by-1)
  // Each path below sets s_wm_name to the correct scan watermark and shifts
  // s_wm_prev / s_wm_pp so they reflect the page being loaded.
  if (startPage == 0) {
    // First page: reset entire chain.
    s_wm_name[0]      = '\0'; s_wm_isDir      = 1;
    s_wm_prev_name[0] = '\0'; s_wm_prev_isDir = 1;
    s_wm_pp_name[0]   = '\0'; s_wm_pp_isDir   = 1;
  } else if (startPage == (uint8_t)(s_sortCachedPage + 1)) {
    // Sequential forward: s_wm_name is already the correct scan watermark.
    // Shift chain: pp <- prev <- name (name stays for scan, overwritten by pass 2).
    memcpy(s_wm_pp_name,   s_wm_prev_name, 32); s_wm_pp_isDir   = s_wm_prev_isDir;
    memcpy(s_wm_prev_name, s_wm_name,      32); s_wm_prev_isDir = s_wm_isDir;
    LOGI(DIR, "RD wm fwd hit");
  } else if (s_sortCachedPage != 0xFF && startPage == s_sortCachedPage) {
    // Same-page reload: use the watermark that was used to enter this page.
    memcpy(s_wm_pp_name, s_wm_prev_name, 32); s_wm_pp_isDir = s_wm_prev_isDir;
    memcpy(s_wm_name,    s_wm_prev_name, 32); s_wm_isDir    = s_wm_prev_isDir;
    // s_wm_prev unchanged (still the correct incoming watermark for this page).
  } else if (s_sortCachedPage > 0 && s_sortCachedPage != 0xFF &&
             startPage == (uint8_t)(s_sortCachedPage - 1)) {
    // Backward by one page: s_wm_pp holds the watermark for startPage.
    // Copy pp -> name first (saves W_in before chain shift overwrites pp).
    memcpy(s_wm_name,      s_wm_pp_name,   32); s_wm_isDir      = s_wm_pp_isDir;
    memcpy(s_wm_pp_name,   s_wm_prev_name, 32); s_wm_pp_isDir   = s_wm_prev_isDir;
    memcpy(s_wm_prev_name, s_wm_name,      32); s_wm_prev_isDir = s_wm_isDir;
    LOGI(DIR, "RD wm back hit");
  } else {
    // Non-sequential (random / large jump) page access.
    // Rebuild watermark by re-scanning pages 0 .. startPage-1.
    LOGI(DIR, "RD wm rebuild");
    s_wm_name[0] = '\0'; s_wm_isDir = 1;

    // Re-use sharedBuf.ni as the sort buffer during rebuild passes too.
    DirSortSlot* const slots = reinterpret_cast<DirSortSlot*>(sharedBuf.ni);

    // Track two history levels to populate prev/pp after the rebuild.
    char    rb_prev[32]; rb_prev[0] = '\0';
    uint8_t rb_prev_isDir = 1;

    for (uint8_t p = 0; p < startPage; p++) {
      // Save current watermark (end of p-1) before advancing to end of p.
      memcpy(rb_prev, s_wm_name, 32); rb_prev_isDir = s_wm_isDir;

      const bool   ddOnP  = (dirFunc.InSubDir != 0 && p == 0);
      const uint16_t sidxP = (uint16_t)numberOfEntries * p;
      uint8_t cntP;
      if      (sidxP >= (uint16_t)dirFunc.GetCount())                      cntP = 0;
      else if ((uint16_t)dirFunc.GetCount() >= sidxP + numberOfEntries)    cntP = numberOfEntries;
      else                                                                   cntP = (uint8_t)(dirFunc.GetCount() - sidxP);
      const uint8_t stP = cntP - (ddOnP ? 1 : 0);
      if (stP == 0) break;

      // One O(N) forward scan to collect the 'stP' best entries > watermark.
      uint8_t ns = 0;
      dirFunc.Rewind();
      while (dirFunc.Iterate() && !dirFunc.IsFinished) {
        const char*   name  = dirFunc.currentFileName;
        const uint8_t isDir = dirFunc.IsDirectory ? 1 : 0;
        if (name[0]=='.' && name[1]=='.' && name[2]=='\0') continue;
        if (cmpDirEntry(isDir, name, s_wm_isDir, s_wm_name) <= 0) continue;
        char key[16]; strncpy(key, name, 15); key[15] = '\0';
        sortSlotInsert(slots, ns, stP, key, dirFunc.currentDirIdx, isDir);
      }
      // Retrieve the full LFN of the last slot for an accurate watermark.
      if (ns > 0) {
        bool wm_id = false;
        if (dirFunc.GetLFNByDirIdx(slots[ns-1].dirIdx, s_wm_name, sizeof(s_wm_name), &wm_id)) {
          s_wm_name[31] = '\0';
          s_wm_isDir = wm_id ? 1 : 0;
        } else {
          // Fallback: truncated key (slightly less precise but functional).
          strncpy(s_wm_name, slots[ns-1].key, 15);
          s_wm_name[15] = '\0';
          s_wm_isDir = slots[ns-1].isDir;
        }
      }
    }
    // Populate the chain from the rebuild history so the next navigation
    // (forward or backward) from this page can hit the cache.
    memcpy(s_wm_pp_name,   rb_prev,   32); s_wm_pp_isDir   = rb_prev_isDir;
    memcpy(s_wm_prev_name, s_wm_name, 32); s_wm_prev_isDir = s_wm_isDir;
    // s_wm_name already holds the scan watermark (end of startPage-1).
  }

  // ---- Pass 1: single O(N) forward scan (interrupts enabled) ----
  // Collect the 'scanTarget' smallest entries strictly greater than the
  // watermark into the sort buffer overlaid on sharedBuf.ni.
  DirSortSlot* const slots = reinterpret_cast<DirSortSlot*>(sharedBuf.ni);
  uint8_t numSlots = 0;
  if (scanTarget > 0) {
    dirFunc.Rewind();
    while (dirFunc.Iterate() && !dirFunc.IsFinished) {
      const char*   name  = dirFunc.currentFileName;
      const uint8_t isDir = dirFunc.IsDirectory ? 1 : 0;
      // ".." is emitted separately; exclude it from the sort.
      if (name[0]=='.' && name[1]=='.' && name[2]=='\0') continue;
      // Only entries strictly greater than the watermark belong on this page.
      if (cmpDirEntry(isDir, name, s_wm_isDir, s_wm_name) <= 0) continue;
      char key[16]; strncpy(key, name, 15); key[15] = '\0';
      sortSlotInsert(slots, numSlots, scanTarget, key, dirFunc.currentDirIdx, isDir);
    }
  }

  // ---- Send response AFTER pass 1 so data follows immediately ----
  // The C64's WAITFOR loop has been watching bank=0 since the top of this
  // function.  Setting it to SUCCESSFUL here unblocks the C64, and pass 2
  // transmits all 768 bytes in one burst (~46 ms).
  HandleResponse(SUCCESSFUL, 1);
  cartInterface.ResetIndex();

  uint16_t actualTransferredBytes = 0;
  noInterrupts();

  cartInterface.TransmitByteFast(currentItemsCount);
  cartInterface.TransmitByteFast(pageCount);
  actualTransferredBytes = 2;

  // ".." entry (always first in a subdirectory, always on page 0).
  if (dotdotOnThisPage) {
    cartInterface.TransmitByteFast('.');
    cartInterface.TransmitByteFast('.');
    for (uint8_t i = 2; i < 31; i++) cartInterface.TransmitByteFast(0x00);
    cartInterface.TransmitByteFast(0x04);  // directory type flag
    actualTransferredBytes += 32;
  }

  // ---- Pass 2: retrieve full LFN via dirIdx then transmit ----
  // GetLFNByDirIdx does random-access SD reads (cacheDir + seekSet +
  // openNext).  Those reads must happen with interrupts ENABLED: SdFat
  // Timeout uses millis() which is frozen under noInterrupts(), and the
  // SD SPI bus should not be held while NMI timing is unrelated.
  // Strategy: toggle interrupts per entry — SD read with IRQ on, NMI
  // byte-burst with IRQ off.  Between bursts NMI is HIGH and the C64 is
  // spinning in PROT_ReceiveFragment's WAIT_TRANSFER_DONE loop, so
  // re-enabling interrupts here is safe (no IO2 bytes in flight).
  char    fullName[32];
  bool    entIsDir = false;
  for (uint8_t i = 0; i < numSlots; i++) {
    if (actualTransferredBytes + 32 > maxBytesToTransfer) break;

    // SD read — interrupts enabled so millis() / SdFat timeouts work.
    interrupts();
    const bool ok = dirFunc.GetLFNByDirIdx(slots[i].dirIdx, fullName, sizeof(fullName), &entIsDir);
    noInterrupts();

    if (!ok) {
      // Fallback: use the truncated sort key so the slot is not silently lost.
      strncpy(fullName, slots[i].key, 15);
      fullName[15] = '\0';
      entIsDir = (slots[i].isDir != 0);
    }

    uint8_t flen = (uint8_t)strlen(fullName);
    if (flen > 31) flen = 31;
    for (uint8_t j = 0; j < flen; j++)
      cartInterface.TransmitByteFast((uint8_t)fullName[j]);
    for (uint8_t j = flen; j < 31; j++)
      cartInterface.TransmitByteFast(0x00);
    cartInterface.TransmitByteFast(entIsDir ? 0x04 : 0x00);
    actualTransferredBytes += 32;

    // Update watermark to the full name of the entry just sent.
    strncpy(s_wm_name, fullName, 31);
    s_wm_name[31] = '\0';
    s_wm_isDir = entIsDir ? 1 : 0;
  }

  ClearCachedPageDirIdx();
  uint8_t pageCacheRow = 0;
  if (dotdotOnThisPage) {
    SetCachedPageDirIdx(pageCacheRow++, INVALID_DIR_IDX);
  }
  for (uint8_t i = 0; i < numSlots && pageCacheRow < 21; i++) {
    SetCachedPageDirIdx(pageCacheRow++, slots[i].dirIdx);
  }
  s_pageEntryCount = pageCacheRow;
  s_pageEntryPage = startPage;

  // Pad the transfer to the exact page size expected by the C64.
  for (uint16_t i = actualTransferredBytes; i < maxBytesToTransfer; i++) {
    cartInterface.TransmitByteFast(0x00);
  }

  interrupts();

  // Cache this page so the next sequential NEXTPAGE request reuses the
  // watermark already stored in s_wm_name / s_wm_isDir.
  s_sortCachedPage = startPage;
  delayMicroseconds(20);
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
    InvalidatePageEntryCache();
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
    InvalidatePageEntryCache();
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
  if (!dirFunc.FindDirSFN(fileName, (uint8_t)strlen(fileName),
                          s_sfnBuf, sizeof(s_sfnBuf))) {
    HandleResponse(DIR_NOT_FOUND, 0);
    return;
  }
  if (sd.rmdir(s_sfnBuf)) {
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

static inline char LowerAscii(char c) {
  return (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
}

static bool IsPluginPrgPath(const char* value) {
  if (value == NULL) return false;
  const size_t prefixLen = 9;   // "/plugins/"
  const size_t suffixLen = 10;  // "plugin.prg"
  size_t valueLen = strlen(value);
  if (valueLen < prefixLen + suffixLen) return false;

  if (value[0] != '/') return false;
  if (LowerAscii(value[1]) != 'p') return false;
  if (LowerAscii(value[2]) != 'l') return false;
  if (LowerAscii(value[3]) != 'u') return false;
  if (LowerAscii(value[4]) != 'g') return false;
  if (LowerAscii(value[5]) != 'i') return false;
  if (LowerAscii(value[6]) != 'n') return false;
  if (LowerAscii(value[7]) != 's') return false;
  if (value[8] != '/') return false;

  value += valueLen - suffixLen;
  if (LowerAscii(value[0]) != 'p') return false;
  if (LowerAscii(value[1]) != 'l') return false;
  if (LowerAscii(value[2]) != 'u') return false;
  if (LowerAscii(value[3]) != 'g') return false;
  if (LowerAscii(value[4]) != 'i') return false;
  if (LowerAscii(value[5]) != 'n') return false;
  if (value[6] != '.') return false;
  if (LowerAscii(value[7]) != 'p') return false;
  if (LowerAscii(value[8]) != 'r') return false;
  if (LowerAscii(value[9]) != 'g') return false;
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

// Uses already-open workingFile (set by caller).  Mirrors LoadAndLaunchOpenedFile
// for PRGs: caller opens by dirIdx, then calls this for the two-file transfer.
void CartApi::HandleKoalaInvokeFromOpenFile(const char* returnPath) {
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

// Open media file by SFN path from the current CWD (already set to parent dir
// by HandleInvokeWithName), then run the two-file KOA transfer.
void CartApi::HandleKoalaInvoke(char* mediaPath, const char* returnPath) {
  if (workingFile && workingFile.isOpen()) workingFile.close();
  workingFile = sd.open(mediaPath, FILE_READ);
  if (!workingFile) {
    LOGE(SYS, "KOA media open");
    RestorePathIfProvided(returnPath);
    HandleResponse(FILE_NOT_FOUND, 0);
    return;
  }
  HandleKoalaInvokeFromOpenFile(returnPath);
}

void CartApi::HandleInvokeWithName() {
  GetArgumentsDynamic(1);
  unsigned int fileNameLength = Arguments[1];
  char * fileName = (char *) &Arguments[2];
  // Reuse NI-buffer tail (bytes 130-193) instead of a local array; ni[130+] is
  // beyond the args overlap (ni[0..129]) and is never touched by IO2/NI
  // streaming during command dispatch. Sequential use only.
  char* savedPath = reinterpret_cast<char*>(sharedBuf.ni + 130);

  // NUL-terminate the received filename (GetArgumentsDynamic does not do this).
  Arguments[2 + fileNameLength] = '\0';

  // Capture the user's CWD for error rollback and plugin/media launch. Standard
  // PRG launch intentionally does not restore menu directory state after reset.
  strncpy(savedPath, dirFunc.currentPath, 63);
  savedPath[63] = '\0';

  bool isKoa = EndsWithIgnoreCase(fileName, ".koa");
  bool expectPluginSession = IsPluginPrgPath(fileName);

  // For absolute paths (e.g. "/PLUGINS/PRGPLUGIN.PRG"), the target file is NOT
  // in the current CWD — navigate to the parent directory so SdFat 2.x can open
  // the basename reliably (absolute LFN paths are flaky in SdFat 2.x). The CWD
  // stays at the parent into LoadAndLaunchFile so its sd.open() succeeds.
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
  uint8_t nameLen = strlen(openName);
  if (!dirFunc.FindFileSFN(openName, nameLen, s_sfnBuf, sizeof(s_sfnBuf))) {
    // Restore user CWD before erroring so menu state stays consistent.
    dirFunc.NavigateToPath(savedPath);
    HandleResponse(FILE_NOT_FOUND, 0);
    return;
  }
  openName = s_sfnBuf;

  if (isKoa) {
    HandleKoalaInvoke((char*)openName, savedPath);
    return;
  }

  // Do NOT restore CWD here: LoadAndLaunchFile's sd.open(openName) needs the
  // parent directory as CWD. Close the directory iterator copy before streaming
  // so a large menu directory is not held open during the launch burst.
  dirFunc.CloseDirHandle();
  HandleResponse(SUCCESSFUL, 0);
  LoadAndLaunchFile(openName, expectPluginSession);
}

void CartApi::HandleInvokeWithIndex() {
  GetArgumentsStatic(3);

  const uint8_t pageIndex = Arguments[0];
  const uint8_t rowIndex = Arguments[1];
  const uint8_t flags = Arguments[2];
  (void)flags;

  if (rowIndex >= 21 ||
      s_pageEntryPage != pageIndex ||
      rowIndex >= s_pageEntryCount) {
    HandleResponse(INVALID_ARGUMENT, 0);
    return;
  }

  const uint16_t dirIdx = GetCachedPageDirIdx(rowIndex);
  if (dirIdx == INVALID_DIR_IDX) {
    HandleResponse(INVALID_ARGUMENT, 0);
    return;
  }

  char selectedName[32];
  bool isDir = false;
  if (!dirFunc.GetLFNByDirIdx(dirIdx, selectedName, sizeof(selectedName), &isDir) || isDir) {
    HandleResponse(FILE_NOT_FOUND, 0);
    return;
  }

  if (!dirFunc.OpenFileByDirIdx(dirIdx, workingFile)) {
    HandleResponse(FILE_CANNOT_BE_OPENED, 0);
    return;
  }

  dirFunc.CloseDirHandle();

  // KOA files require a two-file transfer (media + KOAPLUGIN.PRG).
  // workingFile is already open; HandleKoalaInvokeFromOpenFile uses it directly.
  if (EndsWithIgnoreCase(selectedName, ".koa")) {
    HandleKoalaInvokeFromOpenFile(nullptr);
    return;
  }

  HandleResponse(SUCCESSFUL, 0);
  LoadAndLaunchOpenedFile(selectedName, false);
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
  enum NiExitReason {
    NI_EXIT_EOF,
    NI_EXIT_FIRST_BYTE_TIMEOUT,
    NI_EXIT_IO2_FALL_TIMEOUT,
    NI_EXIT_IO2_RISE_TIMEOUT
  };
  NiExitReason exitReason = NI_EXIT_EOF;
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
  
  LOG_NI_START();
  GetArgumentsStatic(1);
  if (!m_argsOk) {
    LOG_NI_EXIT("args-timeout");
    return;
  }
  uint8_t countOf8Bytes = Arguments[0];  

  if (countOf8Bytes == 0 || countOf8Bytes > NON_INTERRUPTED_BUFFER_SIZE / 8) {
    LOG_NI_EXIT("invalid-arg");
    HandleResponse(INVALID_ARGUMENT, 0);
  } else if (!workingFile.isOpen()) {
    LOG_NI_EXIT("no-file");
    HandleResponse(FILE_IS_NOT_OPENED, 0);
  } else {
      // Clear the previous command's response immediately. The C64 side is now
      // in PROT_WaitProcessing and must keep polling zero until the first NI
      // block is loaded and the AVR is about to arm the IO2 loop.
      cartInterface.SetPage(0);
      cartInterface.SetPage(0);

      // Disable receiving interrupt but keep the state of the communication channel on.
      cartInterface.SoftEndListening();
      bufferLength = countOf8Bytes * 8;
      LOG_NI_BLOCK_SIZE(bufferLength);
      bool stopAfterCurrentBuffer = ReadAndPadFinalAware(workingFile, sharedBuf.ni, bufferLength, 0x00);

      // Only now report success: the first block is resident in SRAM, so the
      // response means the NI stream can actually be started.
      HandleResponse(SUCCESSFUL, 0);
      
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
            const uint8_t val = sharedBuf.ni[bufferIndex];
            const uint8_t outD = portDVal | (val & 0xF0);
            const uint8_t outC = portCVal | (val & 0x0F);
            uint8_t retriesLeft = firstByte ? IO2_FIRST_BYTE_RETRIES : 1;
            uint16_t waitLoops = 0;

            while (PIND & 0x08) {
               if (++waitLoops == IO2_EDGE_TIMEOUT_LOOPS) {
                 if (--retriesLeft == 0) {
                   exitReason = firstByte ? NI_EXIT_FIRST_BYTE_TIMEOUT : NI_EXIT_IO2_FALL_TIMEOUT;
                   goto ni_out;
                 }
                 waitLoops = 0;
               }
            }

            waitLoops = 0;
            while ((PIND & 0x08) == 0) {
              if (++waitLoops == IO2_EDGE_TIMEOUT_LOOPS) {
                exitReason = NI_EXIT_IO2_RISE_TIMEOUT;
                goto ni_out;
              }
            }  // Wait for rising edge

            // Match the original IRQHack64 NI-stream handshake: the $DF00
            // read is only the trigger; the C64 fetches the actual byte from
            // ROML (CARTRIDGE_BANK_VALUE, $80AB on old ROMs) immediately
            // afterwards. Precompute above, then
            // latch the byte as soon as /IO2 returns high.
            PORTD = outD;
            PORTC = outC;
            firstByte = false;
        }

        if (stopAfterCurrentBuffer) {
          exitReason = NI_EXIT_EOF;
          goto ni_out;
        }
        
        // --- Refill the buffer we just finished sending ---
        // C64 is currently busy processing the 400 bytes we just sent.
        // interrupts() re-enabled here for SD card stability.
        // EOF check: short reads are padded and exact block-size EOF is detected
        // with available()==0, so no synthetic extra block is requested.
        // The C64 detects end-of-stream via its CVD_SIZE frame counter and will
        // call PROT_StartTalking to re-establish the session after this exit.
        interrupts();
        stopAfterCurrentBuffer = ReadAndPadFinalAware(workingFile, sharedBuf.ni, bufferLength, 0x00);
        noInterrupts();
      } 

ni_out:
      interrupts();
      TIMSK2 = 0x02; // Enable timer 2 interrupts
      cartInterface.DisableCartridge(); // Always return to BASIC-safe bus state
      cartInterface.StartListening();
      switch (exitReason) {
        case NI_EXIT_EOF:
          LOG_NI_EXIT("eof");
          break;
        case NI_EXIT_FIRST_BYTE_TIMEOUT:
          LOG_NI_FIRST_TIMEOUT();
          LOG_NI_EXIT("first-byte-timeout");
          break;
        case NI_EXIT_IO2_FALL_TIMEOUT:
          LOG_NI_EXIT("io2-fall-timeout");
          break;
        case NI_EXIT_IO2_RISE_TIMEOUT:
          LOG_NI_EXIT("io2-rise-timeout");
          break;
      }
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
          case COMMAND_INVOKE_WITH_INDEX : HandleInvokeWithIndex();break;
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
  dirFunc.Prepare();
  
  unsigned char readFromFile = 0;
  LOG_PRINT_F("Menu RAM="); LOG_PRINTLN(FreeStack());
  if (OpenMenuFromSdRoot(workingFile)) {
    readFromFile = 1;
  }

  //int menu_data_length = (readFromFile? workingFile.size() : data_len) ;
  int menu_data_length = (readFromFile? workingFile.size() : data_len) ;

  cartInterface.EnableCartridge();
  cartInterface.ResetC64();

  delay(300);

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
  cartInterface.StartListening();

  if (readFromFile && workingFile) workingFile.close();
}


void CartApi::LoadAndLaunchOpenedFile(const char* selectedFileName, bool expectPluginSession) {
  const size_t BUF_SIZE = 16;
  uint8_t buf[BUF_SIZE];
  cartInterface.EndListening();

  unsigned char crtFile = 0;
  unsigned char booter = 0;
  uint16_t contentLength = 0;

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
    
    unsigned char low;
    unsigned char high;
    if (!crtFile) {
        low = workingFile.read();
        high = workingFile.read();
    } else {
      low = 0;
      high = 0x80;
    }
    
    noInterrupts();
    SendHeader(low, high, transferPages, transferLength, (crtFile ? TYPE_CARTRIDGE : (booter ? TYPE_BOOTER : TYPE_STANDARD_PRG)), cartInterface.TransferMode); 

    #ifdef  USERAMLAUNCHER
    SendLoaderStub();
    #endif

    bool readOk = TransmitFileBytes(workingFile, (uint32_t)transferLength, buf, BUF_SIZE);
        
    if (padBytes>0) {
      TransmitZeroBytes((uint32_t)padBytes);
    }
    interrupts();
    
    delayMicroseconds(30);
    workingFile.close();               // close before chdir — prevents SdFat state corruption
    cartInterface.DisableCartridge();  // EXROM HIGH + data bus tristate — clean state after transfer

    if (!readOk) {
      LOGE(SYS, "PRG read short");
    }

    // Standard PRG/CRT/IRQ launch is final from the menu's point of view:
    // do not rebuild directory state or navigate back into a large folder here.
    // Media plugins are the only launches expected to talk back immediately.
    if (expectPluginSession) {
      cartInterface.StartListening();

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

    LOGI(PRG, "Launched - C64 running game");
    LOG_LOAD_DONE();

    } else {
      LOGE(SYS, "FILENOTFOUND!");
    }
}

void CartApi::LoadAndLaunchFile(const char* selectedFileName, bool expectPluginSession) {
  if (workingFile && workingFile.isOpen()) workingFile.close();
  workingFile = sd.open(selectedFileName, FILE_READ);
  LoadAndLaunchOpenedFile(selectedFileName, expectPluginSession);
}

void CartApi::ResetNoCartridge() {
  cartInterface.DisableCartridge();
  cartInterface.ResetC64();
}
