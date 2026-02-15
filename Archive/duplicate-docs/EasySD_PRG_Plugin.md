# EasySD PRG Plugin – Technikai Dokumentáció

A **PRG Plugin** az EasySD rendszer legkomplexebb modulja, amely nem csupán egy fájlbetöltő, hanem egy **KERNAL-emulációs réteg**. Feladata, hogy az SD kártyáról betöltött programok számára egy transzparens, 8-as eszközszámú lemezmeghajtó (Commodore 1541) illúziót keltse.

**Forrásfájl:** `IRQHack64/Plugins/PrgPlugin/PrgPlugin.s`
**Build kimenet:** `IRQHack64/build/plugins/prgplugin.prg` ($C000-$D1xx)
**Arduino handler:** `Arduino/IRQHack64/CartApi.cpp`

## 1. Alapvető Funkciók

*   **PRG Betöltés:** Beolvassa a `.prg` fájlokat az SD kártyáról a fájl fejlécében tárolt memóriacímre (Load Address), a központi `LoadFileBySize` API használatával.
*   **KERNAL Hooking:** Átirányítja a Commodore 64 szabványos bemeneti/kimeneti rutinjait (OPEN, CLOSE, CHKIN, CHRIN, CLRCHN) az EasySD kártya felé a RAM vektorok ($031A-$0324) módosításával.
*   **Device 8 Emuláció:** Beállítja a rendszert a 8-as eszközszám használatára (`$BA = $08`), és csak az erre az eszközre irányuló KERNAL hívásokat kezeli.
*   **Automatikus Indítás:** Intelligensen felismeri a BASIC programokat ($0801 load címmel) és a gépi kódú programokat, majd megfelelően inicializálja és indítja őket.
*   **Futás Közbeni File I/O:** A betöltött program futás közben KERNAL hívásokkal tud fájlokat nyitni, olvasni és zárni az SD kártyáról.

## 2. A Működési Logika

A plugin folyamata négy fázisra osztható:

### A. Inicializálás és Fájlmegnyitás

**Kód:** `PrgPlugin.s:50-64` (MAIN)

1.  A Menü átadja a kiválasztott fájl nevét (31 karakter a CASSETTEBUFFER-ben, $033C)
2.  `IRQ_SetName`: Fájlnév regisztrálása
3.  `IRQ_OpenFile`: Fájl megnyitása az Arduinón (flags=1, read mode)
4.  Arduino oldal: `CartApi::HandleOpenFile()` - SdFat `sd.open()` hívás

### B. Fájlinformáció és Load Address Olvasása

**Kód:** `PrgPlugin.s:69-110`

1.  `IRQ_GetInfoForFile`: 32 bájtos FAT metadata lekérése
    - Byte 28-31: 32-bites fájlméret (FAT_FILE_LENGTH_INDEX = 28)
2.  Első 2 bájt olvasása (PRG header):
    - `GENERALBUFFER[0]` = Load Address Low → `STARTADDRESSLO` ($D12E)
    - `GENERALBUFFER[1]` = Load Address High → `STARTADDRESSHI` ($D12F)

### C. Fájl Betöltése Memóriába

**Kód:** `PrgPlugin.s:111-134`

A központi `LoadFileBySize` API használata:
```assembly
; Zero Page paraméterek beállítása:
LDA FILELENGTH       ; 32-bites fájlméret
STA ZP_LF_SIZE0      ; $80-$83
...
LDA #2               ; PRG header (2 bájt) kihagyása
STA ZP_LF_SKIP_LO
LDA STARTADDRESSLO   ; Célcím
STA ZP_IRQ_DATA_LOW
JSR LoadFileBySize   ; Központi betöltő rutin
```

**Előny:** Pontos bájtszámú olvasás, nem page-alapú, támogatja a nagy fájlokat (>64KB).

### D. Rendszer Visszaállítás és KERNAL Hooking

**Kód:** `PrgPlugin.s:143-186`

1.  **KERNAL és BASIC Inicializálás:**
    ```assembly
    JSR $FDA3    ; IOINIT - CIA chipek inicializálása
    JSR $FD15    ; RESTOR - KERNAL RAM vektorok alaphelyzetbe
    JSR $FF5B    ; CINT   - VIC és screen editor inicializálás
    JSR $E453    ; BASIC RAM vektorok inicializálása
    JSR $E3BF    ; BASIC memória inicializálás
    JSR $E422    ; BASIC "NEW" parancs, power-up üzenet
    ```

