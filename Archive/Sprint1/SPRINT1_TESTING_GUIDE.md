# Sprint 1 - Tesztelési Útmutató

## Hardver Követelmények

### EasySD Cartridge Architektúra
- **Arduino:** Nano vagy ProMini (ATmega328P)
- **SD kártya modul:** SPI interface (CS = pin 10)
- **C64 Interface:** Cartridge port pineken keresztül
- **USB Serial:** Debug és programozás (FTDI/CH340)

### Tápellátás
Az Arduino-nak mindenképpen **5V táp** kell a működéshez:

**Opció A: C64 Cartridge Port**
- EasySD cartridge bedugva a C64-be
- C64 bekapcsolva
- 5V táp a cartridge port +5V pinjéről

**Opció B: USB Programozó**
- USB kábel PC-hez
- FTDI vagy CH340 chip biztosítja az 5V-ot
- Működik standalone (C64 nélkül) HA van SD

**Opció C: Külső Táp**
- 5V külső tápegység
- VIN vagy 5V pin
- Működik standalone (C64 nélkül) HA van SD

### SD Kártya KÖTELEZŐ!
Az Arduino firmware a setup()-ban megpróbálja inicializálni az SD-t:
```cpp
if (!sd.begin(chipSelect, SPI_FULL_SPEED)) {
    Serial.println(F("Can't initialize!"));
    sd.initErrorHalt();  // ❌ MEGÁLL!
}
```
**Ha nincs SD kártya → a firmware megáll, nem működnek a teszt parancsok!**

---

## Tesztelési Módszerek

### MÓDSZER 1: Teljes Rendszer Teszt (Ajánlott)

**Szükséges:**
- ✅ C64 számítógép
- ✅ EasySD cartridge
- ✅ SD kártya behelyezve (teszt könyvtárakkal)
- ✅ USB kábel (EasySD → PC)

**Eljárás:**
1. **SD kártya előkészítése:**
   - Formázd FAT16 vagy FAT32-re
   - Hozz létre teszt könyvtárakat:
     ```
     /
     ├── GAMES/
     │   ├── ARCADE/
     │   └── STRATEGY/
     ├── MUSIC/
     └── DEMOS/
     ```

2. **Hardver összeállítás:**
   - Helyezd be az SD kártyát az EasySD-be
   - Dugd be az EasySD cartridge-t a C64 cartridge portjába
   - Csatlakoztasd az USB kábelt (EasySD → PC)
   - Kapcsold be a C64-et

3. **Arduino IDE beállítások:**
   - Nyisd meg az Arduino IDE-t
   - Board: Arduino Nano (vagy ProMini)
   - Processor: ATmega328P
   - Port: Válaszd ki a megfelelő COM portot

4. **Firmware feltöltés:**
   - Nyisd meg: `Arduino\IRQHack64\IRQHack64.ino`
   - Ellenőrizd hogy a `#define DEBUG` be van kapcsolva az `IrqHack64.h`-ban
   - Upload (Ctrl+U)

5. **Serial Monitor megnyitása:**
   - Tools → Serial Monitor (Ctrl+Shift+M)
   - Baud rate: **57600**
   - Line ending: "Newline"

6. **Ellenőrzés:**
   Ha minden rendben, a következőt kell látnod:
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

   Free RAM: XXXX
   ```

---

### MÓDSZER 2: Standalone Arduino Teszt

**Szükséges:**
- ✅ Arduino + SD modul (külön breadboarden)
- ✅ USB táp (programozó)
- ✅ SD kártya teszt adatokkal
- ❌ C64 NEM kell

**Előny:** Gyorsabb iteráció, nincs szükség C64-re
**Hátrány:** Nem teljes rendszer teszt

**Wiring (ha külön breadboard):**
```
Arduino Nano    SD Module
-----------     ---------
D10       →     CS
D11 (MOSI)→     MOSI
D12 (MISO)→     MISO
D13 (SCK) →     SCK
5V        →     VCC
GND       →     GND
```

**Eljárás:**
1. SD kártya előkészítése (mint Módszer 1)
2. Csatlakoztasd az SD modult
3. USB kábel → PC
4. Upload firmware
5. Serial Monitor @ 57600 baud

**Korlátok:**
- A C64 interface funkciók nem tesztelhetők
- EXROM, NMI, RESET, SEL gomb nem működik
- Csak a dirFunc/CartApi rész tesztelhető

---

### MÓDSZER 3: Mock Mode (Jövőbeli fejlesztés)

**JELENLEG NEM ELÉRHETŐ!**

Az Arduino firmware módosítása szükséges:
```cpp
#ifdef DEBUG_MOCK_SD
  // Mock SD - nem hívjuk az sd.begin()-t
  Serial.println(F("Mock SD mode - no real SD needed"));
