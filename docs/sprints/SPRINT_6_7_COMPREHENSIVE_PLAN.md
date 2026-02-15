# Sprint 6 + Sprint 7 Átfogó Közös Terv

**Dátum:** 2025-12-26
**Projekt:** EasySD IRQHack64
**Célok:** Sprint 6 lezárás + Sprint 7 build rendszer átstrukturálás
**Készítette:** Közös tervezés (User + Claude Sonnet 4.5)

---

## 🎯 Executive Summary

### Jelenlegi Helyzet

**Sprint 6 (v2.1.0 Production Polish):** ✅ **TECHNIKAI SZEMPONTBÓL KÉSZ**
- Arduino firmware production-ready
- File I/O API működik és tesztelve
- Release build UART-mentes
- POST-SPRINT6 cleanup befejezve (DebugLog.h, dead code removal, init cleanup)

**VISZONT:**
- **Build rendszer állapota tisztázatlan** (Sprint 6 közben build issues merültek fel)
- **Sprint 6 dokumentáció hiányos** (nincs hivatalos SPRINT6_COMPLETION.md master verzió)
- **Build metrics megbízhatatlanok** (target konfúzió miatt)

### Felismert Probléma (Sprint 6 végén)

**"Build értelmezési hibák"** - A Sprint 6 alatt a következő problémák merültek fel:

1. **FlashLib.h és BuildConfig.h repo-ba íródik** (generált fájlok verziókezelve)
2. **Target típusok keveredése** (release vs debug-vice vs debug-arduino)
3. **BuildConfig.h "stale state"** rizikó (melyik build generálta utoljára?)
4. **VICE-only build felesleges artifact-eket generál** (FlashLib.h, BuildConfig.h)
5. **Arduino compile nem ellenőrzi FlashLib.h frissességét**

### Sprint 7 Cél

**Build rendszer "világok" szétválasztása:**

```
BUILD (artifact generálás)
  ↓
  ├─→ C64 artifacts (PRG, listing, symbols)
  ├─→ Arduino headers (FlashLib.h, BuildConfig.h) → build/artifacts/
  └─→ NEM ír repo forrásokba

COMPILE/UPLOAD/MONITOR (tool műveletek)
  ↓
  └─→ Arduino workspace (FlashLib.h, BuildConfig.h másolva build/-ból)
```

**Kulcs elvek:**
- **BUILD** ≠ **TOOL MŰVELETEK** (compile/upload)
- **VICE-only** ≠ **Arduino artifacts** generálás
- **Git clean workspace** (FlashLib.h, BuildConfig.h .gitignore)
- **Stale detection** (timestamp + intent tracking)

---

## 📋 SPRINT 6 Lezárási Státusz (Tényszerű)

### ✅ Teljesült Feladatok (100%)

| Komponens | Státusz | Bizonyíték |
|-----------|---------|-----------|
| **A1:** Build system EASYSD_DEBUG_SERIAL | ✅ KÉSZ | `Tools/build.py:340-344` |
| **A2:** DEBUG → EASYSD_DEBUG_SERIAL átnevezés | ✅ KÉSZ | 108 occurrence, 0 hiba |
| **B1:** DebugLog.h unified API | ✅ KÉSZ | `Arduino/IRQHack64/DebugLog.h` létezik |
| **B2:** Dead code removal | ✅ KÉSZ | 93 sor törölve `CartApi.cpp`-ből |
| **B3:** Init log deduplication | ✅ KÉSZ | `IRQHack64.ino` duplikáció fix |
| **B4:** F() macro compliance | ✅ KÉSZ | 0 violation |
| **D1-D3:** File I/O API | ✅ KÉSZ | HandleOpen/Read/Close verified |
| **D4:** File I/O test suite | ✅ KÉSZ | `Tools/test_file_io.py` + docs léteznek |
| **P1.1:** Cold boot retry logic | ✅ KÉSZ | Sprint 6 plan szerint implementálva |
| **P1.2:** Serial UI/UX | ✅ KÉSZ | Banner, help, listing, error handling |
| **P2:** Error handling + Memory display | ✅ KÉSZ | Sprint 6 plan szerint |