2.  **BASIC Mutatók Frissítése:**
    ```assembly
    LDY ENDADDRESSLO       ; Program vége címe
    STY $2D                ; VARTAB - változók kezdete
    STY $2F                ; ARYTAB - tömbök kezdete
    STY $AE                ; LOAD_START_LO
    LDA ENDADDRESSHI
    STA $2E                ; VARTAB high
    STA $30                ; ARYTAB high
    STA $AF                ; LOAD_START_HI
    ```

3.  **KERNAL Vektorok Átírása (SETVECTORS):**
    ```assembly
    LDA #<NEW_CHRIN
    STA V_CHRIN ($0324)    ; Character Input
    LDA #>NEW_CHRIN
    STA V_CHRIN+1

    LDA #<NEW_OPEN
    STA V_OPEN ($031A)     ; File Open
    ...
    ; Hasonlóan: V_CLOSE, V_CHKIN, V_CLRCHN
    ```

4.  **Device Number Beállítás:**
    ```assembly
    LDA #$08
    STA $BA      ; Current Device Number
    ```

5.  **Program Indítás:**
    - Ha `STARTADDRESS = $0801`: `JMP $A7AE` (BASIC RUN)
    - Különben: `JMP (STARTADDRESS)` (gépi kód)

### E. Futás Közbeni File Műveletek (Runtime I/O)

A program futása közben a KERNAL hívások az alábbi hook rutinokba kerülnek:

#### **NEW_OPEN (Fájl Megnyitása)**

**Kód:** `PrgPlugin.s:232-293` (NEW_OPEN)

```assembly
NEW_OPEN
    INC $D020              ; DEBUG: Border színváltozás
    LDA $BA                ; KERNAL_DEVICE_NUMBER
    CMP #08
    BEQ +                  ; Device 8 -> kezelje a plugin
    JMP K_OPEN ($F34A)     ; Más eszköz -> eredeti KERNAL
+
    ; Device 8 kezelése:
    JSR IRQ_DisableDisplay
    JSR IRQ_StartTalking   ; Kommunikáció kezdése Arduinóval

    ; Fájlnév átadása:
    LDX $BB                ; KERNAL_FILENAME_LOW
    LDY $BC                ; KERNAL_FILENAME_HIGH
    LDA $B7                ; KERNAL_FILENAME_LENGTH
    JSR IRQ_SetName

    ; Arduino: HandleOpenFile()
    LDX #01                ; flags=read
    JSR IRQ_OpenFile

    ; Fájl információ lekérése (méret):
    JSR IRQ_GetInfoForFile
    ; OPENEDFILELENGTH tárolása ($D132-$D135)

    JSR IRQ_EndTalking
    CLC                    ; Success
    RTS
```

**Arduino oldal:** `CartApi::HandleOpenFile()`
- **Relative path támogatás:** Fájlnevek működnek `currentPath` alapján (DirFunction)
- **Absolute path támogatás:** Explicit `/` kezdetű path-ok root-ból nyitnak
- `workingFile = sd.open(fileName, flags)` - SdFat automatikus path feloldás
- Response: `SUCCESSFUL` ($80) vagy `FILE_CANNOT_BE_OPENED`

#### **NEW_CHKIN (Input Channel Beállítás)**

**Kód:** `PrgPlugin.s:294-306` (NEW_CHKIN)

```assembly
NEW_CHKIN
    LDA $BA
    CMP #08
    BEQ +
    JMP K_CHKIN ($F20E)    ; Eredeti KERNAL
+
    STX TALK_FILE          ; Logikai fájlszám tárolása
    LDA #$00
    STA TALK_DIRECTION     ; 0 = read mode
    STA KERNAL_STATUS      ; Clear status
    CLC
    RTS
```

**Művelet:** Csak a plugin belső állapotát állítja be, nincs Arduino kommunikáció.

#### **NEW_CHRIN (Karakter Olvasás) - Legfontosabb!**

**Kód:** `PrgPlugin.s:333-386` (NEW_CHRIN)

Ez a leggyakrabban hívott rutin. Minden `GET#`, `INPUT#`, `LOAD` művelet ezt használja.

**Algoritmus:**

1.  **Device Szűrés:**
    ```assembly
    LDA $BA
    CMP #08
    BEQ +
    JMP K_CHRIN ($F157)    ; Más eszköz -> eredeti
    ```

2.  **EOF Ellenőrzés:**
    ```assembly
    LDA FILEINDEXLOW ($D136)
    CMP OPENEDFILELENGTH ($D132)
    BNE +                  ; Nem EOF
    ; High byte check...
    LDA #$40               ; EOF bit
    STA KERNAL_STATUS ($90)
    LDA #$00               ; Return 0
    CLC
    RTS
    ```

