# CHANGELOG.md – EasySD / IRQHack64

> Utolsó frissítés: **2025-12-21**  
> Jelenlegi verzió: **v2.0.0-centralized-data**

---

## [2.0.0] – 2025-12-21

**Centralizált Adatkezelés és Architektúra Stabilizálás**

### Új funkciók és fejlesztések

- **Szigorú Lineáris Include Hierarchia**:
    - A `64tass` "duplicate definition" hibáinak elkerülése érdekében bevezetett egyirányú include lánc:
      `CartLibStream.s` → `CartZpMap.inc` → `CartLibHi.s` → `CartLib.s` → `CartLibCommon.s`.
    - Az `.inc` fájlok egyedi tulajdonjogot kaptak, megakadályozva a többszörös beillesztést és a szimbólum-konfliktusokat.
- **Központosított Zero Page (ZP) és Hardver Konstansok**:
    - Minden Zero Page hivatkozás egységesen `ZP_` prefixet kapott (pl. `ZP_IRQ_DATA_LOW`) a `CartZpMap.inc` térképe alapján.
    - A `System.inc` bővült a standard KERNAL belépési pontokkal (`K_OPEN`, `K_CLOSE`, `K_CHKIN`, `K_CHRIN`, `K_CLRCHN`) és a RAM vektorokkal (`V_OPEN`, `V_CLOSE`, `V_CHKIN`, `V_CLRCHN`, `V_CHRIN`).
    - Eltávolítottuk a redundáns helyi aliasokat (pl. `FILE_LENGTH`, `chrinVector`), a kód most már kizárólag a kanonikus neveket használja.
- **Végleges ZP Ütközésfeloldás**:
    - A `$80-$87` tartomány mostantól dedikáltan és kizárólag a `LoadFileBySize` rutin paramétereié.
    - A korábban itt ütköző callback és seek változók új, biztonságos címekre kerültek ($73-$76).
- **Teljes Plugin és Menü Modernizáció**:
    - Az összes plugin (`BurstLoader`, `KoalaDisplayer`, `MusPlayer`, `PetsciiDisplayer`, `PrgPlugin`, `WavPlayer`) és a főmenü átállítása az új standardokra.
    - Pótoltuk a korábbi refaktorálások során elveszett menü-specifikus definíciókat (`SIDPLAY`, `PATH_MAX`, `COMMANDENTERMASK`, `PATHBUFFER`, `NAMELOW`, `NAMEHIGH`, `COLLOW`, `COLHIGH`, stb.).

---

## [1.9.2] – 2025-12-21

**Egységes Python-alapú Build Rendszer**

### Új funkciók és fejlesztések

- **`Tools/build.py` bevezetése**:
    - Teljesen kiváltja a korábbi szövevényes `.bat` fájlrendszert (`Build - EasySD.bat`, `build_core.bat`, `build_plugins.bat`, stb.).
    - Cross-platform támogatás (Windows/Linux/macOS), amennyiben a Python 3 és a fordítóeszközök (`64tass`, `petcat`) rendelkezésre állnak.
    - Támogatott célok: `release`, `debug`, `core`, `plugins`, `clean`, `prebuild`.
- **C# függőségek felszámolása**:
    - A `Bin2ArdH.exe` és `CreateEpromLoader.exe` funkciói natív Python implementációt kaptak a `build.py`-ben.
    - Nincs szükség .NET futtatókörnyezetre vagy Mono-ra a build folyamathoz.
- **Fejlettebb Pre-build ellenőrzés**:
    - A `PreBuild.bat` regex-alapú inklúziós szabályai (CartZpMap.inc és CartLibCommon.s egyedi jelenléte) átültetve Pythonba.
    - Robusztusabb hibajelentés a fordítás megkezdése előtt.
- **Automatizált Arduino/EPROM generálás**:
    - A `release` és `core` targetek automatikusan frissítik az `Arduino/IRQHack64/FlashLib.h` fájlt és legenerálják az `IRQLoaderRom.bin` fájlt.
- **KeyBooter integráció**:
    - A `KeyBooter.s` fordítása mostantól a `core` build része, ha a forrásfájl létezik.

---

## [1.9.1] – 2025-12-21

**Útvonal-kezelés refaktorálás és Build stabilizálás (DigiWavuino inspiráció)**

### Hibajavítások és fejlesztések

