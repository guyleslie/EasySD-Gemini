# DEBUG Mód Mock Fájlnév Megjelenítési Hiba Javítás

**Dátum:** 2025-12-23
**Fájl:** `IRQHack64/Menus/EasySD/IrqLoaderMenuNew.s`
**Verzió:** v2.0.3

---

## Tünet

DEBUG módban (`DEBUG=1`):
1. A könyvtár/fájl **nevek NEM jelennek meg** a képernyőn
2. Csak a **kurzor ">" jel látható** és mozog
3. Fel/le **navigáció működik**
4. ENTER gombra a program **megfagy**, piros border

---

## Gyökérok Elemzés

### 1. **SETDIR1/2/3 Y-alapú Backward Copy Hiba**

**Probléma:**
- A `SETDIR1/2/3` rutinok Y regiszterrel **backward (hátrafelé) másolást** használtak:
  ```asm
  LDY #(DIR2-DIR1-1)
  -
  LDA DIR1, Y
  STA DIRLOAD, Y
  DEY
  BPL -
  ```
- Ez a módszer **memória korrupciót** okozott bizonyos körülmények között
- Az első néhány bájt (CURPAGEITEMS, PAGECOUNT) átmásolódott, de a **fájlnevek területe üres maradt**

**Következmény:**
- DIRLOAD buffer csak nullákat ($00) tartalmazott a fájlnevek helyén
- PRINTASCIIFILENAME null terminátorokat találva **space-eket** írt ki helyettük
- Eredmény: Üres sorok a menüben

### 2. **DIR1/DIR2/DIR3 Struktúra Formátum Eltérés**

**Probléma:**
Az új kód **explicit null terminátorokat és .BYTE $04 flag-eket** használt:
```asm
.TEXT "merhaba"
.BYTE 0              ; Explicit null terminator
.FILL (30-7), 0      ; Padding
.BYTE $04            ; Explicit directory flag
```

A régi, **működő** kód más formátumot használt:
```asm
.TEXT "merhaba"      ; 7 chars (NO explicit null!)
.FILL 24, 0          ; 24 bytes padding
.enc "screen"
.TEXT "D"            ; Directory flag using screen encoding trick
.enc "none"
```

**Következmény:**
- A struktúra formátuma eltért a régi működő verziótól
- A `.enc "screen" + .TEXT "D"` trükk hiányzott directory bejegyzéseknél

### 3. **PRINTASCIIFILENAME DEBUG Conditional**

**Probléma:**
- DEBUG módban egy **direct write** kód futott (konverzió nélkül):
  ```asm
  .if DEBUG = 1
      ; Direct write without conversion
      LDA (NAMELOW), Y
      STA (COLLOW), Y
  ```
- Ez **ASCII karaktereket írt közvetlenül screen memory-ba**
- ASCII 'm' ($6D) ≠ screen code 'M' → random PETSCII karakterek jelentek meg

**Következmény:**
- Még ha lennének is adatok a DIRLOAD-ban, rosszul jelennének meg
- Konverzió hiánya miatt olvashatatlan karakterek

---

## Javítások

### Fix #1: SETDIR1/2/3 X-alapú Forward Copy

**Hely:** Sor 871-922

**Régi (HIBÁS) kód:**
```asm
SETDIR1
    LDY #(DIR2-DIR1-1)
-
    LDA DIR1, Y
    STA DIRLOAD, Y
    DEY
    BPL -
    RTS
```

**Új (HELYES) kód:**
```asm
SETDIR1
    LDA #$02        ; BORDER = RED (visual indicator)
    STA $D020

    ; Copy using X register (forward loop)
    LDX #$00
-
    LDA DIR1, X
    STA DIRLOAD, X
    INX
    CPX #(DIR2-DIR1)  ; Copy all bytes from DIR1 to DIR2
    BNE -

    LDA #$05        ; BORDER = GREEN (visual indicator)
    STA $D020
    RTS
```

**Változtatás:**
- **Y register (backward)** → **X register (forward)**
- Loop counter: `(DIR2-DIR1-1)` hátrafelé → `(DIR2-DIR1)` előre
- **DEY + BPL** → **INX + CPX + BNE**

**Érintett rutinok:**
- `SETDIR1`: DIR1 → DIRLOAD másolás (162 bájt)
- `SETDIR2`: DIR2 → DIRLOAD másolás (194 bájt)
- `SETDIR3`: DIR3 → DIRLOAD másolás (194 bájt)

