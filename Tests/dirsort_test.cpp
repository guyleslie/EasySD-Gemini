// Host-side tests for the directory display-order and pagination logic.
//
// Run with:  python Tools/build.py test
//
// Why this exists: HandleReadDirectory() serves the menu one page of 21 entries
// at a time by collecting the N smallest entries strictly greater than a
// watermark. On hardware that path needs an SD card, a C64 and a human pressing
// keys, which is why five revert/restore commits went through it without ever
// pinning down what was wrong. The primitives are pure functions, so they can
// be driven here in a second.
//
// The page loop below mirrors the firmware pass 1 + pass 2 in
// Arduino/EasySD/CartApi.cpp (HandleReadDirectory). If that loop changes, this
// model must change with it.

#include "../Arduino/EasySD/DirSort.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// ---------------------------------------------------------------- framework

static int g_failures = 0;
static int g_checks = 0;
static int g_knownBugs = 0;

static void expect(bool cond, const char* what) {
  ++g_checks;
  if (!cond) {
    ++g_failures;
    std::printf("  FAIL  %s\n", what);
  }
}

static void printList(const char* label, const std::vector<std::string>& v) {
  std::printf("        %s", label);
  for (const auto& s : v) std::printf(" [%s]", s.c_str());
  std::printf("\n");
}

static void expectEq(const std::vector<std::string>& got,
                     const std::vector<std::string>& want,
                     const char* what) {
  ++g_checks;
  if (got == want) return;
  ++g_failures;
  std::printf("  FAIL  %s\n", what);
  printList("want:", want);
  printList("got: ", got);
}

// A defect that is known and deliberately not fixed yet: reported, not counted
// as a failure, so the suite stays green until someone fixes it on purpose.
static void knownBug(bool bugStillPresent, const char* id, const char* what) {
  ++g_knownBugs;
  std::printf("  %s  %s: %s\n",
              bugStillPresent ? "KNOWN BUG" : "FIXED?   ", id, what);
  if (!bugStillPresent) {
    std::printf("        This no longer reproduces. If that was intentional, turn this\n");
    std::printf("        case into a normal expectation and drop the knownBug() wrapper.\n");
  }
}

// ---------------------------------------------------------------- the model

struct Entry {
  std::string name;
  bool isDir;
};

// One page, exactly as the firmware builds it.
//   pass 1: single forward scan over the directory in on-disk order, keeping
//           the 'cap' smallest entries greater than the watermark, compared by
//           a 15-character truncated key;
//   pass 2: each slot retrieves its FULL name by dirIdx, transmits it, and the
//           watermark becomes that full name.
static std::vector<std::string> collectPage(const std::vector<Entry>& dir,
                                            std::string& wmName,
                                            uint8_t& wmIsDir,
                                            uint8_t cap) {
  std::vector<DirSortSlot> slots(cap);
  uint8_t numSlots = 0;

  for (uint16_t i = 0; i < dir.size(); ++i) {
    const char* name = dir[i].name.c_str();
    const uint8_t isDir = dir[i].isDir ? 1 : 0;
    if (std::strcmp(name, "..") == 0) continue;
    if (cmpDirEntry(isDir, name, wmIsDir, wmName.c_str()) <= 0) continue;
    char key[16];
    std::strncpy(key, name, 15);
    key[15] = '\0';
    sortSlotInsert(slots.data(), numSlots, cap, key, i, isDir);
  }

  std::vector<std::string> sent;
  for (uint8_t i = 0; i < numSlots; ++i) {
    const Entry& e = dir[slots[i].dirIdx];
    sent.push_back(e.name);
    wmName = e.name;
    wmIsDir = e.isDir ? 1 : 0;
  }
  return sent;
}

// Page through the whole directory the way the menu does.
static std::vector<std::string> pageThrough(const std::vector<Entry>& dir, uint8_t pageSize) {
  std::vector<std::string> all;
  std::string wmName;
  uint8_t wmIsDir = 1;   // firmware starts with an empty name and isDir = 1
  for (;;) {
    std::vector<std::string> page = collectPage(dir, wmName, wmIsDir, pageSize);
    if (page.empty()) break;
    all.insert(all.end(), page.begin(), page.end());
  }
  return all;
}

// What the display order should be, independent of on-disk order.
static std::vector<std::string> expectedOrder(const std::vector<Entry>& dir) {
  std::vector<const Entry*> ptrs;
  for (const auto& e : dir) ptrs.push_back(&e);
  for (size_t i = 0; i < ptrs.size(); ++i) {
    for (size_t j = i + 1; j < ptrs.size(); ++j) {
      if (cmpDirEntry(ptrs[j]->isDir, ptrs[j]->name.c_str(),
                      ptrs[i]->isDir, ptrs[i]->name.c_str()) < 0) {
        std::swap(ptrs[i], ptrs[j]);
      }
    }
  }
  std::vector<std::string> out;
  for (const auto* e : ptrs) out.push_back(e->name);
  return out;
}