#else
  // Real SD
  if (!sd.begin(chipSelect, SPI_FULL_SPEED)) {
      sd.initErrorHalt();
  }
#endif
```

Ha később implementáljuk, lehetővé teszi:
- SD kártya nélküli tesztelést
- Mock directory struktúra memóriában
- Gyorsabb fejlesztési ciklus

---

## Sprint 1 Teszt Parancsok

### Parancs 'p' - Print Current State

**Mit csinál:** Kiírja az aktuális könyvtár állapotot

**Használat:**
1. Serial Monitor-ban írd be: `p`
2. Nyomj Enter-t

**Elvárt kimenet:**
```
=== Current State ===
Path: /
Depth: 0
InSubDir: 0
Count: 3
```

---

### Parancs 'd' - Directory Navigation Test

**Mit csinál:** Interaktív könyvtár navigáció

**Használat:**
1. Serial Monitor-ban írd be: `d`
2. Amikor kéri, írd be a könyvtár nevét (pl. `GAMES`)
3. Nyomj Enter-t

**Példa - Belépés könyvtárba:**
```
d
=== Directory Navigation Test ===
Current path: /
Path depth: 0
Enter directory name (or .. to go back):
GAMES
Attempting to navigate to: GAMES
SUCCESS!
New path: /GAMES/
Item count: 15
```

**Példa - Vissza a szülő könyvtárba:**
```
d
=== Directory Navigation Test ===
Current path: /GAMES/
Path depth: 1
Enter directory name (or .. to go back):
..
Attempting to navigate to: ..
SUCCESS!
New path: /
Item count: 3
```

**Példa - Nem létező könyvtár:**
```
d
=== Directory Navigation Test ===
Current path: /
Path depth: 0
Enter directory name (or .. to go back):
NOTEXIST
Attempting to navigate to: NOTEXIST
FAILED!
```

---

### Parancs 'r' - Reset to Root

**Mit csinál:** Azonnal visszatér a root könyvtárba

**Használat:**
1. Navigálj mélyre (pl. /GAMES/ARCADE/)
2. Serial Monitor-ban írd be: `r`
3. Nyomj Enter-t

**Elvárt kimenet:**
```
=== Reset to Root ===
Path: /
Count: 3
```

---

## Teljes Teszt Szekvencia (7 teszt)

### 1. Teszt: Kezdeti Állapot
```
> p
=== Current State ===
Path: /
Depth: 0
InSubDir: 0
Count: 3
```
✅ **PASS** ha Path="/", Depth=0

### 2. Teszt: Belépés Létező Könyvtárba
```
> d
GAMES
Attempting to navigate to: GAMES
SUCCESS!
New path: /GAMES/
Item count: 15
```
✅ **PASS** ha SUCCESS és path="/GAMES/"

### 3. Teszt: Vissza Szülő Könyvtárba (..)
```
> d
..
Attempting to navigate to: ..
SUCCESS!
New path: /
```
✅ **PASS** ha SUCCESS és vissza a root-ra

### 4. Teszt: Nem Létező Könyvtár
```
> d
NOTEXIST
Attempting to navigate to: NOTEXIST
FAILED!
```
✅ **PASS** ha FAILED és path változatlan

### 5. Teszt: Mély Navigáció És Visszalépés
```
> d
GAMES
SUCCESS! → /GAMES/

> d
ARCADE
SUCCESS! → /GAMES/ARCADE/

