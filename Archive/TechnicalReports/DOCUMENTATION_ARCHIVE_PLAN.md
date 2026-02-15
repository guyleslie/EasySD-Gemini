# Documentation Archive & Cleanup Plan

**Dátum:** 2025-12-25
**Cél:** Elavult, redundáns és félrevezető dokumentumok archiválása

---

## Archiválandó Dokumentumok

### 1. Elavult BUGFIX Jelentések (Sprint 1 előtt)

**Archivál:**
- `BUGFIX_REPORT_2025_12_22.md` → `Archive/Bugfixes/`
- `BUGFIX_RelativePath_Support.md` → `Archive/Bugfixes/`
- `BUGFIX_DEBUG_Directory_Navigation_2025_12_22.md` → `Archive/Bugfixes/`
- `BUGFIX_DEBUG_Mock_Display_2025_12_23.md` → `Archive/Bugfixes/`

**Indok:** Ezek az információk bekerültek a CHANGELOG_UNIFIED.md-be (v2.0.1, v2.0.2, v2.0.3). Az eredeti bugfix jelentések történelmi értékűek, de a napi használathoz zavaróak.

---

### 2. Régi CHANGELOG Fájlok

**Archivál:**
- `CHANGELOG.md` → `Archive/Changelogs/CHANGELOG_v1.x_to_v2.0.0.md`
- `CHANGELOG_v2.0.1.md` → `Archive/Changelogs/`
- `CHANGELOG_PHASE2A_CHRONOLOGICAL.md` → `Archive/Changelogs/`
- `CHANGELOG_STREAMING_IMPLEMENTATION.md` → `Archive/Changelogs/`

**Megtart:**
- `CHANGELOG_UNIFIED.md` ← **Egyetlen aktív changelog**

**Indok:** Öt különböző changelog fájl van, ami zavaró. A CHANGELOG_UNIFIED.md tartalmazza az összeset kronológikusan.

---

### 3. Sprint 1 Teszt Dokumentumok

**Archivál:**
- `SPRINT1_TESTING_GUIDE.md` → `Archive/Sprint1/`
- `SPRINT1_ARDUINO_ONLY_TEST.md` → `Archive/Sprint1/`
- `SPRINT1_BUILD_SYSTEM_CHANGES.md` → `Archive/Sprint1/`
- `SPRINT1_TEST_1.md` → `Archive/Sprint1/`

**Megtart:**
- `SPRINT1_COMPLETION.md` ← **Sprint 1 hivatalos összefoglalója**

**Indok:** A teszt dokumentumok ideiglenesek voltak. A végeredmény a SPRINT1_COMPLETION.md-ben van.

---

### 4. Technikai Jelentések (Beépültek a Kódba)

**Archivál:**
- `IMPLEMENTATION_REPORT_PHASE2A.md` → `Archive/TechnicalReports/`
- `STREAMING_FIXES_REPORT.md` → `Archive/TechnicalReports/`
- `TECHNICAL_ANALYSIS.md` → `Archive/TechnicalReports/`

**Indok:** Ezek az elemzések értékesek történelmi szempontból, de a végleges implementáció a kódban és a CHANGELOG_UNIFIED.md-ben dokumentált.

---

### 5. SdFat Migration Audit

**Döntés szükséges:**
- `SDFAT_MIGRATION_AUDIT.md` → **Megtartani vagy archiválni?**

**Érv megtartásra:**
- Tartalmazza a fennmaradó P1-P3 prioritású feladatokat Sprint 2-höz
- Referencia dokumentum a jövőbeli SdFile → File migrációhoz

**Érv archiválásra:**
- Sprint 1 befejezett, az audit eredményei beépültek
- A kritikus bugok javítva (buffer overflow, strtok stb.)

**Javaslat:** **Megtartani**, de átnevezni:
- `SDFAT_MIGRATION_AUDIT.md` → `SDFAT2_MIGRATION_ROADMAP.md`
- Frissíteni Sprint 1 eredményekkel
- Hozzáadni Sprint 2 prioritásokat

---

### 6. Elavult Nyelvű Dokumentumok

**Probléma:**
- `hibajelentés.md` → Magyar nyelvű, egyedi hibajelentés (nincs dátum)

**Döntés:** Ellenőrizni tartalmat, majd:
- Ha releváns → Angol verzió készítése vagy beépítés CHANGELOG-ba
- Ha elavult → Archivál `Archive/Legacy/`

---

## Archív Mappa Struktúra

```
Archive/
├── Bugfixes/
│   ├── BUGFIX_REPORT_2025_12_22.md
│   ├── BUGFIX_RelativePath_Support.md
│   ├── BUGFIX_DEBUG_Directory_Navigation_2025_12_22.md
│   └── BUGFIX_DEBUG_Mock_Display_2025_12_23.md
│
├── Changelogs/
│   ├── CHANGELOG_v1.x_to_v2.0.0.md (átnevezett CHANGELOG.md)
│   ├── CHANGELOG_v2.0.1.md
│   ├── CHANGELOG_PHASE2A_CHRONOLOGICAL.md
│   └── CHANGELOG_STREAMING_IMPLEMENTATION.md
│
├── Sprint1/
│   ├── SPRINT1_TESTING_GUIDE.md
│   ├── SPRINT1_ARDUINO_ONLY_TEST.md
│   ├── SPRINT1_BUILD_SYSTEM_CHANGES.md
│   └── SPRINT1_TEST_1.md
│
├── TechnicalReports/
│   ├── IMPLEMENTATION_REPORT_PHASE2A.md
│   ├── STREAMING_FIXES_REPORT.md
│   └── TECHNICAL_ANALYSIS.md
│
└── Legacy/
    └── hibajelentés.md (ha nem releváns)
```

