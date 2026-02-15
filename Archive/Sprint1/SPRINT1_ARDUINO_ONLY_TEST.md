# Sprint 1 - Arduino Firmware Teszt

## Build Rendszer (Frissítve: 2025-12-23)

A projekt build rendszere két módot támogat, és **SPRINT 1-től mindkét mód építi az Arduino firmwaret:**

### DEBUG Build (C64 Menü + Arduino Fejlesztéshez)
- **DEBUG=1** → C64 mock adatokat használ (SETDIR1/2/3)
- **BUILD_ARDUINO=1** → ✅ **ÉPÍTI az Arduino firmwaret!** (Sprint 1-től)
- **Cél:** C64 menü fejlesztése VICE debugger-rel + Arduino firmware tesztelés
- **FlashLib.h:** Generálódik az Arduino kódból
- **Előny:** VICE debug + Serial Monitor együtt használható

### RELEASE Build (Éles Használatra)
- **DEBUG=0** → C64 valódi Arduino kommunikációt használ
- **BUILD_ARDUINO=1** → ✅ Építi az Arduino firmwaret
- **Cél:** Éles cartridge használatra
- **FlashLib.h:** Generálódik (mint mindig)

---

## Sprint 1 Tesztelési Lehetőségek

A Sprint 1 **csak az Arduino firmware-t** fejleszti (DirFunction refaktor). Két módon tesztelhető:

### MÓDSZER A: Python Build Rendszer (Új, Sprint 1-től)

**Előnyök:**
✅ Teljes build környezet (C64 + Arduino együtt)
✅ FlashLib.h automatikusan generálódik
✅ Egyetlen parancs: `python build.py debug`
✅ Készen áll Sprint 2-re (C64 menü integráció)

**Hátrányok:**
❌ Lassabb iteráció (teljes build)
❌ Arduino IDE-ből kell feltölteni (vagy CLI tool)

**Használat:**
```bash
cd "C:\EasySD Gemini"
python Tools\build.py debug
# FlashLib.h → Arduino\IRQHack64\FlashLib.h
# Arduino IDE-ből upload: Arduino\IRQHack64\IRQHack64.ino
```

### MÓDSZER B: Arduino IDE Direkt (Gyors Iteráció)

**Előnyök:**
✅ Gyors iteráció (direkt upload)
✅ Serial Monitor azonnali visszajelzés
✅ Nincs szükség Python build-re
✅ Független a C64 résztől

**Hátrányok:**
❌ FlashLib.h manuálisan kell frissíteni (ha C64 kód változik)
❌ Teljes rendszer integráció nem tesztelhető

**Használat:**
```
Arduino IDE → Open: Arduino\IRQHack64\IRQHack64.ino
Upload (Ctrl+U)
Serial Monitor (Ctrl+Shift+M) @ 57600 baud
```

---

## Teszt Setup (Arduino IDE-ből)

### 1. Hardver Konfiguráció

**Minimum Setup (Ajánlott Sprint 1-hez):**
```
Arduino Nano/ProMini
    ├─ SD Card Module (SPI)
    │   ├─ CS   → D10
    │   ├─ MOSI → D11
    │   ├─ MISO → D12
    │   └─ SCK  → D13
    ├─ USB → PC (táp + Serial @ 57600)
    └─ SD kártya: FAT16/32, teszt könyvtárakkal
```

**Opcionális (Teljes EasySD Cartridge):**
- Ha van kész EasySD cartridge: C64-be bedugva (táp)
- USB Serial: Debug output
- SD kártya: Teszt adatok

---

### 2. Arduino Kód Konfiguráció

Az **IrqHack64.h** fájlban **hagyd bekapcsolva** a DEBUG-ot:
```cpp
#define DEBUG  // ✅ KELL a Serial.println() kimenetekhez!
```

Ez **NEM** ugyanaz mint a C64 DEBUG mód! Ez csak:
- Serial.println() debug üzenetek
- Teszt parancsok ('d', 'r', 'p') engedélyezése
- Részletes hibakeresési log

---

### 3. Arduino IDE Build és Upload

**Lépések:**

1. **Nyisd meg az Arduino IDE-t**

2. **File → Open:**
   ```
   C:\EasySD Gemini\Arduino\IRQHack64\IRQHack64.ino
   ```

3. **Tools → Board:**
   - Arduino Nano (vagy Arduino Pro or Pro Mini)

4. **Tools → Processor:**
   - ATmega328P (Old Bootloader ha szükséges)

5. **Tools → Port:**
   - Válaszd ki a megfelelő COM portot

6. **Sketch → Upload** (Ctrl+U)
   - Várj a "Done uploading" üzenetre

7. **Tools → Serial Monitor** (Ctrl+Shift+M)
   - Baud rate: **57600**
   - Line ending: "Newline" vagy "Both NL & CR"

---

