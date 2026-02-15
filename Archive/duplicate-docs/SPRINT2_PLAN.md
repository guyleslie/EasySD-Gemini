# Sprint 2 - SdFat 2.x API Modernization - PLANNING

> **Dátum:** 2025-12-25
> **Verzió cél:** v2.0.5 (Option A) / v2.1.0 (Option B)
> **Előzmény:** Sprint 1 Complete (v2.0.4)
> **Státusz:** Planning Phase

---

## Sprint Áttekintés

### Kontextus
A Sprint 1 során sikeresen stabilizáltuk a directory navigációt és kijavítottuk az összes kritikus memória és stack hibát. A rendszer **production-ready**, de még mindig használ néhány deprecated SdFat 1.x API-t backward compatibility miatt.

### Sprint 2 Célja
**SdFat 2.x API teljes megfelelés elérése** anélkül, hogy a stabilitást veszélyeztetnénk.

---

## Irányértékelés (Refaktor Terv Review)

### ✅ Jó Irány Megerősítése

A Sprint 1 eredményei alapján **nagyon jól abba az irányba haladunk**, amit a refaktor dokumentumban lefektettünk:

1. **✅ Prioritás helyes volt:**
   - Sprint 1-ben a "stabil dir navigáció + memória/stack stabilitás" lett priorizálva, nem az API-szépség
   - Ez pontosan illik a refaktor alapelvéhez: előbb legyen *determinista és konzisztens* a state, csak utána "szépítsünk" API-t

2. **✅ Kritikus bugok kijavítva:**
   - strtok corruption, overflow, leak, stack hibák mind javítva
   - A navigáció "10+ ciklus stabil memóriával" PASS
   - Ez a *bizonyíték*, hogy a firmware-state központú út működik

3. **✅ Fázisosság konzisztens:**
   - P1: deprecated API-k takarítása
   - P2: "enhanced sync" (openCwd)
   - P3: quality sweep
   - Ez teljesen konzisztens a nagy refaktor terv *fázisosságával*

### Finomhangolás

**Kritikus szabály hozzáadása a Sprint 2 Definition of Done-hoz:**

> **"A C64 oldalon a dir state ne legyen 'rekonstruált', hanem minden művelet után friss listázás / firmware-confirm."**

Ez az elv már megvan a dokumentációban, de most **Definition of Done** részévé kell tenni.

---

## Sprint 2 Scope

### Javasolt Megközelítés: Option A (Recommended)

**Scope:** Minimális API Cleanup - **Low Risk, High Value**
**Becsült effort:** 1-2 óra
**Target verzió:** v2.0.5

#### Feladatok

**P1-1: SdFile → File Type Migration**
- **Lokáció:** `DirFunction.cpp:169, 211`
- **Változtatás:**
  ```cpp
  // Jelenlegi:
  SdFile file;  // ⚠️ Deprecated

  // Sprint 2:
  File file;    // ✅ SdFat 2.x preferred
  ```
- **Effort:** 10 perc (2 módosítás)
- **Risk:** LOW - backward compatible típus

**P1-2: openNext() API Signature Update**
- **Lokáció:** `DirFunction.cpp:195, 224`
- **Változtatás:**
  ```cpp
  // Jelenlegi:
  file.openNext(&m_dirFile, O_READ)  // ⚠️ 2 paraméter

  // Sprint 2:
  file.openNext(&m_dirFile)          // ✅ 1 paraméter (O_READ implicit)
  ```
- **Effort:** 5 perc (2 módosítás)
- **Risk:** LOW - API egyszerűsítés

#### Definition of Done (Option A)

**Funkcionális követelmények:**
- ✅ SdFile → File minden előfordulásban lecserélve
- ✅ openNext() egyparaméteres API használata
- ✅ Fordítás sikeres, nincs warning
- ✅ Alapvető regressziós tesztek PASS