### ⚠️ Hiányzó Dokumentáció (Sprint 6)

| Deliverable | Státusz | Prioritás |
|-------------|---------|-----------|
| **SPRINT6_COMPLETION.md** (master) | ❌ HIÁNYZIK | HIGH |
| **CHANGELOG_UNIFIED.md** v2.1.0 entry | ❓ ELLENŐRZENDŐ | MEDIUM |
| **SERIAL_UI_GUIDE.md** | ❌ HIÁNYZIK | LOW |
| **Hardware debug jumper docs** | ❌ HIÁNYZIK | LOW |
| **Dokumentáció archiválás** | ❌ NEM TÖRTÉNT | LOW |

### 🔧 Felismert Build Rendszer Problémák (Sprint 6 alatt)

Ezek a problémák **Sprint 6 során merültek fel**, de **Sprint 7-ben** oldódnak meg:

1. **FlashLib.h repo-ba írás** → Sprint 7: build/artifacts/ + .gitignore
2. **BuildConfig.h intent confusion** → Sprint 7: single source of truth
3. **VICE-only waste** → Sprint 7: no Arduino artifacts for VICE
4. **Stale detection hiánya** → Sprint 7: timestamp + pre-build check
5. **Build metrics összehasonlíthatatlanok** → Sprint 7: target dokumentálás

---

## 🚀 SPRINT 7 Terv (Build Rendszer Átstrukturálás)

### Sprint 7 Fókusz (User által megosztott terv alapján)

**Cél:** Build rendszer "határai" világosak legyenek (mit mikor csinálhat)

**Kulcs Elvek:**
- **BUILD:** csak artefaktokat gyárt *a build könyvtárba* (nem fordít, nem tölt fel)
- **COMPILE:** fordít (Arduino)
- **UPLOAD:** feltölt (Arduino)
- **MONITOR:** soros monitor (Arduino)

**Targetenként izoláltan:**
- **release:** C64 DEBUG=0, Arduino Serial OFF
- **vice-only:** C64 DEBUG=1, **NEM GENERÁL** Arduino artifacts
- **arduino-only (serial/debug):** Arduino compile/upload, BuildConfig.h kezelés

### Sprint 7 Fázisok (User terv alapján)

#### Fázis 0: Dokumentum Audit (0.5 óra)

**Cél:** Sprint 4-6 lezárások, changelog, build workflow áttekintése

**Kimenet:** 1 oldalas "Sprint 7 előfeltétel összefoglaló"
- Mi számít release-nek
- Mi számít vice-onlynak
- Mi számít arduino-only debugnak

**Fájlok áttekintése:**
- SPRINT4_COMPLETION.md, SPRINT5_COMPLETION.md
- POST_SPRINT6_FINAL_COMPLETION.md
- CHANGELOG_UNIFIED.md
- build_new.py workflow

---

#### Fázis 1: Architektúra Elemzés (KÓD NÉLKÜL) (1-2 óra)

**Cél:** Hol keletkeznek artefaktok, ki ír mit, mikor

**Elemzendő kódrészek (felelősségekkel):**

1. **build_new.py**
   - Hol választ targetet? → `main()` arg parsing
   - Hol kezeli build könyvtárat? → `Context` dataclass
   - Hol épít C64 oldalt? → `build_core()` petcat/64tass
   - Hol nyúl Arduino fájlokhoz? → `bin2ardh()`, `shutil.copyfile()`
   - Hol generál BuildConfig-ot? → Háromszor! (build_core, arduino_generate_buildconfig, arduino_upload előtt)

2. **Arduino tool-hívások**
   - Melyik mappát fordítja? → `Arduino/IRQHack64/` (repo!)
   - Mikor generálja BuildConfig-ot? → Compile előtt
   - Stale állapot? → Ellenőrzés NINCS

3. **Arduino sketch struktúra**
   - Fix források: .ino, .cpp, .h fájlok
   - Generáltak: FlashLib.h, BuildConfig.h
   - Arduino-CLI követelmény: KELL a sketch könyvtárba

