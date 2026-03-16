#ifndef _DIR_FUNCTION_H
#define _DIR_FUNCTION_H

#include <SdFat.h>
// #include <SdFatUtil.h>  // Removed: Not available in SdFat 2.x


#include "StringPrint.h"
#include "CharStack.h"

class DirFunction  {

 protected:
   //SdFile   file;
   File m_dirFile;  // SdFat 2.x: Directory file handle for iteration

 protected:
    // Sprint 5 P2.2: Unified directory state synchronization helper
    bool ResyncDirFromCwd();

 public:
   static const unsigned int NMax = 20;
   char currentPath[64];
   uint8_t pathDepth;

   unsigned int count;
   unsigned int currentIndex;
   unsigned int selected;



    void SetSd(SdFat* sdFat);
    void ReInit(void);
    void ToRoot();
    bool GoBack();  // MODIFIED: now returns bool (Sprint 1)
    void Rewind();
    void Prepare();
    bool ChangeDirectory(char * directory);  // MODIFIED: now returns bool (Sprint 1)
    void SetSelected(unsigned int );
    unsigned int GetSelected(void);
    //void InitSerialize();
    //unsigned char Serialize();
    //unsigned char  Deserialize(unsigned char p);
    unsigned int GetCount();
    //void ChangeToSavedDirectory();
    int Iterate();

    // NEW METHODS FOR SPRINT 1: Enhanced basename navigation
    bool ChangeDirectoryBasename(const char* basename);
    bool NavigateToPath(const char* absPath); // Navigate from root to absolute path (Multi-Load V2)
    const char* GetCurrentPath() const;
    void ForceReset();
    void CloseDirHandle();
    StringPrint CurrentFileName;  
    int  IsDirectory;
    int IsFinished;
    int IsHidden;
    int InSubDir;
	
};
#endif _DIR_FUNCTION_H
