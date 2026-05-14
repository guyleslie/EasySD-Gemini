// DirFunction — directory navigation and state for the SD card.
// Invariants:
//   - Navigation is relative (basename chdir). SdFat 2.x absolute LFN paths are
//     unreliable, so NavigateToPath() walks segment by segment from root.
//   - After any sd.chdir(), call ResyncDirFromCwd() to keep m_dirFile in sync.
//   - currentPath is a UI mirror only — the firmware CWD is the source of truth.
//   - GoBack/ChangeDirectory roll back path + depth on failure.
#include <SdFat.h>
#include "EasySD.h"
#include "Arduino.h"
#include "DirFunction.h"
#include "EasySDLog.h"

extern SdFat  sd;

namespace {

class FilenameCaptureSink : public Print {
 public:
  FilenameCaptureSink(char* buffer, size_t capacity)
      : m_buffer(buffer), m_capacity(capacity), m_index(0) {
    reset();
  }

  size_t write(uint8_t c) override {
    if (m_capacity > 1 && (m_index + 1) < m_capacity) {
      m_buffer[m_index++] = static_cast<char>(c);
      m_buffer[m_index] = '\0';
    }
    return 1;
  }

  void reset() {
    m_index = 0;
    if (m_capacity > 0) {
      m_buffer[0] = '\0';
    }
  }

 private:
  char* m_buffer;
  size_t m_capacity;
  size_t m_index;
};

static void CaptureFileNamePreview(File& file, char* outName, size_t outSize) {
  FilenameCaptureSink sink(outName, outSize);
  file.printName(&sink);
}

static bool PrefixMatchesCaseInsensitive(const char* candidate,
                                         const char* prefix,
                                         uint8_t len) {
  for (uint8_t i = 0; i < len; i++) {
    if (tolower((uint8_t)candidate[i]) != tolower((uint8_t)prefix[i])) {
      return false;
    }
  }
  return true;
}

}  // namespace

// Canonical way to synchronize m_dirFile with the CWD after any sd.chdir().
// openCwd() is the SdFat 2.x method that ties the file object to the volume's
// current working directory — do not open by currentPath string (UI only).
bool DirFunction::ResyncDirFromCwd() {
  if (m_dirFile.isOpen()) {
    m_dirFile.close();
  }
  if (!m_dirFile.openCwd()) {
    LOGE(DIR, "openCwd FAIL after chdir to ");
    LOG_PRINTLN(currentPath);
    return false;
  }
  m_dirFile.rewind();
  if (!m_dirFile.isOpen()) {
    LOGE(DIR, "ASSERT FAIL - dirFile not open after openCwd");
  }
  if (!m_dirFile.isDir()) {
    LOGE(DIR, "ASSERT FAIL - dirFile is not a directory");
  }
  return true;
}

void DirFunction::ReInit() {
  ToRoot();
}

void DirFunction::ToRoot() {
  // Reset state variables
  count = 0;
  currentIndex = 0;
  IsFinished = 0;
  IsDirectory = 0;
  InSubDir = 0;
  pathDepth = 0;
  memset(currentPath, 0, sizeof(currentPath));
  strcpy(currentPath, "/");

  if (!sd.chdir()) {
    LOGE(DIR, "chdir root FAIL");
    return;
  }
  if (!ResyncDirFromCwd()) {
    LOGE(DIR, "ResyncDirFromCwd FAIL at root");
    return;
  }
  CountEntries();

  LOGI(DIR, "Changed to ROOT");
}

