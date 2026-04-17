#ifndef _DIR_FUNCTION_H
#define _DIR_FUNCTION_H

#include <SdFat.h>

class DirFunction {

  protected:
    File m_dirFile;
    bool ResyncDirFromCwd();
    void CountEntries();

  public:
    char currentPath[64];
    uint8_t pathDepth;

    unsigned int count;
    unsigned int currentIndex;
    unsigned int selected;

    void ReInit(void);
    void ToRoot();
    bool GoBack();
    void Rewind();
    void Prepare();
    bool ChangeDirectory(char* directory);
    void SetSelected(unsigned int);
    unsigned int GetSelected(void);
    unsigned int GetCount();
    int Iterate();

    bool ChangeDirectoryBasename(const char* basename);
    bool FindDirectoryNameByVisibleIndex(uint16_t visibleIndex, char* outName, size_t outSize);
    bool NavigateToPath(const char* absPath);
    const char* GetCurrentPath() const;
    void ForceReset();
    void CloseDirHandle();

    // Scan CWD for a non-hidden file whose LFN starts with the first `len`
    // chars of `prefix` (case-insensitive). On match writes the captured name
    // into outName[outSize] and returns true. Does not affect Iterate() state.
    bool FindByPrefix(const char* prefix, uint8_t len, char* outName, size_t outSize);
    bool FindDirectoryByPrefix(const char* prefix, uint8_t len, char* outName, size_t outSize);

    // Preview buffer used for menu listing transport to the C64.
    // It intentionally stores only the leading part of a filename.
    char currentFileName[64];
    int IsDirectory;
    int IsFinished;
    int InSubDir;
};

#endif  // _DIR_FUNCTION_H
