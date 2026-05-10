#ifndef _DIR_FUNCTION_H
#define _DIR_FUNCTION_H

#include <SdFat.h>

class DirFunction {

  protected:
    File m_dirFile;
    bool ResyncDirFromCwd();
    void CountEntries();
    bool FindEntrySFN(const char* prefix, uint8_t len, char* outSFN, size_t outSize, bool wantDir);

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

    // Resolve a (possibly LFN) basename to its 8.3 short filename (SFN).
    // SdFat 2.x sd.open()/sd.chdir() can fail for LFN names with spaces or
    // lowercase even when the entry exists; the SFN form (e.g. PICBRA~1.KOA,
    // KOALAP~1) opens reliably for the same on-disk entry. Iterates CWD via
    // openNext (which reads LFN entries correctly), case-insensitive prefix-
    // matches the LFN, then writes the SFN into outSFN.
    // SFN max is 12 chars + NUL — outSize 16 is plenty.
    bool FindFileSFN(const char* prefix, uint8_t len, char* outSFN, size_t outSize);
    bool FindDirSFN(const char* prefix, uint8_t len, char* outSFN, size_t outSize);

    // Preview buffer used for menu listing transport to the C64.
    // It intentionally stores only the leading part of a filename.
    char currentFileName[32];
    int IsDirectory;
    int IsFinished;
    int InSubDir;
};

#endif  // _DIR_FUNCTION_H
