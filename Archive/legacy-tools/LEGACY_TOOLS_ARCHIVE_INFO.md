# Legacy Tools - Archive Information

**Dátum:** 2025-12-27
**Projekt:** EasySD IRQHack64
**Verzió:** v2.2.0

---

## Archivált Fájlok (Legacy 2019)

Ez a dokumentum tartalmazza az archivált legacy eszközök leírását, amelyek a projekt 2019-es verziójából származnak és már nem használtak a v2.2.0+ verzióban.

### Miért archivált?

A `build.py` v2.2.0 verziója **Python reimplementációt tartalmaz** az összes legacy C# eszközre:
- `Bin2ArdH.cs` → `bin2ardh()` Python function (build.py:199-215)
- `CreateEpromLoader.cs` → `create_eprom_loader()` Python function (build.py:218-233)

Ezért az eredeti .exe és .cs fájlok **redundánsak és nem használtak**.

---

## Archivált Legacy Fájlok

### 1. Binary→Header Konverter
**Fájlok:**
- `Bin2ArdH.exe` (5 KB, 2019-06-20)
- `Bin2ArdH.cs` (1768 bytes, C# forráskód)

**Funkció:**
Bináris fájlokat konvertál Arduino PROGMEM header fájlokká.

**Példa használat:**
```bash
Bin2ArdH.exe loader.bin FlashLib.h loaderSize loaderData
```

**Kimenet:**
```cpp
int loaderSize = 1234;
static const unsigned char PROGMEM loaderData[1234] = {
  0x4C, 0x00, 0x80, ...
};
```

**Státusz:** ✅ Felváltva Python implementációval (`build.py:199-215`)

---

### 2. EPROM Loader Generátor
**Fájlok:**
- `CreateEpromLoader.exe` (5 KB, 2019-06-20)
- `CreateEpromLoader.cs` (1818 bytes, C# forráskód)

**Funkció:**
EPROM loader fájlokat generál 256 byte-os blokkokból 64KB EPROM image-ekké.

**Státusz:** ✅ Felváltva Python implementációval (`build.py:218-233`)

---

### 3. Checksum Utility
**Fájlok:**
- `CheckSum.exe` (4.5 KB, 2019-06-20)
- `CheckSum.cs` (1172 bytes, C# forráskód)

**Funkció:**
Bináris fájlok checksum számítása (pontos algoritmus ismeretlen).

**Státusz:** ❌ Nem használt a v2.2.0+ build rendszerben

---

### 4. IRQHack Serial Upload Eszközök
**Fájlok:**
- `IRQHackSend.exe` (6.5 KB, 2019-06-20)
- `IRQHackSendNew.exe` (19 KB, 2019-06-20)
- `IRQHackSend/` mappa - Visual Studio C# projekt (forrás + .sln)

**Funkció:**
Legacy soros port feltöltő eszközök a C64-re bináris küldésére (feltételezhetően).

**Státusz:** ❌ Nem használt (modern build rendszer arduino-cli-t használ)

---

### 5. SpeedCode Utility
**Fájlok:**
- `SpeedCode/` mappa - Visual Studio C# projekt (.sln fájl)

**Funkció:**
Ismeretlen (forrás nem volt elérhető a mappában, csak .sln fájl).

**Státusz:** ❌ Nem használt, ismeretlen funkció

---

### 6. ComputeSidPlayer.prg
**Fájl:**
- `ComputeSidPlayer.prg` (3155 bytes, 2019-12-19)

**Funkció:**
Compute! SID Player binary (feltételezhetően C64 SID zene lejátszó).

**Státusz:** ❌ Nem része a projekt fő funkciójának (SD kártya interface)

---

## Aktív Eszközök (v2.2.0+)

### Használt Fájlok (NEM archivált)

| Fájl | Funkció | Státusz |
|------|---------|---------|
| `build.py` | Fő build script (v2.2.0) | ✅ Aktív |
| `test_directory_navigation.py` | Directory navigation teszt | ✅ Aktív |
| `test_file_io.py` | File I/O teszt | ✅ Aktív |
| `README.md` | Tools dokumentáció | ✅ Aktív |
| `ARDUINO_CLI_SETUP.md` | Arduino CLI setup guide | ✅ Aktív |
| `FILE_IO_TEST_README.md` | File I/O test dokumentáció | ✅ Aktív |
| `SPRINT1_TEST_STEPS.txt` | Test protokoll (referencia) | ✅ Archív (hasznos) |

---

## Modern Workflow (v2.2.0+)

**Régi (2019):**
```bash
# 1. C# eszközök futtatása Windows-on
Bin2ArdH.exe loader.bin FlashLib.h ...
CreateEpromLoader.exe ...

# 2. Arduino IDE manuális feltöltés
```

**Új (2025):**
```bash
# 1. Egységes Python build (cross-platform)
python Tools/build.py debug-arduino

# 2. Automatikus Arduino build + upload
python Tools/build.py arduino-upload COM4
```

**Előnyök:**
- ✅ Cross-platform (Linux, macOS, Windows)
- ✅ Egyetlen build script (Python)
- ✅ Automatizált artifact generálás
- ✅ arduino-cli integráció (IDE nélkül)
- ✅ Staleness detection (FlashLib.h, BuildConfig.h)

---

## Archiválási Döntés

**Archivált fájlok:** `Tools_Legacy_2019.zip`

**Tartalma:**
- Bin2ArdH.exe + .cs
- CheckSum.exe + .cs
- CreateEpromLoader.exe + .cs
- IRQHackSend.exe
- IRQHackSendNew.exe
- IRQHackSend/ (teljes Visual Studio projekt)
- SpeedCode/ (teljes Visual Studio projekt)
- ComputeSidPlayer.prg

**Archiválás helye:** `C:\EasySD Gemini\docs\Archive_Legacy_Tools_20251227.zip`

**Törlés indoklása:**
1. ✅ Redundáns - Python reimplementáció létezik
2. ✅ Nem használt - v2.2.0+ build rendszer nem hivatkozza őket
3. ✅ Legacy - 2019-ből származik (~6 éves kód)
4. ✅ Platform függő - Windows-only .exe fájlok
5. ✅ Karbantartás költség - senki sem tartja karban

**Megőrzés indoklása:**
- Történeti dokumentáció
- Esetleges jövőbeli reverse engineering (ha szükséges)
- Archív reference implementation

---

## Következő Lépések

1. ✅ Legacy fájlok archiválása ZIP-be
2. ✅ ZIP elhelyezése docs/ mappában
3. ✅ Legacy fájlok törlése Tools/ mappából
4. ✅ Tools/README.md frissítése (legacy hivatkozások eltávolítása)

---

**Dokumentum készítette:** AI Assistant (Claude Sonnet 4.5)
**Dátum:** 2025-12-27
**Projekt Verzió:** v2.2.0 (Sprints 8-11 Complete)