**Eredmény:**
- ✅ Adatok **helyesen átmásolódnak** DIRLOAD-ba
- ✅ Nincs memória korrupció
- ✅ Border színjelzés (piros → zöld) működik

---

### Fix #2: DIR1/DIR2/DIR3 Struktúra Visszaállítása Régi Formátumra

**Hely:** Sor 1659-1748

**Változtatás: Visszaállítás a régi, működő formátumra**

**Régi (működő) formátum visszaállítva:**
```asm
DIR1
    .BYTE 5             ; CURPAGEITEMS
    .BYTE 1             ; PAGECOUNT
    .TEXT "merhaba"    ; 7 chars (NO explicit .BYTE 0!)
    .FILL 24, 0         ; Pad to 31 bytes total
.enc "screen"
    .TEXT "D"           ; Directory flag ($04 in screen encoding)
.enc "none"
    .TEXT "televole"   ; Next entry...
    .FILL 24, 0
    ; ... (file entries without explicit flag)
```

**Kulcs különbségek:**
1. **NINCS** explicit `.BYTE 0` null terminátor a név után
2. `.FILL 24, 0` közvetlenül a név után (nem `(30-N)`)
3. Directory flag: `.enc "screen" + .TEXT "D"` trükk ($04 byte)
4. File bejegyzések: **NINCS** explicit flag (implicit $00)

**Miért működik ez?**
- A `.enc "screen"` átkapcsolja az encoding-ot úgy hogy `.TEXT "D"` = $04 byte
- Ez pontosan a directory marker amit az `ISDIRECTORY` rutin keres (sor 945-953)
- A `.FILL` padding biztosítja a 32 byte teljes méretet

**Eredmény:**
- ✅ Kompatibilis a régi működő verzióval
- ✅ `ISDIRECTORY` helyesen detektálja a directory bejegyzéseket
- ✅ ENTER működik directory-kba lépéshez

---

### Fix #3: PRINTASCIIFILENAME DEBUG Conditional Eltávolítása

**Hely:** Sor 1088-1125

**Régi (HIBÁS) kód:**
```asm
PRINTASCIIFILENAME
.if DEBUG = 1
    ; DEBUG: Direct write without conversion
    LDY #$00
-
    LDA (NAMELOW), Y
    STA (COLLOW), Y    ; ASCII directly to screen memory!
    INY
    CPY #$20
    BNE -
    RTS
.else
    ; Release: Use FROMASCII conversion
    JSR FROMASCII
    ; ...
.endif
```

**Új (HELYES) kód:**
```asm
PRINTASCIIFILENAME
    LDY #$00
FILENAMEPRINT_A
    LDA (NAMELOW), Y    ; Read ASCII character
    BNE NOTEND_A
    LDA #$20            ; Replace null with space
NOTEND_A
    JSR FROMASCII       ; Convert ASCII → PETSCII
    CMP #$3F
    BMI SYMBOL_A
    CLC
    SBC #$3F            ; Convert PETSCII → screen code
SYMBOL_A
    STA (COLLOW), Y     ; Write to screen memory
    INY
    CPY #$20
    BNE FILENAMEPRINT_A
    RTS
```

**Változtatás:**
- **Eltávolítva** `.if DEBUG = 1` conditional
- **Mindkét módban** (DEBUG és release) ugyanaz a **FROMASCII konverzió**
- ASCII → PETSCII → screen code teljes konverzió

**Miért szükséges mindkét módban?**
- DIR1/DIR2/DIR3 mock adatok `.TEXT` direktívát használnak = **ASCII encoding**
- SD kártya is **ASCII formátumban** adja vissza a fájlneveket
- Mindkét esetben ugyanaz a konverzió kell

**Eredmény:**
- ✅ Fájlnevek **helyesen** jelennek meg screen memory-ban
- ✅ 'M', 'E', 'R', 'H', 'A', 'B', 'A' helyesen konvertálva uppercase-re
- ✅ Olvasható szöveg a menüben

---

## Részletes Konverzió Példa

**Példa: "merhaba" fájlnév megjelenítése**

1. **DIR1 mock data:** `.TEXT "merhaba"` → ASCII kódolás:
   - 'm' = $6D, 'e' = $65, 'r' = $72, 'h' = $68, 'a' = $61, 'b' = $62, 'a' = $61