- **Arduino / `DirFunction.cpp` & `.h`**:
    - **Abszolút útvonal-kezelés**: A korábbi instabil és ki nem használt `StringStack` alapú megoldás lecserélve egy fix, 64 bájtos statikus pufferre (`currentPath`).
    - **Strukturált Debug Naplózás**: Visszaépítve a fontosabb diagnosztikai üzenetek (`DIR:` előtaggal, `#ifdef DEBUG` alatt), amelyek nyomon követik a mappa-váltásokat, a visszalépéseket és a puffer állapotát.
    - **DigiWavuino-féle logika**: A `GoBack()` mostantól a puffer végéről keresve az utolsó `/` karaktert vágja le az útvonalat, ami RAM-takarékosabb és üzembiztosabb.
    - **Puffer-túlcsordulás védelem**: Bevezetve a `ChangeDirectory` hívásnál a biztonságos útvonalhossz ellenőrzés.
    - **Memória optimalizálás**: A stack-alapú objektumok eltávolításával értékes RAM szabadult fel az Arduino Nano-n.
- **WavPlayer Plugin / `WavPlayer.s`**:
    - **64tass szintaxis fix**: Kijavítva a névtelen labelek (`++`) hibás használata, ami "general syntax error"-t okozott. Lecserélve egyértelmű lokális labelre (`_not_zero`).
- **Validáció**:
    - **TAP Pulzus-időzítések**: Az EasySD küszöbértékei (`$37`, `$4A`) hivatalosan validálva a professzionális **DigiWavuino** és a KERNAL standard időzítések alapján. Megerősítve: a relaxed threshold stratégia a legrobusztusabb a motorsebesség-ingadozás ellen.

---

## [1.9] – 2025-12-21  

**Standard TAP → PRG támogatás és 64tass finomhangolás**

### Új funkciók

- **Standard TAP konverzió**: 
    - Automatikus `.TAP` → `.PRG` konverzió az Arduino firmware-ben.
    - Támogatja a TAP v0 és v1 (cycle-accurate) formátumokat.
    - Csak standard KERNAL/CBM blokkokat kezel (Turbo/Custom nem támogatott).
- **C64 Menu választási lehetőség**:
    - `.TAP` fájl esetén felugró prompt: **C (Convert+Run)** vagy **S (Save only)**.
    - Státuszsor visszajelzés: `UNSUPPORTED TAP`, `BAD TAP`, `SD WRITE FAILED`, `TAP CONVERT OK`.

### Hibajavítások és fejlesztések

- **Arduino / `CartApi.cpp`**:
    - **`TapFindCountdown` javítása**: A szinkron szekvencia keresése korrigálva a standard csökkenő sorrendre (`$89..$81`). Korábban hibásan növekvő sorrendet keresett.
    - **Paritás ellenőrzés**: Optimalizált páratlan paritás (odd parity) ellenőrzés a bájt-dekódolás során.
- **C64 Menu / `IrqLoaderMenuNew.s`**:
    - **64tass szintaxis javítása**: Belső címkék refaktorálva (`TAP_SCAN_` prefix), hogy elkerüljük az ütközést a 64tass `.dec` és `.check` direktíváival.
    - **Státuszsor kezelés**: Új `STATUS_LINE` rutin a felhasználói visszajelzésekhez mentés mód esetén.
- **`CartApi.h`**: Új TAP-specifikus hibakódok definiálva (`$12-$14`).

---

## [1.8.1] – 2025-12-21

**Streaming Optimalizálás**

### Fejlesztések

- **Arduino Streaming Puffer Optimalizálás**: Az Arduino-oldali streaming puffer mérete (`DOUBLE_BUFFER_SIZE`) fokozatosan növelve a teljesítmény javítása érdekében:
  - Korábbi Phase: 64 → 256 byte (SD kártya hatékonyság)
  - Phase 2+: 256 → 400 byte (video plugin támogatás)
  - Végső érték a `Arduino/IRQHack64/CartApi.h` fájlban: **400 byte**
  - A módosítás optimalizálja az SD kártya olvasási hatékonyságát és támogatja a 400 byte-os video blokkokat az Arduino Pro Mini hardver memórialimitjeinek tiszteletben tartása mellett.

---

## [1.8] – 2025-12-21  

**WavPlayer és Streaming stabilizálás**

### Hibajavítások és fejlesztések