**Regressziós tesztek:**
1. ✅ Root operations: `r` parancs működik
2. ✅ Directory navigation: `d` → UTILS → Enter sikeres
3. ✅ GoBack: `d` → A → B, majd `..` → `..` sikeres
4. ✅ Memory stability: 10+ ciklus, FreeStack() monitoring
   - Boot: 425 bytes
   - Root prepare: 341 bytes
   - Navigation: 333-332 bytes stabil tartomány
   - Reset: vissza 341 bytes-ra

**State Sync követelmény (KRITIKUS):**
- ✅ Minden directory művelet után **friss listázás / firmware-confirm**
- ✅ Dir state NEM rekonstruált, mindig firmware a forrás
- ✅ Path tracking konzisztens a firmware state-tel

**Code Quality:**
- ✅ Kód olvasható, konzisztens style
- ✅ Nincs új TODO/FIXME marker
- ✅ Dokumentáció frissítve (CHANGELOG, README)

---

### Alternatív Megközelítés: Option B (Deferred)

**Scope:** Teljes SdFat 2.x Migráció + Enhanced Sync
**Becsült effort:** 4-6 óra
**Target verzió:** v2.1.0+ (későbbi sprint)

**Miért halasztjuk?**
- Option A már jelentős értéket ad (API modernizáció)
- openCwd() integráció (P2) "enhancement", nem kritikus
- Csökkenti a Sprint 2 kockázatát
- Lehetővé teszi több tesztelési időt Option A-ra

**P2 feladatok (jövőbeli Sprint):**
- openCwd() integráció ToRoot(), ChangeDirectory(), GoBack(), Prepare()-ben
- Extended testing: Multi-level navigation, edge cases
- SdFat 2.x best practice teljes compliance

---

## Tesztelési Stratégia

### Minimális Regressziós Tesztek (Option A)

**Pre-deployment checklist:**

1. **Basic Navigation Test**
   ```
   Boot → Serial Monitor
   Command: r
   Expected: DIR: ROOT, Count: 2+
   ```

2. **Subdirectory Entry**
   ```
   Command: d
   Input: UTILS
   Expected: DIR: Entered /UTILS, Items: 3+
   ```

3. **List Function**
   ```
   Command: l
   Expected: Lista UTILS tartalommal (UTILS2, .., files)
   ```

4. **GoBack Navigation**
   ```
   Navigate: UTILS → UTILS2
   Command: .. (twice)
   Expected: Visszatérés Root-ba
   ```

5. **Memory Stability**
   ```
   10+ navigációs ciklus:
   Root → UTILS → UTILS2 → Root (repeat)
   Monitor: FreeStack() változás
   Pass: 341-425 bytes tartomány, nincs leak
   ```

### Test Environment

**Hardware:**
- Arduino Nano (ATmega328P)
- 16MHz clock
- SPI SD card interface
- Serial Monitor 57600 baud

**Software:**
- SdFat 2.3.0
- Arduino IDE 1.8.6 vagy arduino-cli
- FAT32 SD kártya (2-8GB tested)

---

## Kockázatkezelés

### Azonosított Kockázatok

| Kockázat | Valószínűség | Impact | Mitigáció |
|----------|--------------|--------|-----------|
| Regresszió navigációban | LOW | HIGH | Teljes regressziós teszt suite |
| API inkompatibilitás | LOW | MEDIUM | SdFat dokumentáció ellenőrzése |
| Memória növekedés | VERY LOW | MEDIUM | FreeStack() monitoring |
| Build hiba | LOW | LOW | Compile test pre-commit |

### Rollback Plan

**Ha critical bug találunk:**
1. Git revert a Sprint 2 commit-ra
2. Visszatérés v2.0.4-re
3. Root cause analysis
4. Fix és re-test

---

## Success Criteria

### Sprint 2 sikeres, ha:

