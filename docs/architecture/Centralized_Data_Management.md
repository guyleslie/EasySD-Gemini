# Centralized Data Management for EasySD Gemini Project

Ez a dokumentum rögzíti az EasySD Gemini projekt központosított adat- és címkezelési szabályait. A cél a build stabilitásának biztosítása, a Zero Page ütközések elkerülése és a kód karbantarthatóságának javítása a `64tass` assembler környezetben.

---

## 1. Architekturális Alapelvek

A projekt a **"Linear Include Chain"** (Lineáris beágyazási lánc) elvét követi. Mivel a `64tass` nem támogatja a hagyományos C-stílusú include-guard-okat (`.ifndef`), a többszörös beágyazás "duplicate definition" hibát okoz.

### 1.1. A Lineáris Lánc felépítése
A szimbólumok az alábbi sorrendben öröklődnek:
`CartLibStream.s` (Wrapper)
  └── `CartZpMap.inc` (ZP definíciók - **Kizárólag itt!**)
  └── `CartLibHi.s` (High-level API)
        └── `CartLib.s` (Low-level interface)
              └── `CartLibCommon.s` (Alapvető rendszercímek)
                    └── `Common/System.inc` (C64 hardver & KERNAL)
                    └── `Common/IRQHack.inc` (Hardware parancsok)

### 1.2. Include Ownership (Tulajdonjog)
A build rendszer (`build.py`) szigorúan ellenőrzi, hogy bizonyos fájlok csak egyszer szerepeljenek:
*   **`CartZpMap.inc`**: Kizárólag a `Loader/CartLibStream.s` ágyazhatja be.
*   **`CartLibCommon.s`**: Kizárólag a `Loader/CartLib.s` ágyazhatja be.
*   **Pluginok/Menü**: Soha nem ágyazhatják be közvetlenül a fenti `.inc` vagy `.s` fájlokat, ha a `CartLibStream.s`-t használják.

---

## 2. Központi Definíciós Fájlok

### 2.1. `System.inc` (C64 Standard)
Tartalmazza a Commodore 64 fix címeit. Aliasok helyett a kanonikus neveket használjuk:
*   **KERNAL Belépési pontok (ROM):** `K_OPEN` ($F34A), `K_CLOSE` ($F291), `K_CHKIN` ($F20E), `K_CHRIN` ($F157), `K_CLRCHN` ($F32F).
*   **KERNAL RAM Vektorok:** `V_OPEN` ($031A), `V_CLOSE` ($031C), `V_CHKIN` ($031E), `V_CLRCHN` ($0322), `V_CHRIN` ($0324).
*   **Hardver Regiszterek:** `VIC_CONTROL_1` ($D011), `VIC_INT_ACK` ($D019), `CIA_1_BASE` ($DC00), stb.
*   **Hardver Maszkok:** `VIC_DEN` ($10), `VIC_INT_RASTER` ($01).

### 2.2. `IRQHack.inc` (Hardware API)
Az IRQHack kártya specifikus parancsai és státuszkódjai:
*   **Parancsok:** `COMMAND_READ_FILE` (78), `COMMAND_OPEN_FILE` (2), `COMMAND_STREAM` (25), stb.
*   **Státusz:** `CARTRIDGE_READY` ($00), `CARTRIDGE_PROCESS_OK` ($80).
*   **KERNAL Paraméterek:** `KERNAL_FILENAME_LENGTH` ($B7), `KERNAL_FILENAME_LOW` ($BB), `KERNAL_STATUS` ($90).

### 2.3. `CartZpMap.inc` (Zero Page Térkép)
Ez a fájl a **Single Source of Truth** minden ZP-t használó rutin számára. Minden itt lévő név `ZP_` prefixet kap.

| Tartomány | Leírás | Címkék (példa) |
|:---|:---|:---|
| **$64** | Foreground Sync | `ZP_IRQ_WaitHandle` |
| **$69-$6A** | Data/Seek Pointer | `ZP_IRQ_SEEK_LOW`, `ZP_IRQ_SEEK_HIGH` |
| **$6B** | Data Length | `ZP_IRQ_DATA_LENGTH` |
| **$6C-$6D** | Buffer Pointer | `ZP_IRQ_DATA_LOW`, `ZP_IRQ_DATA_HIGH` |
| **$73-$74** | Callback Pointer | `ZP_IRQ_CALLBACK_LO`, `ZP_IRQ_CALLBACK_HI` |
| **$75-$76** | Seek Upper Word | `ZP_IRQ_SEEK_UPPER_LO`, `ZP_IRQ_SEEK_UPPER_HI` |
| **$77** | Temp Storage | `ZP_IRQ_TEMP` |
| **$80-$87** | `LoadFileBySize` | `ZP_LF_SIZE0..3`, `ZP_LF_SKIP_LO/HI`, `ZP_LF_PAYLOAD_LO/HI` |
| **$8B-$8E** | *(reserved, currently unused)* | — |
| **$90-$95** | `StreamLargeFile` | `ZP_STREAM_TARGET_ADDR_LO/HI`, `ZP_STREAM_BYTES_REMAIN_0..3` |