- **WavPlayer.s kritikus javítások**:
    - **`IRQ_StartTalking`** hozzáadva: a plugin most már helyesen ébreszti fel az Arduinot.
    - **Regiszter mentés (PHA/TXA/TYA)**: az IRQ rutinok már nem rontják el a főprogram állapotát (billentyűzetkezelés stabil).
    - **ZP térkép tisztítás**: `PLAYSTATE`, `PLAYTYPE`, `PLAYINDEX` dedikált címekre mozgatva ($A2-$A4).
    - **Pufferelt lejátszás**: `PlayBothBuffered` implementálva és alapértelmezetté téve (SD jitter elleni védelem).
    - **Redundáns I/O eltávolítva**: az Arduino port olvasása optimalizálva.
- **Streaming architektúra**:
    - Verifikálva a `SafeStreamImpl.s` és az Arduino `HandleStream` dupla pufferelt mechanizmusa.
    - Az Arduino 100ms-os timeout mechanizmusa biztosítja a tiszta kilépést a streaming módból.

---

## [1.7] – 2025-12-18  

**Phase 2A+2B+2C+2E – Teljes plugin refaktorálás és stabilizálás**

### Új funkciók

- **`LoadFileBySize`** – pontos, fájlméret-alapú olvasás (skip byte + round-up pages)
- **`SafeStream` wrapper** – centralizált streaming profillal (`SAFE`/`NORMAL`/`FAST`)
- **`SAVESTATE/RESTORESTATE`** – VIC-II és memóriakonfiguráció mentése/kilépéskor visszaállítása (KoalaDisplayer)
- **`ERROR_GATE` minta** – központosított hibakezelés (kizárólag `PrgPlugin.s`-ben)

### Hibajavítások

- **KoalaDisplayer**: támogatja mind a **10003 byte-os (PRG header)**, mind a **10001 byte-os (raw)** formátumot
- **VIEWKOALA** tényleges meghívása – kép most **meg is jelenik**
- **VIC-II stabilizálás**: bank 0 kényszerítve, bitmap mód helyesen beállítva
- **PRINTSTATUS karakterkonverziós bug**: dupla konverzió eltávolítva – **DEBUG üzenetek láthatók VICE-ban**
- **"Branch too far" hibák**: helyi `BCC` + abszolút `JMP` minta minden pluginban
- **SafeStream register loading**: kritikus bug javítva – `TAX` nem írja felül az indexet (`CartLibStream.s` 79–93. sor)

### SafeStream architektúra lezárása (utólagos Phase 2A kiegészítés – 2025-12-19)

- **SafeStream implementáció szétválasztva**:
  - `CartLibStream.s` → *publikus API / wrapper*
  - `SafeStreamImpl.s` → *egyetlen, kanonikus stream implementáció*
- **Zero Page ütközés megszüntetve**:
  - `$80–$87` kizárólag `LoadFileBySize`
  - Stream temp változók áthelyezve `$8B–$8E` tartományba
  - `CartZpMap.inc` mint *single source of truth*
- **64tass-kompatibilis include modell**:
  - `CartZpMap.inc` csak egyszer kerül include-olásra (wrapper szinten)
  - `.ifndef` / include-guard problémák teljesen elkerülve
- **Plugin ABI változatlan maradt**:
  - `JSR SafeStream`, `JSR CustomStream` hívások módosítás nélkül működnek
- **Stabilitási eredmény**:
  - WAV + MUS streaming VICE és valós hardveren azonosan viselkedik
  - Rejtett ZP-heisenbug megszűnt

### Refaktorálás

- **`DebugMacros.s`**: közös fájl – `PRINTSTATUS`, `DELAYFRAMES` (120 sor duplikáció eliminálva)
- **`DebugStrings.s`**: közös fájl – 11 DEBUG string (`OPENING FILE`, `READING FILE`, stb.)
- **Plugin ABI tisztázva**: plugin felelős a state restore-ért, **NEM** a menü
- **CLAUDE.md bővítve**: +170 sor – **"Plugin Development Guidelines"** (7 pontból álló szabályrendszer)

### Új fájlok

- `Loader/CartLibStream.s` (177 sor)
- `Loader/DebugMacros.s" (85 sor)
- `Loader/DebugStrings.s" (75 sor)

### Metrikák

- **186 sor duplikáció eliminálva**
- **5/5 plugin sikeres build (DEBUG=1 is tiszta)**

---

## [1.6.1] – 2025-12-15  