1. ✅ **P1 feladatok befejezve** - SdFile → File, openNext() API
2. ✅ **Zero regresszió** - Minden Sprint 1 teszt továbbra is PASS
3. ✅ **Memória stabil** - 341-425 bytes tartomány változatlan
4. ✅ **Build sikeres** - Nincs compiler warning
5. ✅ **Dokumentáció naprakész** - CHANGELOG, ROADMAP frissítve
6. ✅ **State sync rule betartva** - Firmware-confirm minden műveletnél

---

## Timeline és Mérföldkövek

### Sprint 2 Fázisok

**1. Planning Phase** (✅ Complete)
- Scope finalizálás (Option A kiválasztva)
- Definition of Done meghatározása
- Dokumentáció létrehozása (SPRINT2_PLAN.md)

**2. Implementation Phase** (⏳ Pending)
- P1-1: SdFile → File migration (~10 perc)
- P1-2: openNext() update (~5 perc)
- Build test és compile ellenőrzés

**3. Testing Phase** (⏳ Pending)
- Regressziós tesztek futtatása
- Memory stability verification (10+ cycles)
- Edge case testing

**4. Documentation Phase** (⏳ Pending)
- CHANGELOG frissítés
- SDFAT2_MIGRATION_ROADMAP.md update
- SPRINT2_COMPLETION.md létrehozása

**5. Deployment** (⏳ Pending)
- Version bump: v2.0.4 → v2.0.5
- Git tag létrehozása
- Release notes publikálása

---

## Kapcsolódó Dokumentumok

### Projekt Dokumentáció
- `SDFAT2_MIGRATION_ROADMAP.md` - Teljes migrációs terv
- `SPRINT1_COMPLETION.md` - Sprint 1 eredmények
- `SPRINT2_TESTING_GUIDE.md` - Sprint 2 részletes tesztelési útmutató
- `SPRINT2_COMPLETION.md` - **Sprint 2 eredmények** ← Befejezve!
- `CHANGELOG_UNIFIED.md` - Verzió történet
- `GEMINI.md` - Fejlesztői útmutató

### SdFat Library Referenciák
- [SdFat Migration Guide](https://github.com/greiman/SdFat/issues/353)
- [SdFat 2.x DirectoryFunctions Example](https://github.com/greiman/SdFat/blob/master/examples/DirectoryFunctions/DirectoryFunctions.ino)
- [SdFat 2.x OpenNext Example](https://github.com/greiman/SdFat/blob/master/examples/OpenNext/OpenNext.ino)

---

## Következő Lépések

### Immediate Actions
1. ⏳ Review és approve Sprint 2 Plan
2. ⏳ P1 feladatok implementálása
3. ⏳ Regressziós tesztek futtatása

### Future Sprints (v2.1.0+)
- P2: openCwd() integration
- P3: strcpy() global review
- Performance tuning és optimalizációk

---

## Appendix: Firmware-Confirm Szabály

### Miért kritikus?

A refaktor terv alapelve: **"firmware a single source of truth"**

**Rossz megközelítés (NE):**
```cpp
// C64 oldal "rekonstruálja" a state-et
currentPath += "/" + dirname;  // ❌ Feltételezés, nem confirm
```

**Helyes megközelítés (IGEN):**
```cpp
// Firmware művelet után FRISS listázás
sd.chdir(dirname);
if (m_dirFile.isOpen()) { m_dirFile.close(); }
m_dirFile.open(sd.vwd());  // ✅ Firmware state = source of truth
Prepare();  // ✅ Friss lista a firmware-ből
```

### Implementációs Checklist

Minden directory művelet után:
- ✅ Firmware state frissítve (sd.chdir, sd.open, etc.)
- ✅ m_dirFile újra nyitva a friss state-tel
- ✅ Prepare() vagy hasonló listázás meghívva
- ✅ Path tracking konzisztens check (opcionális assert)

---

**Verzió:** v1.0
**Készítette:** Claude Sonnet 4.5
**Dátum:** 2025-12-25
**Sprint Status:** 📋 PLANNING
**Approval:** ⏳ Pending User Review