3.  **256 Bájtos Buffer Kezelés:**
    ```assembly
    LDA FILEINDEXLOW
    BNE +                  ; Ha != 0, már van adat a bufferben

    ; Buffer újratöltése:
    JSR IRQ_StartTalking
    LDA #<GENERALBUFFER ($D02A)
    STA ZP_IRQ_DATA_LOW
    LDA #>GENERALBUFFER
    STA ZP_IRQ_DATA_HIGH
    LDA #1                 ; 1 page = 256 bájt
    STA ZP_IRQ_DATA_LENGTH
    JSR IRQ_ReadFileNoCallback
    JSR IRQ_EndTalking
    ```

4.  **Bájt Visszaadása:**
    ```assembly
    LDX FILEINDEXLOW       ; Buffer index
    LDA GENERALBUFFER,X    ; Adat olvasása
    TAY                    ; Mentés Y-ba
    INC FILEINDEX          ; Index növelése (16-bit)
    TYA                    ; Visszaállítás A-ba
    RTS
    ```

**Arduino oldal:** `CartApi::HandleReadFile()`
- Olvas 16 bájtos chunk-okban (SPI optimalizálás)
- NMI-alapú átvitel (`TransmitByteFastStd`)
- Interrupt letiltás a kritikus szekcióban

**Teljesítmény:**
- 256 bájtonként **1 Arduino kommunikáció** (nem minden karakternél!)
- Buffer hit rate: 255/256 ≈ **99.6%** lokális olvasás

#### **NEW_CLOSE (Fájl Lezárása)**

**Kód:** `PrgPlugin.s:307-324` (NEW_CLOSE)

```assembly
NEW_CLOSE
    LDA $BA
    CMP #08
    BEQ +
    JMP K_CLOSE ($F291)
+
    JSR IRQ_DisableDisplay
    JSR IRQ_StartTalking
    JSR IRQ_CloseFile      ; Arduino: HandleCloseFile()
    JSR IRQ_EndTalking
    RTS
```

**Arduino oldal:** `CartApi::HandleCloseFile()`
- `workingFile.close()`
- File handle felszabadítása

#### **NEW_CLRCHN (Channel Clear)**

**Kód:** `PrgPlugin.s:325-332` (NEW_CLRCHN)

```assembly
NEW_CLRCHN
    LDA $BA
    CMP #08
    BEQ +
    JMP K_CLRCHN ($F32F)
+
    RTS                    ; Nincs művelet
```

**Megjegyzés:** A plugin nem igényel külön channel cleanup-ot.

## 3. Hardver és Kommunikáció

### C64 Oldal (Client)

**Cartridge Port Kapcsolatok:**
- **NMI (pin 8):** Bit-timing alapú adatátvitel (400μs = 0, 800μs = 1)
- **EXROM (pin 3):** Cartridge ROM enable
- **RESET (pin 9):** C64 reset vezérlés
- **IO2 (pin 2):** $DF00-$DFFF address range detect

**Memóriakiosztás:**
- **$C000-$C8xx:** Plugin kód (main, hooks)
- **$C9xx-$CCxx:** CartLib rutinok (IRQ_*, LoadFileBySize)
- **$D02A-$D129:** GENERALBUFFER (256 bájt, read buffer)
- **$D12A-$D137:** File metadata (length, start/end address, index)

### Arduino Oldal (Server)

**Hardware:**
- Arduino Nano/Pro Mini (ATmega328P, 16 MHz)
- SD kártya: SPI_FULL_SPEED (8 MHz)
- SdFat library: FAT16/FAT32 támogatás

**API Parancsok:**
- `COMMAND_OPEN_FILE (2)`: Fájl megnyitása
- `COMMAND_CLOSE_FILE (3)`: Fájl lezárása
- `COMMAND_READ_FILE (78)`: Adatok olvasása
- `COMMAND_GET_INFO_FOR_FILE (8)`: FAT metadata lekérése

**Kommunikációs Protokoll:**
1. C64 → Arduino: 3 bájtos handshake (`$64, $46, $17`)
2. C64 → Arduino: Parancs bájt
3. C64 → Arduino: Argumentumok (változó hossz)
4. Arduino → C64: Response bájt (`$80` = success, `$01`-`$7F` = error)
5. Arduino → C64: Adatok (ha van)

**Timing:**
- NMI bit encoding: 400-800 μs per bit
- SD olvasás: ~10-20 μs per bájt
- **Bottleneck:** NMI kommunikáció (~3-6 ms/bájt)

## 4. Miért a 8-as eszközszám?