### 4. Elvárt Serial Monitor Output

**Sikeres inicializálás:**
```
Card type:
SD2

---- IrqHack64 by I.R.on----
1. Receive program
2. Load menu
3. Reset C64
4. Reset C64 - Cart disabled
5. Update File
6. Serial Terminal

Free RAM: 1234
```

**Ha hibás:**
```
Can't initialize!
```
→ Ellenőrizd az SD kártya wiring-et és formátumot!

---

## Sprint 1 Tesztek (Serial Monitor-ban)

### SD Kártya Előkészítés

Hozz létre teszt könyvtárakat az SD kártyán:
```
/
├── GAMES/
│   ├── ARCADE/
│   └── STRATEGY/
├── MUSIC/
├── DEMOS/
└── TOOLS/
```

### Teszt Parancsok

#### 🔹 Parancs 'p' - Print State
**Parancs:**
```
p
```

**Elvárt kimenet:**
```
=== Current State ===
Path: /
Depth: 0
InSubDir: 0
Count: 4
```

---

#### 🔹 Parancs 'd' - Directory Navigation

**1. Belépés könyvtárba:**
```
d
GAMES
```

**Elvárt kimenet:**
```
=== Directory Navigation Test ===
Current path: /
Path depth: 0
Enter directory name (or .. to go back):
GAMES
DIR: ChangeDirectoryBasename: GAMES
DIR: Entered /GAMES/
Attempting to navigate to: GAMES
SUCCESS!
New path: /GAMES/
Item count: 2
```

**2. Mély navigáció:**
```
d
ARCADE
```

**Elvárt:**
```
DIR: ChangeDirectoryBasename: ARCADE
DIR: Entered /GAMES/ARCADE/
Attempting to navigate to: ARCADE
SUCCESS!
New path: /GAMES/ARCADE/
Item count: X
```

**3. Vissza szülő könyvtárba:**
```
d
..
```

**Elvárt:**
```
DIR: ChangeDirectoryBasename: ..
DIR: GoBack to /GAMES/
Attempting to navigate to: ..
SUCCESS!
New path: /GAMES/
```

**4. Hibás könyvtár:**
```
d
NOTEXIST
```

**Elvárt:**
```
DIR: ChangeDirectoryBasename: NOTEXIST
DIR: chdir FAILED: /NOTEXIST
Attempting to navigate to: NOTEXIST
FAILED!
```

---

#### 🔹 Parancs 'r' - Reset to Root

**Parancs:**
```
r
```

**Elvárt kimenet:**
```
=== Reset to Root ===
DIR: ForceReset called
DIR: Reset complete, path=/
DIR: Count=4
Path: /
Count: 4
```

---

## Teljes Teszt Szekvencia

Futtasd ezt a szekvenciát végig a Serial Monitor-ban:

```
# 1. Kezdeti állapot
p
→ Expected: Path="/", Depth=0

# 2. Belépés GAMES-be
d
GAMES
→ Expected: SUCCESS, path="/GAMES/"

# 3. Belépés ARCADE-ba
d
ARCADE
→ Expected: SUCCESS, path="/GAMES/ARCADE/"

# 4. Vissza egyet (..)
d
..
→ Expected: SUCCESS, path="/GAMES/"

# 5. Vissza root-ra
d
..
→ Expected: SUCCESS, path="/"

# 6. Hibás könyvtár
d
NOTEXIST
→ Expected: FAILED, path="/"

# 7. Reset mély helyről
d
GAMES
d
ARCADE
r
→ Expected: Path="/"

# 8. Aktuális állapot
p
→ Expected: Path="/", Depth=0
```

---

## Debug Output Értelmezése

### Sikeres Navigate (ChangeDirectoryBasename)
```
DIR: ChangeDirectoryBasename: GAMES         # ← Metódus hívva
DIR: Entered /GAMES/                        # ← sd.chdir() sikeres
```
✅ **PASS:** `ChangeDirectory()` return true

### Sikeres GoBack
```
DIR: GoBack to /                            # ← Path truncated
```
✅ **PASS:** `GoBack()` return true

### Sikertelen Navigate (Rollback)
```
DIR: chdir FAILED: /NOTEXIST                # ← sd.chdir() failed
```
✅ **PASS:** `ChangeDirectory()` return false, path unchanged

### Sikertelen GoBack (Root)
```
DIR: Already at ROOT, can't go back         # ← pathDepth==0
```
✅ **PASS:** `GoBack()` return false at root

---

## Hibaelhárítás

### "Can't initialize!" hiba

**Okok:**
1. Nincs SD kártya behelyezve
2. SD kártya rosszul formázva (nem FAT16/32)
3. Rossz wiring (SPI vonalak)
4. SD kártya hibás