---

## Aktív Dokumentumok (Root Directory)

**Projekt Alapok:**
- `README.MD` ← Főoldal
- `GEMINI.md` ← AI assistant guide
- `CHANGELOG_UNIFIED.md` ← Egyetlen aktív changelog

**Sprint Eredmények:**
- `SPRINT1_COMPLETION.md` ← Sprint 1 összefoglaló

**Technikai Dokumentáció:**
- `Centralized_Data_Management.md` ← Architektúra szabályok (C64)
- `SDFAT2_MIGRATION_ROADMAP.md` ← SdFat 2.x migráció (átnevezett)
- `EasySD_TAP_to_PRG_Implementation_Notes.md` ← TAP konverzió
- `EasySD_PRG_Plugin.md` ← PRG plugin leírás
- `EasySD_MUS_Plugin.md` ← MUS plugin leírás

**Build & Deployment:**
- `Tools/README.md` ← Build rendszerek leírása
- `Tools/ARDUINO_CLI_SETUP.md` ← Arduino CLI telepítés
- `Arduino/IRQHack64/DIR_NAVIGATION_API.md` ← Dir API reference

---

## Végrehajtási Terv

### 1. Lépés: Archive Mappa Létrehozása
```bash
mkdir Archive
mkdir Archive\Bugfixes
mkdir Archive\Changelogs
mkdir Archive\Sprint1
mkdir Archive\TechnicalReports
mkdir Archive\Legacy
```

### 2. Lépés: Fájlok Áthelyezése
```bash
# Bugfixes
move BUGFIX_*.md Archive\Bugfixes\

# Changelogs
move CHANGELOG.md Archive\Changelogs\CHANGELOG_v1.x_to_v2.0.0.md
move CHANGELOG_v2.0.1.md Archive\Changelogs\
move CHANGELOG_PHASE2A_CHRONOLOGICAL.md Archive\Changelogs\
move CHANGELOG_STREAMING_IMPLEMENTATION.md Archive\Changelogs\

# Sprint1
move SPRINT1_TESTING_GUIDE.md Archive\Sprint1\
move SPRINT1_ARDUINO_ONLY_TEST.md Archive\Sprint1\
move SPRINT1_BUILD_SYSTEM_CHANGES.md Archive\Sprint1\
move SPRINT1_TEST_1.md Archive\Sprint1\

# Technical Reports
move IMPLEMENTATION_REPORT_PHASE2A.md Archive\TechnicalReports\
move STREAMING_FIXES_REPORT.md Archive\TechnicalReports\
move TECHNICAL_ANALYSIS.md Archive\TechnicalReports\

# Legacy (ellenőrzés után)
# move hibajelentés.md Archive\Legacy\
```

### 3. Lépés: Átnevezés
```bash
# SdFat migration roadmap
move SDFAT_MIGRATION_AUDIT.md SDFAT2_MIGRATION_ROADMAP.md
```

### 4. Lépés: Frissítés
- `SDFAT2_MIGRATION_ROADMAP.md` frissítése Sprint 1 eredményekkel
- `README.MD` Documentation szakaszának frissítése
- `GEMINI.md` Important File Paths frissítése

### 5. Lépés: Archive README Létrehozása
```markdown
# Archive/README.md
Ez a mappa történelmi dokumentumokat tartalmaz a projekt fejlesztésének különböző fázisaiból.

## Struktúra
- **Bugfixes/**: Sprint 1 előtti bugfix jelentések (2025-12-22 - 2025-12-23)
- **Changelogs/**: Régi changelog fájlok (v1.x - v2.0.3)
- **Sprint1/**: Sprint 1 tesztelési dokumentumok
- **TechnicalReports/**: Phase 2A és streaming implementáció jelentések
- **Legacy/**: Régi formátumú vagy nyelvű dokumentumok

## Aktív Dokumentáció
A friss dokumentáció a root könyvtárban található:
- CHANGELOG_UNIFIED.md
- SPRINT1_COMPLETION.md
- README.MD
- GEMINI.md
```

---

## Hatás

**Előnyök:**
✅ Tisztább root directory (28 → 12 fájl)
✅ Egy központi changelog (CHANGELOG_UNIFIED.md)
✅ Történelmi dokumentumok megőrzése
✅ Könnyebb orientáció új fejlesztőknek

**Hátrányok:**
⚠️ Git history bonyolultabbá válik (file moves)
⚠️ Külső linkek törhetnek (ha valaki hivatkozott rá)

**Mitigáció:**
- README.MD-ben note az archiválásról
- Archive/README.md útmutató a régi dokumentumokhoz

---

**Státusz:** Tervezés
**Jóváhagyás szükséges:** Felhasználói megerősítés
**Végrehajtás:** ~15 perc (file operations)