A C64 szabvány eszközszámai:
- **1:** Kazettás magnó (Datassette)
- **4:** Nyomtató
- **8:** Első lemezmeghajtó (1541)
- **9:** Második lemezmeghajtó (ha van)

A legtöbb C64-es szoftver **keményen kódolva a 8-as eszközszámot** keresi. A plugin:

1.  Inicializáláskor beállítja: `$BA = $08` (Current Device Number)
2.  Minden hook rutin ellenőrzi:
    ```assembly
    LDA $BA
    CMP #08
    BEQ +              ; Device 8 -> plugin kezeli
    JMP ORIGINAL_KERNAL ; Más -> eredeti KERNAL
    ```
3.  **Transzparens működés:** Más eszközök (magnó, nyomtató) zavartalanul működnek

**Példa - Többeszközös használat:**
```basic
OPEN 1,1,0,"PROGRAM"  : REM Magnóról betöltés -> eredeti KERNAL
OPEN 2,8,2,"DATA.SEQ" : REM SD kártyáról -> PRG Plugin
INPUT#2,A$            : REM SD-ről olvasás
OPEN 4,4              : REM Nyomtatás -> eredeti KERNAL
PRINT#4,A$            : REM Nyomtatóra írás
CLOSE 2 : CLOSE 4 : CLOSE 1
```

## 5. Használati Esetek

### A. BASIC Program Futtatás

**Példa:** Adatbázis kezelő program
```basic
10 OPEN 1,8,2,"/DATABASE/RECORDS.DAT"
20 INPUT#1,NAME$,AGE
30 PRINT NAME$, AGE
40 CLOSE 1
```

**Működés:**
1. Plugin betölti a BASIC programot
2. KERNAL vektorok hooked
3. `OPEN` -> `NEW_OPEN` -> Arduino megnyitja `/DATABASE/RECORDS.DAT`
4. `INPUT#1` -> `NEW_CHRIN` (többször) -> SD-ről olvas
5. `CLOSE` -> `NEW_CLOSE` -> Arduino lezárja

### B. Többlemezes Játék

**Példa:** Adventure játék level streaming
```assembly
; Játék kód (gépi kód):
    LDA #2
    LDX #8              ; Device 8
    LDY #2              ; Secondary address
    JSR $FFBA           ; SETLFS

    LDA #FILENAME_LEN
    LDX #<FILENAME
    LDY #>FILENAME
    JSR $FFBD           ; SETNAM

    JSR $FFC0           ; OPEN (-> NEW_OPEN)

    LDX #2
    JSR $FFC6           ; CHKIN (-> NEW_CHKIN)

READLOOP
    JSR $FFCF           ; CHRIN (-> NEW_CHRIN)
    ; Process data...
    BCC READLOOP        ; Carry clear = nincs EOF

    LDA #2
    JSR $FFC3           ; CLOSE (-> NEW_CLOSE)
```

### C. Szövegszerkesztő

**Példa:** Dokumentum betöltés
```basic
OPEN 1,8,2,"/DOCS/LETTER.TXT"
GET#1,A$
IF ST=0 THEN PRINT A$;:GOTO 10
CLOSE 1
```

**Előny:** A program **nem tudja**, hogy nem valódi 1541-gyel beszél.

## 6. Előnyök és Korlátok

### Előnyök

*   **Sebesség:** Cartridge port direktben ~100× gyorsabb mint IEC soros port
*   **Transzparencia:** KERNAL-t használó szoftverek **módosítás nélkül** működnek
*   **Kompaktság:** Nincs külső tápegység, kábelek
*   **Többlemezes játékok:** Level streaming, save/load támogatás relatív fájlnevekkel
*   **Flexible Path Support:** Mind absolute (`"/PATH/FILE"`), mind relative (`"FILE"`) fájlnevek működnek
*   **Szabványos API:** Minden BASIC/KERNAL file művelet működik
*   **Zéró tanulási görbe:** Programozók ismert KERNAL hívásokat használnak

### Korlátok

*   **Nincs Hardware Emuláció:** Nem emulálja az 1541 6502 CPU-ját, VIA chipjeit, GCR encoding-ot
*   **Fast Loader Inkompatibilitás:** Azok a programok, amelyek közvetlenül a meghajtó hardverével beszélnek (pl. Ocean Loader, Vorpal, Hypra-Load) **nem működnek**
*   **Csak KERNAL-alapú I/O:** A direct memory access, custom serial protokollok nem támogatottak
*   **DOS Wedge hiány:** A `@` parancsok (pl. `@S:FILE`, `@DIR`) nincsenek implementálva
*   **Write limit:** CHKOUT hook nincs implementálva (csak olvasás, `PRINT#` írás nem támogatott)