bool DirFunction::GoBack() {
  if (pathDepth == 0) {
    return false;
  }

  int len = strlen(currentPath);
  if (len <= 1) {
    ToRoot();
    return true;
  }

  // Save for rollback
  char savedPath[64];
  strcpy(savedPath, currentPath);
  uint8_t savedDepth = pathDepth;

  // Strip trailing slash
  if (currentPath[len-1] == '/') { currentPath[len-1] = '\0'; len--; }

  // Strip last path component
  for (int i = len - 1; i >= 0; i--) {
    if (currentPath[i] == '/') {
      if (i == 0) {
        ToRoot();
        return true;
      }
      currentPath[i] = '\0';
      break;
    }
  }

  pathDepth--;
  if (pathDepth == 0) InSubDir = 0;

  LOGI(DIR, "GoBack to: "); LOG_PRINTLN(currentPath);

  // Use chdir("..") instead of chdir(absolutePath): SdFat 2.x absolute LFN
  // paths are unreliable, while ".." reads the parent entry directly from
  // the current dir's metadata regardless of LFN content in the path.
  if (!sd.chdir("..")) {
    LOGE(DIR, "GoBack chdir FAIL");
    strcpy(currentPath, savedPath);
    pathDepth = savedDepth;
    InSubDir = (pathDepth > 0) ? 1 : 0;
    return false;
  }

  if (!ResyncDirFromCwd()) {
    LOGE(DIR, "GoBack ResyncDirFromCwd FAIL");
    strcpy(currentPath, savedPath);
    pathDepth = savedDepth;
    InSubDir = (pathDepth > 0) ? 1 : 0;
    return false;
  }

  CountEntries();
  return true;
}

bool DirFunction::ChangeDirectory(char * directory) {
  if (!directory || directory[0] == '\0') {
    return false;
  }

  if (strlen(currentPath) + strlen(directory) + 2 > sizeof(currentPath)) {
    LOGE(DIR, "ChangeDirectory: path OVERFLOW");
    return false;
  }

  // Save current path for rollback
  char savedPath[64];
  strcpy(savedPath, currentPath);
  uint8_t savedDepth = pathDepth;

  // Build new absolute path
  if (currentPath[strlen(currentPath)-1] != '/') {
    strcat(currentPath, "/");
  }
  strcat(currentPath, directory);

  // Use basename-relative chdir.  SdFat 2.x absolute LFN paths are unreliable
  // and even relative LFN names with spaces/lowercase can fail intermittently;
  // on such failure, resolve the basename to its 8.3 SFN via openNext()
  // (which reads LFN entries reliably) and retry with the SFN form.
  bool chdirOk = sd.chdir(directory);
  if (!chdirOk) {
    char sfn[16];
    if (FindDirSFN(directory, (uint8_t)strlen(directory), sfn, sizeof(sfn))) {
      chdirOk = sd.chdir(sfn);
    }
  }
  if (!chdirOk) {
    LOGE(DIR, "chdir FAILED: ");
    LOG_PRINTLN(directory);
    strcpy(currentPath, savedPath);
    pathDepth = savedDepth;
    InSubDir = (pathDepth > 0) ? 1 : 0;
    return false;
  }
  if (!ResyncDirFromCwd()) {
    LOGE(DIR, "ChangeDirectory ResyncDirFromCwd FAIL");
    strcpy(currentPath, savedPath);
    pathDepth = savedDepth;
    InSubDir = (pathDepth > 0) ? 1 : 0;
    return false;
  }

  // Success - update depth and count entries in one scan
  InSubDir = 1;
  pathDepth++;
  CountEntries();
  LOGI(DIR, "Entered: ");
  LOG_PRINTLN(currentPath);
  return true;
}

void DirFunction::CountEntries() {
  count = 0;
  currentIndex = 0;
  m_dirFile.rewind();
  if (InSubDir == 1) count++;
  File file;
  while (file.openNext(&m_dirFile)) {
    if (!file.isHidden()) count++;
    file.close();
  }
  m_dirFile.rewind();
}

void DirFunction::Prepare() {
  // Resync from CWD, then count. Used by Init/TransferMenu/ForceReset.
  // After ChangeDirectory/ToRoot, CountEntries() is already called internally
  // so callers in HandleChangeDirectory do not need to call Prepare().
  if (!ResyncDirFromCwd()) {
    LOGE(DIR, "Prepare ResyncDirFromCwd FAIL at ");
    LOG_PRINTLN(currentPath);
    return;
  }
  CountEntries();
}