---

## 3. Használati Útmutató Fejlesztőknek

### 3.1. Beágyazás (Plugin / Menü)
A pluginok elején tilos a `.inc` fájlok direkt meghívása, ha a kód a lánc valamelyik elemét használja.
**Helyes módszer:**
```assembly
; Plugin kód...
.include "../../Loader/CartLibStream.s" ; Ez automatikusan hozza a ZP és System definíciókat
```

### 3.2. Hivatkozás a Zero Page-re
Soha ne használj fix címet vagy prefix nélküli nevet!
*   **Helytelen:** `STA $6C` vagy `STA IRQ_DATA_LOW`
*   **Helyes:** `STA ZP_IRQ_DATA_LOW`

### 3.3. Kanonikus nevek használata
A kód olvashatósága és a központi módosíthatóság érdekében kerüld a helyi aliasokat.
*   **Helytelen:** `STA FILENAME_LOW`
*   **Helyes:** `STA KERNAL_FILENAME_LOW`

---

## 4. DEBUG Mode Viselkedés és Korlátai

A projekt támogatja a `DEBUG=1` build flag-et (64tass: `-D DEBUG=1`), amely **jelentősen módosítja** a futási viselkedést. A DEBUG mode **KIZÁRÓLAG** VICE emulátorban történő fejlesztéshez és hibakereséshez használható.

### 4.1. DEBUG Mode Módosítások

**CartLibHi.s - IRQ_WaitProcessing bypass:**
```assembly
IRQ_WaitProcessing
.if DEBUG = 1
    ; DEBUG: Skip hardware wait, return immediate success
    CLC
    RTS
.else
    ; Normal hardware polling...
```

**Hatás:**
- Minden hardware polling azonnal sikerként tér vissza
- **NINCS** valós Arduino kommunikáció
- File operációk "színlelt" sikerrel visszatérnek

**SafeStreamImpl.s - Parameter Validation:**
```assembly
.if DEBUG = 1
SafeStream_Debug_Impl:
    CMP #0
    BEQ SafeStream_Error_Interval  ; BRK - VICE debugger megáll
    ; ...
```

**Hatás:**
- Érvénytelen paraméterek `BRK` utasítással állítják meg a futást
- VICE debuggerben azonnal látható a hiba helye
- Hibakód a képernyőn: `$01` (interval), `$02` (chunk), `$03` (delay)

### 4.2. KRITIKUS FIGYELMEZTETÉS

**⚠️ DEBUG=1 build SOHA NEM futtatható valós EasySD hardveren!**

**Miért?**
- Az `IRQ_WaitProcessing` bypass miatt a C64 **nem vár** az Arduino válaszra
- A memória unitializált marad vagy hibás adatokat tartalmaz
- A program "látszólag fut" de hibásan működik
- **Silent failure** - nehezen diagnosztizálható hibák

**Használati Útmutató:**
```bash
# VICE emulátorban (fejlesztés):
64tass -D DEBUG=1 EasySDMenu.s -o menu.prg

# Valós hardveren (production):
64tass -D DEBUG=0 EasySDMenu.s -o menu.prg
# VAGY egyszerűen:
64tass EasySDMenu.s -o menu.prg  (DEBUG alapértelmezetten 0)
```

### 4.3. Ajánlott Fejlesztési Workflow

1. **VICE-ban tesztelés** (DEBUG=1):
   - Gyors iteráció
   - Parameter validation aktív
   - Nincs szükség Arduino hardverre

2. **Production build** (DEBUG=0):
   - Valós hardware kommunikáció
   - EPROM programozás
   - Végső tesztelés fizikai C64-en

---

## 5. Konfigurációs Szabályok (Summary)

*   A **$80-$87** tartomány szent és sérthetetlen: kizárólag a `LoadFileBySize` használhatja.
*   A menü és a pluginok saját, ideiglenes változói a **$FB-$FE** (User range) tartományba kerülhetnek, de ezeket nem szabad a `CartZpMap.inc`-be tenni.
*   Ha egy új rutin ZP-t igényel, azt **kötelező** regisztrálni a `CartZpMap.inc` fájlban a konfliktusok elkerülése végett.