> d
..
SUCCESS! → /GAMES/

> d
..
SUCCESS! → /
```
✅ **PASS** ha minden lépés sikeres és végén root

### 6. Teszt: Force Reset Mély Helyről
```
> d
GAMES
SUCCESS! → /GAMES/

> d
ARCADE
SUCCESS! → /GAMES/ARCADE/

> r
Path: /
Count: 3
```
✅ **PASS** ha azonnal root-ra ugrik

### 7. Teszt: Path Overflow Védelem
```
> d
AVeryLongDirectoryNameThatExceedsSixtyFourCharactersAndShouldBeRejected
Attempting to navigate to: AVeryLongDirectoryNameThatExceedsSixtyFourCharactersAndShouldBeRejected
FAILED!
```
✅ **PASS** ha FAILED, nincs crash

---

## Hibaelhárítás

### SD Kártya Nem Inicializálódik
**Tünet:**
```
Can't initialize!
```

**Megoldások:**
1. Ellenőrizd az SD kártya formátumát (FAT16/FAT32)
2. Próbáld ki más SD kártyával
3. Ellenőrizd a wiring-et (MOSI, MISO, SCK, CS)
4. Csökkentsd a sebességet: `SPI_HALF_SPEED` helyett `SPI_FULL_SPEED`

### Serial Monitor Nem Mutat Semmit
**Megoldások:**
1. Ellenőrizd a baud rate-et: 57600
2. Ellenőrizd a COM portot
3. Próbáld újraindítani az Arduino-t (Reset gomb)
4. Ellenőrizd hogy a `#define DEBUG` be van-e kapcsolva

### Teszt Parancsok Nem Működnek
**Megoldások:**
1. Ellenőrizd hogy feltetöltötted-e az új firmware-t
2. Nézd meg a Serial Monitor-t, van-e hibaüzenet
3. Próbáld a 'p' parancsot először (egyszerűbb)
4. Ellenőrizd hogy van-e SD kártya behelyezve

### C64 Nem Reagál
**Ha az EasySD be van dugva a C64-be:**
- A C64 tesztelés Sprint 2 része lesz
- Most csak a firmware-t teszteljük Serial Monitor-on
- A C64 nem kell hogy reagáljon erre a tesztre

---

## Jegyzőkönyv Sablon

```
SPRINT 1 TESZT JEGYZŐKÖNYV
==========================
Dátum: _______________
Tesztelő: _______________

HARDVER KONFIGURÁCIÓ:
[ ] Teljes rendszer (C64 + EasySD)
[ ] Standalone Arduino + SD modul
Arduino típus: _______________
SD kártya típus: _______________
SD kártya méret: _______________

SD TARTALOM:
Könyvtár struktúra:
[ ] /GAMES/
[ ] /GAMES/ARCADE/
[ ] /MUSIC/
[ ] /DEMOS/

FIRMWARE VERZIÓ:
Commit/Branch: _______________
DEBUG mode: [ ] ON [ ] OFF

TESZTEK:
[  ] 1. Kezdeti állapot (p parancs)
[  ] 2. Belépés létező könyvtárba
[  ] 3. Vissza szülőre (..)
[  ] 4. Nem létező könyvtár
[  ] 5. Mély navigáció
[  ] 6. Force reset
[  ] 7. Path overflow védelem

HIBÁK:
_______________________________________
_______________________________________
_______________________________________

MEGJEGYZÉSEK:
_______________________________________
_______________________________________
_______________________________________

ÖSSZESÍTÉS:
Sikeres tesztek: ___/7
Sprint 1 státusz: [ ] PASS [ ] FAIL
```

---

## Következő Lépések

Ha Sprint 1 tesztek sikeresek:
1. ✅ Firmware rész működik
2. ➡️ Sprint 2: C64 menü refaktorálás
3. ➡️ Sprint 3: Plugin-ok frissítése
4. ➡️ Sprint 4: Integrációs teszt

---

**Dokumentum verzió:** 1.0
**Utolsó frissítés:** 2025-12-23
**Sprint:** 1 (Firmware Foundation)
**Státusz:** Ready for Testing