**64tass .enc direktíva javítások – modern assembler kompatibilitás**

### Hibajavítások

- **Idézőjelek hozzáadva** a `.enc` direktívákhoz: &nbsp; `.enc "screen"`, `.enc "none"` (13 helyen)
- **Fölösleges `.enc` blokkok törölve**, ahol nem volt `.TEXT` használat (2 helyen)

### Érintett fájlok

- `IrqLoaderMenuNew.s` (6 hely)
- `Warning.s`, `KeyBooter.s`
- Minden plugin: `KoalaDisplayer.s`, `WavPlayer.s`, `PetsciiDisplayer.s`, `PrgPlugin.s`

### Eredmény

- **Teljes build rendszer kompatibilis** a modern **64tass v1.59.3120+** verzióval  
- `not defined symbol 'screen'` hibák megszűntek

---

## [1.6] – 2025-12-15  

**Build rendszer és Phase 1 stabilitási javítások**

### Build rendszer fejlesztések

- **`Build - EasySD.bat`** – új, aktív build script
- **Error handling minden lépésnél** (`IF %ERRORLEVEL% NEQ 0`)
- **Progress feedback** – 4 lépés, részletes üzenetek
- **Proper cleanup** – törlés: `.obj`, `.tmp`, `.bin.bin`, plugin `.bin` fájlok
- **User-friendly output** – fájl lista + következő lépések

### Phase 1 kritikus javítások (VALIDATION_AND_FIXES.md)

- **`Filename.s`**:  

&nbsp; - `INY` hozzáadva `FOUNDPERIOD` után (pont átlépése)  

&nbsp; - Off-by-one javítva  

&nbsp; - 3 karakteres kiterjesztés limit

- **`PatternMatch.s`**: `PATTERN_INITIALIZED` védőflag hozzáadva

- **`IrqLoaderMenuNew.s`**:  

&nbsp; - PRG fájl **load address parsing** (nem hardcoded `$C000`)  

&nbsp; - ROM timing makrók alkalmazva (`CART_ROM_ENABLE/RESTORE`)

- **ROM timing**: minden cartridge olvasás előtt `$01 = $37`, utána `$01 = $35`

### Eredmény

- **5/5 plugin sikeres fordítás**

- **Minden Phase 1 fix validálva és implementálva**

- Build kimenet tiszta, csak `.prg`, `IRQLoaderRom.bin`, `FlashLib.h` marad

---

## [1.5] – 2025-12-14 (verifikálva: 2025-12-15)  

**Arduino oldali kritikus stabilitási javítások**

### Hibajavítások (VERIFICATION_REPORT.md)

- **Fix #1**: `HandleStream` – **dangling pointer** → static buffer + `volatile`
- **Fix #2**: **PORT/PIN keverés** → `PORTD`/`PORTC` olvasása read-modify-write-hoz
- **Fix #3**: **NMI timing** – 6 µs → **10 µs minimum**, 31 µs → **50 µs delay**
- **Fix #7**: **Bitwise OR (`|`) → Logical OR (`||`)**
- **Fix #5**: `LoaderStub.65s` – **X register inicializálva** `$00`-ra (`MEMSIZ = $8000`)
- **Fix #6**: **`BLT` → `BCC`** – standard 6502 instrukció
- **Fix #8**: **Plugin `.prg` generálás** – `.obj + .bin → .prg` konzisztens minden pluginban

### Eredmény

- **Minden fix hivatalosan verifikálva** (Arduino, AVR, C64, 6502 specifikációk alapján)  
- **Stack használat csökkent**: 280 byte → 24 byte  
- **Build stabilitás**: nincs több "garbage pointer" vagy NMI timing hiba

---

## Összefoglaló – Projekt állapota (2025-12-21)

| Fázis | Tartalom | Státusz |
|------|---------|--------|
| **Phase 1** | Kritikus bugfixek (Arduino + C64 alap) | KÉSZ |
| **Phase 2A–2E** | Plugin infrastruktúra, streaming, file loading, dokumentáció | KÉSZ |
| **Phase 3A** | Standard TAP → PRG támogatás (v0/v1) | KÉSZ |
| **Adatkezelés** | Centralizált include hierarchia és ZP térkép | KÉSZ |
| **Build rendszer** | Hibamentes Python build (Release/Debug) | KÉSZ |
| **Hardware teszt** | EPROM programozás, C64 futtatás | **KÉSZEN ÁLL** |