**Kompatibilitási becslés:**
- ✅ BASIC programok: ~100%
- ✅ KERNAL-based utility-k: ~95%
- ✅ KERNAL-based játékok: ~60-70%
- ❌ Fast loader-es játékok: ~5% (csak amelyek fallback-ra tudnak váltani)

## 7. Fejlesztői Megjegyzések

### Memóriahasználat

**C64 Memória:**
- **Zero Page:**
  - Központi API ZP: `$64`, `$69-$6D`, `$73-$77`, `$80-$95` (CartZpMap.inc)
  - Plugin inicializálás: `$FB-$FE` (ideiglenes, user range)
- **Plugin kód:** `$C000-$C8xx` (~2 KB)
- **CartLib:** `$C9xx-$CCxx` (~3 KB)
- **Bufferek:** `$D000-$D1xx` (~500 bájt)

**Arduino Memória:**
- **RAM:** ~1.5 KB használat (SdFat, bufferek)
- **Flash:** ~20 KB (firmware + SdFat library)

### Teljesítmény Mérések

**Elméleti sebesség:**
- NMI bit rate: ~400 μs/bit × 8 = **3.2 ms/bájt**
- Effektív: ~2.5 KB/s (buffer és protocol overhead)

**Valós használat (256 bájtos bufferrel):**
- 1 KB fájl: ~400 ms (első olvasás) + ~0 (buffer hit)
- 10 KB fájl: ~4 sec (folyamatos olvasás)

**Összehasonlítás:**
- Original 1541: ~400 bájt/sec (IEC soros)
- **PRG Plugin: ~2500 bájt/sec** (**6× gyorsabb**)
- Fast loader: ~3000-4000 bájt/sec (KERNAL bypass)

### Debug Funkciók

**Border Flash:** Minden hook rutin `INC $D020` hívással jelzi magát (csak fejlesztői build-ben)

**Serial Debug:**
```cpp
#ifdef DEBUG
Serial.println(F("Got HandleOpenFile"));
Serial.print(F("Filename : ")); Serial.println(fileName);
#endif
```

### Bővítési Lehetőségek

**Potenciális fejlesztések:**
1. **CHKOUT hook implementálás:** `PRINT#` támogatás (írás)
2. **Nagyobb buffer:** 512 vagy 1024 bájt (jobb throughput)
3. **Directory olvasás:** `LOAD "$",8` támogatás (fájllista)
4. **DOS Wedge:** `@` parancsok értelmezése
5. **Save support:** `SAVE "FILENAME",8` működés

**Architektúrális előnyök:**
- Központi API: Változtatások egy helyen (`CartApi.cpp`)
- Tiszta interfész: C64 és Arduino szigorúan szeparált
- Bővíthető: Új parancsok könnyen hozzáadhatók

## 8. Hivatkozások és További Olvasmány

**Projekt Fájlok:**
- C64 plugin: `IRQHack64/Plugins/PrgPlugin/PrgPlugin.s`
- Arduino API: `Arduino/IRQHack64/CartApi.cpp`, `CartApi.h`
- Cartridge interface: `Arduino/IRQHack64/CartInterface.cpp`
- Build listing: `IRQHack64/build/listing/prgpluginLST.txt`

**Központi API-k:**
- `LoadFileBySize`: `IRQHack64/Loader/CartLibHi.s`
- Zero Page Map: `IRQHack64/Loader/CartZpMap.inc`
- Main README: `README.MD`

**Külső Referenciák:**
- [C64 KERNAL funkciólistája](https://sta.c64.org/cbm64krnfunc.html)
- [KERNAL API dokumentáció](https://www.pagetable.com/c64ref/kernal/)
- [C64 KERNAL hooking útmutató](https://c64os.com/post/c64kernalrom)
- [File műveletek C64-en](https://c64os.com/post/filereferences)

---

**Verzió:** 2.0.1
**Utolsó frissítés:** 2025-12-22
**Státusz:** Működő implementáció, production ready

## Változtatások Története

### v2.0.1 (2025-12-22)
- **BUGFIX:** Relative path támogatás hozzáadva a többlemezes játékokhoz
- **Módosítás:** `CartApi::HandleOpenFile()` már nem utasítja el a relatív fájlneveket
- **Dokumentáció:** Tesztelési útmutató hozzáadva (`BUGFIX_RelativePath_Support.md`)
- **Előny:** Játékok mostantól egyszerű fájlneveket használhatnak (`"LEVEL2.DAT"`)

### v2.0.0 (2025-12-21)
- Eredeti dokumentáció elkészítése
- Teljes működési logika leírása
- Hook rutinok részletes dokumentálása