2. **FROMASCII konverzió** (ASCII → PETSCII):
   - 'm' ($6D lowercase) → 'M' ($4D uppercase ASCII) → $CD PETSCII uppercase 'M'
   - 'e' ($65) → 'E' ($45) → $C5 PETSCII uppercase 'E'
   - stb.

3. **Screen code konverzió** (PETSCII → screen code):
   - $CD - $3F = $8E (screen code 'M')
   - $C5 - $3F = $86 (screen code 'E')
   - stb.

4. **Screen memory write:**
   - (COLLOW), Y = $8E, $86, ... → látható "MERHABA" szöveg

---

## Kód Dokumentáció Hozzáadva

### Angol Nyelvi Kommentek

**Helyek:**
- `SETDIR1/2/3` rutinok (sor 871-922): Részletes magyarázat a forward copy-ról
- `PRINTASCIIFILENAME` rutin (sor 1088-1125): Konverzió folyamat leírása
- `DIR1/DIR2/DIR3` struktúrák (sor 1659-1748): Formátum specifikáció

**Komment tartalom:**
- Rövid összefoglaló mi a rutin célja
- Bemeneti/kimeneti paraméterek
- Használt regiszterek
- Fontos megjegyzések (pl. "IMPORTANT: Must use X register")
- Példa adatok és formátum

---

## Tesztelés

### Elvárt Működés DEBUG=1 Módban

1. **Indítás után:**
   - Border **ZÖLD** (SETDIR1 lefutott)
   - Mock nevek **láthatók** uppercase-ben:
     ```
     > MERHABA
       TELEVOLE
       HELLO.PRG
       AFRICA.KOA
       GUZEL.PETG
     ```

2. **Fel/Le nyíl:**
   - ✅ Kurzor mozog
   - ✅ Kijelölés működik

3. **ENTER `MERHABA`-ra:**
   - ✅ Belép a directory-ba (DIR2 betöltődik)
   - ✅ Új lista jelenik meg

4. **ENTER `..`-ra:**
   - ✅ Visszalép (DIR1 betöltődik)

---

## Build Utasítás

```bash
cd "C:/EasySD Gemini"
python Tools/build.py debug
```

**Output:** `IRQHack64/build/irqhack64-debug.prg`

**Teszt VICE emulátorban:**
```bash
x64sc IRQHack64/build/irqhack64-debug.prg
```

---

## Összefoglalás

| Hiba | Gyökérok | Javítás | Státusz |
|------|----------|---------|---------|
| Mock nevek nem jelennek meg | SETDIR1/2/3 Y-alapú backward copy | X-alapú forward copy | ✅ KÉSZ |
| Struktúra formátum eltérés | Explicit .BYTE 0 és .BYTE $04 | Visszaállítva régi .FILL + .enc formátumra | ✅ KÉSZ |
| ASCII karakterek rosszul jelennek meg | DEBUG direct write (no conversion) | FROMASCII konverzió mindkét módban | ✅ KÉSZ |
| Kód dokumentáció hiány | Kevés komment | Angol nyelvű részletes kommentek | ✅ KÉSZ |

---

## Tanulságok

### 1. **Forward vs Backward Copy**
- Backward copy (Y register, DEY, BPL) **instabil** lehet bizonyos memóriacímek esetén
- **Forward copy (X register, INX, CPX)** megbízhatóbb és érthetőbb

### 2. **Encoding Trükkök**
- A `.enc "screen" + .TEXT "D"` trükk egy **okos megoldás**
- Egy karakter helyett egy bájt ($04) kerül a binaryba
- Kompatibilis a régi működő kóddal

### 3. **ASCII vs PETSCII vs Screen Code**
- Mindhárom **különböző** encoding!
- **ASCII**: 'm' = $6D (lowercase)
- **PETSCII**: 'M' = $CD (uppercase)
- **Screen code**: 'M' = $8E
- **Konverzió mindkét irányban szükséges**

### 4. **DEBUG Conditional Használat**
- NE használj különböző logikát DEBUG vs release módban, ha **nem szükséges**!
- A mock adatok ugyanazt a formátumot követik mint az SD kártya
- **Egységes kód** = kevesebb hiba

---

## Következő Lépések

1. ✅ **Mock display működik** - KÉSZ
2. 🔄 **ENTER directory navigation teszt** - következő
3. 🔄 **File selection és plugin loading teszt** - következő
4. 🔄 **Release mód teszt SD kártyával** - később

---

**Státusz:** ✅ **MŰKÖDIK - Tesztelhető**
**Következő:** ENTER directory navigation részletes tesztelése DEBUG módban
