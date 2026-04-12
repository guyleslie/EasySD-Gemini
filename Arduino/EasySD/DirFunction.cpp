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

  // Compute parent path by stripping the last path component
  char parentPath[64];
  strcpy(parentPath, currentPath);
  int plen = strlen(parentPath);
  if (parentPath[plen-1] == '/') { parentPath[--plen] = '\0'; }
  for (int i = plen - 1; i >= 0; i--) {
    if (parentPath[i] == '/') {
      if (i == 0) {
        ToRoot();
        return true;
      }
      parentPath[i] = '\0';
      break;
    }
  }

  LOGI(DIR, "GoBack to: "); LOG_PRINTLN(parentPath);

  // Navigate segment-by-segment from root — consistent with NavigateToPath().
  // sd.chdir(absolutePath) with LFN names is unreliable in SdFat 2.x.
  if (!NavigateToPath(parentPath)) {
    LOGE(DIR, "GoBack FAIL");
    return false;
  }
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

  // Use basename-relative chdir — SdFat 2.x absolute LFN paths are unreliable.
  // CWD is already positioned correctly by prior navigation calls.
  if (!sd.chdir(directory)) {
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

  // Success - update depth
  InSubDir = 1;
  pathDepth++;
  LOGI(DIR, "Entered: ");
  LOG_PRINTLN(currentPath);
  return true;
}

void DirFunction::Prepare() {
  File   file;
  count = 0;
  currentIndex = 0;

  // currentPath is for UI/debug only; CWD is the single source of truth.
  if (!ResyncDirFromCwd()) {
    LOGE(DIR, "Prepare ResyncDirFromCwd FAIL at ");
    LOG_PRINTLN(currentPath);
    return;
  }

  if (InSubDir == 1) count++;

  while (file.openNext(&m_dirFile)) {
    if (!file.isHidden()) {
      count++;
    }
    file.close();
  }

  m_dirFile.rewind();
}

int DirFunction::Iterate() {
  File file;

  currentFileName[0] = '\0';

  if (InSubDir == 1 && currentIndex == 0) {
    strcpy(currentFileName, "..");
    IsDirectory = 1;
    IsHidden = 0;
    currentIndex++;
    return 1;
  }

  if (currentIndex < count) {
    if (file.openNext(&m_dirFile)) {
      if (!file.isHidden()) {
        CaptureFileNamePreview(file, currentFileName, sizeof(currentFileName));
        currentIndex++;
        IsDirectory = file.isSubDir();
        IsHidden = 0;
        file.close();
        return 1;
      } else {
        IsHidden = 1;
        IsDirectory = file.isSubDir();
        file.close();
        return 1;
      }
    } else {
      IsFinished = 1;
      return 0;
    }
  } else {
    IsFinished = 1;
    return 0;
  }
}

unsigned int DirFunction::GetCount() {
  return count;
}

void DirFunction::Rewind() {
  m_dirFile.rewind();
  currentIndex = 0;
  IsDirectory = 0;
  IsHidden = 0;
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

const char* DirFunction::GetCurrentPath() const {
  return currentPath;
}

// Navigate from root to an absolute path, segment by segment.
// Used by COMMAND_GOTO_PATH (MultiLoad path restore).
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

  ToRoot();
  Prepare();

}

void DirFunction::CloseDirHandle() {
  if (m_dirFile.isOpen()) {
    m_dirFile.close();
  }
}

bool DirFunction::FindByPrefix(const char* prefix, uint8_t len,
                               char* outName, size_t outSize) {
  m_dirFile.rewind();
  File f;
  while (f.openNext(&m_dirFile)) {
    if (f.isDir() || f.isHidden()) { f.close(); continue; }
    CaptureFileNamePreview(f, outName, outSize);
    size_t n = strlen(outName);
    f.close();
    if (n < len) continue;
    if (PrefixMatchesCaseInsensitive(outName, prefix, len)) return true;
  }
  return false;
}

bool DirFunction::FindDirectoryByPrefix(const char* prefix, uint8_t len,
                                        char* outName, size_t outSize) {
  m_dirFile.rewind();
  File f;
  while (f.openNext(&m_dirFile)) {
    if (!f.isDir() || f.isHidden()) { f.close(); continue; }
    CaptureFileNamePreview(f, outName, outSize);
    size_t n = strlen(outName);
    f.close();
    if (n < len) continue;
    if (PrefixMatchesCaseInsensitive(outName, prefix, len)) return true;
  }
  return false;
}
