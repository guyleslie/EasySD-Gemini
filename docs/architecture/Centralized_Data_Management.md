# Centralized Data Management for EasySD Gemini Project

Ez a dokumentum a jelenlegi EasySD kódbázis központosított adat- és címkezelési szabályait foglalja össze. A cél a build stabilitásának biztosítása, a Zero Page ütközések elkerülése és a karbantartható `64tass` include-lánc rögzítése. Ha eltérés van a dokumentum és a forrás között, a forrás az elsődleges.

---

## 1. Architekturális Alapelvek

A projekt a **"Linear Include Chain"** (Lineáris beágyazási lánc) elvét követi. Mivel a `64tass` nem támogatja a hagyományos C-stílusú include-guard-okat (`.ifndef`), a többszörös beágyazás "duplicate definition" hibát okoz.

### 1.1. A Lineáris Lánc felépítése
A szimbólumok a jelenlegi forrásban az alábbi sorrendben öröklődnek:
`CartLibStream.s` (wrapper)
  └── `CartZpMap.inc` (ZP definíciók)
  └── `CartLibHi.s` (high-level API)
      └── `CartLib.s` (low-level interface)
          └── `CartLibCommon.s` (alapvető rendszercímek)
              └── `Common/System.inc` (C64 hardver és KERNAL)
              └── `Common/EasySD.inc` (EasySD parancsok és státuszkódok)

Az API-makrók külön réteget alkotnak: az `APIMacros.s` nincs automatikusan ebbe a láncba kötve, ezért azt minden olyan fájlban explicit módon kell include-olni, amelyik használja a makróit.

### 1.2. Include Ownership (Tulajdonjog)
Ez jelenleg projektkonvenció, nem külön build-rendszer által kikényszerített szabályrendszer:
*   **`CartZpMap.inc`**: a normál include-láncon keresztül kerüljön be, ne közvetlenül több helyről.
*   **`CartLibCommon.s`**: a `CartLib.s` tulajdona, ne pluginból vagy menüből include-old közvetlenül.
*   **Pluginok/Menü**: a wrapper szintet include-olják (`CartLibStream.s`, illetve szükség szerint `APIMacros.s`), ne a lánc belső elemeit.

---

## 2. Központi Definíciós Fájlok

### 2.1. `System.inc` (C64 Standard)
Tartalmazza a Commodore 64 fix címeit. Aliasok helyett a kanonikus neveket használjuk:
*   **KERNAL Belépési pontok (ROM):** `K_OPEN` ($F34A), `K_CLOSE` ($F291), `K_CHKIN` ($F20E), `K_CHRIN` ($F157), `K_CLRCHN` ($F32F).
*   **KERNAL RAM Vektorok:** `V_OPEN` ($031A), `V_CLOSE` ($031C), `V_CHKIN` ($031E), `V_CLRCHN` ($0322), `V_CHRIN` ($0324).
*   **Hardver Regiszterek:** `VIC_CONTROL_1` ($D011), `VIC_INT_ACK` ($D019), `CIA_1_BASE` ($DC00), stb.
*   **Hardver Maszkok:** `VIC_DEN` ($10), `VIC_INT_RASTER` ($01).

### 2.2. `EasySD.inc` (Hardware API)
Az EasySD kártya specifikus parancsai és státuszkódjai:
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

**CartLibHi.s - `PROT_WaitProcessing` bypass:**
```assembly
PROT_WaitProcessing
.if DEBUG = 1
    CLC
    RTS
.else
    ; normal hardware polling
```

**Hatás:**
- A feldolgozási várakozás debug buildben azonnal sikeresnek látszik.
- Ez gyors VICE iterációt ad, de nem reprezentál valós Arduino kommunikációt.
- A dokumentum korábbi SafeStream-specifikus debug leírásai már nem számítanak jelenlegi, normatív viselkedésnek.

### 4.2. KRITIKUS FIGYELMEZTETÉS

**⚠️ DEBUG=1 build SOHA NEM futtatható valós EasySD hardveren!**

**Miért?**
- Az `PROT_WaitProcessing` bypass miatt a C64 **nem vár** az Arduino válaszra
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
    - cartridge ROML chip programozás
    - Végső tesztelés fizikai C64-en

---

## 5. Konfigurációs Szabályok (Summary)

*   A **$80-$87** tartomány szent és sérthetetlen: kizárólag a `LoadFileBySize` használhatja.
*   A menü és a pluginok saját, ideiglenes változói a **$FB-$FE** (User range) tartományba kerülhetnek, de ezeket nem szabad a `CartZpMap.inc`-be tenni.
*   Ha egy új rutin ZP-t igényel, azt **kötelező** regisztrálni a `CartZpMap.inc` fájlban a konfliktusok elkerülése végett.