int DirFunction::Iterate() {
  currentFileName[0] = '\0';

  if (InSubDir == 1 && currentIndex == 0) {
    strcpy(currentFileName, "..");
    IsDirectory = 1;
    currentIndex++;
    return 1;
  }

  if (currentIndex >= count) {
    IsFinished = 1;
    return 0;
  }

  File file;
  while (file.openNext(&m_dirFile)) {
    if (file.isHidden()) {
      file.close();
      continue;
    }

    CaptureFileNamePreview(file, currentFileName, sizeof(currentFileName));
    IsDirectory = file.isDir() ? 1 : 0;
    currentDirIdx = file.dirIndex(); // save FAT entry index for GetLFNByDirIdx
    file.close();
    currentIndex++;
    return 1;
  }

  IsFinished = 1;
  return 0;
}

unsigned int DirFunction::GetCount() {
  return count;
}

// Open a directory entry by FAT dir-entry index and capture its full LFN name.
// Used by HandleReadDirectory pass 2 so full names are delivered without a
// second forward scan.  After open(dirFile, index) SdFat scans backward for
// the LFN chain, so printName() returns the complete long filename.
bool DirFunction::GetLFNByDirIdx(uint16_t idx, char* outName, size_t outSize, bool* outIsDir) {
  File f;
  if (!f.open(&m_dirFile, idx, O_RDONLY)) return false;
  CaptureFileNamePreview(f, outName, outSize);
  if (outIsDir) *outIsDir = f.isDir();
  f.close();
  return true;
}

bool DirFunction::OpenFileByDirIdx(uint16_t idx, File& outFile) {
  if (!m_dirFile.isOpen() && !ResyncDirFromCwd()) return false;
  if (outFile.isOpen()) outFile.close();
  if (!outFile.open(&m_dirFile, idx, O_RDONLY)) return false;
  if (outFile.isDir()) {
    outFile.close();
    return false;
  }
  return true;
}

void DirFunction::Rewind() {
  m_dirFile.rewind();
  currentIndex = 0;
  IsDirectory = 0;
  IsFinished = 0;
}

void DirFunction::SetSelected(unsigned int selectedIndex) {
  selected = selectedIndex;
}

unsigned int DirFunction::GetSelected(void) {
  return selected;
}


bool DirFunction::ChangeDirectoryBasename(const char* basename) {
  if (!basename || basename[0] == '\0') {
    return false;
  }

  // Special case: ".." means go back
  if (strcmp(basename, "..") == 0) {
    return GoBack();
  }

  // Validate basename doesn't contain path separators
  if (strchr(basename, '/') != NULL) {
    return false;
  }

  // Use existing ChangeDirectory method
  return ChangeDirectory((char*)basename);
}

