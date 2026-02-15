# EasySD v2.0.1 - Relative Path Support Bugfix

**Dátum:** 2025-12-22
**Típus:** Bugfix
**Prioritás:** Magas (többlemezes játékok kompatibilitás)

## Rövid Összefoglaló

A PRG Plugin mostantól támogatja a **relatív fájlneveket**, amely kritikus a többlemezes játékok működéséhez. Az `HandleOpenFile()` függvény már nem utasítja el az olyan fájlneveket, mint `"LEVEL2.DAT"`.

## Módosított Fájlok

### 1. Arduino/IRQHack64/CartApi.cpp
**Sorok:** 137-188 (HandleOpenFile függvény)

**Változtatás:**
- ❌ ELTÁVOLÍTVA: Absolute path kötelező ellenőrzés (159-162 sor)
- ✅ HOZZÁADVA: Relative/Absolute path debug információk
- ✅ HOZZÁADVA: Kommentek a működésről

**Előtte:**
```cpp
if (fileName[0] != '/') {
    HandleResponse(INVALID_ARGUMENT, 1);
    return;
}
```

**Utána:**
```cpp
// Support both absolute and relative paths
// Relative paths use current directory set by sd.chdir()
// (Absolute path ellenőrzés eltávolítva)
```

### 2. EasySD_PRG_Plugin.md
**Változtatások:**
- Frissítve: Arduino oldali HandleOpenFile leírás (sor 147-151)
- Hozzáadva: "Flexible Path Support" az Előnyök-höz (sor 416)
- Módosítva: "Többlemezes játékok" előny pontosítva (sor 415)
- Frissítve: Verzió 2.0 → 2.0.1 (sor 512)
- Hozzáadva: Változtatások története szakasz (sor 516-527)

### 3. BUGFIX_RelativePath_Support.md (ÚJ)
**Teljes tartalom:**
- Részletes probléma leírás
- Kód módosítások magyarázata
- Tesztelési útmutató (3 teszt szcenárió)
- Debug kimenet példák
- Backward compatibility elemzés

### 4. CHANGELOG_v2.0.1.md (ÚJ)
Jelen dokumentum.

## Hatás

### Előnyök
✅ **Többlemezes játékok mostantól működnek:** `OPEN 1,8,2,"LEVEL2.DAT"` típusú hívások
✅ **Backward compatible:** Régi absolute path-ok továbbra is működnek
✅ **Szabványos viselkedés:** 1541-hez hasonló működés (relatív fájlnevek)
✅ **Zéró C64 oldali változtatás:** Csak Arduino firmware frissítés szükséges

### Tesztelés Szükséges
⚠️ **Arduino firmware újrafordítás és feltöltés kötelező**
⚠️ **Debug móddal tesztelés ajánlott** (serial monitor)
⚠️ **Többlemezes játék teszt** (pl. adventure game level streaming)

## Telepítési Útmutató

### 1. Arduino Firmware Frissítés

**Arduino IDE:**
```
1. File → Open → Arduino/IRQHack64/IRQHack64.ino
2. Tools → Board → Arduino Nano
3. Tools → Processor → ATmega328P (Old Bootloader)
4. Sketch → Verify/Compile
5. Sketch → Upload
```

**Arduino CLI:**
```bash
cd "C:\EasySD Gemini"
arduino-cli compile --fqbn arduino:avr:nano:cpu=atmega328old Arduino/IRQHack64
arduino-cli upload -p COM3 --fqbn arduino:avr:nano:cpu=atmega328old Arduino/IRQHack64
```

### 2. Debug Tesztelés (Opcionális)

**Kapcsold be a DEBUG flag-et:**
`Arduino/IRQHack64/CartApi.h` vagy `IRQHack64.ino`:
```cpp
#define DEBUG
```

**Serial Monitor (57600 baud):**
```
Got HandleOpenFile
Filename : LEVEL2.DAT
  Path type: RELATIVE (cwd: /GAMES/ADVENTURE)
Success!
```

### 3. Teszt Programok

**Egyszerű BASIC teszt (TEST.PRG):**
```basic
10 OPEN 1,8,2,"DATA.SEQ"
20 GET#1,A$
30 IF ST=0 THEN PRINT A$;:GOTO 20
40 CLOSE 1
50 PRINT "FILE READ OK!"
```

**SD Struktúra:**
```
/TEST/
    TEST.PRG
    DATA.SEQ    (tartalom: "HELLO WORLD")
```

**Várt eredmény:**
```
HELLO WORLD
FILE READ OK!
```

## Kompatibilitás

### Backward Compatibility
✅ **Régi firmware:** Csak absolute path-ok működnek
✅ **Új firmware:** Absolute + relative path-ok is működnek
✅ **Nincs breaking change:** Minden régi kód működik

### Forward Compatibility
✅ **C64 oldali kód:** Nincs változtatás, minden hook változatlan
✅ **Protokoll:** Nincs változás az NMI kommunikációban
✅ **API:** `IRQ_OpenFile`, `IRQ_SetName` változatlan

## Következő Lépések

1. ✅ **Kód javítás:** Kész
2. ✅ **Dokumentáció:** Frissítve
3. ⚠️ **Tesztelés:** Szükséges (felhasználói tesztek)
4. ⚠️ **Validálás:** Valós többlemezes játékkal
5. 📋 **Release:** v2.0.1 verzió publikálása

## Kapcsolódó Dokumentumok

- **Részletes bugfix leírás:** `BUGFIX_RelativePath_Support.md`
- **Plugin dokumentáció:** `EasySD_PRG_Plugin.md` (v2.0.1)
- **Fő README:** `README.MD`
- **Arduino forráskód:** `Arduino/IRQHack64/CartApi.cpp`

## Támogatás

Ha problémába ütközöl:
1. Ellenőrizd a Serial Monitor kimenetét (DEBUG mód)
2. Olvasd el a `BUGFIX_RelativePath_Support.md` tesztelési szakaszát
3. Ellenőrizd az SD kártya könyvtár struktúráját
4. Győződj meg róla, hogy a DirFunction helyes könyvtárban van

---

**Státusz:** ✅ Kész, tesztelésre vár
**Build:** v2.0.1
**Dátum:** 2025-12-22
