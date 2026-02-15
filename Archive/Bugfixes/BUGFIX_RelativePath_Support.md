# BUGFIX: Relative Path Support for Multi-Disk Games

**Dátum:** 2025-12-22
**Komponens:** Arduino/IRQHack64/CartApi.cpp
**Érintett Funkció:** `CartApi::HandleOpenFile()`
**Verzió:** 2.0.1

## Probléma Leírása

### Eredeti Hiba

A PRG Plugin **többlemezes játék támogatása nem működött** az alábbi ok miatt:

**Tünet:**
```basic
REM Játék futás közben:
OPEN 1,8,2,"LEVEL2.DAT"
```
→ **INVALID_ARGUMENT** error, fájl nem nyílik meg

**Gyökérok:**
Az `HandleOpenFile()` függvény a 159-162 sorokban **elutasította a relatív fájlneveket**:
```cpp
if (fileName[0] != '/') {
    HandleResponse(INVALID_ARGUMENT, 1);  // ❌ Elutasítás
    return;
}
```

### Miért volt ez probléma?

1. **Klasszikus C64 játékok** relatív fájlneveket használnak:
   - `"LEVEL2.DAT"`
   - `"SAVEGAME.SAV"`
   - `"DATA.SEQ"`

2. **KERNAL szabvány** szerint a programok **NEM adnak meg abszolút path-t**, csak a fájlnevet

3. **Normál 1541 működés:** A lemez **aktuális könyvtárában** keres (nincs alkönyvtár támogatás)

4. **EasySD esetén:** A menü navigál a könyvtárszerkezetben:
   ```
   /GAMES/ADVENTURE/   <- Menü ide navigál
       MAIN.PRG        <- Plugin ezt betölti
       LEVEL1.DAT      <- Játék ezt akarja olvasni (relative path)
       LEVEL2.DAT
   ```

## Megoldás

### Kód Módosítás

**Fájl:** `Arduino/IRQHack64/CartApi.cpp:137-188`

**Eltávolítva:**
```cpp
// RÉGI KÓD (159-162 sor):
if (fileName[0] != '/') {
    HandleResponse(INVALID_ARGUMENT, 1);
    return;
}
```

**Hozzáadva:**
```cpp
// ÚJ KÓD (149-151, 162-171 sor):
// Support both absolute and relative paths
// Absolute paths (starting with '/') open from root
// Relative paths use current directory set by sd.chdir() in DirFunction

#ifdef DEBUG
Serial.print(F("Filename : "));Serial.println(fileName);
if (fileName[0] == '/') {
    Serial.println(F("  Path type: ABSOLUTE"));
} else {
    Serial.print(F("  Path type: RELATIVE (cwd: "));
    Serial.print(dirFunc.currentPath);
    Serial.println(F(")"));
}
#endif
```

### Működési Elv

Az **SdFat library** automatikusan támogatja a relatív path-okat:

1. **DirFunction osztály** kezeli a current directory-t:
   ```cpp
   dirFunc.ChangeDirectory("GAMES");
   dirFunc.ChangeDirectory("ADVENTURE");
   // currentPath = "/GAMES/ADVENTURE"
   // sd.chdir("/GAMES/ADVENTURE") meghívva
   ```

2. **sd.open()** automatikusan feloldja a relatív path-okat:
   ```cpp
   // SdFat internal state: current dir = "/GAMES/ADVENTURE"
   workingFile = sd.open("LEVEL2.DAT", flags);
   // Megnyitja: /GAMES/ADVENTURE/LEVEL2.DAT
   ```

3. **Absolute path továbbra is működik:**
   ```cpp
   workingFile = sd.open("/CONFIG/SETTINGS.DAT", flags);
   // Megnyitja: /CONFIG/SETTINGS.DAT (root-ból)
   ```

## Tesztelési Útmutató

### 1. Fordítás

**Arduino firmware fordítása:**
```bash
# Arduino IDE: File → Open → Arduino/IRQHack64/IRQHack64.ino
# Tools → Board → Arduino Nano
# Tools → Processor → ATmega328P (Old Bootloader)
# Sketch → Upload
```

**Vagy Arduino CLI:**
```bash
arduino-cli compile --fqbn arduino:avr:nano:cpu=atmega328old Arduino/IRQHack64
arduino-cli upload -p COM3 --fqbn arduino:avr:nano:cpu=atmega328old Arduino/IRQHack64
```

### 2. Debug Mód Tesztelés

**Kapcsold be a DEBUG flag-et:**
`Arduino/IRQHack64/IRQHack64.ino` vagy `CartApi.h`:
```cpp
#define DEBUG
```

**Serial Monitor (57600 baud):**
```
Got HandleOpenFile
Flags : 1
Filename : LEVEL2.DAT
  Path type: RELATIVE (cwd: /GAMES/ADVENTURE)
Success!
```

### 3. Funkcionális Tesztek

#### A. Egyszerű Teszt Program (BASIC)

**SD Kártya Struktúra:**
```
/TEST/
    MAIN.PRG        <- BASIC program
    DATA1.SEQ       <- Teszt adat
    DATA2.SEQ       <- Teszt adat
```

**MAIN.PRG tartalma:**
```basic
10 PRINT "TESTING RELATIVE PATH SUPPORT"
20 OPEN 1,8,2,"DATA1.SEQ"
30 GET#1,A$
40 PRINT A$;
50 IF ST=0 THEN 30
60 CLOSE 1
70 PRINT
80 PRINT "FILE 1 OK, OPENING FILE 2..."
90 OPEN 1,8,2,"DATA2.SEQ"
100 GET#1,A$
110 PRINT A$;
120 IF ST=0 THEN 100
130 CLOSE 1
140 PRINT
150 PRINT "ALL FILES OPENED SUCCESSFULLY!"
```