4. **VICE-only ág**
   - Arduino artifact generálás? → IGEN (feleslegesen!)
   - BuildConfig.h írás? → IGEN (waste!)

**Kimenet (Sprint 7 deliverable #1):**
- **build_pipeline_map.md** - Inputok, outputok, side effects, döntési pontok

---

#### Fázis 2: Új Build Modell Leírása (KÓD NÉLKÜL) (1 óra)

**BUILD (artifact generálás):**
- Target-alapú build mappába dolgozik (`build/release/`, `build/debug-vice/`, stb.)
- C64 artefaktok: PRG-k, listák, symbols
- Arduino artefaktok: FlashLib.h, BuildConfig.h → `build/artifacts/` (NEM repo-ba!)
- **FONTOS:** BUILD nem fordít Arduino-t, nem tölt fel, nem nyit monitort

**COMPILE/UPLOAD/MONITOR (tool fázisok):**
- Tool műveletek, nem targetek
- Előre elkészített **build workspace**-en dolgoznak
- BuildConfig.h **itt** generálódik (vagy másolódik build/artifacts/-ból)

**Vice-only szabály:**
- Vice-only **SOHA NEM** hoz létre Arduino workspace-t
- Vice-only **SOHA NEM** generál FlashLib.h-t vagy BuildConfig.h-t

**Kimenet (Sprint 7 deliverable #2):**
- **build_model_design.md** - Fogalmak, szabályok, pipeline

---

#### Fázis 3: Tesztelési Terv (2-3 óra)

**Regressziós tesztek (minimum):**

1. **release BUILD**
   - Létrejönnek C64 artefaktok ✅
   - NEM jön létre Arduino workspace ✅
   - Repo Arduino mappa NEM változik ✅

2. **debug-vice BUILD**
   - Létrejönnek C64 debug/vice futtatható kimenetek ✅
   - NINCS ino másolás ✅
   - Repo érintetlen ✅

3. **debug-arduino BUILD**
   - Létrejönnek Arduino-hoz szükséges generált fájlok `build/artifacts/`-ban ✅
   - Workspace összeállhat, de **feltöltés nem történik** ✅

4. **arduino-compile**
   - Kizárólag build workspace-ből fordít ✅
   - BuildConfig.h frissül compile előtt ✅
   - Kimenet (hex/elf) build target alá kerül ✅

5. **arduino-upload**
   - Előfeltétel: compile vagy önmaga triggereli ✅
   - Port/board beállítások konzisztensek ✅
   - Upload után firmware elvárt módban fut ✅

6. **arduino-monitor**
   - Debug módban minimális "banner" látszik ✅

**"Stale state" ellenőrzés (KRITIKUS):**

Teszt forgatókönyv:
```bash
# 1. Release build
python build.py release
# Elvárt: BuildConfig.h = Serial OFF

# 2. Arduino-serial compile debug nélkül
python build.py arduino-compile
# Elvárt: BuildConfig.h = Serial OFF (konzisztens)

# 3. Arduino-serial compile debug-gal
python build.py arduino-compile --debug
# Elvárt: BuildConfig.h = Serial ON (újragenerálva)

# 4. Ellenőrzés: BuildConfig.h mindig az utolsó kérést tükrözi
cat Arduino/IRQHack64/BuildConfig.h
```

**Kimenet (Sprint 7 deliverable #3):**
- **test_scenarios_checklist.md** - Parancsok sorrendje + elvárt jelenség

---

#### Fázis 4: Build Rendszer Dokumentálás (1-2 óra)

**Dokumentálandó:**

1. **Fogalmak:**
   - Mi a BUILD target
   - Mi a tool művelet
   - Mi a workspace
   - Mi a BuildConfig szerepe

2. **Ajánlott workflow-k:**
   - Release build
   - VICE-only debug futtatás
   - Arduino serial debug build → compile → upload → monitor

3. **Hibaelhárítás:**
   - "Nincs serial output" esetek
   - "Rossz targetből fordít" esetek
   - Stale FlashLib.h detection

**Kimenet (Sprint 7 deliverable #4):**
- **BUILD_SYSTEM.md** - Teljes build rendszer dokumentáció

---

### Sprint 7 Elfogadási Kritériumok (Definition of Done)

Sprint 7 **KÉSZ**, ha:

1. ✅ Release / vice-only / arduino-only **nem piszkálják egymás outputját**
2. ✅ VICE-only ágban **bizonyíthatóan nincs ino/workspace művelet**
3. ✅ Arduino compile/upload **bizonyíthatóan a build workspace-ből** dolgozik
4. ✅ BuildConfig.h kezelés **nem tud "bennragadni"**
5. ✅ Tesztek checklist szerint lefutnak, eredmény dokumentálva
6. ✅ Van friss **BUILD_SYSTEM.md** dokumentáció a repóban

---

## 🗂️ Közös Sprint 6+7 Ütemterv

### Sprint 6 Lezárás (0.5-1 óra)

**Céle:** Hivatalos Sprint 6 dokumentáció befejezése

**Feladatok:**

1. **SPRINT6_COMPLETION.md létrehozása** (master verzió)
   - Összefoglalja Sprint 6 + POST-SPRINT6 eredményeit
   - Firmware metrics (v2.1.0 final)
   - Tesztelési eredmények
   - Definition of Done ellenőrzés

2. **CHANGELOG_UNIFIED.md frissítése**
   - v2.1.0 entry ellenőrzése/kiegészítése
   - Sprint 6 változások listázása

3. **Sprint 6 hivatalos lezárás**
   - Git commit: "Sprint 6 (v2.1.0 Production Polish) - COMPLETE"
   - Tag: `v2.1.0` (ha még nincs)

**Kimenet:**
- ✅ Sprint 6 hivatalosan lezárva
- ✅ v2.1.0 production-ready firmware
- ✅ Dokumentáció teljes

---

### Sprint 7 Fázis 0-1: Előkészítés és Elemzés (2-3 óra)

**Feladatok:**

1. **Fázis 0:** Dokumentum audit (0.5 óra)
   - Sprint 4-6 áttekintése
   - Build workflow mapping
   - **Kimenet:** `SPRINT7_PREREQUISITES.md`

2. **Fázis 1:** Architektúra elemzés (1.5-2 óra)
   - build_new.py működés feltérképezése
   - Arduino tool-hívások elemzése
   - FlashLib.h/BuildConfig.h generálás audit
   - **Kimenet:** `build_pipeline_map.md`

**Milestone:** ✅ Teljes build rendszer állapot tisztázva (KÓD NÉLKÜL)

---

### Sprint 7 Fázis 2-3: Tervezés és Teszt Előkészítés (3-4 óra)

**Feladatok:**

1. **Fázis 2:** Build modell design (1 óra)
   - BUILD vs TOOL műveletek szétválasztása
   - VICE-only szabályok
   - Workspace kezelés stratégia
   - **Kimenet:** `build_model_design.md`

2. **Fázis 3:** Tesztelési terv (2-3 óra)
   - Regressziós teszt forgatókönyvek
   - Stale state teszt script
   - **Kimenet:** `test_scenarios_checklist.md`

**Milestone:** ✅ Sprint 7 implementáció teljesen megtervezett

---

### Sprint 7 Fázis 4: Implementáció (4-6 óra)

**Feladatok:**

1. **Git változtatások:**
   - `.gitignore` frissítés (FlashLib.h, BuildConfig.h)
   - Backup jelenlegi állapot (branch vagy tag)

2. **build_new.py refactoring:**
   - BuildConfig.h generálás centralizálása
   - VICE-only ág: Arduino artifact generálás KIKAPCSOLÁSA
   - FlashLib.h/BuildConfig.h → `build/artifacts/` írás
   - Arduino workspace másolás (compile előtt)

3. **Stale detection implementálás:**
   - Timestamp check (FlashLib.h vs C64 sources)
   - Pre-compile validation
   - Figyelmeztetés, ha stale

4. **Tesztelés:**
   - Összes regressziós teszt futtatása
   - Stale state teszt
   - Dokumentálás

**Milestone:** ✅ Build rendszer átstrukturálva és tesztelve

---

### Sprint 7 Fázis 5: Dokumentálás és Lezárás (2-3 óra)

**Feladatok:**

1. **BUILD_SYSTEM.md létrehozása**
   - Teljes build rendszer dokumentáció
   - Workflow példák
   - Hibaelhárítás

2. **SPRINT7_COMPLETION.md**
   - Sprint 7 eredmények
   - Definition of Done ellenőrzés

3. **README.md frissítése**
   - Build rendszer használat
   - Target típusok táblázat

4. **Git lezárás:**
   - Commit: "Sprint 7 (Build System Refactoring) - COMPLETE"
   - Tag: `v2.1.1` vagy `v2.2.0` (build rendszer változás)

**Milestone:** ✅ Sprint 7 hivatalosan lezárva

---

## 📊 Összesített Sprint 6+7 Effort Estimate

| Sprint | Fázis | Feladatok | Becsült Idő | Kumulatív |
|--------|-------|-----------|-------------|-----------|
| **Sprint 6** | Lezárás | Dokumentáció befejezés | 0.5-1h | 1h |
| **Sprint 7** | Fázis 0 | Dokumentum audit | 0.5h | 1.5h |
| **Sprint 7** | Fázis 1 | Architektúra elemzés (kód nélkül) | 1.5-2h | 3.5h |
| **Sprint 7** | Fázis 2 | Build modell design (kód nélkül) | 1h | 4.5h |
| **Sprint 7** | Fázis 3 | Tesztelési terv | 2-3h | 7.5h |
| **Sprint 7** | Fázis 4 | Implementáció + tesztelés | 4-6h | 13.5h |
| **Sprint 7** | Fázis 5 | Dokumentálás + lezárás | 2-3h | **16.5h total** |

**Becsült teljes időtartam:**
- **Sprint 6 lezárás:** 0.5-1 óra
- **Sprint 7 teljes:** 12-15 óra
- **Összesen:** **13-16 óra** (2-3 munkanap casual pace vagy 1.5-2 nap focused sprint)

---

## 🎯 Következő Lépések Javaslat

### Opció A: Sprint 6 Lezárás ELŐSZÖR (Javasolt)

**Előnyök:**
- Clean slate Sprint 7 indításához
- Dokumentáció teljes
- v2.1.0 hivatalosan production-ready

**Lépések:**
1. SPRINT6_COMPLETION.md létrehozása (30 perc)
2. CHANGELOG frissítés (15 perc)
3. Git commit + tag (15 perc)
4. ✅ Sprint 6 lezárva → Sprint 7 indítása

---

### Opció B: Sprint 7 Azonnal Indítás (Rizikósabb)

**Előnyök:**
- Gyorsabb haladás
- Build problémák azonnal kezelve

**Hátrányok:**
- Sprint 6 dokumentáció hiányos marad
- Nehezebb utólag rekonstruálni

**Lépések:**
1. Sprint 7 Fázis 0 (dokumentum audit) - PÁRHUZAMOSAN Sprint 6 lezárással
2. Sprint 7 Fázis 1-5 végrehajtása
3. Sprint 6 dokumentáció utólag

---

### Opció C: Hibrid Megközelítés (Rugalmas)

**Lépések:**
1. **MA:** Sprint 6 gyors lezárás (1 óra) + Sprint 7 Fázis 0 dokumentum audit (0.5 óra)
2. **HOLNAP:** Sprint 7 Fázis 1-2 elemzés és tervezés (3-4 óra, KÓD NÉLKÜL)
3. **HARMADIK NAP:** Sprint 7 Fázis 3-5 implementáció, teszt, dokumentálás (8-10 óra)

---

## ❓ Megbeszélendő Kérdések

### 1. Sprint 6 Lezárás

**Kérdés:** Készítsünk hivatalos SPRINT6_COMPLETION.md master dokumentumot?
- **A)** Igen, azonnal (30 perc, tiszta lezárás)
- **B)** Később, Sprint 7 után
- **C)** Nem szükséges (POST_SPRINT6_FINAL_COMPLETION.md elég)

---

### 2. Sprint 7 Build Modell Opciók

**User által megosztott terv alapján, melyik build flow stratégiát válasszuk?**

**Opció A: "Copy to workspace" (javasolt - egyszerűbb)**
```
IRQHack64/build/artifacts/
├── FlashLib.h          (generated here)
└── BuildConfig.h       (generated here)

Arduino/IRQHack64/
├── FlashLib.h          (copied from build/artifacts before compile)
├── BuildConfig.h       (copied from build/artifacts before compile)
└── .gitignore          (FlashLib.h, BuildConfig.h added)
```

**Előnyök:**
- Egyszerű implementáció
- Arduino-CLI kompatibilis (sketch könyvtárban kell lennie)
- Git clean (.gitignore)

**Hátrányok:**
- File másolás overhead (minimális)

---

**Opció B: "Build workspace in build/" (komplexebb)**
```
IRQHack64/build/arduino-workspace/
├── IRQHack64.ino       (symlink or copy)
├── *.cpp, *.h          (symlink or copy)
├── FlashLib.h          (generated)
└── BuildConfig.h       (generated)

Arduino/IRQHack64/      (source only, no generated files)
```

**Előnyök:**
- Teljes repo clean (semmilyen generált fájl nincs Arduino/IRQHack64/-ban)
- Build outputs izoláltak

**Hátrányok:**
- Arduino-CLI sketch path kezelés
- Windows symlink support kérdéses
- Bonyolultabb workspace setup

---

**Opció C: "Pre-build check" (jelenlegi + stale detection)**
```
Jelenlegi struktúra megtartva:
Arduino/IRQHack64/
├── FlashLib.h          (generated, .gitignore)
├── BuildConfig.h       (generated, .gitignore)

+ Pre-build validation:
  - FlashLib.h timestamp vs C64 sources
  - BuildConfig.h intent tracking (comment: "Generated by: release")
  - Figyelmeztetés, ha stale
```

**Előnyök:**
- Minimális változtatás jelenlegi rendszerhez
- Gyors implementáció

**Hátrányok:**
- Továbbra is repo-ban van (csak .gitignore-olva)

---

### 3. VICE-only Build Behavior

**Kérdés:** Vice-only build generáljon Arduino artifacts-et?

**Jelenlegi:** Generál (FlashLib.h, BuildConfig.h), de felesleges

**Opció A:** VICE-only **NEM** generál Arduino artifacts (tisztább)
- Előny: Nincs waste, gyorsabb build
- Hátrány: Ha utána arduino-compile, lehet FlashLib.h stale

**Opció B:** VICE-only továbbra is generál (biztonságosabb)
- Előny: Arduino artifacts mindig frissek
- Hátrány: Felesleges művelet VICE-only futtatásnál

---

### 4. BuildConfig.h "Intent Tracking"

**Kérdés:** BuildConfig.h tartalmazza-e, melyik target generálta?

**Opció A:** Igen (comment tracking)
```cpp
// Generated by: release (2025-12-26 16:30)
// EASYSD_DEBUG_SERIAL disabled (release build)
```

**Opció B:** Nem, csak timestamp
- Hátrány: Nem látszik intent, csak mtime

---

## 📌 Végső Kérdés

**Hogyan haladjunk tovább?**

1. **Sprint 6 lezárást** kezdjük (SPRINT6_COMPLETION.md)?
2. Vagy **Sprint 7 Fázis 0** dokumentum audit-tal indítunk (párhuzamosan)?
3. Vagy **megbeszéljük** a Sprint 7 build modell opciókat először?

**Várom a döntésed, hogy melyik irányt választjuk!** 🚀

---

**Dokumentum verzió:** 1.0 (Draft - megbeszélésre vár)
**Következő lépés:** User döntés a fenti kérdésekre
**Eszközök készen:** Sprint 6 lezárás ÉS Sprint 7 indítás egyaránt végrehajtható
