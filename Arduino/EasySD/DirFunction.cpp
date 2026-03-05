#include <SdFat.h>
// #include <SdFatUtil.h>  // Removed: Not available in SdFat 2.x
#include <FreeStack.h>  // SdFat 2.x: For memory debugging
#include "EasySD.h"
#include "Arduino.h"
#include "DirFunction.h"
#include "EasySDLog.h"

extern SdFat  sd;

// ========================================================================
// Sprint 5 P2.2: Unified directory state synchronization helper
// This is THE canonical way to synchronize m_dirFile with the firmware's
// current working directory after any sd.chdir() operation.
// ========================================================================
bool DirFunction::ResyncDirFromCwd() {
  // Step 1: Close any open directory handle
  if (m_dirFile.isOpen()) {
    m_dirFile.close();
  }

  // Step 2: Open current working directory (openCwd is the SdFat 2.x canonical method)
  // Reference: SdFat 2.x API - openCwd() synchronizes with firmware state
  if (!m_dirFile.openCwd()) {
    LOGE(DIR, "openCwd FAIL after chdir to ");
    LOG_PRINTLN(currentPath);
    return false;
  }

  // Step 3: Rewind to ensure clean iteration state
  m_dirFile.rewind();

  // Sprint 5 P2.1: Explicit state validation in DEBUG mode
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

  // Sprint 5 P1.1: Change directory to root
  // SdFat chdir() without parameters returns to root (official example)
  if (!sd.chdir()) {
    LOGE(DIR, "chdir root FAIL");
    return;
  }

  // Sprint 5 P1.1: MANDATORY - Resync directory handle after chdir
  // This ensures m_dirFile is synchronized with firmware's CWD
  if (!ResyncDirFromCwd()) {
    LOGE(DIR, "ResyncDirFromCwd FAIL at root");
    return;
  }

  LOGI(DIR, "Changed to ROOT");
}

bool DirFunction::GoBack() {
  if (pathDepth == 0) {
    LOGW(DIR, "GoBack: Already at ROOT");
    return false;
  }

  int len = strlen(currentPath);
  if (len <= 1) {
    ToRoot();
    return true;
  }

  // Save current state for rollback
  char savedPath[64];
  strcpy(savedPath, currentPath);
  uint8_t savedDepth = pathDepth;

  // Remove trailing slash
  if (currentPath[len-1] == '/') {
    currentPath[len-1] = '\0';
    len--;
  }

  // Find last '/' and truncate
  for (int i = len - 1; i >= 0; i--) {
    if (currentPath[i] == '/') {
      if (i == 0) {
        // FIXED: Going back to root - use ToRoot() for consistency
        ToRoot();
        return true;
      } else {
        currentPath[i] = '\0';
      }
      break;
    }
  }

  pathDepth--;
  if (pathDepth == 0) InSubDir = 0;

  LOGD(DIR, "GoBack to: "); LOG_PRINTLN(currentPath);

  // Sprint 5 P1.1: Change directory
  if (!sd.chdir(currentPath)) {
    LOGE(DIR, "GoBack chdir FAIL");
    // Rollback
    strcpy(currentPath, savedPath);
    pathDepth = savedDepth;
    InSubDir = (pathDepth > 0) ? 1 : 0;
    return false;
  }

  // Sprint 5 P1.1: MANDATORY - Resync directory handle after chdir
  if (!ResyncDirFromCwd()) {
    LOGE(DIR, "GoBack ResyncDirFromCwd FAIL");
    // Rollback
    strcpy(currentPath, savedPath);
    pathDepth = savedDepth;
    InSubDir = (pathDepth > 0) ? 1 : 0;
    return false;
  }

  return true;
}

bool DirFunction::ChangeDirectory(char * directory) {
  if (!directory || directory[0] == '\0') {
    LOGW(DIR, "ChangeDirectory: Empty name");
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

  // Sprint 5 P1.1: Use RELATIVE path with sd.chdir() - SdFat 2.x best practice
  // No need to go back to root, just navigate relative to current directory
  // Reference: SdFat 2.3.0 examples/DirectoryFunctions/DirectoryFunctions.ino line 121
  if (!sd.chdir(directory)) {
    LOGE(DIR, "chdir FAILED: ");
    LOG_PRINTLN(directory);
    // Rollback - restore state
    strcpy(currentPath, savedPath);
    pathDepth = savedDepth;
    InSubDir = (pathDepth > 0) ? 1 : 0;
    return false;
  }

  // Sprint 5 P1.1: MANDATORY - Resync directory handle after chdir
  if (!ResyncDirFromCwd()) {
    LOGE(DIR, "ChangeDirectory ResyncDirFromCwd FAIL");
    // Rollback - restore state
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

  // Sprint 5 P1.1: CRITICAL FIX - Use openCwd() instead of open(currentPath)
  // currentPath is for UI/debug ONLY. The firmware's CWD is the single source of truth.
  // This ensures we're always synchronized with the actual directory state.
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

  LOGD(DIR, "Prepare: "); LOG_PRINT(currentPath); LOG_PRINT_F(" n="); LOG_PRINTLN(count);
}

int DirFunction::Iterate() {
  File   file;

  CurrentFileName.ResetIndex();

  if (InSubDir == 1 && currentIndex == 0) {
    CurrentFileName.Copy("..");
    IsDirectory = 1;
    IsHidden = 0;
    currentIndex++;
    return 1;
  }

  if (currentIndex < count) {
    if (file.openNext(&m_dirFile)) {
      if (!file.isHidden()) {
        file.printName(&CurrentFileName);
        currentIndex++;
        IsDirectory = file.isSubDir();
        IsHidden = 0;
        file.close();
        return 1;
      }  else {
        IsHidden = 1;
        IsDirectory = file.isSubDir();
        file.close();
        return 1;
      }
    } else {
      IsFinished = 1;
      LOGD(DIR, "Iterate EOF or Error");
      return 0;
    }
  } else {
    IsFinished = 1;
    LOGD(DIR, "Iterate Finished");
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

// ========================================================================
// NEW METHODS FOR SPRINT 1: Enhanced basename navigation with validation
// ========================================================================

bool DirFunction::ChangeDirectoryBasename(const char* basename) {
  if (!basename || basename[0] == '\0') {
    LOGW(DIR, "ChangeDirectoryBasename: Empty basename");
    return false;
  }

  LOGD(DIR, "CD: "); LOG_PRINTLN(basename);

  // Special case: ".." means go back
  if (strcmp(basename, "..") == 0) {
    return GoBack();
  }

  // Validate basename doesn't contain path separators
  if (strchr(basename, '/') != NULL) {
    LOGW(DIR, "ChangeDirectoryBasename: Invalid name (contains /)");
    return false;
  }

  // Use existing ChangeDirectory method
  return ChangeDirectory((char*)basename);
}

const char* DirFunction::GetCurrentPath() const {
  return currentPath;
}

void DirFunction::ForceReset() {
  LOGI(DIR, "ForceReset");

  ToRoot();
  Prepare();

  LOGD(DIR, "After reset: "); LOG_PRINT(currentPath); LOG_PRINT_F(" n="); LOG_PRINTLN(count);
}

void DirFunction::CloseDirHandle() {
  if (m_dirFile.isOpen()) {
    m_dirFile.close();
  }
}