// ----------------------------------------------------------------- the tests

static void test_compare_order() {
  std::printf("compare order\n");
  expect(cmpDirEntry(1, "ZZZ", 0, "AAA") < 0, "directories sort before files");
  expect(cmpDirEntry(0, "aaa.prg", 0, "AAA.PRG") == 0, "comparison is case-insensitive");
  expect(cmpDirEntry(0, "A.PRG", 0, "B.PRG") < 0, "files sort alphabetically");
  expect(cmpDirEntry(1, "GAMES", 1, "DEMOS") > 0, "directories sort among themselves");
}

static void test_single_page() {
  std::printf("single page holds everything\n");
  std::vector<Entry> dir = {
    {"ZORK.PRG", false}, {"GAMES", true}, {"elite.koa", false},
    {"DEMOS", true}, {"Bubble.prg", false},
  };
  expectEq(pageThrough(dir, 21), expectedOrder(dir), "one page, sorted");
}

static void test_pagination_invariant() {
  std::printf("pagination over many pages\n");
  std::vector<Entry> dir;
  char buf[32];
  for (int i = 0; i < 17; ++i) {          // directories, deliberately unsorted
    std::snprintf(buf, sizeof buf, "DIR%02d", (i * 7) % 17);
    dir.push_back({buf, true});
  }
  for (int i = 0; i < 48; ++i) {          // files, deliberately unsorted
    std::snprintf(buf, sizeof buf, "GAME%02d.PRG", (i * 11) % 48);
    dir.push_back({buf, false});
  }
  const std::vector<std::string> got = pageThrough(dir, 21);
  expect(got.size() == dir.size(), "every entry is served exactly once across pages");
  expectEq(got, expectedOrder(dir), "page boundaries do not disturb the order");
}

static void test_page_size_one() {
  std::printf("degenerate page size\n");
  std::vector<Entry> dir = {{"C.PRG", false}, {"A.PRG", false}, {"B.PRG", false}};
  expectEq(pageThrough(dir, 1), expectedOrder(dir), "one entry per page still covers all");
}

// B1: the sort key is the first 15 characters of the name, but the watermark
// filter compares full names. Two entries sharing a 15-character prefix are
// therefore equal to pass 1 and distinct to the filter, so which one survives
// page 0 depends on the physical directory order.
//
// "MEGAGAME PART 0" is the first 15 characters of both names below.
static void test_b1_truncated_key_collision() {
  std::printf("B1 - 15-character key collision at a page boundary\n");

  const char* kIntro = "MEGAGAME PART 01 - INTRO.PRG";
  const char* kMusic = "MEGAGAME PART 01 - MUSIC.PRG";

  // Case 1: on disk MUSIC comes first (FAT returns creation order, not sorted).
  std::vector<Entry> unlucky = {
    {"AAA.PRG", false}, {kMusic, false}, {kIntro, false}, {"ZZZ.PRG", false},
  };
  const std::vector<std::string> gotUnlucky = pageThrough(unlucky, 2);
  const std::vector<std::string> wantUnlucky = expectedOrder(unlucky);

  // Case 2: same directory, same page size, only the on-disk order differs.
  std::vector<Entry> lucky = {
    {"AAA.PRG", false}, {kIntro, false}, {kMusic, false}, {"ZZZ.PRG", false},
  };
  const std::vector<std::string> gotLucky = pageThrough(lucky, 2);
  const std::vector<std::string> wantLucky = expectedOrder(lucky);

  const bool bug = (gotUnlucky != wantUnlucky);
  knownBug(bug, "B1",
           "an entry is dropped when two names share a 15-character prefix "
           "and the on-disk order differs from the display order");
  if (bug) {
    std::printf("        on-disk MUSIC,INTRO:\n");
    printList("want:", wantUnlucky);
    printList("got: ", gotUnlucky);
    std::printf("        on-disk INTRO,MUSIC:\n");
    printList("got: ", gotLucky);
    std::printf("        Pass 1 compares truncated keys (DirSortSlot.key) while the\n");
    std::printf("        watermark filter compares full names, so the entry kept on page 0\n");
    std::printf("        depends on directory order and the loser is then filtered out as\n");
    std::printf("        already sent.\n");
    // The favourable order must still be correct, or the diagnosis is wrong.
    expectEq(gotLucky, wantLucky, "B1: the favourable on-disk order still pages correctly");
  }
}

int main() {
  std::printf("dirsort tests\n\n");
  test_compare_order();
  test_single_page();
  test_pagination_invariant();
  test_page_size_one();
  test_b1_truncated_key_collision();
  std::printf("\n%d checks, %d failures, %d known bug(s)\n",
              g_checks, g_failures, g_knownBugs);
  return g_failures == 0 ? 0 : 1;
}