bool DirFunction::FindDirectoryNameByVisibleIndex(uint16_t visibleIndex,
                                                   char* outName,
                                                   size_t outSize) {
  if (!outName || outSize < 13) {
    LOGE(DIR, "CDVI: bad scratch");
    return false;
  }

  // ".." always occupies sorted position 0 when inside a subdirectory.
  if (InSubDir && visibleIndex == 0) {
    strncpy(outName, "..", outSize - 1);
    outName[outSize - 1] = '\0';
    return true;
  }

  // Adjust for the ".." slot: directories start at position 0 when at root,
  // or position 1 when in a subdirectory (position 0 = "..").
  const uint16_t dirSortIndex = InSubDir ? visibleIndex - 1 : visibleIndex;

  // Scan-based sorted lookup — mirrors HandleReadDirectory sort logic.
  // Find the dirSortIndex-th directory in case-insensitive A-Z order.
  char lastFoundName[32];
  char bestName[32];
  lastFoundName[0] = '\0';

  for (uint16_t i = 0; i <= dirSortIndex; i++) {
    bool found = false;
    bestName[0] = '\0';

    Rewind();
    while (Iterate()) {
      if (!IsDirectory) continue;
      // Skip ".." — handled separately above.
      if (currentFileName[0] == '.' &&
          currentFileName[1] == '.' &&
          currentFileName[2] == '\0') continue;

      // Accept if name > watermark and is a new best (smallest candidate).
      if (strcasecmp(currentFileName, lastFoundName) > 0) {
        if (!found || strcasecmp(currentFileName, bestName) < 0) {
          strncpy(bestName, currentFileName, 31);
          bestName[31] = '\0';
          found = true;
        }
      }
    }

    if (!found) {
      LOGE(DIR, "CDVI: index not found");
      LOG_PRINT_F(" vis="); LOG_PRINTLN(visibleIndex);
      Rewind();
      return false;
    }

    strncpy(lastFoundName, bestName, 31);
    lastFoundName[31] = '\0';
  }

  strncpy(outName, lastFoundName, outSize - 1);
  outName[outSize - 1] = '\0';
  LOGI(DIR, "CDVI found: ");
  LOG_PRINTLN(outName);
  Rewind();
  return true;
}

const char* DirFunction::GetCurrentPath() const {
  return currentPath;
}

// Navigate from root to an absolute path, segment by segment.
// Returns true on success, false if any segment fails (leaves at root).
bool DirFunction::NavigateToPath(const char* absPath) {
  if (!absPath || absPath[0] != '/' || absPath[1] == '\0') {
    // Root or invalid — just go to root
    ToRoot();
    return true;
  }

  ToRoot();

  char buf[64];
  // Copy safely, null-terminate
  uint8_t len = 0;
  while (len < 63 && absPath[len]) { buf[len] = absPath[len]; len++; }
  buf[len] = '\0';

  char* p = buf + 1;  // skip leading '/'
  while (*p) {
    char* slash = strchr(p, '/');
    if (slash) *slash = '\0';
    bool ok = ChangeDirectory(p);
    if (slash) *slash = '/';
    if (!ok) {
      LOGE(DIR, "NavigateToPath: seg fail");
      ToRoot();
      return false;
    }
    if (!slash) break;
    p = slash + 1;
  }
  return true;
}

void DirFunction::ForceReset() {
  LOGI(DIR, "ForceReset");
  // ToRoot() already calls ResyncDirFromCwd() + CountEntries(); Prepare() would
  // repeat both operations for no benefit.
  ToRoot();
}

void DirFunction::CloseDirHandle() {
  if (m_dirFile.isOpen()) {
    m_dirFile.close();
  }
}

bool DirFunction::FindFileSFN(const char* prefix, uint8_t len,
                              char* outSFN, size_t outSize) {
  return FindEntrySFN(prefix, len, outSFN, outSize, false);
}

bool DirFunction::FindDirSFN(const char* prefix, uint8_t len,
                             char* outSFN, size_t outSize) {
  return FindEntrySFN(prefix, len, outSFN, outSize, true);
}

bool DirFunction::FindEntrySFN(const char* prefix, uint8_t len,
                               char* outSFN, size_t outSize, bool wantDir) {
  char lfnBuf[64];
  m_dirFile.rewind();
  File f;
  while (f.openNext(&m_dirFile)) {
    if (f.isHidden() || (bool)f.isDir() != wantDir) { f.close(); continue; }
    CaptureFileNamePreview(f, lfnBuf, sizeof(lfnBuf));
    size_t n = strlen(lfnBuf);
    if (n >= len && PrefixMatchesCaseInsensitive(lfnBuf, prefix, len)) {
      f.getSFN(outSFN, outSize);
      f.close();
      return true;
    }
    f.close();
  }
  return false;
}