**Megoldás:**
1. Ellenőrizd az SD kártya formátumát (FAT32)
2. Próbálj ki másik SD kártyát
3. Csökkentsd a sebességet:
   ```cpp
   // IRQHack64.ino:64
   if (!sd.begin(chipSelect, SPI_HALF_SPEED)) {  // SPI_FULL_SPEED helyett
   ```

### Serial Monitor nem mutat semmit

**Megoldás:**
1. Ellenőrizd a baud rate: **57600**
2. Próbáld meg Reset-elni az Arduino-t
3. Válts USB portot
4. Ellenőrizd hogy jó COM portot választottál-e

### Teszt parancsok nem reagálnak

**Ellenőrizd:**
1. Line ending: "Newline" vagy "Both NL & CR"
2. DEBUG define be van-e kapcsolva (IrqHack64.h)
3. Firmware tényleg feluploadolódott-e (upload után)

### "DIR: chdir FAILED" minden könyvtárra

**Okok:**
1. SD kártya nem tartalmaz könyvtárakat
2. SD kártya nem inicializálódott rendesen

**Megoldás:**
1. Teszteld a 'p' parancsot: mutatja-e a root-ban lévő fájlokat?
2. Hozz létre könyvtárakat az SD kártyán számítógéppel
3. Próbáld ki a 'r' parancsot (reset)

---

## Sprint 1 Sikerkritérium

### ✅ PASS Feltételek

1. **Setup sikeres:**
   - SD kártya inicializálódik
   - Serial Monitor mutat debug üzeneteket

2. **'p' parancs működik:**
   - Kiírja a path-ot, depth-et, count-ot

3. **'d' parancs működik:**
   - Létező könyvtárba be tud lépni (SUCCESS)
   - Nem létező könyvtárra FAILED-et ad
   - ".." működik (vissza parent-re)

4. **'r' parancs működik:**
   - Azonnal root-ra ugrik bármilyen mélységből

5. **Rollback működik:**
   - Sikertelen navigate NEM változtatja a path-ot
   - Debug log mutatja a "chdir FAILED" üzenetet

6. **State konzisztencia:**
   - pathDepth mindig megegyezik a path '/' karaktereinek számával
   - InSubDir = 1 ha pathDepth > 0

### ❌ FAIL Feltételek

- SD inicializálás fail
- Parancsok nem reagálnak
- Sikeres navigate után path nem változik
- Sikertelen navigate után path megváltozik (ROLLBACK FAIL!)
- 'r' parancs után nem root-on van

---

## Következő Lépés

Ha Sprint 1 Arduino teszt **PASS:**
1. ✅ Firmware működik standalone
2. ✅ DirFunction metódusok helyesek
3. ✅ Rollback mechanizmus működik
4. ➡️ **Sprint 2:** C64 menü refaktorálás kezdődhet
   - DIRSTACK eltávolítása
   - Basename-only navigation C64 oldalon
   - Integráció az új firmware API-val

Ha Sprint 1 Arduino teszt **FAIL:**
1. Dokumentáld a hibát (mit csináltál, mit vártál, mit kaptál)
2. Serial Monitor teljes log mentése
3. Debug a problémás metódus (ChangeDirectory vagy GoBack)
4. Javítás és újra teszt

---

## Jegyzőkönyv Sablon (Arduino Only)

```
SPRINT 1 - ARDUINO FIRMWARE TESZT
===================================
Dátum: _______________
Tesztelő: _______________

HARDVER:
Arduino típus: [ ] Nano [ ] ProMini
SD kártya: ___________ (típus/méret)
USB Táp: [ ] PC [ ] Külső

FIRMWARE:
Verzió/Commit: _______________
DEBUG mode: [ ] ON [ ] OFF
Upload: [ ] Sikeres [ ] Sikertelen

SD TARTALOM:
[ ] /GAMES/
[ ] /GAMES/ARCADE/
[ ] /MUSIC/
[ ] /DEMOS/

SETUP TESZT:
[ ] Serial Monitor 57600 működik
[ ] SD inicializálás sikeres
[ ] Debug menü megjelenik

PARANCSOK:
[ ] 'p' - Print State OK
[ ] 'd' - Navigate létező dir OK
[ ] 'd' - Navigate ".." OK
[ ] 'd' - Navigate hibás dir FAIL OK
[ ] 'r' - Reset to Root OK

ROLLBACK TESZT:
[ ] Sikertelen navigate NEM változtatja a state-et

SPRINT 1 STÁTUSZ:
[ ] PASS - Folytatható Sprint 2
[ ] FAIL - Javítás szükséges

HIBÁK/MEGJEGYZÉSEK:
_______________________________________
_______________________________________
```

---

**Verzió:** 1.1
**Dátum:** 2025-12-23 (Frissítve: Build rendszer módosítás)
**Sprint:** 1 (Firmware Foundation)
**Teszt módszerek:**
- Python build.py debug (FlashLib.h auto-generálás)
- Arduino IDE direkt (gyors iteráció)
