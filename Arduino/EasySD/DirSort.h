#ifndef _DIRSORT_H
#define _DIRSORT_H

// Directory display-order primitives, shared by the firmware and by the
// host-side test suite (Tests/dirsort_test.cpp, run via
// `python Tools/build.py test`).
//
// These are pure functions with no Arduino or SdFat dependency, which is the
// whole point: HandleReadDirectory() pages a directory by repeatedly collecting
// the N smallest entries greater than a watermark, and that logic is impossible
// to exercise on real hardware without an SD card and a C64. Keeping it here
// lets it be tested on a PC.
//
// Moved verbatim out of CartApi.cpp; the firmware binary is unchanged.

#include <stdint.h>
#include <string.h>

// One slot in the in-place sort buffer overlaid on sharedBuf.ni.
// 19 bytes * 21 = 399 bytes <= NON_INTERRUPTED_BUFFER_SIZE (400).
struct DirSortSlot {
  char     key[16];   // first 15 chars of LFN + NUL (sort key, may be truncated)
  uint16_t dirIdx;    // FAT directory-entry index for pass-2 metadata/name lookup
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

#endif  // _DIRSORT_H