**DATA1.SEQ tartalma:**
```
HELLO FROM FILE 1
```

**DATA2.SEQ tartalma:**
```
HELLO FROM FILE 2
```

**Várt Eredmény:**
```
TESTING RELATIVE PATH SUPPORT
HELLO FROM FILE 1
FILE 1 OK, OPENING FILE 2...
HELLO FROM FILE 2
ALL FILES OPENED SUCCESSFULLY!
```

#### B. Többlemezes Játék Szimuláció

**SD Kártya Struktúra:**
```
/GAMES/ADVENTURE/
    GAME.PRG
    LEVEL1.DAT
    LEVEL2.DAT
    LEVEL3.DAT
```

**GAME.PRG pseudo-kód:**
```basic
10 REM Betöltés 1. szinten
20 OPEN 1,8,2,"LEVEL1.DAT"
30 REM ... adatok olvasása ...
40 CLOSE 1
50 REM Betöltés 2. szinten
60 OPEN 1,8,2,"LEVEL2.DAT"
70 REM ... adatok olvasása ...
80 CLOSE 1
```

**Tesztelendő:**
- ✅ Minden LEVEL*.DAT megnyílik hiba nélkül
- ✅ Adatok helyesen olvashatók
- ✅ Nincs `INVALID_ARGUMENT` error

#### C. Absolute vs. Relative Path Teszt

```basic
10 REM Relative path (ugyanabban a könyvtárban)
20 OPEN 1,8,2,"LOCAL.DAT"
30 CLOSE 1
40 REM Absolute path (más könyvtárból)
50 OPEN 1,8,2,"/CONFIG/GLOBAL.DAT"
60 CLOSE 1
70 PRINT "BOTH PATHS WORK!"
```

### 4. Serial Debug Kimenetek

**Helyes Működés:**
```
Got HandleOpenFile
Filename : LEVEL1.DAT
  Path type: RELATIVE (cwd: /GAMES/ADVENTURE)
Success!

Got HandleOpenFile
Filename : /CONFIG/SETTINGS.DAT
  Path type: ABSOLUTE
Success!
```

**Hibás Eset (fájl nem létezik):**
```
Got HandleOpenFile
Filename : NOTEXIST.DAT
  Path type: RELATIVE (cwd: /GAMES/ADVENTURE)
Fail!
```

## Backward Compatibility

### Érintett Komponensek

**✅ NEM változik:**
- C64 oldali kód (PrgPlugin.s)
- KERNAL hooking mechanizmus
- NMI kommunikációs protokoll
- IRQ_SetName / IRQ_SendFileName

**✅ Módosul (backward compatible):**
- `CartApi::HandleOpenFile()` - Most már **több**et tud (absolute + relative)

### Kompatibilitás

**Régi viselkedés (csak absolute path):**
```cpp
workingFile = sd.open("/GAMES/MAIN.PRG", flags);  // ✅ Működött
workingFile = sd.open("DATA.SEQ", flags);         // ❌ INVALID_ARGUMENT
```

**Új viselkedés (absolute + relative):**
```cpp
workingFile = sd.open("/GAMES/MAIN.PRG", flags);  // ✅ Továbbra is működik
workingFile = sd.open("DATA.SEQ", flags);         // ✅ Most már működik!
```

**Következmény:** Minden korábbi működő kód **továbbra is működik**, de most **új lehetőségek** is vannak.

## Dokumentáció Frissítések

### EasySD_PRG_Plugin.md Módosítások

**6. Előnyök és Korlátok → Korlátok szakasz:**

**ELTÁVOLÍTVA:**
~~Write limit: CHKOUT hook nincs implementálva (csak olvasás, nem írás a `PRINT#` paranccsal)~~

**HOZZÁADVA:**
- ✅ **Relative path támogatás:** Játékok egyszerű fájlneveket használhatnak (pl. `"LEVEL2.DAT"`)
- ✅ **Absolute path támogatás:** Explicit path megadása (pl. `"/CONFIG/DATA.DAT"`)

**6. Előnyök szakasz:**

**HOZZÁADVA:**
- ✅ **Valódi többlemezes játék támogatás:** Runtime file I/O működik relative path-okkal

## Frissítési Jegyzék

| Komponens | Fájl | Sorok | Módosítás Típusa |
|-----------|------|-------|------------------|
| Arduino API | CartApi.cpp | 137-188 | Bug fix |
| Dokumentáció | EasySD_PRG_Plugin.md | - | Frissítés |
| Teszt útmutató | BUGFIX_RelativePath_Support.md | - | Új |

## Hivatkozások

**Módosított Fájlok:**
- `Arduino/IRQHack64/CartApi.cpp` (HandleOpenFile)
- `EasySD_PRG_Plugin.md` (Dokumentáció frissítés)

**Kapcsolódó Komponensek:**
- `Arduino/IRQHack64/DirFunction.cpp` (currentPath kezelés)
- `Arduino/IRQHack64/DirFunction.h` (DirFunction osztály)
- `IRQHack64/Plugins/PrgPlugin/PrgPlugin.s` (C64 oldali hook-ok)

**SdFat Library Dokumentáció:**
- [SdFat chdir() reference](https://github.com/greiman/SdFat)

---

**Státusz:** ✅ Javítás kész, tesztelésre vár
**Következő lépések:**
1. Arduino firmware feltöltése
2. Debug móddal tesztelés
3. Valós többlemezes játék teszt
4. Dokumentáció véglegesítése
